# The reMarkable OS release this flake targets — and the only place to change it.
#
# Programs that link against the device's *own* userland are tied to this
# release (xochitl's Qt, the system glibc), and reMarkable publishes one kernel
# source branch per release, so the numbers have to live in one place instead of
# being repeated in each derivation:
#
#   os.nix      this file: release, ABI, kernel pin
#   kernel.nix  takes `os` and builds the kernel from os.kernel
#   system.nix  records the lot in the generation as $out/os
#
# Bumping the OS is a three-step job, all here: set `version`, set the matching
# `kernel` pin from https://github.com/reMarkable/linux-imx-rm (hash = the
# unpacked tree, which is what fetchzip pins), and re-check `glibc`/`qt` against
# that release's notes. Then rebuild rmpp_kernel and rmpp_config; expect the
# prebuilt rmweb bundle to need a matching upstream release too.
#
# The 3.28 triple below is verified against the device and cross-checked with
# https://github.com/skdlzlvk/paper-pro-move-dualboot-installer/blob/main/docs/KERNEL-SOURCE.md
{
  version = "3.28";

  # Userland ABI of that release. A program built against Nix libraries does not
  # care, but one built against the OS's own (the prebuilt rmweb bundle is the
  # case in point: it loads xochitl's Qt 6.10.3) has to match these.
  glibc = "2.39";
  qt = "6.10.3";

  # The kernel that ships with this release, from reMarkable's published GPL
  # source (tracked with git LFS). `branch` is the rmpp_<kernel>_v<...>.x branch
  # they maintain for it, so the pin is versioned by the OS, not by us.
  kernel = {
    version = "6.12.49";
    branch = "rmpp_6.12.49_v3.27.x";
    file = "linux-imx-rel-5.7-wd-3.27.2.1-f21cbcc9ed9a.tar.gz";

    # Unpacked tree, i.e. what fetchzip pins.
    hash = "sha256-2OFtlMGX44zyuOvj9OeC1JsAFFOX7BMubFuGs2f0TKU=";

    # The tarball itself, for re-checking a re-download by hand.
    tarballSha256 = "ad8ab17a897bb35ecec877f6b3e7e766a534ce25e46766991f7ec92b276e583f";
  };
}
