# Adaptation of https://github.com/MaximeRivest/android-on-remarkable-paper-pro
# for this flake.
#
# Upstream runs Android 13 (Waydroid, LineageOS 20) on the Paper Pro by drawing
# a headless wlroots compositor onto the e-ink panel through their `einkbridge`
# (quill) and feeding pen/touch back, all hand-built with reMarkable's Yocto SDK
# and copied into /home/root.
#
# What is adapted here is the *runtime*, not their build tooling: Waydroid and
# labwc are ordinary nixpkgs packages, so they arrive as native aarch64-linux
# derivations that cache.nixos.org already serves -- no SDK, no cross compiler,
# nothing to compile -- and upstream's device-side files (kernel config
# fragment, GPU device-tree patch, session/takeover scripts, systemd units,
# Android e-ink theme) are shipped verbatim from the pinned flake input.
#
# Deliberately not packaged: the kernel. Upstream builds reMarkable's GPL kernel
# source with the SDK and flashes `fitImage`; that artifact is device-specific,
# version-locked to the installed OS and replaced by every OS update, so their
# scripts stay the source of truth for it (they are installed under
# $out/share/rmpp-android/kernel).
{
  inputs,
}:
{
  perSystem =
    { pkgs, lib, ... }:
    let
      rmppPkgs = import ../aarch64-pkgs.nix pkgs;
      upstream = inputs.android-on-remarkable-paper-pro;

      # Upstream's files, exactly as committed: the scripts run on the tablet
      # under BusyBox/gash, not on the build host, so no shebang rewriting.
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
      packages = lib.optionalAttrs pkgs.stdenv.hostPlatform.isLinux {
        # Upstream's device files on their own, for reference or a hand-built
        # install: kernel fragment, GPU DT patch, scripts, units, theme.
        # nix build .#rmpp_android_files
        rmpp_android_files = androidFiles;

        # The runtime closure: Waydroid plus the headless wlroots compositor it
        # renders into, all substituted from cache.nixos.org. Mesa is here for
        # the tablet's Vivante GC600 (etnaviv), the same GPU path upstream
        # enables with kernel/gpu-etnaviv-dt.patch.
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
      };
    };
}
