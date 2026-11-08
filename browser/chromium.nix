# Packaging for MaximeRivest/chromium on the reMarkable Paper Pro.
# Provenance:
#   Architecture & sources: https://github.com/MaximeRivest/chromium
#   Quill display layer:   https://github.com/MaximeRivest/quill
#
# Instead of downloading Ubuntu deb packages and Playwright prebuilt zips,
# we use the native aarch64-linux chromium package from cache.nixos.org,
# build chromium-cdp and chromium_viewer from source against the pinned
# os.qt and os.gcc, and package an owned AppLoad entry and rmpp-chromium service.

{
  lib,
  stdenv,
  buildGoModule,
  fetchFromGitHub,
  pkg-config,
  patchelf,
  binutils,
  writeTextFile,
  buildEnv,
  quill,
  chromium,
  os,
}:

let
  rev = "1bedeec94d53e7581b5d9bc5f3df0df13e85dfe0";
  src = fetchFromGitHub {
    owner = "MaximeRivest";
    repo = "chromium";
    inherit rev;
    hash = "sha256-G/40EaOL+KbI+4ML2uFUHGmvOVJknRrCHHk3ufip7rI=";
  };

  # 1. chromium-cdp: Go DevTools controller
  chromium-cdp = buildGoModule {
    pname = "chromium-cdp";
    version = "0.5.0";
    src = "${src}/cdp";
    vendorHash = "sha256-0Qxw+MUYVgzgWB8vi3HBYtVXSq/btfh4ZfV/m1chNrA=";

    meta = {
      description = "DevTools Protocol driver for headless Chromium on e-paper";
      homepage = "https://github.com/MaximeRivest/chromium";
      license = lib.licenses.mit;
      platforms = [ "aarch64-linux" ];
    };
  };

  # 2. chromium_viewer: C++ viewer driving Quill color path and evdev gestures
  chromium-viewer = stdenv.mkDerivation {
    pname = "chromium-viewer";
    version = "0.5.0";
    src = "${src}/viewer";

    nativeBuildInputs = [
      pkg-config
      patchelf
      binutils
    ];
    buildInputs = [ quill.qtbase ];

    dontWrapQtApps = true;
    dontPatchELF = true;

    buildPhase = ''
      runHook preBuild
      $CXX -O2 -std=c++17 -DNDEBUG -DQT_NO_DEBUG \
        -I${quill}/include \
        $(pkg-config --cflags Qt6Core Qt6Gui) \
        chromium_viewer.cpp \
        -L${quill}/lib -lquill \
        $(pkg-config --libs Qt6Core Qt6Gui) -ldl \
        -o chromium_viewer

      # Set loader and rpath for the tablet environment
      patchelf --set-rpath /usr/lib:${quill}/lib chromium_viewer
      patchelf --set-interpreter "${os.loader}" chromium_viewer

      # Verify glibc symbol constraints against target OS
      for v in $(readelf --version-info chromium_viewer | grep -oE 'GLIBC_[0-9]+\.[0-9]+' | sort -Vu); do
        test "$(printf '%s\n' '${os.glibc}' "''${v#GLIBC_}" | sort -V | tail -1)" = '${os.glibc}' || {
          echo "chromium_viewer requires $v, tablet has glibc ${os.glibc}" >&2; exit 1;
        }
      done
      runHook postBuild
    '';

    installPhase = ''
      runHook preInstall
      install -Dm755 chromium_viewer $out/bin/chromium_viewer
      runHook postInstall
    '';

    meta = {
      description = "Quill e-paper viewer and input daemon for Chromium";
      homepage = "https://github.com/MaximeRivest/chromium";
      license = lib.licenses.mit;
      platforms = [ "aarch64-linux" ];
    };
  };

  # 3. Wrapper script and runtime assets
  # Adheres strictly to AGENTS.md rules: manifest-owned state under /home/root/.rmpp/chromium
  runtime = writeTextFile {
    name = "rmpp-chromium-runtime";
    destination = "/bin/rmpp-chromium";
    executable = true;
    text = ''
      #!/bin/sh
      set -eu

      STATE="/home/root/.rmpp/chromium"
      MANIFEST="$STATE/manifest"
      OWNED_FLAG="$STATE/.rmpp-owned"
      RESTORE_FLAG="$STATE/restore-xochitl"
      SESSION_LOG="$STATE/session.log"
      PROFILE="$STATE/profile"
      OUT="$STATE/out"
      EVENTS="$OUT/events"
      CURRENT="$OUT/current.png"
      LOCK="$STATE/session.lock"

      CHROME="${chromium}/bin/chromium"
      CDP="${chromium-cdp}/bin/cdp"
      VIEWER="${chromium-viewer}/bin/chromium_viewer"
      ADAPTERS="${src}/chromium/adapters"
      LOADING_IMG="${src}/chromium/loading.png"
      ERROR_IMG="${src}/chromium/error.png"

      VIEWER_PID=""
      CHROME_PID=""
      DRIVER_PID=""

      log() {
        echo "rmpp-chromium: $*" >&2
      }

      own_state() {
        if [ ! -d "$STATE" ]; then
          mkdir -p "$STATE"
          touch "$OWNED_FLAG"
        fi
        if [ ! -f "$OWNED_FLAG" ]; then
          log "refusing to touch unowned directory $STATE"
          exit 1
        fi
        mkdir -p "$PROFILE" "$OUT"
        printf '%s\n' "$STATE" "$MANIFEST" "$OWNED_FLAG" "$RESTORE_FLAG" "$SESSION_LOG" "$PROFILE" "$OUT" "$EVENTS" "$CURRENT" "$LOCK" > "$MANIFEST"
      }

      kill_children() {
        [ -n "$DRIVER_PID" ] && kill "$DRIVER_PID" 2>/dev/null || true
        [ -n "$CHROME_PID" ] && kill "$CHROME_PID" 2>/dev/null || true
        [ -n "$VIEWER_PID" ] && kill "$VIEWER_PID" 2>/dev/null || true
        [ -n "$VIEWER_PID" ] && wait "$VIEWER_PID" 2>/dev/null || true
        [ -n "$DRIVER_PID" ] && wait "$DRIVER_PID" 2>/dev/null || true
        if [ -n "$CHROME_PID" ]; then
          sleep 1
          kill -9 "$CHROME_PID" 2>/dev/null || true
          wait "$CHROME_PID" 2>/dev/null || true
        fi
        VIEWER_PID=""
        CHROME_PID=""
        DRIVER_PID=""
      }

      recover() {
        if [ -f "$RESTORE_FLAG" ]; then
          systemctl start xochitl || true
          rm -f "$RESTORE_FLAG"
        fi
      }

      cleanup() {
        kill_children
        rm -f "$EVENTS"
        recover
      }

      case "''${1:-run}" in
        start)
          systemctl start --no-block rmpp-chromium.service
          exit 0
          ;;
        stop)
          systemctl stop rmpp-chromium.service
          exit 0
          ;;
        status)
          systemctl status rmpp-chromium.service
          exit 0
          ;;
        recover)
          recover
          exit 0
          ;;
        run)
          ;;
        *)
          echo "Usage: rmpp-chromium {start|stop|status|run|recover}" >&2
          exit 1
          ;;
      esac

      own_state

      # Check if xochitl is running; avoid fighting foreign apps
      if ! systemctl is-active --quiet xochitl; then
        log "xochitl is already stopped; another application may own the panel"
        exit 1
      fi

      touch "$RESTORE_FLAG"
      trap cleanup EXIT INT TERM

      log "stopping xochitl..."
      systemctl stop xochitl
      sleep 1
      rm -f /tmp/epframebuffer.lock

      rm -f "$EVENTS"
      mkfifo "$EVENTS"

      if [ ! -f "$CURRENT" ]; then
        cp -f "$LOADING_IMG" "$CURRENT"
      fi

      URL="''${CHROMIUM_URL:-https://chatgpt.com}"
      PORT="''${CHROMIUM_CDP_PORT:-9222}"
      REFRESH="''${CHROMIUM_REFRESH:-2s}"
      UA="''${CHROMIUM_UA:-Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/130.0.0.0 Safari/537.36}"

      log "launching viewer..."
      "$VIEWER" "$CURRENT" stretch 1 "$EVENTS" > "$STATE/viewer.log" 2>&1 &
      VIEWER_PID=$!

      log "launching headless chromium..."
      "$CHROME" \
        --headless=new --no-sandbox --disable-gpu --disable-dev-shm-usage \
        --disable-crash-reporter --disable-breakpad \
        --renderer-process-limit=2 --disk-cache-size=104857600 --media-cache-size=0 \
        --user-data-dir="$PROFILE" \
        --password-store=basic \
        --window-size=1620,2160 --hide-scrollbars \
        --user-agent="$UA" \
        --disable-blink-features=AutomationControlled \
        --remote-debugging-port="$PORT" \
        about:blank > "$STATE/chrome.log" 2>&1 &
      CHROME_PID=$!

      log "launching cdp controller..."
      "$CDP" -port "$PORT" -url "$URL" -out "$CURRENT" \
        -fifo "$EVENTS" -selector 'main, body' \
        -wait 120 -refresh "$REFRESH" \
        -adapters "$ADAPTERS" \
        > "$STATE/cdp.log" 2>&1 &
      DRIVER_PID=$!

      while kill -0 "$VIEWER_PID" 2>/dev/null; do
        if [ -n "$DRIVER_PID" ] && ! kill -0 "$DRIVER_PID" 2>/dev/null; then
          log "cdp driver exited unexpectedly"
          cp -f "$ERROR_IMG" "$CURRENT" 2>/dev/null || true
          break
        fi
        sleep 1
      done

      log "exiting session and restoring xochitl"
    '';
  };

in
buildEnv {
  name = "rmpp-chromium";
  paths = [
    chromium-cdp
    chromium-viewer
    runtime
  ];
  pathsToLink = [
    "/bin"
    "/share"
  ];
  passthru = {
    cdp = chromium-cdp;
    viewer = chromium-viewer;
    inherit src;
  };
  meta = {
    description = "Full Chromium browser on e-ink for the reMarkable Paper Pro";
    homepage = "https://github.com/MaximeRivest/chromium";
    license = lib.licenses.mit;
    platforms = [ "aarch64-linux" ];
    mainProgram = "rmpp-chromium";
  };
}
