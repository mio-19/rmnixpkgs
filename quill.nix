{
  lib,
  pkgs,
  fetchFromGitHub,
  fetchurl,
  qt6,
  pkg-config,
  binutils,
  patchelf,
  os,
}:
let
  # This compile is necessary: the vendor boundary must use the exact OS Qt
  # headers, rather than the newer cached nixpkgs Qt. No proprietary SDK/blob.
  qtbase =
    (qt6.qtbase.override {
      version = os.qt;
      qttranslations = null;
      src = fetchurl {
        url = "https://download.qt.io/official_releases/qt/${lib.versions.majorMinor os.qt}/${os.qt}/submodules/qtbase-everywhere-src-${os.qt}.tar.xz";
        hash = os.qtbaseHash;
      };
    }).overrideAttrs
      (_: {
        # The current nixpkgs patches target a newer Qt. Quill needs public QtCore
        # and QtGui APIs only, not the nixpkgs plugin discovery modifications.
        patches = [ ];
      });
in
# GCC from os.nix: libquill.so is loaded next to the device's own libstdc++.
pkgs."gcc${os.gcc}Stdenv".mkDerivation {
  pname = "rmpp-quill";
  version = "0-39262ee";
  # Quill (MIT), unpacked-tree hash, no vendor/libqsgepaper.so redistributed.
  src = fetchFromGitHub {
    owner = "MaximeRivest";
    repo = "quill";
    rev = "39262ee0bef69915e3ead3ac218d5973916f422a";
    hash = "sha256-sQQZLzkqlG0mrnkU2KW43BJu9JS327DeIlm89fYjCa0=";
  };
  nativeBuildInputs = [
    pkg-config
    binutils
    patchelf
  ];
  buildInputs = [ qtbase ];
  dontWrapQtApps = true;
  dontConfigure = true;
  dontPatchELF = true;
  # Recipe adapted from https://github.com/MaximeRivest/quill/blob/39262ee0bef69915e3ead3ac218d5973916f422a/build.sh
  # The vendor API is already resolved with dlsym upstream. Defer its loading
  # to our separate worker, which preloads the tablet's own matching Qt first.
  buildPhase = ''
    runHook preBuild
    $CXX -fPIC -shared -O2 -std=c++17 src/vendor_probe.cpp src/quill_c.cpp \
      $(pkg-config --cflags --libs Qt6Core Qt6Gui) -ldl -o libquill.so
    # Fail if compiling against newer libc headers introduced a symbol the
    # tablet cannot provide. The worker uses the device loader/libc.
    for v in $(readelf --version-info libquill.so | grep -oE 'GLIBC_[0-9]+\.[0-9]+' | sort -Vu); do
      test "$(printf '%s\n' '${os.glibc}' "''${v#GLIBC_}" | sort -V | tail -1)" = '${os.glibc}' || {
        echo "Quill requires $v, tablet has glibc ${os.glibc}" >&2; exit 1;
      }
    done
    # The isolated worker must use device Qt/libstdc++, not Nix runtime libs.
    # Load Quill before libqsgepaper so QImage constructor interposition works.
    patchelf --set-rpath /usr/lib libquill.so
    runHook postBuild
  '';
  installPhase = ''
    runHook preInstall
    install -Dm755 libquill.so $out/lib/libquill.so
    install -Dm644 src/quill.h $out/include/quill.h
    install -Dm644 LICENSE $out/share/licenses/quill/LICENSE
    runHook postInstall
  '';
  passthru = { inherit qtbase; };
  meta = {
    description = "Quill display boundary, built from source for the pinned tablet Qt ABI";
    homepage = "https://github.com/MaximeRivest/quill";
    license = lib.licenses.mit;
    platforms = [ "aarch64-linux" ];
  };
}
