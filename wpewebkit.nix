{
  lib,
  stdenv,
  fetchurl,
  cmake,
  ninja,
  pkg-config,
  python3,
  perl,
  ruby,
  gperf,
  unifdef,
  gettext,
  bison,
  flex,
  glib,
  libsoup_3,
  libwpe,
  libxml2,
  libxslt,
  libpng,
  libjpeg_turbo,
  libwebp,
  sqlite,
  libpsl,
  libtasn1,
  libidn2,
  libunistring,
  harfbuzz,
  icu,
  cairo,
  freetype,
  fontconfig,
  libepoxy,
  mesa,
  libgbm,
  libdrm,
  libxkbcommon,
  libseccomp,
  libgcrypt,
  libgpg-error,
  nettle,
  p11-kit,
  expat,
  lcms2,
  zlib,
  brotli,
}:

# WPE WebKit for the Paper Pro, from the upstream release tarball because
# nixpkgs ships webkitgtk (the GTK port) and `libwpe` but not `wpewebkit`
# itself. Same version and configure flags rmweb's author uses
# (engine/build-wpe.incontainer.sh, WPE WebKit 2.48.5): software rendering,
# Skia CPU painting, no media/GStreamer/WebGL/sandbox, headless WPE platform.
#
# This is the expensive part of the browser: a full WebKit build is hours on
# many cores and needs a lot of RAM to link (see
# remarkable-paper-pro.md). It is a normal nixpkgs derivation, so it
# builds natively for aarch64-linux with the host's own gcc and cmake.
let
  # WebKit's Source/cmake/FindHarfBuzz.cmake asks for the ICU component
  # (`harfbuzz-icu` pkg-config module + libharfbuzz-icu.so) as a REQUIRED_VAR
  # and fails configure without it. Upstream's
  # https://github.com/exp78/rmweb/blob/v0.9.7/engine/build-wpe.incontainer.sh
  # builds harfbuzz with `-Dicu=enabled` for exactly this reason; nixpkgs only
  # produces that variant when `withIcu` is set (it propagates the plain
  # `harfbuzz` the rest of WebKit uses).
  harfbuzzWithIcu = harfbuzz.override { withIcu = true; };
