{
  lib,
  stdenv,
  fetchurl,
  fetchzip,
  bc,
  bison,
  elfutils,
  flex,
  kmod,
  openssl,
  perl,
  ubootTools,
  xz,
  os,
  kernelVersion,
  applyStablePatches,
  configFragment,
  gpuDeviceTreePatch,
}:

# reMarkable OS kernel for the Paper Pro (ferrari), rebuilt with
#
#   * the Android/Waydroid requirements, and
#   * the Vivante GPU driver, which the stock OS never exposes to userland.
#
# Adapted from https://github.com/MaximeRivest/android-on-remarkable-paper-pro
# (`kernel/build-kernel.sh` recipe, `kernel/waydroid.cfg` and
# `kernel/gpu-etnaviv-dt.patch`, the last two passed in verbatim from the pinned
# flake input). Their script needs the binary Yocto SDK and cross-compiles; this
# is the same source and the same configure steps, built natively for
# aarch64-linux by nixpkgs' own gcc. The source pin is not in this file: it
# comes from `os` (os.nix), because reMarkable tracks one source branch per OS
# release and the OS version is declared in exactly one place.
#
# WHY THE GPU MATTERS: stock reMarkable OS ships no GPU driver at all — no
# render node, no etnaviv module, no EGL/GLES/GBM — which is why
# https://github.com/exp78/rmweb/blob/master/docs/device-profile.md records
# "GPU present on die, but no stock driver ... all rendering is CPU" and why
# rmweb renders with Mesa llvmpipe. `gpu-etnaviv-dt.patch` retargets the i.MX8MM
# gpu@38000000 node to `compatible = "vivante,gc"` and enables it; the config
# fragment then builds CONFIG_DRM_ETNAVIV=m, so Mesa's etnaviv driver gets a
# render node to talk to.
#
# SECURITY UPDATES: reMarkable's branch is frozen at 6.12.49, so after the GPU
# patch this also applies the upstream stable chain pinned in os.nix
# (`kernel.stable`) — the same files kernel.org publishes at
# https://cdn.kernel.org/pub/linux/kernel/v6.x/incr/ . `applyStablePatches`
# (`rmpp.kernel.securityPatches.enable`) turns that off; `kernelVersion` is what
# default.nix recorded for the resulting tree either way.
let
  baseVersion = lib.versions.majorMinor os.kernel.version;
  stable = os.kernel.stable;
  stableLevels = lib.range stable.first stable.last;

  # One fetch per incremental patch, straight from where the stable
  # maintainers publish them; the hashes live in os.nix with the source pin.
  stablePatches = lib.optionals applyStablePatches (
    map (
      level:
      fetchurl {
        name = "patch-${baseVersion}.${toString (level - 1)}-${toString level}.xz";
        url = "https://cdn.kernel.org/pub/linux/kernel/v6.x/incr/patch-${baseVersion}.${toString (level - 1)}-${toString level}.xz";
        hash = stable.hashes.${toString level};
      }
    ) stableLevels
  );
in
assert lib.assertMsg
  (!applyStablePatches || lib.toInt (lib.versions.patch os.kernel.version) + 1 == stable.first)
  "os.nix: kernel.stable.first must be one past the pinned kernel's sublevel (e.g. 6.12.49 -> 50), or the chain starts from the wrong base";
assert lib.assertMsg
  (
    !applyStablePatches || lib.all (level: builtins.hasAttr (toString level) stable.hashes) stableLevels
  )
  "os.nix: kernel.stable.hashes is missing a level; a missing hash would silently drop a security fix";
