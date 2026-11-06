{ ... }:
{
  perSystem =
    { pkgs, lib, ... }:
    let
      rmppPkgs = import ./aarch64-pkgs.nix pkgs;

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
      # substitute for the tablet (see the extra-platforms note above).
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
      };
    };
}
