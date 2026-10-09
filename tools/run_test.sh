#!/usr/bin/env bash
# Runs a Godot autotest without taking over the desktop: an unfocusable window (display/window/size/no_focus via a
# temporary game/override.cfg) placed off-screen, so it never steals keyboard/mouse focus or covers other windows.
# Screenshots still render (they come from the viewport). New class_name scripts must be registered first
# (tools/godot/...console.exe --headless --path game --import), or every script that uses them fails to compile.
# Run it under the game lock:
#   tools/with_lock.sh <who> tools/run_test.sh --fleshtest=game/test_out/flesh
set -u
ROOT=.
OVR="$ROOT/game/override.cfg"
if [ -e "$OVR" ]; then
  echo "run_test: $OVR already exists; not touching it" >&2
  exit 1
fi
cat > "$OVR" <<'CFG'
[display]

window/size/no_focus=true
CFG
trap 'rm -f "$OVR"' EXIT
# Hard limit so a broken script can never leave a frozen window behind (override with RUN_TEST_LIMIT=<s>).
# RUN_TEST_ENGINE_ARGS: extra engine flags before "--" (e.g. "--fixed-fps 60" for frame-exact animation captures).
# shellcheck disable=SC2086
timeout "${RUN_TEST_LIMIT:-300}" "$ROOT/tools/godot/Godot_v4.7.2-stable_win64_console.exe" --path "$ROOT/game" --windowed --resolution 1280x720 --position -4000,-4000 ${RUN_TEST_ENGINE_ARGS:-} -- "$@"
