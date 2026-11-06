# The tablet package set: a *native* aarch64-linux instantiation of the same
# nixpkgs the flake is pinned to.
#
# This is the whole trick behind "reuse cache.nixos.org". The Paper Pro runs an
# aarch64 userland, and Hydra builds and signs every aarch64-linux derivation of
# nixpkgs, so `import <nixpkgs> { system = "aarch64-linux"; }` names exactly the
# derivations the binary cache already has: `nix build` downloads them instead
# of compiling anything. Cross-compiling (`pkgsCross.aarch64-multiplatform`)
# would instead produce *different* derivations that nobody caches, and would
# hand the device binaries built against a toolchain reMarkable never shipped.
#
# `config` is inherited from the host so an overlay or `allowUnfree` set on the
# caller does not silently change the closure on one machine only.
pkgs:
import pkgs.path {
  inherit (pkgs) config;
  system = "aarch64-linux";
}
