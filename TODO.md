# TODO: build rmweb (and Paper Pro packages) from source with nixpkgs

Goal: stop shipping upstream's prebuilt `rmweb-0.9.7.tar.gz` bundle and stop
using reMarkable's binary Yocto SDK. Compile the engine and the app from source
with nixpkgs' own bootstrap toolchain (`gcc`, `cmake`, `ninja`, `qt6`, `mesa`),
for `aarch64-linux`, so everything is a normal Nix derivation — and package the
Android/Waydroid stack from `android-on-remarkable-paper-pro` the same way.

State at time of writing: `flake.nix` + `flake.lock` (nixpkgs `1d060086`, i.e.
2026-11-03), `.#rmpp_tools` / `.#rmpp_nix_setup` build, `.#rmpp_rmweb` (source
build), `.#rmpp_rmweb_prebuilt` (upstream bundle, still the only one that
renders), `.#rmpp_android` / `.#rmpp_android_files` all evaluate.

## Done

- [x] `flake.nix` + `flake.lock`: nixpkgs (`nixos-unstable`), flake-parts,
      `android-on-remarkable-paper-pro` input (non-flake, files only);
      `nixConfig` declares `cache.nixos.org` + public key and
      `extra-platforms = aarch64-linux`.
- [x] `remarkable/aarch64-pkgs.nix`: the one place the native aarch64 package
      set is defined (`import pkgs.path { system = "aarch64-linux"; }`), with
      the cache-hit rationale documented there.
- [x] `remarkable/rmweb/wpewebkit.nix`: WPE WebKit 2.48.5 from the upstream
      tarball, upstream's configure flags, nixpkgs deps, `-latomic` for the A53.
- [x] `remarkable/rmweb/package.nix`: `rmweb-wpeqt` from tag `v0.9.7` against
      nixpkgs Qt 6 + that engine; upstream's device tree, Readability JS, and a
      wrapper carrying the runtime env (no `LD_LIBRARY_PATH`; the device tree is
      a `/home/root` copy because the launcher writes `.lock`/`rmweb.log`).
- [x] Mesa: nixpkgs `mesa` (llvmpipe/swrast, surfaceless EGL) instead of
      upstream's `build/stage-mesa`.
- [x] `remarkable/android/default.nix`: `rmpp_android` (waydroid, labwc,
      wlroots, wayland-utils, mesa — all cached aarch64) + `rmpp_android_files`
      (kernel fragment, GPU DT patch, scripts, units, theme verbatim).
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
