{
  lib,
  stdenv,
  fetchFromGitHub,
  cmake,
  ninja,
  pkg-config,
  qt6,
  wpewebkit,
  glib-networking,
  libsoup_3,
  libwpe,
  makeWrapper,
}:

# rmweb (https://github.com/exp78/rmweb, MIT): the Qt + WPE WebKit browser for
# the Paper Pro, built here from the v0.9.7 tag against nixpkgs' Qt and against
# the WPE WebKit in ./wpewebkit.nix instead of upstream's prebuilt release
# bundle. Everything is aarch64-linux (see ./aarch64-pkgs.nix).
stdenv.mkDerivation (finalAttrs: {
  pname = "rmweb";
  version = "0.9.7";

  src = fetchFromGitHub {
    owner = "exp78";
    repo = "rmweb";
    tag = "v${finalAttrs.version}";
    hash = "sha256-IUuJxNtSs3w2CrnTfteaMosnxPpe+D3j4bBA6q/qjQE=";
  };

  # engine/wpeqt is the application: a single main.cpp plus headers, CMake,
  # C++17, Qt6 Gui/Qml/Quick and pkg-config for wpe-webkit-2.0 and
  # wpe-platform-2.0 (both provided by ./wpewebkit.nix).
  nativeBuildInputs = [
    cmake
    ninja
    pkg-config
    makeWrapper
  ];
  buildInputs = [
    qt6.qtbase
    qt6.qtdeclarative
    wpewebkit
    glib-networking
    # Not linked against directly, but `pkg-config --libs wpe-webkit-2.0`
    # resolves the .pc file's Requires line (libsoup-3.0) through the consumer's
    # PKG_CONFIG_PATH, so configure fails without it: "Package 'libsoup-3.0',
    # required by 'wpe-webkit-2.0', not found". Adding it to ./wpewebkit.nix's
    # propagatedBuildInputs would be tidier for every consumer but rebuilds the
    # whole engine, so it is listed here. Same for wpe-1.0 (libwpe), the other
    # public Requires entry that is not already in the closure by name.
    libsoup_3
    libwpe
  ];

  # The CMake project has no install rules (upstream assembles the /home/root
  # bundle with scripts/bundle.sh instead), so configure/build/install are done
  # explicitly here and the tree is laid out to match upstream's bundle.
  dontConfigure = true;

  # qtPreHook refuses a qtbase-dependent derivation without a wrapping decision.
  # The wrapper below is the decision: it sets exactly the WebKit/e-ink env the
  # tablet needs, so Qt's hook must not wrap the wrapper again (it would prepend
  # its own QT_PLUGIN_PATH/QML paths and drop the --set-default knobs).
  dontWrapQtApps = true;

  buildPhase = ''
    runHook preBuild

    cmake -S engine/wpeqt -B build -GNinja \
      -DCMAKE_BUILD_TYPE=Release
    ninja -C build

    runHook postBuild
  '';

  installPhase = ''
        runHook preInstall

        R=$out/share/rmweb

        # The real binary lives outside share/ so the wrapper below can own the
        # environment; rmweb-env.sh keeps the same layout the device launcher and
        # upstream's docs expect.
        install -Dm755 build/rmweb-wpeqt $out/libexec/rmweb/rmweb-wpeqt

        # Upstream's device tree: launcher (stops xochitl, restores it on exit),
        # installer, AppLoad/XOVI entry, icon and version stamp.
        install -d $R
        install -m755 -t $R device/rmweb device/install.sh device/appload-entry.sh
        install -m644 -t $R device/icon.svg VERSION
        cp -a device/appload $R/appload

        # Reader mode: vendored Mozilla Readability (Apache-2.0), injected on demand.
        install -d $R/share/reader
        install -m644 -t $R/share/reader \
          engine/wpeqt/reader/Readability.js \
          engine/wpeqt/reader/Readability-readerable.js

        # bin/rmweb-wpeqt: what device/rmweb execs. The nix store supplies every
        # library, so there is no LD_LIBRARY_PATH / LIBGL_DRIVERS_PATH to set; only
        # the WebKit/WPE knobs and the software-GL choice remain.
        install -d $R/bin
        makeWrapper $out/libexec/rmweb/rmweb-wpeqt $R/bin/rmweb-wpeqt \
          --set WEBKIT_DISABLE_SANDBOX_THIS_IS_DANGEROUS 1 \
          --set WEBKIT_SKIA_ENABLE_CPU_RENDERING 1 \
          --set WEBKIT_INJECTED_BUNDLE_PATH ${wpewebkit}/lib/wpe-webkit-2.0/injected-bundle \
          --set WEBKIT_DISABLE_ASYNC_SCROLLING 1 \
          --set-default WEBKIT_FORCE_VBLANK_TIMER 1 \
          --set GALLIUM_DRIVER llvmpipe \
          --set LIBGL_ALWAYS_SOFTWARE 1 \
          --set EGL_PLATFORM surfaceless \
          --set QSG_RENDER_LOOP basic \
          --set-default QT_QPA_PLATFORM epaper \
          --set-default QT_QUICK_BACKEND epaper \
          --prefix GIO_EXTRA_MODULES : ${glib-networking}/lib/gio/modules \
          --prefix QML2_IMPORT_PATH : ${qt6.qtdeclarative}/lib/qt-6/qml \
          --set RMWEB_READER_DIR $R/share/reader

        # The launcher sources $R/rmweb-env.sh unconditionally (under `set -u`), so
        # it has to exist even though bin/rmweb-wpeqt already carries the nix
        # environment. What is left are the runtime levers upstream exposes.
        cat >$R/rmweb-env.sh <<'EOF'
    # rmweb runtime env, sourced by ./rmweb before it execs bin/rmweb-wpeqt.
    # The nix wrapper has every library and WebKit path baked in, so unlike
    # upstream's bundle there is no LD_LIBRARY_PATH or LIBGL_DRIVERS_PATH here.
    export QT_QPA_PLATFORM="''${RMWEB_QPA_PLATFORM:-epaper}"
    export QT_QUICK_BACKEND="''${RMWEB_QUICK_BACKEND:-epaper}"
    export QSG_RENDER_LOOP=basic
    export JSC_useJIT="''${RMWEB_JIT:-0}"
    export RMWEB_READER_DIR="''${RMWEB_READER_DIR:-$RMWEB_ROOT/share/reader}"
    export FONTCONFIG_PATH=/etc/fonts
    export HOME="''${HOME:-/home/root}"
    EOF

        # Entry point. RMWEB_ROOT keeps upstream's /home/root/rmweb default: the
        # launcher writes its log and its lock next to the app, and the store is
        # read-only, so the device tree is a copy (see remarkable-paper-pro.md).
        # $out/bin is not created by anything above: everything else is installed
        # into libexec/ or share/rmweb.
        install -d $out/bin
        ln -s $R/rmweb $out/bin/rmweb

        runHook postInstall
  '';

  # The panel geometry, the epaper QPA plugin and the writable /home tree are
  # all found at runtime; nothing here belongs to a build host.
  dontPatchShebangs = true;

  meta = {
    description = "WPE WebKit e-ink browser for the reMarkable Paper Pro";
    homepage = "https://github.com/exp78/rmweb";
    license = lib.licenses.mit;
    platforms = [ "aarch64-linux" ];
    mainProgram = "rmweb";
  };
})
