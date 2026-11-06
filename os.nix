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

    # Upstream stable fixes, applied on top of that tree by kernel.nix.
    #
    # reMarkable ships a vendor (NXP) kernel frozen at one stable level and does
    # not move it between OS releases, so every fix the stable maintainers
    # published after it — the security fixes included — is missing from the
    # stock kernel. This is the full incremental chain from
    # https://cdn.kernel.org/pub/linux/kernel/v6.x/incr/ : patch-6.12.49-50.xz
    # through patch-6.12.<last-1>-<last>.xz, the same files kernel.org serves.
    #
    # Each entry is the SRI hash of that .xz, so a re-published patch is a
    # rebuild rather than a silent difference. `first` is one past the pinned
    # version's sublevel (6.12.49 -> 50) and `hashes` has to cover every level
    # up to `last`; kernel.nix asserts both, because a gap would silently drop a
    # security fix.
    #
    # `rmpp.kernel.securityPatches.enable` (config.nix) is the switch. With it
    # on, the built kernel is <version>-with-<last>, e.g. 6.12.115-waydroid, and
    # activation looks for exactly that. Bumping: set `last` to the current
    # 6.12.y, add the new hashes (`nix store prefetch-file <url>` prints the
    # SRI), rebuild.
    #
    # Not every hunk lands: reMarkable's tree is an NXP release, so upstream
    # context has drifted in drivers they changed. What could not be applied is
    # reported by the build and shipped as share/rmpp-kernel/security-patch-rejects
    # (see TODO.md for the measured state of this chain).
    stable = {
      first = 50;
      last = 115;
      hashes = {
        "50" = "sha256-01bnbTKSEMFZOz5GU3Qt/Dm2nGiw3qZAlNnN61cRzPM=";
        "51" = "sha256-KhdR5ZGgjmMzcrXBdx0IcZGKSTIhCmBSD7MCe72a95Q=";
        "52" = "sha256-mqHw0MgJxiokRQXWHeWGLd0BkCZ0MbTlaXUcHZ5gzpY=";
        "53" = "sha256-Ou9zWncVwwPfNlY+QVS15LdiXBlRkpOk8y3J8DdcVtM=";
        "54" = "sha256-P3x2N//JHNLlaj36Gpcc8xGDF5kn4cPurshjU8KHYj4=";
        "55" = "sha256-BhG48yVsxq/OAlb9k2V5b8MUM2XaplO6c+sCHHjgLks=";
        "56" = "sha256-NJAoNBHiZ0LN6mYzjnNf3GAqRW6f45TG47hHNt0wQgI=";
        "57" = "sha256-+ZPaZ8J48nwwyWqX+thWbzQ1wyB8/exg4YELlv1gAKk=";
        "58" = "sha256-hsW8IstzkIOJjAs30RRJtEmMytTVFw+pllofvAJuZbA=";
        "59" = "sha256-qHUWFkLxvrpe4ZEK1SOYeCCz6S7hJh3sDNxH0GCGlxM=";
        "60" = "sha256-Dr4e86v8DyI8uWQ89TK9YVZk6Dgqcd76uYth66Kra4I=";
        "61" = "sha256-hMFfle/FfVouJDsUy/Ge1QYVSOKv1W+AxLy6DXlxUmw=";
        "62" = "sha256-bkfsjjFkYwCClsK4AfYviKoheuPVxtcmM+JWHTX9FzI=";
        "63" = "sha256-umYJ5xQleh8kjKt10gDss0vqtHqa+vnQe5xGAianJTA=";
        "64" = "sha256-7lBs3857dU/O0ONvPNEGf9WccJ4+hWEE0pi3S9ypZjU=";
        "65" = "sha256-yj7DslcdTtC2mHg3Q5JgcavP7fjyRHoPvXPlz95A8uM=";
        "66" = "sha256-ZAITos21llcRqSwRrRb9nbMraceTUMWqMfx0Scz86d0=";
        "67" = "sha256-WojtgwDaB39swZjLtGsltYp6x5nGTsTM5d/vAF5tyGM=";
        "68" = "sha256-mH/zs9B5+3xnvNokZI+YEblxSJJMkq4Ed/FT7mb9e/s=";
        "69" = "sha256-Rr81Arxj0Uk4wfr/A7zLfndXrtyTtQ9hETabKP+KcPw=";
        "70" = "sha256-mq2wL0gsReam3Si8c+Iv0tiIrIkUFIXvVh3XmFi5A8I=";
        "71" = "sha256-Ng7i4ENyRNglynTxKTI/AhQ4GYOIkIT79JKnLlJVvtU=";
        "72" = "sha256-nzxjduB70dx0kQ3/ZTT2uQ9TafSGYTTWukT7++DGt3M=";
        "73" = "sha256-B12YmRwTUbU+pN3H5WKu++8qCfhIWiIhfv/ZmJymjy8=";
        "74" = "sha256-3lgQNKNoc9r31HPYSxtZE4hafzDIGaiiT0nqo+BYDUA=";
        "75" = "sha256-SgYMkqapv/dZbQof5iOUuNstOaTU2GiVtQxnszuYDjs=";
        "76" = "sha256-yBefZ1aU+w0iA5HKKqM6LLrX+mJUxyoeEk7nFVpwfQg=";
        "77" = "sha256-9i6klRgxYoSJlKNDgrC24ryFjpHADJEm5y9wdUjcq94=";
        "78" = "sha256-aAdW8LvtmuguLVEMaZyYKuacaL7QmSYGg9Z+jDjjv40=";
        "79" = "sha256-ghBF0prmdkdVz6xFqcf8j8M1ZRAHovI3rGb9i7uqgVQ=";
        "80" = "sha256-OU7rPF07fHqPrGE1KK0hxGnsm/uVJE426fEZCC3toGw=";
        "81" = "sha256-1TQ3Xmg+rLx6VGtm5muF3cIYcFxS37VO9ulyqyn/pOA=";
        "82" = "sha256-k5/g7M/h3RBWzWv6GuGLvKt0kKDkxQJbn8eGKkxfq30=";
        "83" = "sha256-fjXrsragVGi/Qs4UHRn/ueVHauG5TD4gMc6osxTphgs=";
        "84" = "sha256-svGFMiNjW/Opg3sNLrRZm1U/5t9/qFB+rTlaZSB1vYw=";
        "85" = "sha256-RIh6rPm/4z6QnudbWpXJuaTr/9yxt8Xg+gT2mhx/2gQ=";
        "86" = "sha256-Qp/HyuAtykPvk24GnMnBCf69mMN7HtCx/y8WYMipYyo=";
        "87" = "sha256-oUgOiORpIJYlOQLo2BRVUcGvZDxyEMViVnX82R3XEhs=";
        "88" = "sha256-4eahKm4oXv1pLvYSnsviu6bgI343WLORXMcTxxqZvJQ=";
        "89" = "sha256-IeuwIYH7eXpoGHwFXJg5Vlwmpsw1ljdf4r3AboUwWMc=";
        "90" = "sha256-K9COt5KmB57Q0ElOWr7muEjHXixEzJvGfW1unXFEJXc=";
        "91" = "sha256-G/QkO+v8YghDiEcqEXasvwWIVs0A7xAYIWdhY9Q6soQ=";
        "92" = "sha256-MRHL+E0t6BHKVnAktOvhfDK5o/2Wod5lKH14GpuTMxo=";
        "93" = "sha256-HeWSI52UAT2/lK6cBFGntbg7kx19gqFHZkstLitP0Cc=";
        "94" = "sha256-HVhw0S7RPof6zY7rnfWPx/uwzeZZshTmiuTJLChDYkw=";
        "95" = "sha256-fZ5UOunmTmyqi5oYqS0snNsaBJTys1rBoptI0czvvfs=";
        "96" = "sha256-1mhpWjKqcj6Mcn9cnN5fTCar3ZeQN+CC7VdcSgw7pjk=";
        "97" = "sha256-eHlobBppt2fb6qEgj59uchQbPisuqCdaT3jIxApKzvE=";
        "98" = "sha256-d7oL49qQEGsST8tP0Peg08xZ4o/Ibrdjm3pqgolVSag=";
        "99" = "sha256-oyMMa2AIJQfmdetim/F64rxQkxwSRX73va+bdupHQ7I=";
        "100" = "sha256-jx3kXJvugB2ta5ddqNTbjLZYz2fJ7EthIMpK0tSBvHA=";
        "101" = "sha256-6a9HzHLwPTEptgovkOVul59eWheh3ni+6k1KSaZr7aI=";
        "102" = "sha256-nTPzgL1B3jNYgdwk05oUrVAbKM5ZGu62iShEVOpwlWM=";
        "103" = "sha256-WB83ZfC06ikdRec7oBIth7GKY2up3IZxGWtYMlQ8j8E=";
        "104" = "sha256-9393b9X0NGyWhO3E4QehXk2xqS3kTKByrkRXblA+GZk=";
        "105" = "sha256-/gK5FM9hiRIOKvgU+aMExar4yOsmgWLihycPr3lXe0Y=";
        "106" = "sha256-agbf3yYSZdJPKFgEoUj/85+ezKxkmijt71fFHe2KNaI=";
        "107" = "sha256-x8NwK2FplkTeY3tnFhxOtvxFQ+vztNVE50cd7YOHJTA=";
        "108" = "sha256-wxyrcji02J4QIjYPuibloQhsDpb3+2aEs66vHaYnt9A=";
        "109" = "sha256-sPJ5TTfBHDmNJcpPQyvxKPdOMrXPOaYixbqwpO4yZCM=";
        "110" = "sha256-o+DilbckJ/sDnxP55FjhVQGlNJ7u6xkJyOkmGlw2FDI=";
        "111" = "sha256-WEjRzDCn0gmoefpaXnw8b8vRGdhRKksNCWY9T1Cx/Tc=";
        "112" = "sha256-Ps2WXYCJKQAu6g4dpxx2E4yOd/MyICwmf9PWuJ1cj54=";
        "113" = "sha256-QwsqKZo3UScfK5qkGqSBORIJMt3Niq1CrhG+D73nPJ8=";
        "114" = "sha256-+bgEsueRK6TcYg9/DeIffXEdaKpvKTc9pWMtRWxrQ/k=";
        "115" = "sha256-rt7/VQzw0fBiMQNp5NrpCLRrzLC46bstm2nFxfg9KnU=";
      };
    };
  };
}
