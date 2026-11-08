# TODO: build rmweb (and Paper Pro packages) from source with nixpkgs

Goal: stop shipping upstream's prebuilt `rmweb-0.9.7.tar.gz` bundle and stop
using reMarkable's binary Yocto SDK. Compile the engine and the app from source
with nixpkgs' own bootstrap toolchain (`gcc`, `cmake`, `ninja`, `qt6`, `mesa`),
for `aarch64-linux`, so everything is a normal Nix derivation — and package the
Android/Waydroid stack from `android-on-remarkable-paper-pro` the same way.

State: every package evaluates natively on aarch64, and all eight build on
real aarch64 hardware (OrbStack `nixos` VM) — `.#rmpp_tools`,
`.#rmpp_nix_setup`, `.#rmpp_config`, `.#rmpp_android`, `.#rmpp_android_files`,
`.#rmpp_rmweb_prebuilt`, `.#rmpp_rmweb` (engine and app from source) and
`.#rmpp_kernel`, the last one both as the published vendor tree and as
6.12.115-waydroid with the stable chain enabled explicitly (config.nix defaults
to the vendor 6.12.49-waydroid kernel). The 6.12.49-waydroid kernel and declarative
configuration are now live, active, and verified on real tablet hardware running
reMarkable OS 3.28.0.172 on Slot B.

## Kiwix Native Qt Desktop Deployment & Validation (2026-11-08)

- **Native Kiwix Qt Desktop (`kiwix-desktop` 2.5.1):**
  - Upstream: `https://github.com/kiwix/kiwix-desktop` built with `qt6.qtwebengine`, `libkiwix 14.2.1`, `libzim 9.8.2`.
  - Built natively for `aarch64-linux` (`pkgs.kiwix` / `kiwix-2.5.1`) via nixpkgs.
  - Substituted and copied 154-path closure into the reMarkable Paper Pro Nix store (`/nix/store/iax2x9sv594d90qrqkc6wjy7nxi69jk4-kiwix-2.5.1`).
  - Runs natively without headless server daemons: configured with `--no-sandbox` (required for running as root), software GL fallback (`--disable-gpu`), and QTFB integration via `qtfb-shim.so`.
- **Display Scaling & Fullscreen Window Geometry:**
  - Screen resolution is 1620 × 2160 at 226 DPI.
  - Set `disablesWindowedMode = true` in AppLoad manifest so the app launches fullscreen instead of a small window.
  - Configured high-DPI scaling flags in launcher: `QT_ENABLE_HIGHDPI_SCALING=1`, `QT_SCALE_FACTOR=1.75`, `QT_FONT_DPI=226`, and `--force-device-scale-factor=1.75` for Chromium rendering.
  - Text input: External physical keyboard via USB OTG / Bluetooth, or AppLoad on-screen virtual keyboard.
- **AppLoad & QTFB Integration:**
  - Registered AppLoad external application tile `kiwix` in `config.nix` with official vector icon (`kiwix-icon.png`).
  - Manifest configured with `"qtfb": true`, `disablesWindowedMode: true`, `QTFB_SHIM_MODEL="RM1"`, `QTFB_SHIM_RESPECT_APP_REFRESH_MODES="true"`, and `QTFB_SHIM_RESPECT_FULL_REFRESH_REQUESTS="true"`.
  - Launcher script `/home/root/kiwix/kiwix.sh` automatically detects `.zim` archives under `/home/root/zim/` and launches `kiwix-desktop` directly into the e-ink display.
  - Tested opening `/home/root/zim/alpinelinux.zim` on real device.
- **Kiwix Tools CLI (`kiwix-tools` 3.8.2):**
  - `kiwix-tools` added to `rmpp.packages` exposing `kiwix-search`, `kiwix-manage`, and `kiwix-serve` on system PATH (`/home/root/.rmpp/current/bin/`).

## Dual-Reader Strategy: Kiwix Desktop & Native QML Wikipedia Reader

We maintain two complementary readers for offline `.zim` knowledge bases on the Paper Pro, sharing the same storage directory (`/home/root/zim/*.zim`):

1. **Option A: Kiwix Desktop (`kiwix-desktop` 2.5.1)**
   - *Engine:* Full Chromium via QtWebEngine.
   - *Strengths:* Complete HTML5/CSS, complex mathematical formulas, rich media rendering, interactive ZIM webapps.
   - *Display path:* VNC QPA (`-platform vnc:size=1620x2160,port=5900`) bridged to QTFB via `vnsee-qtfb`.
   - *Scale:* High-DPI scaled (1.75x) to match the 226 DPI display.

2. **Option B: Native E-Ink Wikipedia Reader (`rmpp-wikipedia`)**
   - *Upstream base:* `https://github.com/dps/remarkable-wikipedia` (MIT).
   - *Engine:* Pure Qt Quick / QML (no QtWebEngine Chromium overhead, no offscreen surface issues).
   - *Display path:* Direct `linuxfb` / `qtfb-shim.so` or software QML scene on QTFB.
   - *Input:* Native built-in on-screen soft keyboard (`Keyboard.qml`, `KeyboardKey.qml`) tailored specifically for e-paper touch typing, plus swipe gesture pagination (`SwipeArea.qml`).
   - *Eliminating `kiwix-serve` via C++ QObject (`libzim`):*
     - The original upstream app relied on running an external `kiwix-serve` HTTP daemon on port 8081 and issued `XMLHttpRequest` network calls.
     - We eliminate `kiwix-serve` entirely by writing a small C++ `QObject` backend (`ZimBackend`) linking directly against `pkgs.libzim` 9.8.2.
     - Directly loads `zim::Archive` in-process from `/home/root/zim/*.zim`.
     - Exposes `Q_INVOKABLE QString getArticleHtml(const QString &titleOrPath)`, resolving redirects (`entry.getItem(true)`) and returning article HTML in memory without sockets or HTTP overhead.
     - Exposes `Q_INVOKABLE QVariantList searchSuggestions(const QString &prefix, int limit = 8)` using `zim::SuggestionSearcher` against the archive's internal title index.
     - Exposes `Q_INVOKABLE QString getMainPage()` and `Q_INVOKABLE QStringList listArchives()`.