in
stdenv.mkDerivation (finalAttrs: {
  pname = "wpewebkit";
  version = "2.48.5";

  src = fetchurl {
    url = "https://wpewebkit.org/releases/wpewebkit-${finalAttrs.version}.tar.xz";
    hash = "sha256-AfNgEHBa2xRATFa68DMUf3knzHxrreyBuxQSZvzdjQs=";
  };

  nativeBuildInputs = [
    bison
    cmake
    flex
    gettext
    gperf
    glib # glib-compile-resources, glib-mkenums, gdbus-codegen
    ninja
    perl
    pkg-config
    python3
    ruby
    unifdef
  ];

  buildInputs = [
    brotli
    cairo
    expat
    fontconfig
    freetype
    glib
    harfbuzzWithIcu
    icu
    lcms2
    libdrm
    libepoxy
    libgbm
    libgcrypt
    libgpg-error
    libidn2
    libjpeg_turbo
    libpng
    libpsl
    libseccomp
    libsoup_3
    libtasn1
    libunistring
    libwebp
    libwpe
    libxkbcommon
    libxml2
    libxslt
    mesa # llvmpipe/swrast for the surfaceless EGL WPE renders through
    nettle
    p11-kit
    sqlite
    zlib
  ];

  # WebKit's build helpers are perl/ruby/python scripts with shebangs.
  postPatch = ''
    patchShebangs .

    # CMake >= 4.4 rejects the malformed if() this release produces when a
    # framework is not yet linked anywhere: the unquoted ''${_linked_into}
    # collapses to nothing, so `(NOT ''${_linked_into} IN_LIST ...)` reaches
    # CMake with an argument missing and configure dies with "if given
    # arguments: ( NOT _linked_into ) OR ( WTF STREQUAL ) ... Unknown
    # arguments specified".
    #
    # Upstream fix, taken as-is (drop the ''${} so the empty case still parses;
    # the `(NOT _linked_into)` branch already handles it) instead of pinning an
    # older CMake for the whole build:
    # https://bugs.webkit.org/show_bug.cgi?id=321081
    # https://commits.webkit.org/318630@main
    substituteInPlace Source/cmake/WebKitMacros.cmake \
      --replace-fail \
        'if ((NOT _linked_into) OR (''${framework} STREQUAL ''${_linked_into}) OR (NOT ''${_linked_into} IN_LIST ''${_target}_FRAMEWORKS))' \
        'if ((NOT _linked_into) OR (framework STREQUAL _linked_into) OR (NOT _linked_into IN_LIST ''${_target}_FRAMEWORKS))'
  '';

  cmakeFlags = [
    "-DCMAKE_BUILD_TYPE=Release"
    "-DPORT=WPE"

    # Rendering: software only, no GPU, no media pipeline on this device.
    "-DUSE_SKIA=ON"
    "-DUSE_GSTREAMER=OFF"
    "-DENABLE_VIDEO=OFF"
    "-DENABLE_WEB_AUDIO=OFF"
    "-DENABLE_MEDIA_SOURCE=OFF"
    "-DENABLE_MEDIA_STREAM=OFF"
    "-DENABLE_WEB_CODECS=OFF"
    "-DENABLE_SPEECH_SYNTHESIS=OFF"
    "-DENABLE_WEBGL=OFF"
    "-DENABLE_WEBXR=OFF"
    "-DENABLE_WEB_RTC=OFF"
    "-DUSE_AVIF=OFF"
    "-DUSE_JPEGXL=OFF"
    "-DUSE_LIBHYPHEN=OFF"
    "-DUSE_WOFF2=OFF"

    # Size/scope: the tablet runs this as root, un-sandboxed, with no tooling.
    "-DENABLE_SPELLCHECK=OFF"
    "-DENABLE_GAMEPAD=OFF"
    "-DENABLE_BUBBLEWRAP_SANDBOX=OFF"
    "-DENABLE_INTROSPECTION=OFF"
    "-DENABLE_DOCUMENTATION=OFF"
    "-DENABLE_JOURNALD_LOG=OFF"
    "-DUSE_ATK=OFF"
    "-DUSE_LIBBACKTRACE=OFF"
    "-DUSE_SYSPROF_CAPTURE=OFF"
    "-DENABLE_MINIBROWSER=OFF"
    "-DENABLE_COG=OFF"
    "-DENABLE_API_TESTS=OFF"
    "-DENABLE_WEBDRIVER=OFF"

    # Display path: WPEPlatform headless (the app presents through the device's
    # own epaper Qt plugin), no DRM/Wayland backend, no Qt API.
    "-DENABLE_WPE_PLATFORM=ON"
    "-DENABLE_WPE_PLATFORM_HEADLESS=ON"
    "-DENABLE_WPE_PLATFORM_DRM=OFF"
    "-DENABLE_WPE_PLATFORM_WAYLAND=OFF"
    "-DENABLE_WPE_QT_API=OFF"

    # Cortex-A53 has no 16-byte atomics; WebKit's JSC wants them.
    "-DCMAKE_EXE_LINKER_FLAGS=-latomic"
    "-DCMAKE_SHARED_LINKER_FLAGS=-latomic"
    "-DCMAKE_MODULE_LINKER_FLAGS=-latomic"
  ];

  requiredSystemFeatures = [ "big-parallel" ];

  # WebKit is one enormous shared object; the link step is what needs the RAM,
  # so no separate debug-info pass is worth its disk and time here.
  separateDebugInfo = false;

  meta = {
    description = "Web content engine for embedded devices, WPE port (software rendering)";
    homepage = "https://wpewebkit.org/";
    license = lib.licenses.bsd2;
    platforms = [ "aarch64-linux" ];
    pkgConfigModules = [
      "wpe-webkit-2.0"
      "wpe-platform-2.0"
    ];
  };
})
