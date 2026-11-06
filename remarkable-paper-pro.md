# reMarkable Paper Pro

Notes and packages for the reMarkable Paper Pro (`ferrari`, aarch64, reMarkable
OS 3.x). Everything below assumes developer mode is enabled (Settings →
General → Software → Developer mode), SSH works over USB at `root@10.11.99.1`,
and you accept that you can brick the device by breaking `xochitl`.

## What the device does to you

- The root filesystem is mounted **read-only** at boot. `mount -o remount,rw /`
  makes it writable for the current boot. Writes then land on the real ext4
  rootfs slot and do persist across reboots; the filesystem is simply mounted
  read-only again the next time.
- `/etc` is an **overlay whose upper layer is on tmpfs**. Writing to `/etc`
  without unmounting the overlay silently loses the change at reboot:

  ```sh
  mount -o remount,rw /
  umount -R /etc
  # /etc now points at the real rootfs; /etc/dropbear is gone, so put the SSH
  # host keys (which live on /home) back so the session keeps working:
  mkdir -p /etc/dropbear
  mount --bind /home/root/.dropbear /etc/dropbear
  ```

- `/home` is the only writable storage that survives an **OS update**. An
  update replaces the whole rootfs slot (`/usr`, `/etc`, …) and leaves `/home`
  alone, so anything in `/usr` or `/etc` has to be reinstalled afterwards.
