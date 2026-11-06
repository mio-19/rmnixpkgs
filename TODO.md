# TODO: build rmweb (and Paper Pro packages) from source with nixpkgs

Goal: stop shipping upstream's prebuilt `rmweb-0.9.7.tar.gz` bundle and stop
using reMarkable's binary Yocto SDK. Compile the engine and the app from source
with nixpkgs' own bootstrap toolchain (`gcc`, `cmake`, `ninja`, `qt6`, `mesa`),
for `aarch64-linux`, so everything is a normal Nix derivation — and package the
Android/Waydroid stack from `android-on-remarkable-paper-pro` the same way.

State at time of writing: `flake.nix` + `flake.lock` (nixpkgs pinned from the
nixpkgs-unstable channel tarball), `.#rmpp_tools` / `.#rmpp_nix_setup` build,
`.#rmpp_rmweb` (source build), `.#rmpp_rmweb_prebuilt` (upstream bundle, still
the only one that renders), `.#rmpp_android` / `.#rmpp_android_files`,
`.#rmpp_kernel` all evaluate.

## Done

- [x] `flake.nix` + `flake.lock`: nixpkgs (`nixos-unstable`), flake-parts,
      `android-on-remarkable-paper-pro` input (non-flake, files only);
      `nixConfig` declares `cache.nixos.org` + public key and
      `extra-platforms = aarch64-linux`.
- [x] `aarch64-pkgs.nix`: the one place the native aarch64 package
      set is defined (`import pkgs.path { system = "aarch64-linux"; }`), with
      the cache-hit rationale documented there.
- [x] `wpewebkit.nix`: WPE WebKit 2.48.5 from the upstream
      tarball, upstream's configure flags, nixpkgs deps, `-latomic` for the A53.
- [x] `rmweb.nix`: `rmweb-wpeqt` from tag `v0.9.7` against
      nixpkgs Qt 6 + that engine; upstream's device tree, Readability JS, and a
      wrapper carrying the runtime env (no `LD_LIBRARY_PATH`; the device tree is
      a `/home/root` copy because the launcher writes `.lock`/`rmweb.log`).
- [x] Mesa: nixpkgs `mesa` (llvmpipe/swrast, surfaceless EGL) instead of
      upstream's `build/stage-mesa`.
- [x] `default.nix`: `rmpp_android` (waydroid, labwc,
      wlroots, wayland-utils, mesa — all cached aarch64) + `rmpp_android_files`
      (kernel fragment, GPU DT patch, scripts, units, theme verbatim).
- [x] `os.nix`: one declaration of the target reMarkable OS release — 3.28,
      glibc 2.39, xochitl's Qt 6.10.3, kernel 6.12.49 from branch
      `rmpp_6.12.49_v3.27.x`. `kernel.nix` builds from it, `system.nix` records it
      as `$out/os` (`version=` / `glibc=` / `qt=` / `kernel-version=`) and
      activation logs it. Nothing knows about a release newer than 3.28: the
      next OS update starts by editing this file, then rebuilding `rmpp_kernel`.
- [x] `system.nix` + `config.nix` + `activate.sh`: system-manager-style
      declarative configuration — generations in the store, activation that owns
      only its manifest, a boot unit that re-applies it, and unit names asserted
      to `rmpp-*` so it cannot fight XOVI/vellum units. Includes
      `rmpp.vellum` (a nix-darwin-Homebrew-shaped package list).
- [x] `kernel.nix`: `rmpp_kernel` — reMarkable's published 6.12.49
      source + upstream's `ferrari_defconfig`/`waydroid.cfg` recipe +
      `gpu-etnaviv-dt.patch`, producing fitImage, Image, dtbs and a modules
      tarball in the shape `install-kernel.sh` expects.
- [x] `nixfmt` clean; every package evaluates (`nix eval .#…drvPath`);
      `.#rmpp_tools` verified to substitute from cache.nixos.org (aarch64 ELF).
- [x] Docs: `remarkable-paper-pro.md` covers the flake, the source build and the
      Android adaptation.

## Verified facts (don't re-research)

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
  `6.12.49-waydroid`; modules land in `/lib/modules/<release>` on the device.
