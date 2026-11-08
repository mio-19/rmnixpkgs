{
  lib,
  stdenv,
  pkg-config,
  wayland,
  wayland-scanner,
  wlr-protocols,
  binutils,
  patchelf,
  python3,
  glibc,
  os,
}:
stdenv.mkDerivation {
  pname = "rmpp-einkbridge";
  version = "0.1.0";
  src = lib.fileset.toSource {
    root = ./.;
    fileset = lib.fileset.unions [
      ./einkbridge.c
      ./quill-host.c
      ./einkbridge-wire.h
      ./test-einkbridge.c
      ./test-quill-mock.c
      ./test-quill-host.py
    ];
  };
  nativeBuildInputs = [
    pkg-config
    wayland-scanner
    binutils
    patchelf
  ];
  buildInputs = [ wayland ];
  dontConfigure = true;
  doCheck = true;
  nativeCheckInputs = [ python3 ];
  checkPhase = ''
    runHook preCheck
    $CC -std=c11 -O1 -g -fsanitize=address,undefined -I. test-einkbridge.c wlr-screencopy-protocol.c \
      $(pkg-config --cflags --libs wayland-client) -o test-einkbridge
    ./test-einkbridge
    $CC -shared -fPIC -DTABLET_QT='"${os.qt}"' test-quill-mock.c -o mock-quill.so
    python3 test-quill-host.py ${glibc}/lib/ld-linux-aarch64.so.1 ./rmpp-quill-host "$PWD/mock-quill.so"
    runHook postCheck
  '';
  # New implementation using the protocol itself, not missing upstream code:
  # https://gitlab.freedesktop.org/wlroots/wlr-protocols/-/blob/master/unstable/wlr-screencopy-unstable-v1.xml
  buildPhase = ''
    runHook preBuild
    xml=${wlr-protocols}/share/wlr-protocols/unstable/wlr-screencopy-unstable-v1.xml
    wayland-scanner client-header "$xml" wlr-screencopy-client.h
    wayland-scanner private-code "$xml" wlr-screencopy-protocol.c
    $CC -std=c11 -O2 -Wall -Wextra -Werror -I. einkbridge.c wlr-screencopy-protocol.c \
      $(pkg-config --cflags --libs wayland-client) -o rmpp-einkbridge
    $CC -std=c11 -O2 -Wall -Wextra -Werror -DTABLET_QT='"${os.qt}"' \
      quill-host.c -ldl -o rmpp-quill-host
    patchelf --remove-rpath rmpp-quill-host
    patchelf --set-interpreter '${os.loader}' rmpp-quill-host
    for v in $(readelf --version-info rmpp-quill-host | grep -oE 'GLIBC_[0-9]+\.[0-9]+' | sort -Vu); do
      test "$(printf '%s\n' '${os.glibc}' "''${v#GLIBC_}" | sort -V | tail -1)" = '${os.glibc}' || {
        echo "worker requires $v, tablet has glibc ${os.glibc}" >&2; exit 1;
      }
    done
    runHook postBuild
  '';
  installPhase = ''
    runHook preInstall
    install -Dm755 rmpp-einkbridge $out/bin/rmpp-einkbridge
    install -Dm755 rmpp-quill-host $out/libexec/rmpp-quill-host
    runHook postInstall
  '';
  # The worker deliberately runs with the tablet loader and system libc. Keep
  # fixup from putting a Nix libc path back into that isolated vendor process.
  dontPatchELF = true;
  meta = {
    description = "Wayland screencopy and dirty-rectangle e-paper bridge for the Paper Pro";
    license = lib.licenses.mit;
    platforms = [ "aarch64-linux" ];
    mainProgram = "rmpp-einkbridge";
  };
}
