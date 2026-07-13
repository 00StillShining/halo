# Phase 1 visual gate — owner artifact set

Brief §9 Phase 1 gate. Full-window screenshots of the built **Debug** app in **both
palettes** (A cool "graph paper" / B warm "bone paper") at **both target window sizes**
(1440×900 launch default, 1180×720 the enforced minimum), in **two honest provenance
states**. Regenerate with `tools/dev/capture_gate.sh`.

## The ask — owner action required

**Pick palette A or palette B.** Both currently ship behind one token set and both are
proven working below. The loser is deleted in a later task; until you choose, both remain
functional (no palette is removed by this task).

- **A · graph paper** — cool grey-blue canvas.
- **B · bone paper** — warm off-white canvas.

Compare `phase1-paletteA-*` against `phase1-paletteB-*`: the layout geometry is identical,
only the colour temperature differs.

## Artifacts

Model in every frame is the **Blender-authored USDZ** (`Halo/Resources/EP40.usdz`) — the
status bar shows **no** `PLACEHOLDER MODEL` badge, so the real hero model loaded. Captures
are **@2x** (Retina). Capture date: 2026-07-14.

| File | Palette | Window (pt) | Pixels | State | Provenance shown in status bar |
|---|---|---|---|---|---|
| `phase1-paletteA-1440x900-preview.png`   | A | 1440×900 | 2880×1800 | preview   | NO DEVICE · USB IDLE · DISPLAY PREVIEW · HALO SCAN |
| `phase1-paletteB-1440x900-preview.png`   | B | 1440×900 | 2880×1800 | preview   | NO DEVICE · USB IDLE · DISPLAY PREVIEW · HALO SCAN |
| `phase1-paletteA-1180x720-preview.png`   | A | 1180×720 | 2360×1504 | preview   | NO DEVICE · USB IDLE · DISPLAY PREVIEW · HALO SCAN |
| `phase1-paletteB-1180x720-preview.png`   | B | 1180×720 | 2360×1504 | preview   | NO DEVICE · USB IDLE · DISPLAY PREVIEW · HALO SCAN |
| `phase1-paletteA-1440x900-mock-live.png` | A | 1440×900 | 2880×1800 | mock-live | CONNECTED · USB MIDI RX · DISPLAY LIVE · HALO LINK |
| `phase1-paletteB-1440x900-mock-live.png` | B | 1440×900 | 2880×1800 | mock-live | CONNECTED · USB MIDI RX · DISPLAY LIVE · HALO LINK |
| `phase1-paletteA-1180x720-mock-live.png` | A | 1180×720 | 2360×1504 | mock-live | CONNECTED · USB MIDI RX · DISPLAY LIVE · HALO LINK |
| `phase1-paletteB-1180x720-mock-live.png` | B | 1180×720 | 2360×1504 | mock-live | CONNECTED · USB MIDI RX · DISPLAY LIVE · HALO LINK |

### Provenance — honesty note (Brief §1/§4)

Nothing here is a mock-up of hardware behaviour. Both states are what the app **itself**
derives from what it actually received:

- **preview** — launched with no matching MIDI source. The stage runs its self-declared
  disconnected PREVIEW demo; the status bar says so (`NO DEVICE / PREVIEW / SCAN`). This is
  the pure-honest baseline the owner sees without any hardware attached.
- **mock-live** — the developer CoreMIDI virtual source `tools/dev/mock_midi_send.swift` is
  running. The app reaches `DISPLAY LIVE` **strictly because it observed those MIDI events**;
  pads travel and the LCD shows live note/tempo values. The "device" is the mock source, not
  a real EP-40 — the filename and this table state that explicitly. No frame is presented as
  real-hardware truth.

The 4 **mock-live** frames are the headline in-use gate set; the 4 **preview** frames
document the honest disconnected baseline.

Why @2x pixel heights differ from `points × 2`: `screencapture -l` captures the whole window
frame. Width is exact (1180@2x = 2360, 1440@2x = 2880); the `1180×720` frames are 1504px tall
because the 64px hidden-titlebar strip is included above the content — the app **content** is
at the true minimum size, so the min-size check below is valid.

## Min-size verification — 1180×720 (the enforced minimum)

Both 1180×720 frames were read against the §6 checklist. **Result: PASS, no clipping fixed
or needed.**

| Check | A | B |
|---|---|---|
| Status bar: device/FW/USB/display fields, HALO word, OUTPUT/MONITOR/REC, PALETTE A/B switcher — no `…` truncation, no overlap, no wrap | ✅ | ✅ |
| Mode bar: PLAY / LOAD / EDIT / CAPTURE / BACKUPS all fully rendered with ⌘ hints, even spacing, no trailing-edge clip | ✅ | ✅ |
| Stage: EP-40 model fully inside its viewport, not cropped by the rail | ✅ | ✅ |
| Rail: Play-collapsed spine (`RAIL`) inside its own column, not drawn over the stage | ✅ | ✅ |
| Type legible at @2x, no sub-pixel blur vs the 1440×900 frame | ✅ | ✅ |
| Both palettes identical layout geometry (diff is colour only) | ✅ | ✅ |

Play mode is the default, so the rail is its collapsed spine — the data-heavy rail widths
(LOAD/EDIT/CAPTURE/BACKUPS) are exercised elsewhere and are not part of this gate's default
capture.

## Outstanding follow-up (not in this task)

Brief §9 also calls for a **motion recording** of pad-travel and mode-transition. This task
is screenshots only; that recording is a separate follow-up artifact and is **not** included
here.
