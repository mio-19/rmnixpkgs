# Everything this flake ships for the reMarkable Paper Pro (ferrari, aarch64).
#
# The tree is flat on purpose — every file here is about the Paper Pro:
#   os.nix            the target reMarkable OS release: ABI + kernel source pin
#   aarch64-pkgs.nix  native aarch64-linux package set (the cache.nixos.org trick)
#   wpewebkit.nix     WPE WebKit 2.48.5, the browser engine
#   rmweb.nix         the rmweb browser app, built from source
#   kernel.nix        reMarkable's kernel + Waydroid needs + etnaviv GPU driver
#   system.nix/config.nix/activate.sh
#                     declarative configuration: module, device config, activation
#   nix-setup.sh      device-side persistent-store setup script
{ inputs }:
{
  perSystem =
    {
      pkgs,
      lib,
      config,
      ...
    }:
    let
      rmppPkgs = import ./aarch64-pkgs.nix pkgs;
      upstream = inputs.android-on-remarkable-paper-pro;

      # The OS release registry (os.nix) holds the definitions for supported
      # reMarkable OS releases (3.27, 3.28), ABI, and kernel source pins.
      osRegistry = import ./os.nix;

      # Command line tools that are useful on the tablet itself. Syncthing is
      # the well-trodden way to get files on and off a Paper Pro (headless
      # daemon, web UI from another machine); the rest are quality of life.
      cliTools = with rmppPkgs; [
        syncthing
        tmux
        htop
        rsync
        strace
      ];

      # Declarative configuration layer (system.nix + config.nix), in the spirit
      # of https://github.com/numtide/system-manager: a module describes the
      # device, evaluation produces a generation, activate.sh applies it and a
      # boot unit re-applies it because /etc is a tmpfs overlay.
      mkConfig =
        osForConfig: rmppKernel:
        lib.evalModules {
          modules = [
            ./system.nix
            ./config.nix
          ];
          specialArgs = {
            inherit lib;
            os = osForConfig;
            pkgs = rmppPkgs;
            rmppAndroid = config.packages.rmpp_android;
            rmppAndroidIcon = "${upstream}/device/icon.png";
            rmppChromium = config.packages.rmpp_chromium;
            rmppChromiumIcon = "${config.packages.rmpp_chromium.src}/chromium/icon.png";
            rmppWikipedia = config.packages.rmpp_wikipedia;
            inherit rmppKernel;
          };
        };

      # Two-phase evaluation:
      # 1. Base evaluation using the default OS release to read configuration
      #    switches (`rmpp.os.version` to pick the target OS release 3.27/3.28,
      #    and `rmpp.kernel.securityPatches.enable` for upstream stable patches).
      # 2. Second evaluation with the exact target OS and kernel version, producing
      #    the generation that gets built and activated ($out/os and $out/kernel).
      baseConfig = mkConfig osRegistry.default null;
      targetVersion = baseConfig.config.rmpp.os.version;
      os = osRegistry.forVersion targetVersion;
      applyStablePatches = baseConfig.config.rmpp.kernel.securityPatches.enable;
      kernelVersion =
        if applyStablePatches then
          "${lib.versions.majorMinor os.kernel.version}.${toString os.kernel.stable.last}"
        else
          os.kernel.version;

      mkKernel =
        osForKernel:
        let
          kv =
            if applyStablePatches then
              "${lib.versions.majorMinor osForKernel.kernel.version}.${toString osForKernel.kernel.stable.last}"
            else
              osForKernel.kernel.version;
        in
        rmppPkgs.callPackage ./kernel/kernel.nix {
          # Use GCC 13 matching the device's native Yocto scarthgap toolchain (GCC 13.4.0)
          # to avoid experimental GCC 16 codegen/relocation breakages in arm64 early boot.
          stdenv = rmppPkgs.gcc13Stdenv;
          os = osForKernel;
          inherit applyStablePatches;
          kernelVersion = kv;
          configFragment = "${upstream}/kernel/waydroid.cfg";
          gpuDeviceTreePatch = "${upstream}/kernel/gpu-etnaviv-dt.patch";
        };

      rmpp_kernel = mkKernel os;
      rmpp_kernel_3_27 = mkKernel osRegistry.releases."3.27";
      rmpp_kernel_3_28 = mkKernel osRegistry.releases."3.28";

      rmppConfig = mkConfig (
        if applyStablePatches then
          (
            os
            // {
              kernel = os.kernel // {
                version = kernelVersion;
              };
            }
          )
        else
          os
      ) rmpp_kernel;

      # Device-side files from
      # https://github.com/MaximeRivest/android-on-remarkable-paper-pro
      # (MIT), verbatim from the pinned flake input: kernel config fragment and
      # GPU DT patch, session/takeover scripts, systemd units, Android theme.
      # They run on the tablet under BusyBox/gash, not on the build host, so no
      # shebang rewriting.
      androidFiles = pkgs.stdenvNoCC.mkDerivation {
        pname = "rmpp-android-files";
        version = upstream.shortRev or upstream.rev or "unstable";
        src = upstream;

        dontBuild = true;
        dontPatchShebangs = true;

        installPhase = ''
          runHook preInstall
          install -d $out/share/rmpp-android
          cp -a kernel device chroot android einkbridge README.md LICENSE $out/share/rmpp-android/
          runHook postInstall
        '';

        meta = {
          description = "Device-side files from android-on-remarkable-paper-pro";
          homepage = "https://github.com/MaximeRivest/android-on-remarkable-paper-pro";
          license = lib.licenses.mit;
          platforms = lib.platforms.all;
        };
      };
    in
    {
      formatter = pkgs.nixfmt;

      # Run in the native aarch64-linux builder (OrbStack); none needs a tablet.
      checks = lib.optionalAttrs pkgs.stdenv.hostPlatform.isLinux {
        # activate.sh ownership rules against a fake vellum CLI and AppLoad dir.
        rmpp_activation =
          rmppPkgs.runCommand "rmpp-activation-check"
            {
              nativeBuildInputs = [ rmppPkgs.python3 ];
              src = lib.fileset.toSource {
                root = ./.;
                fileset = lib.fileset.unions [
                  ./activate.sh
                  ./test-activation.py
                ];
              };
            }
            ''
              python3 $src/test-activation.py 2>&1 | tee $out
            '';
        rmpp_android_controller =
          rmppPkgs.runCommand "rmpp-android-controller-check"
            {
              nativeBuildInputs = [ rmppPkgs.python3 ];
              src = lib.fileset.toSource {
                root = ./.;
                fileset = lib.fileset.unions [
                  ./android/android.py
                  ./android/test-android.py
                ];
              };
            }
            ''
              python3 $src/android/test-android.py 2>&1 | tee $out
            '';
        rmpp_quill_boundary =
          rmppPkgs.runCommandCC "rmpp-quill-boundary-check"
            {
              nativeBuildInputs = [
                rmppPkgs.pkg-config
                rmppPkgs.python3
              ];
              buildInputs = [ config.packages.rmpp_quill.qtbase ];
            }
            ''
              $CXX -fPIC -shared ${./bridge/test-quill-vendor.cpp} $(pkg-config --cflags --libs Qt6Core Qt6Gui) -o vendor.so
              TEST_REAL_QUILL=1 LD_LIBRARY_PATH=${
                lib.makeLibraryPath [
                  config.packages.rmpp_quill.qtbase
                  rmppPkgs.stdenv.cc.cc.lib
                ]
              } \
                python3 ${./bridge/test-quill-host.py} ${rmppPkgs.glibc}/lib/ld-linux-aarch64.so.1 \
                  ${config.packages.rmpp_einkbridge}/libexec/rmpp-quill-host "$PWD/vendor.so" \
                  ${config.packages.rmpp_quill}/lib/libquill.so > $out
            '';
        rmpp_einkbridge_session =
          rmppPkgs.runCommand "rmpp-einkbridge-session-check"
            {
              nativeBuildInputs = [
                rmppPkgs.python3
                rmppPkgs.swaybg
              ];
            }
            ''
              sh ${./bridge/test-einkbridge-session.sh} ${config.packages.rmpp_android_tools} ${config.packages.rmpp_einkbridge} > $out
            '';
        # Validate the actual kernel output; successful compilation alone does
        # not prove that olddefconfig retained Android's required settings.
        rmpp_waydroid_kernel =
          rmppPkgs.runCommand "rmpp-waydroid-kernel-check"
            {
              nativeBuildInputs = [
                rmppPkgs.python3
                rmppPkgs.dtc
              ];
            }
            ''
              python3 ${./kernel/check-waydroid-kernel.py} ${upstream}/kernel/waydroid.cfg ${rmpp_kernel} > $out
            '';
        rmpp_waydroid_runtime = rmppPkgs.runCommand "rmpp-waydroid-runtime-check" { } ''
          sh ${./android/check-waydroid-runtime.sh} ${config.packages.rmpp_android_tools} > $out
        '';
      };

      packages = {
        # Device-side helper for a persistent Nix store at /nix, bind mounted
        # from /home/root/nix. See remarkable-paper-pro.md.
        # nix build .#rmpp_nix_setup -o rmpp-nix-setup
        rmpp_nix_setup = pkgs.stdenvNoCC.mkDerivation {
          pname = "rmpp-nix-setup";
          version = "1";

          src = ./nix-setup.sh;
          dontUnpack = true;

          # Keep the #!/bin/sh shebang: this runs on the tablet, not on the
          # build host, so a nix store bash path would be wrong.
          dontPatchShebangs = true;
          installPhase = ''
            runHook preInstall
            install -Dm755 $src $out/bin/rmpp-nix-setup
            runHook postInstall
          '';

          meta = {
            description = "Set up a persistent Nix store on a reMarkable Paper Pro";
            platforms = lib.platforms.all;
          };
        };
      }
      # The payload is aarch64-linux, which only a Linux host can build or
      # substitute for the tablet (see the extra-platforms note in flake.nix).
      // lib.optionalAttrs pkgs.stdenv.hostPlatform.isLinux {
        # nix build .#rmpp_tools -o rmpp-tools
        # nix copy --to ssh://root@10.11.99.1 ./rmpp-tools
        rmpp_tools = pkgs.symlinkJoin {
          name = "rmpp-tools";
          paths = cliTools;
          pathsToLink = [ "/bin" ];
          meta = {
            description = "Command line tools for the reMarkable Paper Pro";
            # The symlink tree itself builds anywhere; the tools it points at
            # are aarch64-linux derivations.
            platforms = lib.platforms.all;
          };
        };

        # The browser from source: rmweb's Qt app (browser/rmweb.nix) against a WPE
        # WebKit compiled here from the wpewebkit.org tarball (browser/wpewebkit.nix),
        # instead of upstream's prebuilt release bundle.
        # nix build .#rmpp_rmweb
        rmpp_rmweb = rmppPkgs.callPackage ./browser/rmweb.nix {
          wpewebkit = rmppPkgs.callPackage ./browser/wpewebkit.nix { };
        };

        # Upstream's release bundle (https://github.com/exp78/rmweb), unchanged
        # from what this repository shipped before the flake. Kept deliberately:
        # it links against the device's own Qt 6.10.3 and so renders through
        # libepaper.so today, while the nixpkgs-Qt build above has no display
        # path until the source build renders on device (see TODO.md). Keep it
        # for now: that is still the artifact that actually displays today.
        # nix build .#rmpp_rmweb_prebuilt -o rmweb-bundle
        # Bump: set `version` to the new tag, then take the asset URL below and
        #   nix store prefetch-file --hash-type sha256 <url>
        # and paste the returned SRI hash.
        rmpp_rmweb_prebuilt = pkgs.stdenvNoCC.mkDerivation (finalAttrs: {
          pname = "rmweb";
          version = "0.9.7";

          src = pkgs.fetchurl {
            url = "https://github.com/exp78/rmweb/releases/download/v${finalAttrs.version}/rmweb-${finalAttrs.version}.tar.gz";
            hash = "sha256-jfPkIO8CmSt55UitbdccjIMkumQekkd+e9KHB5UsPo4=";
          };

          # The bundle unpacks at the top level (bin/, lib/, install.sh, ...)
          # rather than into a single rmweb-<version> directory.
          sourceRoot = ".";

          # The tree runs on the tablet, not on the build host: keep the
          # #!/bin/sh shebangs (BusyBox ash), the aarch64 ELFs and their
          # $ORIGIN RPATHs exactly as shipped.
          dontPatchShebangs = true;
          dontStrip = true;
          dontPatchELF = true;
          dontBuild = true;

          installPhase = ''
            runHook preInstall
            # The release was rolled on macOS, so the archive is littered with
            # AppleDouble metadata files; they are noise on the device.
            find . -name '._*' -delete
            mkdir -p $out
            mv ./* $out/
            runHook postInstall
          '';

          meta = {
            description = "WPE WebKit e-ink browser for the reMarkable Paper Pro (upstream release bundle)";
            homepage = "https://github.com/exp78/rmweb";
            license = lib.licenses.mit;
            platforms = lib.platforms.all;
            sourceProvenance = with lib.sourceTypes; [ binaryNativeCode ];
          };
        });

        # The Waydroid runtime adapted from
        # https://github.com/MaximeRivest/android-on-remarkable-paper-pro:
        # Waydroid plus the headless compositor it renders into, all
        # nixpkgs aarch64-linux packages that cache.nixos.org already serves
        # (no SDK, no cross compiler), with upstream's device files alongside.
        # Mesa is here for the tablet's Vivante GPU, which only works once
        # rmpp_kernel (kernel/kernel.nix) is installed.
        # rmpp_android below layers the session controller and bridge on it.
        rmpp_android_tools = pkgs.buildEnv {
          name = "rmpp-android-tools";
          paths =
            (with rmppPkgs; [
              waydroid
              labwc
              # labwc already links its matching wlroots from the closure.
              # Direct tools used by upstream device/session.sh and enter.sh:
              # https://github.com/MaximeRivest/android-on-remarkable-paper-pro/tree/65b5bf34fb3ef160e3d483a14484b46304ecbc7c/device
              seatd
              wlr-randr
              dbus
              bash
              coreutils
              util-linux
              procps
              iproute2
              iptables
              dnsmasq
              kmod
              lxc
              wayland-utils
              mesa
            ])
            ++ [ androidFiles ];
          # /lib is here for mesa's DRI drivers and glvnd vendor files: the
          # compositor finds them under $env/lib, not in a device path.
          pathsToLink = [
            "/bin"
            "/lib"
            "/share"
          ];
          meta = {
            description = "Waydroid, compositor and container tools used by rmpp_android";
            homepage = "https://github.com/MaximeRivest/android-on-remarkable-paper-pro";
            license = lib.licenses.mit;
            platforms = lib.platforms.all;
          };
        };

        # The original einkbridge Rust entry points are absent from the pinned
        # upstream (and its forks), see
        # https://github.com/MaximeRivest/android-on-remarkable-paper-pro/issues/1
        # Our replacement bridge/session implementation is in bridge/einkbridge.c
        # and android/android.py; upstream scripts remain reference material only.
        # nix build .#rmpp_android -o rmpp-android
        # nix copy --to 'ssh://root@10.11.99.1?remote-program=/nix/var/nix/profiles/default/bin/nix-store' ./rmpp-android
        rmpp_android = rmppPkgs.callPackage ./android/android.nix {
          inherit os kernelVersion;
          tools = config.packages.rmpp_android_tools;
          bridge = config.packages.rmpp_einkbridge;
          quill = config.packages.rmpp_quill;
        };

        rmpp_chromium = rmppPkgs.callPackage ./browser/chromium.nix {
          inherit os;
          quill = config.packages.rmpp_quill;
          chromium = rmppPkgs.chromium;
        };

        rmpp_wikipedia = rmppPkgs.callPackage ./wikipedia/wikipedia.nix { };

        rmpp_einkbridge = rmppPkgs.callPackage ./bridge/einkbridge.nix { inherit os; };

        rmpp_quill = rmppPkgs.callPackage ./bridge/quill.nix { inherit os; };

        # Upstream's device files on their own, for reference or a hand-built
        # install: kernel fragment, GPU DT patch, scripts, units, theme.
        # nix build .#rmpp_android_files
        rmpp_android_files = androidFiles;

        # reMarkable OS kernel + Waydroid requirements + the Vivante/etnaviv GPU
        # driver (kernel.nix), plus the upstream stable security chain from
        # os.nix on top unless `rmpp.kernel.securityPatches.enable = false`.
        # Native aarch64: a kernel build wants a real aarch64 CPU, hours on many
        # cores, ~30 GB of tree.
        # rmpp_kernel builds for the configured rmpp.os.version (3.27 or 3.28).
        # rmpp_kernel_3_27 and rmpp_kernel_3_28 are version-specific shortcuts.
        # nix build .#rmpp_kernel -o rmpp-kernel
        inherit rmpp_kernel rmpp_kernel_3_27 rmpp_kernel_3_28;

        # nix build .#rmpp_config -o rmpp-config
        # scp/copy the closure, then on the device:
        #   /nix/store/<hash>-rmpp-config/activate --install-boot-unit
        rmpp_config = rmppConfig.config.system.build.toplevel;
      };
    };
}