- GPU: `gpu-etnaviv-dt.patch` rewrites `gpu@38000000` in `imx8mm.dtsi` to
  `compatible = "vivante,gc"`, `status = "okay"`, clocks `reg/bus/core/shader`;
  the fragment adds `CONFIG_DRM_ETNAVIV=m` + `CONFIG_DRM_SCHED=m`. Stock OS has
  neither, hence rmweb's "no GPU driver" profile.
- Boot: two rootfs slots (`root_a`/`root_b`), `/boot/fitImage` hash-checked in
  developer mode, `lpgpr` errcnt/p`root_part` sysfs counters, boot watchdog
  flips slots after repeated late-UI reboots (dualboot installer notes).
  `install-kernel.sh` backs the stock fitImage up to
  `/home/root/waydroid/backup` and renames the new one into place atomically.

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

- [ ] Decide the display path above.
- [ ] Build `.#rmpp_rmweb` on aarch64 hardware (or accept an emulated build) and
      check the closure: `readelf -d` sonames/RUNPATH, injected-bundle path,
      `libexec/wpe-webkit-2.0` helpers, `libwpe`/`libsoup`/`glib-networking`.
- [ ] Test on device: `nix copy` the closure, copy the tree to
      `/home/root/rmweb`, `install.sh`, page turns, downloads, AppLoad icon.
- [ ] Test `rmpp_android` on device: `labwc` start, Waydroid bring-up, GPU
      (mesa's etnaviv drivers are linked into `$env/lib/dri`).
- [ ] Build `.#rmpp_kernel` on aarch64 hardware and check the output: fitImage
      packs Image+dtbs, `CONFIG_DRM_ETNAVIV=m` present in
      `share/rmpp-kernel/config`, `6.12.49-waydroid` module tree, patched
      `imx8mm-ferrari.dtb` in `dtbs/`.
- [ ] Flash the kernel on a device (after the backup) and verify
      `/dev/dri/renderD128` appears, `etnaviv` is in dmesg, and Mesa's etnaviv
      driver loads; then check whether rmweb can use it
      (`WEBKIT_SKIA_ENABLE_CPU_RENDERING=0`, `LIBGL_ALWAYS_SOFTWARE=0`) — the
      rmweb research warns GPU painting may not beat llvmpipe on e-ink.
- [ ] Keep the kernel source branch in step with the installed OS version
      (`/etc/version`); the pinned tarball is 3.27.x.
- [ ] Test `rmpp-config` on device: `--install-boot-unit` (with vellum's
      `mount-utils` present, and without), reboot, confirm units/files/AppLoad
      entry come back, confirm vellum's own packages still work, then
      `vellum reenable` after an OS update and re-run the install.
- [ ] Give the `rmweb` AppLoad entry an `icon.png` (AppLoad shows a blank tile
      without it), and flip `qtfb = true` in `config.nix` once rmweb speaks QTFB.
- [ ] Ship a vellum-compatible `post-os-upgrade` story: either publish the boot
      unit as an `.apk` in a vellum repo, or document the manual re-enable step
      next to `vellum reenable` (currently documented only).
- [ ] Drop `rmpp_rmweb_prebuilt` once the source build renders on device.
- [ ] Keep hashes current: `wpewebkit.nix` (tarball) and the `v0.9.7` tag
      (`fetchFromGitHub`), plus upstream's bundle while it is still shipped.
- [ ] Update `TODO.md`/commit as each item lands; do not hand-edit generated
      files; `nixfmt` every `.nix` touched.

## How to resume

```sh
cd repo
git status -sb
nix build .#rmpp_tools            # sanity: native aarch64 via cache.nixos.org
nix eval .#packages.x86_64-linux.rmpp_rmweb.drvPath   # evals without building
# then the display-path decision above
```

Notes:
- Emulated builds are slow; run long `nix build`s in a BACKGROUND shell and
  check logs, or build WPE once natively on an aarch64 machine.
- Keep `rmpp_tools`/`rmpp_nix_setup` as they are: native `aarch64-linux` from
  cache.nixos.org (no cross compile), which is the preferred shape.