## Analysis: `gitman-101111/chiappa` (reMarkable Paper Pro Move)

Analysis of `https://github.com/gitman-101111/chiappa` for applicability to our Paper Pro (`ferrari`) project:

- **Target Device Distinction:**
  - `chiappa` targets the **reMarkable Paper Pro Move** (FCC ID `2AMK2-RM03AA`, NXP i.MX 93 with 2× Cortex-A55 @ 1.7 GHz, 2 GB LPDDR4, 1696×954 264 DPI Gallery 3 color e-paper).
  - Our project targets the **reMarkable Paper Pro** (codename `ferrari`, NXP i.MX 8M Mini with 4× Cortex-A53, Vivante GC600 GPU, 1620×2160 226 DPI Gallery 3 color e-paper).
- **Display Pipeline Architecture:**
  - `chiappa`: SoC LCDIFv3 connects directly via a 16-bit parallel RGB bus (`imx93-parallel-display-format`, RGB565) to `panel-rm-cumulus` at 365×1700 transport framing. There is no FPGA bitstream and no Vivante GPU.
  - `ferrari` (our device): LCDIF connects to the Vivante GC600 GPU (`etnaviv`), which transmits frames over MIPI-DSI to an FPGA display controller (`rm-cumulus-bridge.c`).
- **Valuable Components & Techniques for our Project:**
  - **VKMS Writeback Bridge (`eink/src/vkms_bridge.c`):** An elegant alternative to `wlr-screencopy` for generic Wayland compositors. Instead of patching compositors or using Wayland protocols, the bridge configures DRM VKMS with writeback (`modprobe vkms enable_writeback=1`) and creates DRM leases (`drmModeCreateLease`) handing CRTC/planes to compositors. The compositor flips planes as if on real hardware, and the bridge captures composited frames via the DRM writeback connector. This concept can be adapted to any Linux compositor without protocol dependencies.
  - **Elan Touch PM rules (`eink/60-chiappa-touch.rules`):** Udev rules configuring runtime power management and autosuspend parameters for Elan SPI touch/pen (`elants_spi`), which can improve touch responsiveness and stylus power behavior.
  - **Recovery & Bootloader Documentation (`docs/booting-a-custom-os.md`, `recovery/`):** Detailed walkthroughs of NXP ELE / AHAB lifecycle states (`unlocked=yes` Developer Mode), U-Boot FIT image signing verification bypass, and USB SDP recovery scripts (`rm_recover` / `uuu`).

## Firmware 3.28 Deployment & Device Validation (2026-11-08)

- **Multi-Firmware Support (3.27 & 3.28):** `os.nix` now houses a release registry
  supporting both `3.27` and `3.28` releases with exact kernel tarball pins,
  SHA256 hashes, device tree targets, and ABI definitions (`gcc13Stdenv`). Selected
  via declarative option `rmpp.os.version` in `config.nix`.
- **Kernel Build Fixes for 3.28:**
  - Added `zstd` to `nativeBuildInputs` in `kernel.nix` because 3.28's
    `imx8mm_ferrari_defconfig` enables `CONFIG_MODULE_COMPRESS_ZSTD=y`.
  - Retained `./scripts/config --disable CONFIG_RELR` to avoid arm64 relocation
    packing faults on U-Boot raw Image boot.
  - Built with GCC 13.5.0 (`gcc13Stdenv`) matching reMarkable's Yocto GCC 13.4.0 toolchain.
- **Hardware Watchdog & Failover Root Cause:**
  - Hardware LPGPR registers (`/sys/devices/platform/lpgpr/roota_errcnt` and `rootb_errcnt`)
    track consecutive boot failures. When an errcnt reaches 3, U-Boot flags the partition
    bad and automatically switches to the opposite slot passing `systemd.setenv=RESCUE=1`.
  - The stock OS only clears error counters at clean shutdown via
    `/usr/sbin/rm-reset-boot-count.sh` (which skips clearing if `/tmp/rm-emergency` exists).
  - The previous 3-boot loop on Slot B was caused by a systemd mount ordering cycle in
    `nix.mount`: without `DefaultDependencies=no`, `nix.mount` acquired an automatic
    `Before=local-fs.target` dependency while requiring `home.mount` (which is opened by
    `homecryptor` after `basic.target`). This circular dependency tripped `emergency.target`,
    which runs `/usr/sbin/rm-emergency.sh` and immediately reboots the device without
    clearing the error counter.
  - Fixed by adding `DefaultDependencies=no`, `Conflicts=umount.target`, and `Before=umount.target`
    to `nix.mount` in `nix-setup.sh`.
- **Live Device Verification on 3.28.0.172 (Slot B):**
  - Kernel: `Linux imx8mm-ferrari 6.12.49-waydroid #1 SMP PREEMPT Sun Nov 8 07:02:58 UTC 2026 aarch64`
  - OS Release: `IMG_VERSION="3.28.0.172"`, active slot `b`, `roota_errcnt=0`, `rootb_errcnt=0`.
  - GPU: Vivante GC600 rev 4653 bound and initialized by `etnaviv` (`/dev/dri/renderD128` active).
  - Android/Waydroid support: `binderfs` active (`nodev binder`), CMA pool 640 MiB allocated.
  - Declarative boot unit: `nix.mount` and `rmpp-config.service` active and verified.
  - AppLoad & rmweb hybrid layout: `rmpp_rmweb_prebuilt` (`mr14gr90a33l...`) copied into Nix store.
    `/home/root/rmweb` configured as a lightweight (~500 KB) hybrid directory: runtime files (`.lock`,
    `rmweb.log`, `appload-entry.sh`, `ovl/`) live directly on `/home`, while large read-only trees
    (`lib/`, `bin/`, `libexec/`, `share/`, `appload/`) symlink into `/nix/store`, saving ~600 MB.
    AppLoad manifest configured with `disablesWindowedMode=true` and pointing to `appload-entry.sh`
    (`systemd-run --scope`) to prevent xochitl cgroup cleanup from terminating the browser on startup.
  - Vellum: 14 packages managed and synchronized with `config.nix`.

## Local Waydroid implementation (2026-11-07)

The earlier audit below describes the initial missing integration. It has now
been implemented locally; tablet hardware validation remains open.