- Third-party software therefore lives under `/home/root`. The classic Toltec
  stack does not support this device (aarch64, different framebuffer/Qt); the
  current stack is [XOVI](https://github.com/asivery/xovi) +
  [rm-appload](https://github.com/asivery/rm-xovi-extensions) + QTFB, usually
  installed with [vellum](https://github.com/vellum-dev/vellum) or
  [reManager](https://remanager.io/).

## The flake

`flake.nix` pins nixpkgs (`nixos-unstable`), flake-parts and the
`android-on-remarkable-paper-pro` input, and declares `cache.nixos.org` plus
`extra-platforms = aarch64-linux` in `nixConfig`, so a fresh machine can build
the tablet's packages without extra setup:

```sh
nix build .#rmpp_tools        # CLI tools for the tablet
nix build .#rmpp_rmweb        # the browser, from source
nix build .#rmpp_android      # Waydroid + labwc runtime
nix build .#rmpp_kernel       # kernel with Android requirements + GPU driver
nix build .#rmpp_nix_setup    # device-side Nix store setup script
```

Two things are worth knowing about how the packages are built:

- **Everything is a native `aarch64-linux` derivation.** The package set is
  `import <nixpkgs> { system = "aarch64-linux"; }`
  (`aarch64-pkgs.nix`), not `pkgsCross`. Those are exactly the
  derivations Hydra builds and signs, so `nix build` substitutes them from
  `cache.nixos.org` instead of compiling — no cross toolchain, no reMarkable
  Yocto SDK, no binaries built against libraries the device does not have.
- Because `nixConfig` is only trusted for trusted users, an unprivileged or
  fresh setup may need `--accept-flake-config` to pick up the substituter and
  the extra platform. Passing them by hand works too:

  ```sh
  nix build --accept-flake-config .#rmpp_tools
  nix build --option extra-platforms aarch64-linux .#rmpp_tools
  ```

The packages link against `/nix/store`, which is fine because the tablet gets a
real store (see [Nix on the tablet](#nix-on-the-tablet)): copy the **closure**,
not a bare binary.

The same packages work on the Paper Pro Move: it is the same aarch64 userland,
and rmweb derives the panel geometry at runtime.

## Packages here

```sh
# CLI tools: syncthing, tmux, htop, rsync, strace
# dynamically linked against /nix/store: copy the closure to the tablet's store
# (remote-program: nix-store is not on the tablet's non-interactive PATH; the
# single quotes keep the shell from globbing the `?')
nix copy --to 'ssh://root@10.11.99.1?remote-program=/nix/var/nix/profiles/default/bin/nix-store' ./rmpp-tools

# Nix store plumbing for the tablet (a plain shell script, no closure needed)
nix build .#rmpp_nix_setup -o rmpp-nix-setup
scp rmpp-nix-setup/bin/rmpp-nix-setup root@10.11.99.1:/tmp/
```

The store has to be mounted first (`rmpp_nix_setup`), otherwise the import hits
the read-only rootfs.

### rmweb (WPE WebKit browser, built from source)

[rmweb](https://github.com/exp78/rmweb) is a native e-ink browser for the Paper
Pro: reader mode, downloads that land in the reMarkable library, a home-screen
icon under XOVI/AppLoad.

Both halves are built here:

- `wpewebkit.nix` — **WPE WebKit 2.48.5** from the
  wpewebkit.org tarball (nixpkgs ships the GTK port and `libwpe`, not
  `wpewebkit`), configured the way upstream configures it: software rendering,
  Skia CPU painting, no GStreamer/video/WebRTC/WebGL, no bubblewrap sandbox,
  WPEPlatform **headless** only.
- `rmweb.nix` — the **rmweb app** (`engine/wpeqt`, Qt 6
  Gui/Qml/Quick) from the `v0.9.7` tag, against nixpkgs' Qt and that engine.

This replaces upstream's prebuilt `rmweb-0.9.7.tar.gz` bundle, and it is the
expensive package in this repository: a full WebKit compile is hours on many
cores and needs a lot of RAM to link (tens of GB of build tree). Build it on an
aarch64 machine if you have one, or once per WebKit version and keep the store
path; everything else in the closure still comes from `cache.nixos.org`.

```sh
nix build .#rmpp_rmweb -o rmweb
# the closure (engine + Qt + fonts-ish deps) goes to the tablet's store
nix copy --to 'ssh://root@10.11.99.1?remote-program=/nix/var/nix/profiles/default/bin/nix-store' ./rmweb
# the writable device tree: the launcher writes rmweb.log and .lock next to
# itself, which the read-only store cannot hold
scp -r rmweb/share/rmweb root@10.11.99.1:/home/root/
ssh root@10.11.99.1 /home/root/rmweb/install.sh
```

Then run `/home/root/rmweb/rmweb [URL]`, or start XOVI and tap the **rmweb**
icon that `install.sh` registered. The tree lives on `/home`, so it survives an
OS update — re-run `install.sh` afterwards to re-assert the AppLoad icon, and
re-`nix copy` after a garbage collection. Quit with the ⏻ button so `xochitl`
comes back.

Caveat, and it is the important one: **the stock display path needs the
device's Qt**. `xochitl` presents through the closed-source `libepaper.so` QPA
plugin built against **Qt 6.10.3**, and a QPA plugin is refused on any other Qt
version, so the app built against nixpkgs Qt 6.12 compiles but has no panel to
draw on with reMarkable's own plugin. (The nixpkgs-Qt build is the compile-only
package until the QTFB path lands; the prebuilt bundle — still shipped — is the
artifact that actually renders today.)

**QTFB is the community answer to that.**
([asivery/qtfb](https://github.com/asivery/qtfb), now merged into
[rm-appload](https://github.com/asivery/rm-appload)): a shared-memory
framebuffer server runs *inside* `xochitl` as the `qtfb.so` XOVI extension and
clients draw into it over `/tmp/qtfb.sock`. It never touches `libepaper.so`, so
it does not care which Qt the app was built against — the client is a QPainter
on a shm buffer. That is what the aarch64 ecosystem already uses: KOReader
ships with `KO_USE_QTFB=1`, and AppLoad starts native applications with
`"qtfb": true` in their `external.manifest.json` — AppLoad allocates the
framebuffer and passes its ID to the app as `QTFB_KEY`, which is all a client
needs to map it. Input comes back either through the `qtfb-shim.so` `LD_PRELOAD`
shim (`QTFB_SHIM_MODE=N_RGB565`, `QTFB_SHIM_INPUT_MODE`, `QTFB_SHIM_MODEL`) or
straight from `/dev/input`.

So yes, the modern Qt stack can run on stock reMarkable OS — just not through
reMarkable's own platform plugin. For rmweb that means adding a small QTFB
client path (present the WPE/Quick frame into the shared framebuffer, forward
pen/touch), which is far less work than pinning Qt 6.10.3. Options, in order of
preference:

1. **QTFB**: give rmweb a QTFB present/input path and start it from AppLoad
   with `"qtfb": true`. No `libepaper.so`, no Qt 6.10.3, the flake's Qt works.
2. **Wayland**: `rmpp_android` ships `labwc`, so a Wayland session
   (`QT_QPA_PLATFORM=wayland`) is another Qt-version-independent path; it still
   needs something to copy frames to the panel, which is what `einkbridge`
   does for the Android project.
3. Build Qt 6.10.3 from source in this flake and link rmweb against it, then
   check whether `libepaper.so` loads — it may also need reMarkable's private
   build configuration, and it breaks again with every OS update that bumps Qt.
4. Accept a compile-only package for CI, with no rendering on device.

Until the source build renders on device, `rmpp_rmweb_prebuilt` still ships
upstream's release bundle — unchanged from what this repository used before the
flake — which uses the device's own Qt 6.10.3 and therefore does render today:

```sh
nix build .#rmpp_rmweb_prebuilt -o rmweb-bundle
scp -r rmweb-bundle/. root@10.11.99.1:/home/root/rmweb/
ssh root@10.11.99.1 /home/root/rmweb/install.sh
```

Everything else in the package is real: the runtime environment the wrapper
sets (`WEBKIT_SKIA_ENABLE_CPU_RENDERING`, `GALLIUM_DRIVER=llvmpipe`,
`EGL_PLATFORM=surfaceless`, `GIO_EXTRA_MODULES` for TLS, `RMWEB_READER_DIR`) is
what upstream ships in `rmweb-env.sh`, minus the `LD_LIBRARY_PATH` juggling the
nix store makes unnecessary. `RMWEB_JIT=1` still works for the baseline JIT.

KOReader is not packaged here: upstream ships only prebuilt aarch64 archives
for this device and this repository prefers building from source, so install it
with [vellum](https://github.com/vellum-dev/vellum) (`vellum install koreader`)
or reManager, which place it under `/home/root/xovi/exthome/appload` and keep it
across OS updates.

### Android 13 via Waydroid (adapted)

`default.nix` adapts
[android-on-remarkable-paper-pro](https://github.com/MaximeRivest/android-on-remarkable-paper-pro),
which runs Android 13 (Waydroid/LineageOS 20, Play Store) on the Paper Pro: a
headless wlroots compositor renders into the panel through their `einkbridge`
(quill) and feeds pen/touch back, with a sidebar button in reMarkable's own UI
to switch.

Adapted means: their build tooling is dropped and their *runtime* is a normal
nix closure. `waydroid`, `labwc`, `wlroots` and `mesa` (etnaviv for the Vante
GC600) are nixpkgs `aarch64-linux` packages, so they substitute from
`cache.nixos.org`; their device-side files — the `waydroid.cfg` kernel fragment,
the GPU device-tree patch, the session/takeover scripts, the systemd units and
the Android e-ink theme — ship verbatim from the pinned flake input.

```sh
nix build .#rmpp_android -o rmpp-android
nix copy --to 'ssh://root@10.11.99.1?remote-program=/nix/var/nix/profiles/default/bin/nix-store' ./rmpp-android
# upstream's files for a hand-built install (kernel fragment, DT patch, scripts)
nix build .#rmpp_android_files -o rmpp-android-files
```

#### Custom kernel (Android requirements + the Vivante GPU)

`kernel.nix` builds reMarkable's own published kernel source with the
changes the Android stack needs — and, more interestingly here, **the GPU driver
the stock OS never ships**. Adapted from
[android-on-remarkable-paper-pro/kernel](https://github.com/MaximeRivest/android-on-remarkable-paper-pro/tree/master/kernel):
the device defconfig, the additive `waydroid.cfg` fragment (binder, binderfs,
PSI, BPF, cgroups, loop, veth/bridge, netfilter) and `gpu-etnaviv-dt.patch`,
both taken verbatim from the pinned flake input.

The GPU half is worth spelling out, because it is the one thing a browser would
actually feel. Stock reMarkable OS exposes no GPU to userland at all: no
`/dev/dri/renderD128`, no etnaviv/galcore module, no EGL/GLES/GBM. That is what
[rmweb's device profile](https://github.com/exp78/rmweb/blob/master/docs/device-profile.md)
records ("GPU present on die, but no stock driver … all rendering is CPU"), and
why rmweb is built for Mesa llvmpipe. The patch retargets the i.MX8MM
`gpu@38000000` node from `fsl,imx8mm-gpu` (no driver in this tree) to
`compatible = "vivante,gc"` and flips it to `status = "okay"`; the fragment
then builds `CONFIG_DRM_ETNAVIV=m`. With that kernel, the 3D core is a real DRM
device and Mesa's etnaviv driver can drive it. (The Android project's README
calls the core a GC600, rmweb's profile calls it GC7000 UltraLite — same
i.MX8MM 3D block; both links are above the claim.)

```sh
# aarch64 host: hours, ~30 GB. Emulated is not practical.
nix build .#rmpp_kernel -o rmpp-kernel
# fitImage, Image, dtbs/ and modules-<release>.tar.gz are in the output
nix copy --to 'ssh://root@10.11.99.1?remote-program=/nix/var/nix/profiles/default/bin/nix-store' ./rmpp-kernel
# then upstream's installer (shipped by rmpp_android_files), which backs up the
# stock fitImage to /home/root/waydroid/backup before writing anything
```

Boot safety, per
[paper-pro-move-dualboot-installer](https://github.com/skdlzlvk/paper-pro-move-dualboot-installer):
the tablet has two rootfs slots, the bootloader boots `/boot/fitImage` after a
plain hash check in developer mode, and reMarkable's boot watchdog flips the
active slot after repeated failed boots. Still let `install-kernel.sh` take the
backup, and still read upstream's README first.

##### Kernel security updates

reMarkable's kernel is frozen at one stable level (6.12.49) and does not move
between OS releases, so every fix the stable maintainers shipped afterwards —
the security fixes included — is missing from the stock kernel and from a plain
rebuild of their tree. `os.nix` therefore pins the full upstream incremental
chain from [kernel.org](https://cdn.kernel.org/pub/linux/kernel/v6.x/incr/)
(`kernel.stable`: 6.12.49 → 6.12.115, 66 patches, one SRI hash each), and
`kernel.nix` applies it to that tree before the GPU patch. With it on, the
kernel is **6.12.115-waydroid** — which is also what the configuration
generation records and what activation compares `uname -r` against.

```nix
# config.nix
kernel.securityPatches.enable = true; # default; false = the vendor tree as published
```

The chain goes in with GNU `patch` (`--forward`, so a fix the vendor tree
already carries is skipped rather than reversed; `--fuzz=2` for line drift), best
effort by design: reMarkable's tree is an NXP release, so upstream context has
drifted in the files they changed. Measured on the real tree: **25 of the 66
patches apply cleanly, 41 partially, 100 hunks find no matching context** —
mostly `imx8-isi`, Freescale networking (`enetc`, `dpaa2`), `fsl-edma`,
`gpio-mxc`, `pmdomain/imx` and i.MX device trees, plus a few core files
(`arch/arm64/include/asm/io.h`, `phylink.c`, `spi-imx.c`). Nothing is dropped
silently: the build prints the summary, and the output carries
`share/rmpp-kernel/security-patches` (per patch) and
`share/rmpp-kernel/security-patch-rejects` (every hunk that did not apply).
The partial applications **do** compile: this tree is the build-time chain
application (the derivation that runs GNU `patch` for all 66 levels, then
carries eight small ports and builds the derived syscore-revert), and the
result is the `/nix/store/rd8z2cbs4fgr12sykcgvpkmq7kcg2waa-rmpp-kernel-6.12.115`
closure. The 100 rejects remain what they were — the build would be lying if it
claimed otherwise — and chasing them is the next item, not a precondition.

Two limits worth stating: the pinned tarball is the **3.27.x** branch
(`linux-imx-rel-5.7-wd-3.27.2.1-f21cbcc9ed9a`, base 6.12.49), so on a newer OS
point `kernel.nix` at the matching branch tarball from
[reMarkable/linux-imx-rm](https://github.com/reMarkable/linux-imx-rm); and every
reMarkable OS update replaces the rootfs slot, so the kernel has to be
reinstalled afterwards.

Syncthing is useful headless: run it under `/home/root` and point the web UI at
the device over USB or Wi-Fi.

```sh
ssh root@10.11.99.1
mkdir -p /home/root/syncthing
/nix/store/*-rmpp-tools/bin/syncthing serve \
  --home=/home/root/syncthing --gui-address=0.0.0.0:8384
```

## Declarative configuration (system-manager style)

`system.nix` + `config.nix` describe the device the way a NixOS configuration
does, following [system-manager](https://github.com/numtide/system-manager)'s
model: a module declares the desired state, evaluation produces an immutable
**generation**, and one script activates it. Declare files, services, packages
and AppLoad entries in `config.nix`; nothing on the device is edited by hand.

What is adapted, and why this is not just system-manager:

- `/` is read-only and `/etc` is an overlay on tmpfs, so a generation cannot
  "install into /etc and stay installed". Generations live in the store and
  `rmpp-config.service` re-applies the current one at **every boot**.
- `--install-boot-unit` is the only step that writes to the real rootfs, and it
  reuses **vellum's** `mount-rw`/`mount-restore` helpers when they exist,
  falling back to the same remount/collapse sequence as `nix-setup.sh`.
- Activation records every path it created in a manifest and only ever deletes
  from that manifest — the mechanism that lets it coexist with a device that
  already has a package ecosystem.

```sh
nix build .#rmpp_config -o rmpp-config
nix copy --to 'ssh://root@10.11.99.1?remote-program=/nix/var/nix/profiles/default/bin/nix-store' ./rmpp-config
# first time, and after every reMarkable OS update (the rootfs slot is replaced):
ssh root@10.11.99.1 /nix/store/*-rmpp-config/activate --install-boot-unit
# later, after editing config.nix:
ssh root@10.11.99.1 /home/root/.rmpp/current/activate
```

### Coexisting with vellum, XOVI and AppLoad

That stack is the de-facto package ecosystem on reMarkable OS 3.x, and it owns
its own paths. The rules this layer follows:

| Thing | Where it lives | What `rmpp-config` does |
| --- | --- | --- |
| [vellum](https://github.com/vellum-dev/vellum) | everything under `/home/root/.vellum/` (apk db, repositories, keys, licences, `cache/`, `state/`) | never writes; only *reads* `bin/mount-rw`/`mount-restore` |
| [XOVI](https://github.com/asivery/xovi) | `/home/root/xovi/`, extensions in `extensions.d/` | never touches `extensions.d` or `xovi.so` |
| [AppLoad](https://github.com/asivery/rm-appload) | apps in `/home/root/xovi/exthome/appload/<name>/` | only entries it created (marked `.rmpp-config`); a foreign entry is reported and skipped |
| QMD mods (`qt-resource-rebuilder`) | `/home/root/xovi/exthome/qt-resource-rebuilder/` | untouched |
| systemd | `/etc/systemd/system/` | only `rmpp-*` unit names (asserted); `xochitl` and vellum's units untouched |
| `/etc` | tmpfs overlay | written every boot, never persisted into the rootfs |
| after an OTA | rootfs replaced | `activate --install-boot-unit` again, the counterpart of `vellum reenable` for package-owned files |

Vellum detects the device (`rmpp` virtual package) and pins packages to the OS
version (`remarkable-os`), so it remains the right owner for anything shipped as
an `.apk`; this layer is for what you build from Nix — the browser, the
Waydroid runtime, the kernel, and the units/entries that tie them in.

#### Vellum packages, declared like Homebrew on nix-darwin

The closest prior art for "declaratively list packages another package manager
should own" is [nix-darwin's Homebrew module](https://github.com/nix-darwin/nix-darwin/blob/master/modules/homebrew.nix):
a list in configuration, applied during activation, with opt-in auto-update and
cleanup. The same shape, aimed at vellum:

```nix
rmpp.vellum = {
  enable = true;
  packages = [ "koreader" "appload" ];   # `name`, `name@testing`, apk constraints
  onActivation = {
    autoUpdate = false;   # vellum update first; off, because activation runs at boot
    cleanup = false;      # remove packages this layer added that are no longer listed
  };
};
```

Two deliberate differences from `brew bundle`:

- **cleanup is narrow.** It only removes packages *this layer* added, tracked in
  `/home/root/.rmpp/vellum-managed` — never something vellum installed, an
  `.apk` you added by hand, or another package's dependency. A typo in
  `config.nix` therefore cannot uninstall XOVI out from under the shell.
- **failures warn, they do not abort.** Activation runs at boot; an offline
  tablet still has to get its units and AppLoad entries, so `vellum add` errors
  are reported and the rest of the generation applies.

The apk database stays vellum's: the generation records *intent*, and
`vellum list` / `vellum del` remain the truth for what is actually installed.

### OS version

Programs that link against the device's own userland — the prebuilt rmweb bundle
loading xochitl's Qt, anything expecting the system glibc — are tied to the
installed reMarkable OS release, and reMarkable publishes one kernel source
branch per release. So the release is declared once, in `os.nix`:

```nix
{
  version = "3.28";        # reMarkable OS release
  glibc = "2.39";          # userland ABI of that release
  qt = "6.10.3";           # what xochitl ships
  kernel = {
    version = "6.12.49";
    branch = "rmpp_6.12.49_v3.27.x";   # reMarkable's branch for it
    file = "linux-imx-rel-5.7-wd-3.27.2.1-f21cbcc9ed9a.tar.gz";
    hash = "sha256-…";                 # unpacked tree
    tarballSha256 = "ad8ab17a…";       # the tarball, to re-check a download
  };
}
```

Three consumers, and no second copy of the numbers:

- `kernel.nix` takes `os` and builds the kernel from `os.kernel`, so the source
  pin *is* the declared OS version instead of a branch name to remember
  separately.
- `system.nix` exposes `rmpp.os.{version,glibc,qt,kernelVersion}` (read-only) and
  writes them into the generation as `$out/os`; `activate.sh` logs the version as
  it applies, and `cat /home/root/.rmpp/current/os` answers "what was this built
  for?".
- The prebuilt bundle is the practical case: it loads the *device's* Qt and
  glibc, not Nix's, which is exactly why those numbers are written down.

Bumping it means editing `os.nix` alone: new `version`, the matching `kernel` pin
from [reMarkable/linux-imx-rm](https://github.com/reMarkable/linux-imx-rm)
(hash of the unpacked tree), and `glibc`/`qt` from the release notes. Then
rebuild `rmpp_kernel` and `rmpp_config` — and expect the prebuilt rmweb bundle to
need an upstream release built for the new OS.

### What activation checks

`activate` is also where the configuration meets reality, and it reports instead
of pretending (`set -eu`, but these never abort — a boot has to finish):

- **OS version.** `/etc/version` is compared (major.minor) with the generation's
  `$gen/os`. A mismatch warns loudly: the kernel pin, glibc and Qt ABI in
  `os.nix` describe another release. The kernel line (`uname -r` vs the declared
  kernel version) is checked too, so a stock kernel — an OTA replaced
  `rmpp_kernel`, or it was never installed — is called out.
- **reMarkable OTA updates.** `rmpp.osUpdates.disable = true` (set in
  `config.nix`) masks the stock updater, `update-engine.service` and
  `updatedb.service` by default, using `systemctl mask`'s `/dev/null` symlink,
  and stops it if it is already running. This is not paranoia: an unattended OTA
  replaces the rootfs — taking `rmpp-config.service` with it — and boots the
  stock kernel. The masks are re-created at every boot because `/etc` is volatile.
- **Vellum packages.** After `vellum add` for each declared package, the result
  is verified against vellum's apk database
  (`/home/root/.vellum/lib/apk/db/installed`), not against `vellum list` output:
  a package that is declared but absent is reported as missing, so an offline
  activation cannot look like success.

Taking an OS update deliberately: set `rmpp.osUpdates.disable = false`, activate,
let the OTA run, then update `os.nix` for the new release, rebuild,
`activate --install-boot-unit`, and reinstall `rmpp_kernel`.

## Nix on the tablet

`rmpp_nix_setup` does the whole dance, because Nix hardcodes `/nix` and `/` is
read-only:

1. `mount -o remount,rw /` (temporary),
2. `mkdir -p /nix` — the empty mountpoint on the rootfs (persists),
3. `mount --bind /home/root/nix /nix` — the store on `/home`, which survives
   OS updates,
4. installs the upstream **static aarch64** Nix release into that store
   (2.35.3 by default, `--version` to override),
5. optionally writes `/etc/systemd/system/nix.mount` (after collapsing the
   `/etc` overlay) so the bind mount is recreated on every boot, ordered after
   `home.mount`,
6. `mount -o remount,ro /` — restores the stock read-only rootfs.

```sh
ssh root@10.11.99.1 sh /tmp/rmpp-nix-setup --persist
# then, in a new shell:
export PATH="/nix/var/nix/profiles/default/bin:$PATH"
nix --version
```

Checks and caveats:

```sh
mount | grep ' /nix '          # the bind mount
findmnt -no SOURCE /nix        # /home/root/nix
mount | grep overlay           # remaining overlay mounts under /etc
```

- `--persist` collapses the `/etc` overlay and re-binds `/etc/dropbear`; if
  `umount -R /etc` fails because a process holds it, close other sessions and
  retry, or run without `--persist` and mount by hand after each boot.
- `--keep-rw` leaves `/` writable, `--no-install` only does the mount.
- After a reMarkable OS update, `/nix` and the mount unit are gone (the rootfs
  slot was replaced) while `/home/root/nix` and the store are intact. Re-run
  the script.
- Do not point the store at a directory outside `/home` unless you accept
  losing it on every update.
- Builds on the device itself are slow: build on the host for
  `aarch64-linux` and copy the closure, or use the packages above.

## Building on an x86_64 host

Because the packages are native `aarch64-linux` derivations (that is what makes
them cache hits), a foreign host has to be allowed to name that platform. The
flake's `nixConfig` already sets `extra-platforms = aarch64-linux` (pass
`--accept-flake-config`, or set it in `nix.conf`):

```sh
nix build --accept-flake-config .#rmpp_tools
```

With only that flag, cache misses fail — the normal case is a cache hit, so
this is usually enough. For real emulation register qemu-user with binfmt_misc
(NixOS: `boot.binfmt.emulatedSystems = [ "aarch64-linux" ];`, other distros:
`systemd-binfmt`), then anything not cached is built under emulation. Do not
try to build `rmpp_rmweb` (WPE WebKit) that way unless you are patient: it is
hours of aarch64 code compiled on an emulated CPU.

## References

- <https://remarkable.guide/faqs.html> — read-only rootfs, `/etc` overlay,
  what survives an update
- <https://developer.remarkable.com/documentation/developer-mode> — developer
  mode, `mount -o remount,rw /`
- <https://github.com/asivery/xovi> and
  <https://github.com/asivery/rm-xovi-extensions> — the extension framework
  and AppLoad
- <https://github.com/vellum-dev/vellum> — package manager for reMarkable OS 3.x
- <https://github.com/koreader/koreader/wiki/Installation-on-ReMarkable> —
  KOReader install steps for aarch64 devices (via vellum/AppLoad)
- <https://github.com/exp78/rmweb> — WPE WebKit browser for the Paper Pro
  (MIT), whose app and engine this repository builds from source
- <https://wpewebkit.org/releases/> — WPE WebKit release tarballs
- <https://github.com/asivery/qtfb> and
  <https://github.com/asivery/rm-appload> — QTFB, the shared-memory framebuffer
  that lets a Qt app built against *any* Qt draw on the panel, plus the AppLoad
  extension that hosts it and its `qtfb-shim` for input/fb emulation
- <https://github.com/asivery/rm-xovi-extensions> — XOVI extensions the device
  stack is built from (qt-resource-rebuilder, AppLoad)
- <https://github.com/MaximeRivest/android-on-remarkable-paper-pro> — Android
  13 on the Paper Pro (MIT), whose runtime and device files `rmpp_android`
  packages and whose kernel fragment/DT patch `rmpp_kernel` builds
- <https://github.com/reMarkable/linux-imx-rm> — reMarkable's published GPL
  kernel source (the branch tarball `rmpp_kernel` builds)
- <https://github.com/skdlzlvk/paper-pro-move-dualboot-installer> — the A/B slot
  layout, boot watchdog behaviour and flash-safety notes behind
  `rmpp_kernel`'s warning
- <https://github.com/numtide/system-manager> — the module → generation →
  activate model `system.nix` follows
- <https://github.com/vellum-dev/vellum> and
  <https://github.com/vellum-dev/vellum-cli> — the apk-based package ecosystem
  (and `mount-utils`) this layer stays out of the way of
- <https://github.com/asivery/rm-appload> — AppLoad external manifests, and the
  `qtfb` flag that allocates a QTFB framebuffer (`QTFB_KEY`)
- <https://github.com/kja140/rmpro-hacks> — field notes for Syncthing,
  Tailscale and friends on the Paper Pro
- <https://nixos.org/manual/nix/stable/installation/installing-binary> —
  single-user Nix installation
