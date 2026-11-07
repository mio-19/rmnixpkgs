#!/bin/sh
# End-to-end capture test against labwc's actual screencopy server.
# Headless setup: https://github.com/MaximeRivest/android-on-remarkable-paper-pro/blob/65b5bf34fb3ef160e3d483a14484b46304ecbc7c/device/session.sh
set -eu
tools=$1
bridge=$2
work=$(mktemp -d)
export HOME=$work XDG_RUNTIME_DIR=$work WLR_BACKENDS=headless WLR_RENDERER=pixman
mkdir "$work/config"
"$tools/bin/labwc" -C "$work/config" -s true > "$work/labwc.log" 2>&1 &
compositor=$!
background=
cleanup() {
    [ -z "$background" ] || kill "$background" 2>/dev/null || true
    kill "$compositor" 2>/dev/null || true
    wait "$compositor" 2>/dev/null || true
    # Only the mktemp directory made by this test is removed.
    python3 -c 'import shutil,sys; shutil.rmtree(sys.argv[1])' "$work"
}
trap cleanup EXIT
for attempt in $(seq 1 100); do
    for socket in "$work"/wayland-*; do
        if [ -S "$socket" ]; then WAYLAND_DISPLAY=${socket##*/}; export WAYLAND_DISPLAY; break 2; fi
    done
    kill -0 "$compositor" || { cat "$work/labwc.log"; exit 1; }
    sleep .1
done
"$tools/bin/wlr-randr" --output HEADLESS-1 --custom-mode 810x1080@30
for color in ffffff 000000; do
    swaybg -c "$color" > "$work/background.log" 2>&1 &
    background=$!
    sleep .3
    "$bridge/bin/rmpp-einkbridge" --pgm "$work/$color.pgm" --frames 3 --grayscale
    kill "$background"
    wait "$background" 2>/dev/null || true
    background=
done
python3 - "$work" <<'PY'
from pathlib import Path
import sys
root = Path(sys.argv[1])
for name, value in (("ffffff", 255), ("000000", 0)):
    data = (root / (name + ".pgm")).read_bytes()
    header, pixels = data.split(b"\n255\n", 1)
    assert header == b"P5\n810 1080", header
    assert len(pixels) == 810 * 1080
    # Ignore the small composited cursor when assessing the solid background.
    from collections import Counter
    print(name, Counter(pixels).most_common(4))
    assert pixels.count(value) / len(pixels) > .99, (name, Counter(pixels).most_common(8))
print("real Wayland capture and white/black PGM pixels verified")
PY
# SIGTERM must close the connection and leave the compositor usable.
"$bridge/bin/rmpp-einkbridge" --pgm "$work/term.pgm" --interval-ms 20 &
capture=$!
sleep .3
kill -TERM "$capture"
wait "$capture"
"$tools/bin/wlr-randr" >/dev/null
