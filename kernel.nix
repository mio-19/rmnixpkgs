{
  lib,
  stdenv,
  fetchurl,
  fetchzip,
  bc,
  bison,
  dtc,
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

  # The stable chain's arm64 ioremap rework applies everywhere except this one
  # header hunk, which reMarkable's own ioremap_cache_ns() macro pushes out of
  # range; the patch header explains it and links upstream.
  ioHeaderBackport = ./kernel-ioremap-prot.patch;

  # gpio-mxc: two field widths and one local the chain left half-applied -- its
  # conversion hunks landed, the struct and declaration hunks did not. The
  # header lists both upstream levels.
  gpioBackports = ./kernel-gpio-mxc-backports.patch;

  # iw61x: the driver's own version guard for the set_monitor_channel argument
  # that 6.12.100 backported; see the patch header.
  iw61xMonitorChannel = ./kernel-iw61x-monitor-channel.patch;

  # The rest of the port: five places where a stable level changed an API or a
  # struct that its NXP counterpart in this tree still uses. Each file names its
  # level and why the hunk could not land in its header.
  resetControlFlags = ./kernel-reset-control-flags.patch;
  gpcv2Hsk = ./kernel-imx-gpcv2-gpumix-hsk.patch;
  imx8mErrata = ./kernel-imx8m-blk-ctrl-errata-field.patch;
  imx8mpPowerNb = ./kernel-imx8mp-blk-ctrl-power-nb.patch;
  opteeSupp = ./kernel-optee-supp-pop-entry.patch;
  stableLevels = lib.range stable.first stable.last;

  # One fetch per incremental patch, straight from where the stable
  # maintainers publish them; the hashes live in os.nix with the source pin.
  stablePatch =
    level:
    fetchurl {
      name = "patch-${baseVersion}.${toString (level - 1)}-${toString level}.xz";
      url = "https://cdn.kernel.org/pub/linux/kernel/v6.x/incr/patch-${baseVersion}.${toString (level - 1)}-${toString level}.xz";
      hash = stable.hashes.${toString level};
    };
  stablePatches = lib.optionals applyStablePatches (map stablePatch stableLevels);

  # 6.12.114 reworked the syscore API in one sweep and could not convert
  # reMarkable's NXP drivers, which left the tree inconsistent; the build applies
  # that level and then reverses it. The reversal uses the upstream patch from
  # kernel.org rather than a committed reversed copy: a 5000-line mirror of it
  # would drift, and reversing is mechanical. 114 is the level that carried the
  # rework, not a pin of the OS (os.nix owns `stable`). Only its syscore blocks
  # are reversed: 114 also carries unrelated fixes (io_uring, smart suspend)
  # that must stay.
  syscoreRework = stablePatch 114;
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
    dtc # `mkimage -f ferrari.its` shells out to dtc; scripts/dtc is not on PATH
    elfutils
    flex
    kmod # depmod
    openssl # sign-file / cert handling
    perl
    ubootTools # mkimage, for the fitImage
    xz # the stable patches are published as .xz and unpacked with `xz -dc`
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
          # `|| true` because stdenv runs the builder with `set -o pipefail`: a
          # patch that leaves .rej files without also printing FAILED lines (it
          # applied the rest with fuzz) makes this grep exit 1, which took the
          # whole build down in the middle of writing the report.
          grep -E 'FAILED|can.t find file to patch' "$TMPDIR/stable/log" | sed 's/^/         /' >> "$TMPDIR/stable/report" || true
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

      # The one rejected hunk that is not merely a missing driver fix: without
      # it io.h calls __ioremap_prot() undeclared and nothing compiles. Must
      # apply, so a failure here is a build failure, not a report line.
      patch -p1 < ${ioHeaderBackport}
      printf 'backport %s\n' 'arm64 ioremap (patch-6.12.92-93, patch-6.12.111-112)' >> "$TMPDIR/stable/report"

      # 6.12.114 reworked the syscore API across the tree. reMarkable's NXP
      # drivers (irq-gic-v3, imx-gpcv2, gpio-vf610, pinctrl-imx, scu-pd) were
      # not converted -- their hunks found no context -- which leaves the header
      # at the new API and those callers at the old one, and nothing compiles.
      # Take the rework back out: it is a refactor, not a security fix. Failures
      # here are expected (the very files it could not patch) and are not an
      # error; --forward keeps it from applying anything twice.
      #
      # Only the diff blocks that use the syscore API are reversed. 114 is a
      # stable release, so it also carries unrelated fixes (io_uring, smart
      # suspend) that must stay applied; those blocks are exactly the files the
      # rework touched.
      xz -dc ${syscoreRework} > "$TMPDIR/stable/114.patch"
      awk '/^diff --git / { if (buf != "" && buf ~ /syscore_ops/) printf "%s", buf; buf = "" }
           { buf = buf $0 ORS }
           END { if (buf ~ /syscore_ops/) printf "%s", buf }' \
        "$TMPDIR/stable/114.patch" > "$TMPDIR/stable/114-syscore.patch"
      patch -R -p1 --batch --forward < "$TMPDIR/stable/114-syscore.patch" > "$TMPDIR/stable/syscore-revert.log" 2>&1 || true
      printf 'reverted %s\n' 'syscore API rework (patch-6.12.113-114)' >> "$TMPDIR/stable/report"

      # The chain converted gpio-mxc to bitops but its struct hunk (both_edges
      # and wakeup_pads to unsigned long) found no context, and the is_imx8qm
      # local it uses was added by a hunk that also touched a pad_type_map entry
      # this tree already has. Must apply.
      patch -p1 < ${gpioBackports}
      printf 'backport %s\n' 'gpio-mxc field widths and is_imx8qm (patch-6.12.80-81, 114-115)' >> "$TMPDIR/stable/report"

      # 6.12.100 backported cfg80211's net_device argument for
      # set_monitor_channel (a 6.13 API change), but the NXP driver still gates
      # that argument on 6.13. Must apply.
      patch -p1 < ${iw61xMonitorChannel}
      printf 'backport %s\n' 'iw61x set_monitor_channel guard (patch-6.12.100-101)' >> "$TMPDIR/stable/report"

      # The remaining API/struct drift the chain left in NXP code: reset flags,
      # a gpcv2 parent handshake, two pmdomain structs and optee's supplicant.
      # Each patch is the missing semantic change only; see the headers.
      for extra in ${resetControlFlags} ${gpcv2Hsk} ${imx8mErrata} ${imx8mpPowerNb} ${opteeSupp}; do
        patch -p1 < "$extra"
        printf 'port     %s\n' "$(basename "$extra")" >> "$TMPDIR/stable/report"
      done
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

    # buildPhase leaves the shell inside the copied tree, and `cd kernel` from
    # there lands in the source's own kernel/ subdirectory, so name the tree
    # absolutely instead of relying on where the previous phase stopped.
    cd "$NIX_BUILD_TOP"/kernel

    install -Dm644 fitImage $out/fitImage
    install -Dm644 arch/arm64/boot/Image $out/Image

    # Device trees, including the patched imx8mm-ferrari one.
    mkdir -p $out/dtbs
    # `-exec cp {} $out/dtbs/ +` is rejected by GNU findutils 4.11 with
    # "missing argument to `-exec'" (the + is read as an argument, not the
    # terminator); `cp -t` keeps the directory out of the {} position.
    find arch/arm64/boot/dts -name '*.dtb' -exec cp -t $out/dtbs/ {} +

    # modules_install links each module tree's `build`/`source` at the build
    # directory, which is absolute and does not exist afterwards; fixupPhase
    # rejects the dangling link, and on the tablet it would point at nothing.
    # depmod already ran, and nothing at runtime reads them.
    rm -f $out/lib/modules/*/build $out/lib/modules/*/source

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
      install -Dm644 ${ioHeaderBackport} $out/share/rmpp-kernel/ioremap-prot-backport.patch
      install -Dm644 ${gpioBackports} $out/share/rmpp-kernel/gpio-mxc-backports.patch
      install -Dm644 ${iw61xMonitorChannel} $out/share/rmpp-kernel/iw61x-monitor-channel.patch
      install -Dm644 ${resetControlFlags} $out/share/rmpp-kernel/reset-control-flags.patch
      install -Dm644 ${gpcv2Hsk} $out/share/rmpp-kernel/imx-gpcv2-gpumix-hsk.patch
      install -Dm644 ${imx8mErrata} $out/share/rmpp-kernel/imx8m-blk-ctrl-errata-field.patch
      install -Dm644 ${imx8mpPowerNb} $out/share/rmpp-kernel/imx8mp-blk-ctrl-power-nb.patch
      install -Dm644 ${opteeSupp} $out/share/rmpp-kernel/optee-supp-pop-entry.patch
      # The exact subset of the 6.12.114 patch that the build reversed, derived
      # from it at build time; the source level is named in the report.
      install -Dm644 "$TMPDIR/stable/114-syscore.patch" $out/share/rmpp-kernel/syscore-revert.patch
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
