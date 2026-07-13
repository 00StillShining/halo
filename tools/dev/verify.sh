#!/usr/bin/env bash
# verify.sh — halo loop verification harness (Brief §10 functional gate).
#
# Steps:
#   1. keep the display awake (caffeinate) so headless captures aren't black
#   2. build the app from the command line (fails loudly on error)
#   3. launch the built binary ~5s and assert no crash report is written
#   4. optionally compile + run the mock EP-40 MIDI source so the app reaches
#      DISPLAY LIVE, and take a best-effort screenshot
#   5. print PASS / FAIL
#
# Usage: tools/dev/verify.sh [--no-midi] [--shot PATH]
set -uo pipefail
cd "$(dirname "$0")/../.."
REPO="$(pwd)"

SCHEME="Halo"
DEST='platform=macOS'
WITH_MIDI=1
SHOT=""
for arg in "$@"; do
  case "$arg" in
    --no-midi) WITH_MIDI=0 ;;
    --shot) SHOT="__NEXT__" ;;
    *) if [ "$SHOT" = "__NEXT__" ]; then SHOT="$arg"; fi ;;
  esac
done

fail() { echo "FAIL: $*"; exit 1; }

# 1. Keep the display awake for the duration (best effort; ignore if absent).
caffeinate -u -t 20 >/dev/null 2>&1 &
CAFFEINATE_PID=$!
cleanup() {
  [ -n "${CAFFEINATE_PID:-}" ] && kill "$CAFFEINATE_PID" 2>/dev/null
  [ -n "${MIDI_PID:-}" ] && kill "$MIDI_PID" 2>/dev/null
  [ -n "${APP_PID:-}" ] && kill "$APP_PID" 2>/dev/null
}
trap cleanup EXIT

# 2. Build.
echo "== building =="
xcodebuild -scheme "$SCHEME" -destination "$DEST" -configuration Debug build \
  >/tmp/halo_verify_build.log 2>&1 || { tail -30 /tmp/halo_verify_build.log; fail "build failed"; }
echo "build ok"

APP="$(find "$HOME/Library/Developer/Xcode/DerivedData" -maxdepth 6 -name Halo.app -path '*Products/Debug*' 2>/dev/null | head -1)"
[ -n "$APP" ] || fail "could not locate built Halo.app"
BIN="$APP/Contents/MacOS/Halo"
[ -x "$BIN" ] || fail "missing executable at $BIN"

# Baseline crash-report count so we only notice NEW ones.
CRASH_DIR="$HOME/Library/Logs/DiagnosticReports"
crash_count() { ls "$CRASH_DIR"/Halo* 2>/dev/null | wc -l | tr -d ' '; }
BEFORE_CRASHES="$(crash_count)"

# 4a. Optionally bring up the mock MIDI source before launch.
MIDI_PID=""
if [ "$WITH_MIDI" = "1" ]; then
  echo "== compiling mock MIDI source =="
  if swiftc -O tools/dev/mock_midi_send.swift -o /tmp/halo_mock_midi >/tmp/halo_verify_midi.log 2>&1; then
    /tmp/halo_mock_midi 12 >/dev/null 2>&1 &
    MIDI_PID=$!
    disown "$MIDI_PID" 2>/dev/null || true
    echo "mock MIDI source running (pid $MIDI_PID)"
  else
    echo "WARN: mock MIDI compile failed; continuing without it"
    tail -10 /tmp/halo_verify_midi.log
  fi
fi

# 3. Launch ~5s.
echo "== launching app =="
"$BIN" >/tmp/halo_verify_app.log 2>&1 &
APP_PID=$!
sleep 5

if ! kill -0 "$APP_PID" 2>/dev/null; then
  APP_PID=""
  tail -20 /tmp/halo_verify_app.log
  fail "app exited before smoke window elapsed"
fi

# 4b. Best-effort screenshot (flaky headless; black capture = display asleep).
if [ -n "$SHOT" ] && [ "$SHOT" != "__NEXT__" ]; then
  screencapture -x "$SHOT" >/dev/null 2>&1 && echo "screenshot -> $SHOT" || echo "WARN: screenshot failed"
fi

kill "$APP_PID" 2>/dev/null; wait "$APP_PID" 2>/dev/null; APP_PID=""
[ -n "$MIDI_PID" ] && { kill "$MIDI_PID" 2>/dev/null; MIDI_PID=""; }

# Give the crash reporter a moment to flush, then compare.
sleep 1
AFTER_CRASHES="$(crash_count)"
if [ "$AFTER_CRASHES" -gt "$BEFORE_CRASHES" ]; then
  ls -t "$CRASH_DIR"/Halo* 2>/dev/null | head -1
  fail "new crash report detected"
fi

echo "PASS: build + ~5s launch, no crash report"
