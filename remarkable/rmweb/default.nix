{ ... }:
{
  perSystem =
    { pkgs, lib, ... }:
    let
      rmppPkgs = import ../aarch64-pkgs.nix pkgs;
    in
    {
      # The payload is aarch64-linux, which only a Linux host can build or
      # substitute for the tablet (see the extra-platforms note in flake.nix).
      packages = lib.optionalAttrs pkgs.stdenv.hostPlatform.isLinux {
        # The browser from source: rmweb's Qt app against a WPE WebKit that is
        # compiled here from the wpewebkit.org tarball instead of upstream's
        # prebuilt release bundle.
        # nix build .#rmpp_rmweb
        rmpp_rmweb = rmppPkgs.callPackage ./package.nix {
          wpewebkit = rmppPkgs.callPackage ./wpewebkit.nix { };
        };

        # Upstream's release bundle, unchanged from what this repository shipped
        # before the source build existed. Kept deliberately: it links against
        # the device's own Qt 6.10.3 and so renders through libepaper.so today,
        # while the nixpkgs-Qt build above has no display path until QTFB lands
        # (see TODO.md). Drop this once the source build is verified on device.
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
      };
    };
}