- `einkbridge.c` independently implements wlr-screencopy v3/SHM, padded-stride
  RGB/BGR handling, Y inversion, nearest-neighbor scaling, grayscale/Bayer
  dithering, pixel-difference dirty rectangles, a PGM test backend, and a local
  worker IPC backend. It is C, not a reconstruction of the missing Rust files.
- `quill-host.c` isolates the vendor display stack. It uses the system loader
  from `os.nix`, checks the pinned Qt version, and loads Quill before Qt/vendor
  so constructor observation and RTLD_NEXT resolution work. The worker validates
  rectangle bounds and converts dirty grayscale rows into Quill's RGB32 buffer.
- `quill.nix` builds upstream Quill commit
  `39262ee0bef69915e3ead3ac218d5973916f422a` with GCC 13 and matching public Qt
  headers/libraries compiled from the official source archive pinned in
  `os.nix`. Qt 6.10.3 was freshly compiled in OrbStack (2147 build steps).
  Quill's runtime RPATH is `/usr/lib`: the worker loads device libraries,
  not the source-built Nix Qt. No proprietary library is redistributed.
  Both worker and Quill builds reject direct GLIBC symbol requirements newer
  than `os.glibc`; loading with RTLD_NOW checks the remaining runtime symbols.
- `android.py` replaces the Debian bootstrap: manifest-owned persistent root,
  private mount namespace and `/dev`, pivot_root, Nix-store bind, D-Bus/gbinder,
  runtime image initialization, GBM configuration, seatd/labwc, Waydroid
  container/session and a tracked bridge. libinput supplies physical input
  through Wayland. Airplane Mode exits after Android boot completes.
- `rmpp.android.enable` installs a manual-only `rmpp-android.service`, PATH
  tools and an owned `rmpp-android` AppLoad tile. No sidebar QML patch or
  upstream installer is applied. The service never starts Android at boot.
  Cleanup waits for bridge shutdown before namespace teardown and xochitl
  restart. Tagged live descendants block recovery; SendSIGKILL=no preserves
  the opportunity for vendor display teardown.
- Verified in OrbStack: sanitizer frame/damage tests; worker ABI/bounds tests;
  real source-built Quill initialization and swaps against a fake vendor using
  matching Qt (validates QImage interposition); white/black frame capture from
  real labwc and clean SIGTERM; seven controller tests; private pivot_root
  namespace with Waydroid --version and a private D-Bus GetId round trip.
- Reproduce builds: `nix build --accept-flake-config .#rmpp_android .#rmpp_config`.
  Checks: `nix flake check --accept-flake-config` in the aarch64 OrbStack VM.
  The long Qt compile is necessary to build the public boundary against the
  pinned ABI; unrelated caches/toolchains have not been replaced.
- Still to verify on the tablet: actual vendor loading and panel selection,
  safe handoff/recovery, LXC/cgroups/Binder and networking, image boot, etnaviv
  rendering, touch/pen orientation and pressure, memory use and suspend.
  `rmpp-android doctor` is a prerequisite check, not proof of panel operation.
  Android OTA images are runtime downloads, not source-built or pinned here.

## Review verification (2026-11-07)

- Fixed kernel Nix string delimiters and removed the comment-only optional
  vendor fixup that made the stable-chain build fail with "Only garbage was
  found in the patch input".
- Fixed activation ownership: foreign/dangling AppLoad symlinks and foreign
  `<app>.tmp` entries survive; vellum records only successful new installs,
  retains ownership with cleanup off, and retries failed removals. First
  activation creates its state directory before writing the vellum ledger.
- Kept the generated activation shebang at `#!/bin/sh`; rejected traversal,
  shell metacharacters and invalid modes in managed paths at module evaluation.
- Removed the Nix mount's ordering after `local-fs.target`, which conflicts
  with local mounts' default ordering before that target.
- `python3 test-activation.py`: three regression tests pass on macOS and
  OrbStack. `sh -n` and ShellCheck at warning severity pass for both shell
  scripts; `systemd-analyze verify` accepts the Nix mount unit. Eight module
  evaluation checks pass (valid config, seven malformed config rejections).
- In OrbStack `nixos`, all eight default packages build with:
  `nix --extra-experimental-features "nix-command flakes" build --accept-flake-config --no-link --print-out-paths --cores 6 .#rmpp_tools .#rmpp_nix_setup .#rmpp_android_files .#rmpp_android .#rmpp_rmweb_prebuilt .#rmpp_rmweb .#rmpp_kernel .#rmpp_config`.
  Setup and configuration were rebuilt; other outputs were already in the VM
  store. This was not a fresh WebKit compilation. All eight
  `packages.x86_64-linux.<name>.drvPath` attributes also instantiate.
- Kernel audit now counts actual `@@` reject hunks: **163 across 100 files**,
  with 25 clean and 41 partial patches. It retains per-level `.rej` contents,
  patch logs and syscore reversal logs under `share/rmpp-kernel/`.
- Fresh opt-in stable kernel compilation succeeded at
  `/nix/store/jl63m7dm4hmf2ixix33r3myz2y4qw7ff-rmpp-kernel-6.12.115`.
  Verified `fitImage`, `Image`, modules for `6.12.115-waydroid`, four Ferrari
  device trees, `CONFIG_DRM_ETNAVIV=m`, `CONFIG_DRM_SCHED=m`, 66 patch logs,
  100 per-level reject files containing 163 hunks, and the syscore reversal log.
  To reproduce through the flake, set
  `rmpp.kernel.securityPatches.enable = true` in `config.nix`, then run
  `orb -m nixos bash -lc 'cd ~/rmnixpkgs-review && nix --extra-experimental-features "nix-command flakes" build --accept-flake-config --cores 6 -L .#rmpp_kernel'`
  after syncing the checkout. Check those same artifacts and audit the raw
  rejects against the explicit ports; a successful build does not prove every
  security fix applied. The review built this variant with `callPackage`
  overrides and left the device configuration's switch off.
- No tablet activation, boot or display test has been performed.

## Historical Waydroid audit and source search (before local implementation)

- **Not an end-to-end Android implementation yet.** `rmpp_android` is a
  prerequisite toolkit. The upstream Debian-root namespace, image initialization,
  D-Bus policy, binder/cgroup setup, GPU properties, display/input bridge,
  takeover/teardown and launcher integration are not installed by this flake.
