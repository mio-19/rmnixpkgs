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
nix build .#rmpp_nix_setup    # device-side Nix store setup script
```

Two things are worth knowing about how the packages are built:

- **Everything is a native `aarch64-linux` derivation.** The package set is
  `import <nixpkgs> { system = "aarch64-linux"; }`
  (`remarkable/aarch64-pkgs.nix`), not `pkgsCross`. Those are exactly the
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

- `remarkable/rmweb/wpewebkit.nix` — **WPE WebKit 2.48.5** from the
  wpewebkit.org tarball (nixpkgs ships the GTK port and `libwpe`, not
  `wpewebkit`), configured the way upstream configures it: software rendering,
  Skia CPU painting, no GStreamer/video/WebRTC/WebGL, no bubblewrap sandbox,
  WPEPlatform **headless** only.
- `remarkable/rmweb/package.nix` — the **rmweb app** (`engine/wpeqt`, Qt 6
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
draw on with reMarkable's own plugin.

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

Until one of those lands, `rmpp_rmweb_prebuilt` still ships upstream's release
bundle — unchanged from what this repository used before the flake — which uses
the device's own Qt 6.10.3 and therefore does render today:

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

`remarkable/android/default.nix` adapts
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

**The kernel is not packaged.** Android needs binder, PSI, BPF, loop, veth and
friends, which only exist in a rebuilt kernel, and that artifact is
device-version-locked and wiped by every OS update. Upstream's
`kernel/build-kernel.sh`, `install-kernel.sh` and `test-gate.sh` stay the source
of truth; they are installed under `share/rmpp-android/kernel`. Read their
README before flashing anything — the A/B boot counter is what makes a bad
kernel recoverable.

Syncthing is useful headless: run it under `/home/root` and point the web UI at
the device over USB or Wi-Fi.

```sh
ssh root@10.11.99.1
mkdir -p /home/root/syncthing
/nix/store/*-rmpp-tools/bin/syncthing serve \
  --home=/home/root/syncthing --gui-address=0.0.0.0:8384
```

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
  packages
- <https://github.com/kja140/rmpro-hacks> — field notes for Syncthing,
  Tailscale and friends on the Paper Pro
- <https://nixos.org/manual/nix/stable/installation/installing-binary> —
  single-user Nix installation
