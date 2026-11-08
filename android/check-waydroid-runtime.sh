#!/bin/sh
# Headless integration smoke test, no tablet hardware or Android images needed.
# Compositor setup adapted from the upstream session script:
# https://github.com/MaximeRivest/android-on-remarkable-paper-pro/blob/65b5bf34fb3ef160e3d483a14484b46304ecbc7c/device/session.sh
# Pixman replaces the hardware GLES renderer only for this VM test; it verifies
# the screencopy/virtual-input protocol contract, not etnaviv or e-paper output.
set -eu
runtime=${1:?pass the rmpp_android_tools output path}
work=$(mktemp -d)
export HOME=$work XDG_RUNTIME_DIR=$work WAYLAND_DISPLAY=rmpp-test WLR_BACKENDS=headless WLR_RENDERER=pixman
mkdir -p "$work/config"
"$runtime/bin/labwc" -C "$work/config" -s true > "$work/labwc.log" 2>&1 &
compositor_pid=$!
trap 'kill "$compositor_pid" 2>/dev/null || true; wait "$compositor_pid" 2>/dev/null || true; rm -rf "$work"' EXIT
# labwc chooses its own display name; discover it from this isolated run.
for attempt in $(seq 1 40); do
  for socket in "$work"/wayland-*; do
    if [ -S "$socket" ]; then WAYLAND_DISPLAY=${socket##*/}; export WAYLAND_DISPLAY; break 2; fi
  done
  kill -0 "$compositor_pid" || { cat "$work/labwc.log"; exit 1; }
  sleep .1
done
"$runtime/bin/wlr-randr" --output HEADLESS-1 --custom-mode 810x1080@30
"$runtime/bin/wayland-info" > "$work/globals"
grep -E 'zwlr_screencopy_manager_v1|zwp_virtual_keyboard_manager_v1|zwlr_virtual_pointer_manager_v1' "$work/globals"
grep -q zwlr_screencopy_manager_v1 "$work/globals"
"$runtime/bin/waydroid" --version
