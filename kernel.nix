{
  lib,
  stdenv,
  fetchzip,
  bc,
  bison,
  elfutils,
  flex,
  kmod,
  openssl,
  perl,
  ubootTools,
  os,
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
stdenv.mkDerivation (finalAttrs: {
  pname = "rmpp-kernel";
  version = os.kernel.version;

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
      declared OS release. Reinstall after every reMarkable OS update, and back
      up the stock fitImage first.
    '';
    homepage = "https://github.com/reMarkable/linux-imx-rm";
    license = lib.licenses.gpl2Only;
    platforms = [ "aarch64-linux" ];
  };
})