stdenv.mkDerivation (finalAttrs: {
  pname = "rmpp-kernel";
  # What the tree actually is: the vendor version, or the stable level the chain
  # reaches when it is enabled. default.nix records the same string in the
  # configuration generation, and activation compares `uname -r` against it.
  version = kernelVersion;

  # reMarkable's published GPL source, tracked with git LFS. The pin (branch,
  # file, hashes) lives in os.nix:
  #
  #   url   https://media.githubusercontent.com/media/reMarkable/linux-imx-rm/<branch>/<file>
  #   hash  the unpacked tree, which is what fetchzip pins
  #
  # os.kernel.tarballSha256 is the tarball itself, for cross-checking a
  # re-download against
  # https://github.com/skdlzlvk/paper-pro-move-dualboot-installer/blob/main/docs/KERNEL-SOURCE.md .
  #
  # Version lock: this is the rmpp_6.12.49_v3.27.x branch, the source for OS
  # 3.28. On a newer reMarkable OS, point os.nix at the matching branch tarball
  # from https://github.com/reMarkable/linux-imx-rm and rebuild.
  src = fetchzip {
    url = "https://media.githubusercontent.com/media/reMarkable/linux-imx-rm/${os.kernel.branch}/${os.kernel.file}";
    hash = os.kernel.hash;
  };

  # Unpacked by fetchzip already; the build copies it because the store is
  # read-only and the kernel build writes next to its sources.
  dontUnpack = true;

  nativeBuildInputs = [
    bc
    bison
    elfutils
    flex
    kmod # depmod
    openssl # sign-file / cert handling
    perl
    ubootTools # mkimage, for the fitImage
  ];

  # The gcc wrapper's hardening flags do not survive a kernel build.
  hardeningDisable = [ "all" ];
  NIX_CFLAGS_COMPILE = "";
  NIX_LDFLAGS = "";

  # The kernel brings its own stripping/section layout, and .ko files must not
  # be touched by fixupPhase.
  dontStrip = true;
  dontPatchELF = true;
  dontPatchShebangs = true;
  separateDebugInfo = false;

  buildPhase = ''
    runHook preBuild

    cp -a ${finalAttrs.src} kernel
    chmod -R u+w kernel
    cd kernel

    # Kernel build helpers are #!/bin/sh scripts and the sandbox has no /bin/sh.
    patchShebangs scripts

    ${lib.optionalString applyStablePatches ''
      # Upstream stable (security) fixes, pinned in os.nix, applied to
      # reMarkable's tree before anything else. GNU patch rather than
      # `git apply`, because this tree is an NXP release: upstream context has
      # drifted, and a hunk the vendor already carries must be skipped
      # (--forward) instead of reversed or refused. --fuzz=2 tolerates the
      # remaining line-number drift.
      #
      # Best-effort by design: a hunk with no matching context is recorded and
      # shipped with the build rather than pretending it applied or refusing to
      # build at all. `rmpp.kernel.securityPatches.enable = false` in config.nix
      # builds the vendor tree exactly as published.
      mkdir -p "$TMPDIR/stable"
      : > "$TMPDIR/stable/report"
      : > "$TMPDIR/stable/rejects"
      n_clean=0
      n_partial=0
      n_rejected=0
      for patch_file in ${lib.concatStringsSep " " (map toString stablePatches)}; do
        patch_name=$(basename "$patch_file" .xz)
        xz -dc "$patch_file" > "$TMPDIR/stable/one.patch"
        patch -p1 --batch --forward --fuzz=2 < "$TMPDIR/stable/one.patch" > "$TMPDIR/stable/log" 2>&1 || true
        rejected_files=$(find . -name '*.rej' | sort)
        if [ -z "$rejected_files" ] && ! grep -qE 'FAILED|can.t find file to patch' "$TMPDIR/stable/log"; then
          n_clean=$((n_clean + 1))
          printf 'applied  %s\n' "$patch_name" >> "$TMPDIR/stable/report"
        else
          n_partial=$((n_partial + 1))
          printf 'partial  %s\n' "$patch_name" >> "$TMPDIR/stable/report"
          for rejected in $rejected_files; do
            n_rejected=$((n_rejected + 1))
            printf '         rejected %s\n' "$rejected" >> "$TMPDIR/stable/report"
            printf '%s %s\n' "$patch_name" "$rejected" >> "$TMPDIR/stable/rejects"
          done
          grep -E 'FAILED|can.t find file to patch' "$TMPDIR/stable/log" | sed 's/^/         /' >> "$TMPDIR/stable/report"
          find . -name '*.rej' -delete
        fi
      done

      printf 'rmpp-kernel: stable %s.%s: %s patch(es) applied cleanly, %s partial, %s rejected hunk(s)\n' \
        '${baseVersion}' '${toString stable.last}' "$n_clean" "$n_partial" "$n_rejected" >&2
      if [ "$n_rejected" -gt 0 ]; then
        printf 'rmpp-kernel: warning: those hunks have no matching context in reMarkable\047s tree; they are listed in\n' >&2
        printf 'rmpp-kernel: warning: share/rmpp-kernel/security-patch-rejects. Set\n' >&2
        printf 'rmpp-kernel: warning: rmpp.kernel.securityPatches.enable = false for the vendor tree as published.\n' >&2
      fi

      # The whole point of the chain is to reach <baseVersion>.<last>: if the
      # Makefile did not move there, the base tree or the pin is wrong, and the
      # build would otherwise claim a version it is not.
      tree_version=$(sed -n 's/^VERSION = //p' Makefile).$(sed -n 's/^PATCHLEVEL = //p' Makefile).$(sed -n 's/^SUBLEVEL = //p' Makefile)
      if [ "$tree_version" != '${baseVersion}.${toString stable.last}' ]; then
        printf 'rmpp-kernel: error: tree is at %s, expected ${baseVersion}.${toString stable.last}\n' "$tree_version" >&2
        printf 'rmpp-kernel: the pinned source and os.nix kernel.stable disagree; see os.nix\n' >&2
        exit 1
      fi
    ''}

    # Upstream step 1: enable the Vivante GPU in the device tree.
    patch -p1 -N < ${gpuDeviceTreePatch}

    # Upstream step 2: ferrari_defconfig, then the additive Android fragment
    # (merge_config keeps existing values, so this cannot disable stock options).
    make ARCH=arm64 ferrari_defconfig
    KCONFIG_CONFIG=.config bash scripts/kconfig/merge_config.sh -m -O . .config ${configFragment}
    make ARCH=arm64 olddefconfig

    make ARCH=arm64 -j''${NIX_BUILD_CORES:-1} Image dtbs modules

    make ARCH=arm64 INSTALL_MOD_STRIP=1 INSTALL_MOD_PATH=$out modules_install
    release=$(make -s ARCH=arm64 kernelrelease)
    depmod -b $out "$release"

    # Upstream step 3: the fitImage. ferrari.its ships inside the tarball and
    # refers to arch/... relatively, which is why this builds in-tree.
    mkimage -f ferrari.its fitImage

    runHook postBuild
  '';

  installPhase = ''
    runHook preInstall
    cd kernel

    install -Dm644 fitImage $out/fitImage
    install -Dm644 arch/arm64/boot/Image $out/Image

    # Device trees, including the patched imx8mm-ferrari one.
    mkdir -p $out/dtbs
    find arch/arm64/boot/dts -name '*.dtb' -exec cp {} $out/dtbs/ +

    # The shape upstream's install-kernel.sh expects (it ships in
    # rmpp_android_files): fitImage plus modules-<release>.tar.gz.
    release=$(make -s ARCH=arm64 kernelrelease)
    tar -C $out/lib/modules -czf $out/modules-$release.tar.gz "$release"

    # Audit trail: the exact configuration and fragments that went in.
    install -Dm644 .config $out/share/rmpp-kernel/config
    install -Dm644 ferrari.its $out/share/rmpp-kernel/ferrari.its
    install -Dm644 ${configFragment} $out/share/rmpp-kernel/waydroid.cfg
    install -Dm644 ${gpuDeviceTreePatch} $out/share/rmpp-kernel/gpu-etnaviv-dt.patch
    ${lib.optionalString applyStablePatches ''
      # Audit trail for the stable chain: what applied, and every hunk that did
      # not (so a missing security fix is visible on the device, not implied).
      install -Dm644 "$TMPDIR/stable/report" $out/share/rmpp-kernel/security-patches
      install -Dm644 "$TMPDIR/stable/rejects" $out/share/rmpp-kernel/security-patch-rejects
    ''}

    runHook postInstall
  '';

  meta = {
    description = "reMarkable Paper Pro kernel with Waydroid requirements and the etnaviv GPU driver";
    longDescription = ''
      reMarkable's published GPL kernel source for the Paper Pro (ferrari),
      rebuilt with the Android/Waydroid configuration fragment and the Vivante
      GPU device-tree patch from android-on-remarkable-paper-pro. The stock OS
      exposes no GPU; this kernel gives Mesa's etnaviv driver a render node.
      Source pin and version come from os.nix, so the kernel always matches the
      declared OS release. On top of that tree the upstream stable (security)
      fixes pinned in os.nix are applied, unless
      rmpp.kernel.securityPatches.enable is off; the build reports which hunks
      the vendor tree could not take. Reinstall after every reMarkable OS
      update, and back up the stock fitImage first.
    '';
    homepage = "https://github.com/reMarkable/linux-imx-rm";
    license = lib.licenses.gpl2Only;
    platforms = [ "aarch64-linux" ];
  };
})
