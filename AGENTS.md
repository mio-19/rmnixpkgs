# AGENTS.md

Conventions for this repository: Nix packages for the reMarkable Paper Pro
(`ferrari`, aarch64), built from source where at all possible.

The tree is flat by design — everything in it is about the Paper Pro, so there
are no per-component subdirectories:

| Path | What |
| --- | --- |
| `flake.nix`, `default.nix` | flake entry point, and one module defining every package |
| `os.nix` | the target reMarkable OS release: kernel source pin + stable patch chain, glibc/GCC/Qt ABI |
| `aarch64-pkgs.nix` | the native aarch64-linux package set (cache.nixos.org trick) |
| `wpewebkit.nix`, `rmweb.nix` | browser engine and browser app, both from source |
| `kernel.nix` | reMarkable's kernel + Waydroid needs + etnaviv GPU driver + the upstream stable (security) chain |
| `android.nix`, `android.py` | Waydroid session: private root, compositor, container, manual `rmpp-android` takeover |
| `einkbridge.nix`, `einkbridge.c`, `einkbridge-wire.h`, `quill-host.c` | our Wayland screencopy → e-paper bridge and its isolated vendor-display worker |
| `quill.nix` | Quill, from source against the OS's Qt |
| `system.nix`, `config.nix`, `activate.sh` | declarative configuration: the module, this device's config, the activation script |
| `nix-setup.sh` | device-side persistent-store setup script |
| `test-*`, `check-waydroid-*` | flake checks (`nix flake check` on the aarch64 builder); never installed on the tablet |
| `remarkable-paper-pro.md`, `TODO.md` | device notes; verified facts and open work |

## Provenance: keep the original link

If a file is based on, adapted from, or inspired by anything on the internet — a
patch, a config fragment, a build recipe, a command line, a magic value, an env
var — **leave the original URL in that file**.

- Derived wholesale (a patch, a config fragment, a script): put the link in the
  header comment, together with what was changed, if anything.
- A smaller borrowing (one flag, one formula, one sysfs path): put the link
  inline next to it.
- Downloaded artifacts: name the upstream project and its URL next to the hash,
  and say if the hash is of the unpacked tree rather than the tarball.
- Never strip these links while refactoring, reformatting or "cleaning up". If a
  file clearly came from somewhere and has no link, add the link rather than
  guessing it away.

Examples already in the tree: `kernel.nix` credits
`https://github.com/MaximeRivest/android-on-remarkable-paper-pro/tree/master/kernel`
for `waydroid.cfg` and `gpu-etnaviv-dt.patch`; `wpewebkit.nix`/`rmweb.nix`
credit `https://github.com/exp78/rmweb` and `https://wpewebkit.org/releases/`.

## Packages

- Tablet packages are **native `aarch64-linux`** derivations
  (`aarch64-pkgs.nix`), never `pkgsCross`, so `cache.nixos.org` serves them.
  Anything not cached must be worth the compile: say why in a comment.
- Everything that runs on the tablet lands under `/home/root` (the only
  writable, OTA-surviving location). The store is read-only: a package that
  needs to write next to itself gets copied out of the store on install.
- Ship closures (`nix copy`), not bare binaries; the tablet has a real store.
- Device-side scripts keep their `#!/bin/sh` shebangs (`dontPatchShebangs`) —
  they run under BusyBox, not on the build host.
- Anything that touches the boot chain (kernel, slots) documents the backup and
  the A/B fallback it relies on, and names where that behaviour came from.
- The device already runs vellum + XOVI + AppLoad. A layer may only create and
  delete paths it recorded in its own manifest: never `/home/root/.vellum`,
  never `xovi/extensions.d`, never a foreign AppLoad entry, and only `rmpp-*`
  systemd units.
- Anything tied to the installed OS release — kernel source branch and hashes,
  glibc, xochitl's Qt — lives in `os.nix` and nowhere else. A derivation takes
  it as an argument (`{ os, ... }`) instead of hard-coding a version.
- Kernel security updates are the upstream stable chain pinned in `os.nix`
  (`kernel.stable`, one hash per level) and applied by `kernel.nix`; the switch
  is `rmpp.kernel.securityPatches.enable` in `config.nix`. Adding a level means
  adding its hash — never a level without one. Rejected hunks are reported and
  shipped with the output; they are never silently skipped, and a patch file is
  never reformatted to make it apply.

## Nix style

- Run `nixfmt` on every `.nix` file touched (`nix fmt`, formatter is
  `pkgs.nixfmt`).
- Exception worth breaking the formatter rule for: **patch files must not
  contain hunks that only change formatting.** A `.patch` carries the smallest
  semantic change possible, even if the surrounding style stays inconsistent
  with the file it applies to. Same for vendored upstream files: never reformat
  them, so rebasing and re-applying stays possible.
- Generated files (`flake.lock`) are never hand-edited.

## Verification

- Before claiming a package works, at minimum
  `nix eval .#packages.aarch64-linux.<name>.drvPath`.
- A build that was not run is reported as not run. Say "instantiates" when it
  only instantiates.
- Long or unusual builds (WPE WebKit, the kernel) go in `TODO.md` rather than
  being skipped silently; record the command and what to check.
- `TODO.md` carries the verified device/upstream facts. Add findings there
  instead of re-deriving them next time.