- Missing Rust entry points are an upstream problem, confirmed by
  https://github.com/MaximeRivest/android-on-remarkable-paper-pro/issues/1
  and the pinned Cargo manifest:
  https://github.com/MaximeRivest/android-on-remarkable-paper-pro/blob/65b5bf34fb3ef160e3d483a14484b46304ecbc7c/einkbridge/Cargo.toml
  Both declared Rust files are absent. Verified through GitHub recursive trees,
  `git ls-remote`, the one public branch, empty pull/release lists, and empty
  commit history for `einkbridge/src/main.rs`.
- Public forks checked: https://github.com/mio-19/android-on-remarkable-paper-pro
  and https://github.com/1C8Flyers/android-on-remarkable-paper-pro ; both point
  to the identical upstream commit. No replacement was found in the author's
  `remarkable-experiments`, `rmpp-display-notes`, `remagic`, `riddle`, `chromium`
  repositories or public gists, or via indexed web/code searches. grep.app
  returned HTTP 429, so that index was not exhaustively searched.
- A similarly named bridge has source at
  https://github.com/gitman-101111/chiappa/tree/main/eink but targets the Paper
  Pro Move with rm2fb/VKMS and vendor QPA. It is not this Rust wlr-screencopy
  bridge and is not a drop-in replacement for ferrari.
- https://github.com/MaximeRivest/quill has source (inspected commit
  `39262ee0bef69915e3ead3ac218d5973916f422a`). Its build and vendor/README.md
  require the device's `libqsgepaper.so` and matching Qt boundary. No proprietary
  display binary has been added to this repository.
- Added missing direct prerequisites from upstream `session.sh`/`enter.sh`:
  seatd, wlr-randr, D-Bus, Bash/coreutils/procps/util-linux, LXC, kmod, iproute2,
  iptables and dnsmasq. Removed the redundant standalone wlroots package;
  labwc already links the version it was built against. Included upstream's
  Cargo metadata and license with the reference files.
- Added `checks.<system>.rmpp_waydroid_kernel`: verifies **159** settings,
  actual etnaviv/scheduler/veth/bridge/tun/NAT modules, module archive, kernel
  images, and enabled Vivante GPU nodes in all four Ferrari DTBs. Passes for
  both cached 6.12.49-waydroid and the freshly built 6.12.115-waydroid output.
  The fragment's only discarded positive symbol is `CONFIG_NFT_COUNTER`, which
  no longer exists: `nft_counter.o` is part of `nf_tables` unconditionally.
  https://github.com/torvalds/linux/blob/v6.12/net/netfilter/Makefile#L79-L98
- Runtime smoke testing uses headless pixman in OrbStack, not the tablet GPU.
  Confirmed an 810x1080 output and `zwlr_screencopy_manager_v1` v3 plus virtual
  pointer/keyboard globals; Waydroid reports version 1.6.3. The packaged
  `rmpp_waydroid_runtime` check passes inside the Nix build sandbox.
  `nix flake check --all-systems --no-build` also passes (evaluation only).
- Rebuild/check command in OrbStack (after syncing):
  `nix --extra-experimental-features "nix-command flakes" build --accept-flake-config --no-link --print-out-paths .#rmpp_android .#rmpp_android_files .#rmpp_kernel .#checks.aarch64-linux.rmpp_waydroid_kernel .#checks.aarch64-linux.rmpp_waydroid_runtime`.
- Resolution: the local implementation above replaces the missing bridge and
  private-root lifecycle. Device bring-up still requires a kernel backup and
  the documented A/B fallback; upstream architecture prose is not a device test.

## Verified facts (don't re-research)

### Builds on aarch64 (verified)

Everything below ran natively in an OrbStack `nixos` VM (NixOS 26.11,
aarch64-linux, 9 cores, 15 GB) against a copy of this tree — the VM user cannot
read the macOS checkout over virtiofs, and the flake's `nixConfig` is not
honoured without `--accept-flake-config`:

```sh
tar --exclude=.git -cf - . | orb -m nixos bash -lc \
  'rm -rf ~/rmnixpkgs && mkdir -p ~/rmnixpkgs && tar -xf - -C ~/rmnixpkgs'
orb -m nixos bash -lc 'export NIX_CONFIG="experimental-features = nix-command flakes";
  cd ~/rmnixpkgs && nix build --accept-flake-config -L --cores 6 .#rmpp_kernel'
```

`/etc/nix` is read-only there, so flakes/extra-platforms are set per command.

