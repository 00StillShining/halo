#!/usr/bin/env bash
# capture_gate.sh — Phase 1 visual gate artifact set (Brief §9 Phase 1 gate).
#
# Produces window-scoped screenshots of the built Debug app in BOTH palettes
# (A / B) at BOTH target sizes (1440x900 launch default, 1180x720 min) in TWO
# honestly-labeled provenance states:
#   preview   = no MIDI source; the stage shows its self-declared PREVIEW frame
#   mock-live = mock_midi_send.swift virtual source running; display reaches LIVE
# => 8 PNGs in docs/gate/, driven only by the app's real code paths via the
#    DEBUG env hooks in GateCaptureSupport.swift (no faked hardware state).
#
# Best-effort: needs a real login session with an awake display. A black/blank
# frame (tiny PNG) is a headless/asleep-display artifact, not a layout bug — the
# script retries, and the gate doc records any capture that could not be made.
set -uo pipefail
cd "$(dirname "$0")/../.."
REPO="$(pwd)"

SCHEME="Halo"
DEST='platform=macOS'
OUTDIR="docs/gate"
WID_BIN="/tmp/halo_window_id"
MIDI_BIN="/tmp/halo_mock_midi"
MIN_PNG_BYTES=60000   # smaller than this ≈ a black/blank frame → retry

warn() { echo "WARN: $*" >&2; }
fail() { echo "FAIL: $*" >&2; exit 1; }

# --- 1. Keep the display awake for the whole run. ----------------------------
caffeinate -u -t 400 >/dev/null 2>&1 &
CAFFEINATE_PID=$!
cleanup() {
  [ -n "${CAFFEINATE_PID:-}" ] && kill "$CAFFEINATE_PID" 2>/dev/null
  [ -n "${MIDI_PID:-}" ] && kill "$MIDI_PID" 2>/dev/null
  pkill -f "$HOME/Library/Developer/Xcode/DerivedData/.*Halo.app/Contents/MacOS/Halo" 2>/dev/null
}
trap cleanup EXIT

# --- 2. Build. ---------------------------------------------------------------
echo "== building =="
xcodebuild -scheme "$SCHEME" -destination "$DEST" -configuration Debug build \
  >/tmp/halo_gate_build.log 2>&1 || { tail -30 /tmp/halo_gate_build.log; fail "build failed"; }
echo "build ok"

APP="$(find "$HOME/Library/Developer/Xcode/DerivedData" -maxdepth 6 -name Halo.app -path '*Products/Debug*' 2>/dev/null | head -1)"
[ -n "$APP" ] || fail "could not locate built Halo.app"
BIN="$APP/Contents/MacOS/Halo"
[ -x "$BIN" ] || fail "missing executable at $BIN"
# Launch through LaunchServices (`open`), not the raw binary: a directly-exec'd
# binary registers no WindowServer window in a non-Aqua shell, so screencapture
# has nothing to scope to. `open -n --env` gives a real, on-screen window.
kill_app() { pkill -f "$BIN" 2>/dev/null; }

# --- 3. Compile helpers. -----------------------------------------------------
echo "== compiling window_id helper =="
swiftc -O tools/dev/window_id.swift -o "$WID_BIN" >/tmp/halo_gate_wid.log 2>&1 \
  || { tail -20 /tmp/halo_gate_wid.log; fail "window_id.swift failed to compile"; }

HAVE_MIDI=1
echo "== compiling mock MIDI source =="
if ! swiftc -O tools/dev/mock_midi_send.swift -o "$MIDI_BIN" >/tmp/halo_gate_midi.log 2>&1; then
  HAVE_MIDI=0
  warn "mock MIDI compile failed; producing the preview set only"
  tail -10 /tmp/halo_gate_midi.log >&2
fi

mkdir -p "$OUTDIR"

# Baseline crash-report count so we only notice NEW ones.
CRASH_DIR="$HOME/Library/Logs/DiagnosticReports"
crash_count() { ls "$CRASH_DIR"/Halo* 2>/dev/null | wc -l | tr -d ' '; }
BEFORE_CRASHES="$(crash_count)"

CAPTURED=()
MISSED=()

# capture_one STATE SIZE PALETTE — fresh launch, resize+palette via env, shoot.
capture_one() {
  local state="$1" size="$2" pal="$3"
  local out="$OUTDIR/phase1-palette${pal}-${size}-${state}.png"

  open -n "$APP" --env HALO_GATE_WINDOW="$size" --env HALO_GATE_PALETTE="$pal" \
    >/tmp/halo_gate_app.log 2>&1
  sleep 7   # USDZ import + (mock-live) first pad events + resize settle

  if ! pgrep -f "$BIN" >/dev/null 2>&1; then
    warn "app not running after launch ($state $size $pal)"
    tail -15 /tmp/halo_gate_app.log >&2
    MISSED+=("$out (app exited early)")
    return
  fi

  local wid=""
  wid="$("$WID_BIN" 2>/dev/null)" || wid=""
  if [ -z "$wid" ]; then
    warn "could not resolve Halo window id ($state $size $pal)"
    kill_app; sleep 1
    MISSED+=("$out (no window id)")
    return
  fi

  local ok=0 try
  for try in 1 2 3; do
    screencapture -o -l "$wid" "$out" >/dev/null 2>&1
    if [ -f "$out" ] && [ "$(stat -f%z "$out" 2>/dev/null || echo 0)" -gt "$MIN_PNG_BYTES" ]; then
      ok=1; break
    fi
    sleep 2
  done

  kill_app; sleep 1

  if [ "$ok" = "1" ]; then
    CAPTURED+=("$out")
    echo "captured $out"
  else
    warn "only black/blank frames for $out (display asleep / headless)"
    MISSED+=("$out (blank frame)")
  fi
}

# --- 4. Two provenance states × two sizes × two palettes. --------------------
for STATE in preview mock-live; do
  if [ "$STATE" = "mock-live" ]; then
    [ "$HAVE_MIDI" = "1" ] || { warn "skipping mock-live set (no mock MIDI)"; continue; }
    "$MIDI_BIN" 600 >/dev/null 2>&1 &
    MIDI_PID=$!
    disown "$MIDI_PID" 2>/dev/null || true
    sleep 1
  fi

  for SIZE in 1440x900 1180x720; do
    for PAL in A B; do
      capture_one "$STATE" "$SIZE" "$PAL"
    done
  done

  if [ -n "${MIDI_PID:-}" ]; then kill "$MIDI_PID" 2>/dev/null; MIDI_PID=""; fi
done

# --- 5. Crash guard. ---------------------------------------------------------
sleep 1
AFTER_CRASHES="$(crash_count)"
if [ "$AFTER_CRASHES" -gt "$BEFORE_CRASHES" ]; then
  ls -t "$CRASH_DIR"/Halo* 2>/dev/null | head -1 >&2
  fail "new crash report detected during capture"
fi

# --- 6. Report. --------------------------------------------------------------
echo ""
echo "== gate capture summary =="
echo "captured ${#CAPTURED[@]} / 8 artifacts:"
for f in "${CAPTURED[@]:-}"; do [ -n "$f" ] && echo "  $f"; done
if [ "${#MISSED[@]}" -gt 0 ]; then
  echo "missed ${#MISSED[@]}:"
  for f in "${MISSED[@]}"; do echo "  $f"; done
fi
