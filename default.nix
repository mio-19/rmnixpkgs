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
    { pkgs, lib, ... }:
    let
      rmppPkgs = import ./aarch64-pkgs.nix pkgs;
      upstream = inputs.android-on-remarkable-paper-pro;

      # The OS release this all targets, declared once (os.nix) and handed to
      # everything that has to agree with the installed system: the kernel
      # source pin, and the generation's record of what it was built for.
      os = import ./os.nix;

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
      rmppConfig = lib.evalModules {
        modules = [
          ./system.nix
          ./config.nix
        ];
        specialArgs = {
          inherit lib os;
          pkgs = rmppPkgs;
        };
      };

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
          cp -a kernel device chroot android README.md $out/share/rmpp-android/
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

        # The browser from source: rmweb's Qt app (rmweb.nix) against a WPE
        # WebKit compiled here from the wpewebkit.org tarball (wpewebkit.nix),
        # instead of upstream's prebuilt release bundle.
        # nix build .#rmpp_rmweb
        rmpp_rmweb = rmppPkgs.callPackage ./rmweb.nix {
          wpewebkit = rmppPkgs.callPackage ./wpewebkit.nix { };
        };

        # Upstream's release bundle (https://github.com/exp78/rmweb), unchanged
        # from what this repository shipped before the flake. Kept deliberately:
        # it links against the device's own Qt 6.10.3 and so renders through
        # libepaper.so today, while the nixpkgs-Qt build above has no display
        # path until the QTFB work lands (see TODO.md). Drop it once the source
        # build is verified on device.
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
        # Waydroid plus the headless wlroots compositor it renders into, all
        # nixpkgs aarch64-linux packages that cache.nixos.org already serves
        # (no SDK, no cross compiler), with upstream's device files alongside.
        # Mesa is here for the tablet's Vivante GPU, which only works once
        # rmpp_kernel (kernel.nix) is installed.
        # nix build .#rmpp_android -o rmpp-android
        # nix copy --to 'ssh://root@10.11.99.1?remote-program=/nix/var/nix/profiles/default/bin/nix-store' ./rmpp-android
        rmpp_android = pkgs.buildEnv {
          name = "rmpp-android";
          paths =
            (with rmppPkgs; [
              waydroid
              labwc
              wlroots
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
            description = "Waydroid + headless wlroots runtime for the reMarkable Paper Pro";
            homepage = "https://github.com/MaximeRivest/android-on-remarkable-paper-pro";
            license = lib.licenses.mit;
            platforms = lib.platforms.all;
          };
        };

        # Upstream's device files on their own, for reference or a hand-built
        # install: kernel fragment, GPU DT patch, scripts, units, theme.
        # nix build .#rmpp_android_files
        rmpp_android_files = androidFiles;

        # reMarkable OS kernel + Waydroid requirements + the Vivante/etnaviv GPU
        # driver (kernel.nix). Native aarch64: a kernel build wants a real
        # aarch64 CPU, hours on many cores, ~30 GB of tree.
        # nix build .#rmpp_kernel -o rmpp-kernel
        rmpp_kernel = rmppPkgs.callPackage ./kernel.nix {
          inherit os;
          configFragment = "${upstream}/kernel/waydroid.cfg";
          gpuDeviceTreePatch = "${upstream}/kernel/gpu-etnaviv-dt.patch";
        };

        # nix build .#rmpp_config -o rmpp-config
        # scp/copy the closure, then on the device:
        #   /nix/store/<hash>-rmpp-config/activate --install-boot-unit
        rmpp_config = rmppConfig.config.system.build.toplevel;
      };
    };
}