- `wpewebkit` 2.48.5: **compiles and installs** (hours at `--cores 6`; needs
  the RAM). Two source-build blockers, both fixed in `wpewebkit.nix`: WebKit's
  `FindHarfBuzz` requires the ICU component (`harfbuzz.override { withIcu =
  true; }` — nixpkgs' plain `harfbuzz` has no `harfbuzz-icu.pc`), and CMake
  ≥ 4.4 rejects the malformed `if()` that `Source/cmake/WebKitMacros.cmake`
  generates for a framework not yet linked anywhere (upstream fix applied with
  `substituteInPlace`, URLs in the file).
- `rmweb` 0.9.7: **compiles and links** against that engine. `wpe-webkit-2.0.pc`
  declares `Requires: glib-2.0 libsoup-3.0 wpe-1.0 wpe-platform-2.0`, and
  pkg-config resolves a `.pc` file's `Requires` through the *consumer's*
  `PKG_CONFIG_PATH`,so the app needs `libsoup_3` and `libwpe` in `buildInputs` (moving them to
  `wpewebkit.nix`'s `propagatedBuildInputs` would be tidier for every consumer
  but rebuilds the engine). Two install-side requirements: `dontWrapQtApps =
  true`, because `rmweb.nix` builds its own wrapper and Qt's hook would wrap it
  again, and `install -d $out/bin` before the `rmweb` symlink (everything else
  goes to `libexec/`/`share/rmweb`). Compilation verified on this host against
  nixpkgs' aarch64 toolchain: AArch64 ELF PIE, `ldd` reports no unresolved
  sonames, RUNPATH is `$ORIGIN/../lib` plus the Qt/WPE/glib/libsoup/libwpe/
  glibc/gcc-lib store dirs, and the wrapper carries
  `WEBKIT_INJECTED_BUNDLE_PATH`, `GALLIUM_DRIVER`, `QT_QPA_PLATFORM`. The
  derivation sits at
  `/nix/store/hqmzq7g6j4l03hqy9ci3rrzgiqbcb1wg-rmweb-0.9.7.drv`; it has **not**
  rendered a frame on device — the display path is still open (see below).
- `rmpp_kernel` 6.12.49-waydroid (chain off): **builds**, in about 4 minutes at
  `--cores 6` once the toolchain is warm. Verified output: `fitImage` 15 MB
  (FIT built by `mkimage -f ferrari.its`; the build log lists `kernel-1` and
  the `conf-freescale_ferrari-rev-*` configs), `Image` 15 MB, 605 dtbs in
  `dtbs/` including `ferrari-rev-c` … `ferrari-rev-f`, the patched
  `ferrari-rev-f.dtb` reading `gpu@38000000 { compatible = "vivante,gc"; }`,
  `lib/modules/6.12.49-waydroid` plus `modules-6.12.49-waydroid.tar.gz`
  (3.6 MB), and `share/rmpp-kernel/config` with `CONFIG_DRM_ETNAVIV=m`,
  `CONFIG_DRM_SCHED=m`, `CONFIG_LOCALVERSION="-waydroid"`. With the chain off
  there is deliberately no `share/rmpp-kernel/security-*` file: absence means
  "no fixes applied", not "all applied".
- `rmpp_kernel` 6.12.115-waydroid (chain on): **builds**, same recipe and time.
  Verified: `fitImage` 15,548,032 bytes, `Image` 15,335,432, 605 dtbs (4
  `ferrari-rev-*`), modules in `lib/modules/6.12.115-waydroid` plus 3.8 MB
  tarball, `CONFIG_DRM_ETNAVIV=m`/`CONFIG_DRM_SCHED=m`, and
  `share/rmpp-kernel/security-patches` recording 25 clean / 41 partial and the
  163 rejected hunks, plus every backport and port applied. That is the opt-in stable-chain build;
  the derivation is the build-time chain application, not a committed reversed
  artifact (see below).

- A `make -k` sweep in a `--keep-failed` tree is useful for listing failures
  but is not proof: it once hid an `io_uring` error because the `.o` predated
  the patch that broke it. The clean `nix build` is the arbiter.
- Four build-system traps fixed while getting there: `dtc` must be in
  `nativeBuildInputs` (`mkimage -f ferrari.its` shells out to it; the in-tree
  `scripts/dtc` is not on PATH); `installPhase` must use
  `cd "$NIX_BUILD_TOP"/kernel`, because phases inherit the build tree's cwd and
  Linux sources have their own `kernel/` subdirectory; GNU findutils 4.11
  rejects `-exec cp {} $out/dtbs/ +` ("missing argument to `-exec'", so `cp -t`
  is used); and `modules_install`'s absolute `build`/`source` symlinks have to
  go before the tarball is cut (they dangle and `fixupPhase` refuses them).

### Device
- Paper Pro "ferrari": i.MX8MM, 4x Cortex-A53, OS 3.28 (Yocto scarthgap),
  **glibc 2.39**, kernel 6.12.49, BusyBox userland, 500 MB read-only rootfs.
- Display: **no `/dev/fb*`**, no render node, no EGL/GL/Vulkan/GBM/Wayland.
  xochitl is **Qt 6.10.3** and presents through the closed-source QPA plugin
  `/usr/lib/plugins/platforms/libepaper.so` ("epaper" QPA) -> imx-drm.
  Only other QPA plugins on device: offscreen, minimal, vnc.
- No compiler on device; `/home` (46 GB) is the only writable, OTA-surviving place.
- The Android project proves the panel can be driven *without* the epaper QPA:
  labwc (wlroots) + `einkbridge`/quill over the panel, GPU via etnaviv once
  `kernel/gpu-etnaviv-dt.patch` is applied.

### rmweb upstream (github.com/exp78/rmweb, MIT, v0.9.7 tag)
- App source: `engine/wpeqt/` — CMake, C++17, **single `main.cpp`**, needs
  `Qt6 Gui Qml Quick` + pkg-config `wpe-webkit-2.0 wpe-platform-2.0 glib-2.0
  gobject-2.0`. Flags: `QT_NO_KEYWORDS`, `-rdynamic`, `INSTALL_RPATH
  "$ORIGIN/../lib"`, `BUILD_WITH_INSTALL_RPATH`, `-fstack-protector-strong`,
  RELRO/bind-now. No install rules (upstream assembles the bundle by script).
- Engine: **WPE WebKit 2.48.5** from
  `https://wpewebkit.org/releases/wpewebkit-2.48.5.tar.xz`
  (`sha256-AfNgEHBa2xRATFa68DMUf3knzHxrreyBuxQSZvzdjQs=`).
  Configure options used upstream (`engine/build-wpe.incontainer.sh`):
  `-DPORT=WPE -DUSE_SKIA=ON -DUSE_GSTREAMER=OFF -DENABLE_VIDEO=OFF
  -DENABLE_WEB_AUDIO=OFF -DENABLE_MEDIA_SOURCE=OFF -DENABLE_MEDIA_STREAM=OFF
  -DENABLE_WEB_CODECS=OFF -DENABLE_SPEECH_SYNTHESIS=OFF -DENABLE_WEBGL=OFF
  -DENABLE_WEBXR=OFF -DENABLE_WEB_RTC=OFF -DENABLE_SPELLCHECK=OFF
  -DENABLE_GAMEPAD=OFF -DENABLE_BUBBLEWRAP_SANDBOX=OFF
  -DENABLE_INTROSPECTION=OFF -DENABLE_DOCUMENTATION=OFF -DUSE_AVIF=OFF
  -DUSE_JPEGXL=OFF -DUSE_LIBHYPHEN=OFF -DENABLE_JOURNALD_LOG=OFF
  -DENABLE_WPE_PLATFORM=ON -DENABLE_WPE_PLATFORM_HEADLESS=ON
  -DENABLE_WPE_PLATFORM_DRM=OFF -DENABLE_WPE_PLATFORM_WAYLAND=OFF
  -DENABLE_WPE_QT_API=OFF -DUSE_ATK=OFF -DUSE_WOFF2=OFF
  -DUSE_LIBBACKTRACE=OFF -DUSE_SYSPROF_CAPTURE=OFF -DENABLE_MINIBROWSER=OFF
  -DENABLE_COG=OFF -DENABLE_API_TESTS=OFF -DENABLE_WEBDRIVER=OFF`
  (plus `-latomic` linker flags and their `engine/atomic16.c` shim, which the
  nixpkgs toolchain does not need because it has libatomic).
- Extra deps upstream cross-builds (hashes in `scripts/build-wpe.sh`):
  libwpe 1.16.2, libtasn1 4.19.0, libxslt 1.1.39, harfbuzz 8.3.0 (`-icu`).
  nixpkgs provides all of them, so they are not built here.
- Bundle layout at `/home/root/rmweb`: `bin/rmweb-wpeqt`, `lib/`, `lib/dri/`,
  `lib/gio/modules/`, `libexec/wpe-webkit-2.0`, `lib/wpe-webkit-2.0` (injected
  bundle), `share/wpe-webkit-2.0`, `share/reader/Readability*.js`, `rmweb`,
  `rmweb-env.sh`, `install.sh`, `appload-entry.sh`, `appload/`, `icon.svg`,
  `VERSION`.
- Runtime env (`rmweb-env.sh`): `QT_QPA_PLATFORM=epaper`,
  `QT_QUICK_BACKEND=epaper`, `QSG_RENDER_LOOP=basic`, `GALLIUM_DRIVER=llvmpipe`,
  `LIBGL_ALWAYS_SOFTWARE=1`, `EGL_PLATFORM=surfaceless`, `LIBGL_DRIVERS_PATH=$R/lib/dri`,
  `WEBKIT_SKIA_ENABLE_CPU_RENDERING=1`, `WEBKIT_INJECTED_BUNDLE_PATH=...`,
  `GIO_EXTRA_MODULES=$R/lib/gio/modules`, `WEBKIT_FORCE_VBLANK_TIMER=1`,
  `WEBKIT_DISABLE_SANDBOX_THIS_IS_DANGEROUS=1`, `RMWEB_READER_DIR`,
  `JSC_useJIT`/`RMWEB_JIT`.

### nixpkgs (nixos-unstable at time of writing)
- Has: `libwpe` 1.16.3, `libwpe-fdo`, `cog`, `webkitgtk_6_0` 2.54.1, `mesa`
  26.2.6, `qt6.qtbase` **6.12.0**, `qt6.qtdeclarative`, `libsoup_3`, `harfbuzz`,
  `libxslt`, `libtasn1`, `libepoxy`, `waydroid` 1.6.3, `labwc` 0.20.2,
  `wlroots`, `wayland-utils`.
- Does **not** have: `wpewebkit`, `wpebackend-fdo` (named `libwpe-fdo`).
  => WPE WebKit must be packaged here from the upstream tarball.
- This dev host: x86_64, 16 cores, **binfmt for `aarch64-linux` is registered**
  (`extra-platforms` via the flake's `nixConfig`; unprivileged users need
  `--accept-flake-config` or `--option extra-platforms aarch64-linux`).
  Emulated builds are slow; a WEBKIT build here is not practical.

### reMarkable SDK (rejected, for the record)
- Public installers exist for both hosts
  (`.../remarkable-production-image-5.7.119-ferrari-public-{x86_64,aarch64}-toolchain.sh`,
  ~467 MB). The aarch64 one refuses to install on x86_64.
- **Decision: do not use it.** Binary SDK/toolchain + binary Qt is exactly what
  we are getting away from.

### Kernel / boot
- Source: reMarkable's GPL tarball, branch `rmpp_6.12.49_v3.27.x`, file
  `linux-imx-rel-5.7-wd-3.27.2.1-f21cbcc9ed9a.tar.gz`,
  sha256 `ad8ab17a897bb35ecec877f6b3e7e766a534ce25e46766991f7ec92b276e583f`,
  259,818,958 bytes (also published by the dualboot installer's
  `docs/KERNEL-SOURCE.md`, which verified it file-by-file). Unpacked-tree hash
  used by `fetchzip`: `sha256-2OFtlMGX44zyuOvj9OeC1JsAFFOX7BMubFuGs2f0TKU=`.
- Recipe (upstream `kernel/build-kernel.sh`): `ferrari_defconfig` → merge
  `waydroid.cfg` with `scripts/kconfig/merge_config.sh -m` → `olddefconfig` →
  `make Image dtbs modules` → `modules_install` (INSTALL_MOD_STRIP=1) →
  `mkimage -f ferrari.its fitImage`. `ferrari.its` ships in the tarball and
  refers to `arch/...` relatively (that is why the build is in-tree here).
- `waydroid.cfg` sets `CONFIG_LOCALVERSION="-waydroid"`, so the release is
  `6.12.49-waydroid` (`6.12.115-waydroid` with the stable chain on); modules
  land in `/lib/modules/<release>` on the device.
- Stable chain, measured on the real tree (x86_64 host, GNU patch 2.8,
  `patch -p1 --batch --forward --fuzz=2`, 66 patches 6.12.49 → 6.12.115):
  **25 apply cleanly, 41 partially, 163 hunks rejected**; the Makefile still
  lands on `SUBLEVEL = 115`, so no patch to the version was lost. Rejects sit
  where reMarkable's NXP base differs from vanilla: `imx8-isi`,
  `freescale` networking (`enetc`, `dpaa2`), `fsl-edma`, `gpio-mxc`,
  `pmdomain/imx`, `fsl_sai`/`ak4458`, i.MX `*.dtsi` — plus a few core ones:
  `arch/arm64/include/asm/io.h`, `tlbflush.h`, `drivers/bus/simple-pm-bus.c`,
  `drivers/net/phy/phylink.c`, `drivers/spi/spi-imx.c`.
- `patch --forward` also *silently skips* hunks the tree already contains
  ("Reversed (or previously applied) patch detected") — several NXP fixes are
  already in reMarkable's tree that way. That is why the chain reports per patch
  instead of trusting an exit code. The build counts a patch as partial when it
  leaves a `.rej` **or** when its log shows `FAILED` / `can't find file to
  patch`, which is why the shipped counter says 25 clean / 41 partial where a
  naive "no `.rej` file" tally says 26 / 40: one patch only skipped hunks for
  files the vendor tree does not have.
- GPU: `gpu-etnaviv-dt.patch` rewrites `gpu@38000000` in `imx8mm.dtsi` to
  `compatible = "vivante,gc"`, `status = "okay"`, clocks `reg/bus/core/shader`;
  the fragment adds `CONFIG_DRM_ETNAVIV=m` + `CONFIG_DRM_SCHED=m`. Stock OS has
  neither, hence rmweb's "no GPU driver" profile.
- Boot: two rootfs slots (`root_a`/`root_b`), `/boot/fitImage` hash-checked in
  developer mode, `lpgpr` errcnt/p`root_part` sysfs counters, boot watchdog
  flips slots after repeated late-UI reboots (dualboot installer notes).
  `install-kernel.sh` backs the stock fitImage up to
  `/home/root/waydroid/backup` and renames the new one into place atomically.
- Stable chain on this tree: the switch is **off** by default; enabling it builds at
  6.12.115-waydroid. The chain itself still reports **25 clean / 41 partial /
  163 rejected hunks** (measured above); what changed is that the tree now
  compiles with those applied, by carrying the smallest patch for every place
  where a chain level and reMarkable's NXP code disagree. Eight files, each
  with the upstream incr-patch URL in its header and no formatting-only change:
  - `kernel-ioremap-prot.patch` — arm64 `ioremap_prot`; without it `io.h` calls
    `__ioremap_prot()` undeclared.
  - `kernel-gpio-mxc-backports.patch` — `both_edges`/`wakeup_pads` to
    `unsigned long` and the missing `is_imx8qm` local (6.12.80-81, 114-115).
  - `kernel-iw61x-monitor-channel.patch` — the NXP wifi driver's guard for the
    `net_device` argument 6.12.100 backported into `set_monitor_channel`.
  - `kernel-reset-control-flags.patch` — two `of_reset_control_array_get()`
    callers to `RESET_CONTROL_EXCLUSIVE` (6.12.90-91).
  - `kernel-imx-gpcv2-gpumix-hsk.patch` — drop the GPUMIX handshake the chain
    removed from the parent domain entry (6.12.69-70).
  - `kernel-imx8m-blk-ctrl-errata-field.patch` — the `is_errata_err050531`
    member, default false: no domain in this tree sets it.
  - `kernel-imx8mp-blk-ctrl-power-nb.patch` — the per-domain notifier member
    and its add/remove calls (6.12.69-70).
  - `kernel-optee-supp-pop-entry.patch` — `supp_pop_entry()` loses the `id`
    parameter the chain dropped (6.12.93-94).
- The 6.12.114 syscore revert is **derived at build time**, not committed:
  `kernel.nix` decomposes the upstream `.xz` and reverses only the diff blocks
  that use `syscore_ops`. That filter selects exactly the 109 files the rework
  touched; reversing the whole 1171-file patch also reverts io_uring and
  smart-suspend fixes that must stay. It is a refactor, not a security fix, and
  reMarkable's irq-gic-v3/imx-gpcv2/gpio-vf610/pinctrl-imx/scu-pd were not
  converted. The build ships the derived subset as `syscore-revert.patch`.
- The 163 raw-chain rejected hunks (across 100 rejected files) are recorded
  before the explicit ports and syscore reversal. They must be assessed against
  those later steps before classifying a fix as missing. The raw rejects are
  listed per file in `share/rmpp-kernel/security-patch-rejects`, and sit in
  NXP/vendor code (`imx8-isi`, `enetc`, `fsl-edma`, i.MX dtsi, …) whose context
  vanilla upstream does not have. Nothing was reformatted to make one apply.
- **Compilation under the security chain has been run**, for the first time when
  this was written. The previous sentence still holds: the build compiles with
  the 25 clean / 41 partial applied, by carrying those eight patches plus the
  build-time syscore revert. The raw reject count describes chain application
  before those ports, rather than the final number of missing fixes. The
  build is the base case the checklist depends on; chasing the 163 raw-chain rejects is
  the next item, not a precondition for it.

### Ecosystem on the device (what a config layer must not break)
- **vellum** (`https://github.com/vellum-dev/vellum`, apk-based) keeps
  everything in `/home/root/.vellum/`: `bin/{vellum,apk.vellum,mount-rw,mount-restore}`,
  `etc/apk/{repositories,keys}`, `lib/apk/db` (package database), `local-repo/`,
  `cache/`, `state/`. Virtual packages `rm1/rm2/rmpp/rmppm/rmppure` and a
  dynamically generated `remarkable-os` version package gate compatibility.
  `vellum reenable` runs `post-os-upgrade` hooks after an OS update.
- **XOVI**: `/home/root/xovi/` with `xovi.so` LD_PRELOADed into xochitl,
  extensions in `extensions.d/`, `exthome/` for extension data. Triple-press
  power starts it; it does not survive a reboot by itself.
- **AppLoad**: external apps are directories under
  `/home/root/xovi/exthome/appload/<name>/` with `external.manifest.json`
  (`name`, `application`, `args`, `environment`, `workingDirectory`, `qtfb`,
  `disablesWindowedMode`), plus `icon.png`. `"qtfb": true` makes AppLoad allocate
  a shared-memory framebuffer and pass its ID as `QTFB_KEY`.
- QMD mods live in `/home/root/xovi/exthome/qt-resource-rebuilder/`.
- Consequence: a Nix layer owns only paths it records; `/etc` is a tmpfs overlay,
  so units/files are re-applied at boot (that is what `rmpp-config.service` is).
- vellum CLI surface used here: `vellum add <pkg>`, `vellum del`, `vellum purge`
  (sets `VELLUM_PURGE=1` for scripts), `vellum update`, `vellum list`,
  `vellum reenable` (after an OS update), `vellum testing {enable,disable}`.
  The wrapper lives at `/home/root/.vellum/bin/vellum` and is an apk build, so
  the apk database — not Nix — stays the truth for what is installed.

### KOReader upstream & build findings (deferred)

- **Architecture & Target**: KOReader consists of the Lua frontend (`koreader/koreader`) and a C/C++ native backend (`koreader/koreader-base`) containing ~30 submodules and third-party libraries (MuPDF, CREngine, DjVuLibre, LuaJIT, Leptonica, libk2pdfopt, HarfBuzz, FreeType, etc.).
- **Paper Pro Target**: The 64-bit ARM target for the Paper Pro is `TARGET=remarkable-aarch64` (`ARM64_A53_ARCH = -march=armv8-a+crc+crypto -mtune=cortex-a53`), using `make/remarkable-aarch64.mk`.
- **Toolchain & Container**: Official builds use `./kodev release remarkable-aarch64` via the `koreader/koremarkable` container (`aarch64-remarkable-linux-gnu-gcc 14.4.0` via crosstool-NG). The Docker image is `linux/amd64` on Docker Hub, running via Rosetta emulation on Apple Silicon OrbStack.
- **Why Pure Nix Build is Complex**: `koreader-base` uses CMake custom targets (`download-all`) that download tarballs during the build phase over the network. In the Nix sandbox, internet access is strictly disabled; building natively from source in pure Nix would require fetching, patching, and packaging each of the 30 third-party submodules independently.
- **Current Status**: Deferred. KOReader remains managed via Vellum (`vellum add koreader`, located under `/home/root/xovi/exthome/appload/koreader/` with `"qtfb": true`), which runs reliably.

## Open: the display path (the only thing between the source build and a panel)

`libepaper.so` is closed source and built against **Qt 6.10.3**; a QPA plugin is
refused on a Qt version mismatch, so the nixpkgs Qt 6.12 build has no display
path through reMarkable's own plugin. The community answer is **QTFB**
(asivery/qtfb, merged into asivery/rm-appload): a shared-memory framebuffer
server inside xochitl (`qtfb.so` XOVI extension, `/tmp/qtfb.sock`) that clients
draw into with a QPainter; input via the `qtfb-shim.so` LD_PRELOAD shim
(`QTFB_SHIM_MODE=N_RGB565`, `QTFB_SHIM_INPUT_MODE`, `QTFB_SHIM_MODEL`) or evdev.
Qt-version independent, and already used by KOReader (`KO_USE_QTFB=1`) and
AppLoad external apps (`"qtfb": true` in `external.manifest.json`, which passes
the allocated framebuffer's ID to the app as `QTFB_KEY`).

Decide between:

1. **QTFB present/input path in rmweb** (preferred): present the rendered frame
   into the QTFB shm framebuffer and read pen/touch back, launch from AppLoad
   with `"qtfb": true`. Works with the flake's Qt; no closed plugin.
2. **Wayland**: run `labwc` (already in `rmpp_android`) and start rmweb with
   `QT_QPA_PLATFORM=wayland`; needs a frame copier to the panel, which is what
   `einkbridge` (below) provides.
3. **Qt 6.10.3 from source** (qtbase/qtdeclarative) so `libepaper.so` loads —
   highest effort, breaks on every OS Qt bump.
4. **Compile-only** package: CI proof, nothing renders on device.

Related: package `einkbridge` + `libquill` from source (Rust + the quill takeover
library) for option 2, and take `qtfb`'s client library from `rm-appload` for
option 1.

## Remaining tasks

- [ ] Implement `rmpp-wikipedia` native Qt Quick reader with `libzim` C++ backend:
      Eliminate `kiwix-serve` by compiling a `ZimBackend` QObject linked against `pkgs.libzim`,
      replacing `XMLHttpRequest` in `dps/remarkable-wikipedia`, and integrating with `/home/root/zim/`.
- [ ] Test `kiwix-desktop` high-DPI scaling (`QT_SCALE_FACTOR=1.75`) and fullscreen geometry
      on real Paper Pro hardware via AppLoad tile.
- [ ] Evaluate VKMS DRM writeback (`vkms_bridge.c` from `chiappa`) as an alternative to
      `wlr-screencopy` for generic compositors on `ferrari`.
- [ ] Decide the display path for source-built `rmweb`: add a QTFB present/input
      path or a Wayland session (`labwc`) to allow dropping `rmpp_rmweb_prebuilt`.
- [ ] Validate the local Waydroid implementation on the device: `labwc` start,
      Waydroid container session, physical input through Wayland, and quill vendor worker.
- [ ] Audit the 163 raw-chain rejected hunks if enabling the security patch chain
      at 6.12.115-waydroid (`rmpp.kernel.securityPatches.enable = true`).
- [ ] Ship a vellum-compatible `post-os-upgrade` story: either publish the boot
      unit as an `.apk` in a vellum repo, or document the manual re-enable step
      next to `vellum reenable`.
- [ ] Keep hashes current: `wpewebkit.nix` (tarball) and the `v0.9.7` tag
      (`fetchFromGitHub`), plus upstream's bundle while it is still shipped.
- [ ] KOReader source compilation (deferred): design an offline Nix derivation
      or packaging recipe for `koreader-remarkable-aarch64` without relying on
      network-dependent CMake downloads.

## How to resume

Building natively on aarch64 still needs the VM: it is the only aarch64 Linux
here, `nix build` on this host is emulated (and WebKit is impractical). The
sync/run commands are in "Builds on aarch64 (verified)" above; the kernel is
~4 minutes, WebKit hours, so run the latter detached and poll the log.

```sh
cd repo
git status -sb
nix build .#rmpp_tools            # sanity: native aarch64 via cache.nixos.org
nix eval .#packages.x86_64-linux.rmpp_rmweb.drvPath   # evals without building
# then the display-path decision above
```

Notes:
- Emulated builds are slow; run long `nix build`s in a BACKGROUND shell and
  check logs, or build WPE once natively on an aarch64 machine (the OrbStack
  VM above is the one that has actually built it).
- When a Nix phase fails, `--keep-failed` keeps the build tree (it lands under
  `/nix/var/nix/builds/…` in the VM) — that is how the `fitImage`/`cd kernel`
  mistakes were found; the phase cwd and the file's real location are usually
  the answer.
- Keep `rmpp_tools`/`rmpp_nix_setup` as they are: native `aarch64-linux` from
  cache.nixos.org (no cross compile), which is the preferred shape.
