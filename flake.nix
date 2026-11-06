{
  description = "Nix packages for the reMarkable Paper Pro (ferrari, aarch64-linux)";

  # Every tablet package here is a *native* aarch64-linux derivation: the exact
  # derivation cache.nixos.org already serves, so `nix build` substitutes it
  # instead of building a toolchain. That only works if the substituter and its
  # public key are known and the host is allowed to name the platform, so both
  # are declared here and a plain `nix build .#rmpp_tools` does the right thing
  # on a machine that has never seen this repository.
  #
  # `extra-platforms` lets an x86_64 host *evaluate*/substitute aarch64-linux
  # derivations. Building a cache miss under emulation additionally needs
  # binfmt/qemu-user; see remarkable-paper-pro.md.
  nixConfig = {
    extra-substituters = [ "https://cache.nixos.org" ];
    extra-trusted-public-keys = [
      "cache.nixos.org-1:6NCHdD59X431o0gWypbMrAURkbJ16ZPMQFGspcDShjY="
    ];
    extra-platforms = [ "aarch64-linux" ];
  };

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-parts.url = "github:hercules-ci/flake-parts";

    # Adapted here: the Waydroid/e-ink stack for the Paper Pro. Only its
    # device-side files (kernel fragment, GPU DT patch, session scripts, units)
    # are used; the build tooling it ships is replaced by nixpkgs packages.
    android-on-remarkable-paper-pro.url = "github:MaximeRivest/android-on-remarkable-paper-pro";
    android-on-remarkable-paper-pro.flake = false;
  };

  outputs =
    inputs@{ flake-parts, ... }:
    flake-parts.lib.mkFlake { inherit inputs; } {
      # x86_64-linux builds/substitutes the tablet's aarch64 packages for it;
      # aarch64-linux is the tablet itself (and any arm64 dev machine).
      systems = [
        "x86_64-linux"
        "aarch64-linux"
      ];

      imports = [
        ./remarkable
        ./remarkable/rmweb
        (import ./remarkable/android { inherit inputs; })
      ];
    };
}
