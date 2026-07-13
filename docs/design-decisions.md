# halo — design & architecture decisions

Running log per Brief §11.6. Append and amend; do not silently contradict.

---

### DD-001 · Project format: Xcode synchronized file-system groups
**2026-07-13.** `project.pbxproj` uses `objectVersion = 77` with a
`PBXFileSystemSynchronizedRootGroup` for `Halo/`. Rationale: files added on disk
are picked up without editing the pbxproj — essential for CLI-driven development.
Consequence: keep the on-disk folder layout (Brief §8) authoritative.

### DD-002 · Swift 6 language mode
**2026-07-13.** `SWIFT_VERSION = 6.0`. Rationale: data-race safety matters most in
the audio/MIDI layer (real-time callbacks, cross-actor state); writing it correct
from day one is cheaper than migrating later. Cost: stricter Sendable/actor rules
in Phase 1 UI — acceptable.

### DD-003 · Signing & distribution
**2026-07-13.** Ad-hoc signing (`CODE_SIGN_IDENTITY = "-"`, manual), hardened
runtime off, no team/notarisation. Private single-machine app (Brief §2 non-goals).
`NSMicrophoneUsageDescription` is already set via `INFOPLIST_KEY_*` for when Phase 2
opens the audio input.

### DD-004 · Ship both palettes; owner chooses at the Phase 1 gate
**2026-07-13.** `HaloColorTokens.graphPaper` (A) and `.bonePaper` (B) both exist
behind one token set, switchable via `\.halo` environment. The loser is deleted
after the gate (Brief §5). No colour literals at call sites.

### DD-005 · Design tokens are the only source of colour/space/type
**2026-07-13.** `HaloColors` / `HaloTypography` / `HaloMetrics`. System faces only
(SF Pro / SF Mono); TE proprietary faces never used. 8 px unit; 2–4 px radii;
hairline rules; panel extrusion — deliberately not the rounded-card SaaS look.

### DD-006 · Entity-name contract — FROZEN (corrected by hardware research)
**2026-07-13.** Frozen in `EP40EntityNames.swift`. Research (`docs/research/01-hardware-layout.md`)
verified the physical inventory against TE + K.O. II sources and corrected the
brief's §6 list:
- **Names use underscores, not dots.** USD/Blender sanitizes `.`/`-` → `_`
  (`docs/research/03-realitykit-usdz.md` §2). So the machine contract is
  `chassis_base`, `pad_0`, `button_keys` … The brief's dotted spelling is
  human-readable only. **Blender objects MUST be named with the underscore
  strings** so the USDZ path and procedural fallback resolve identically.
- **Added `button_keys`** — a real KEYS button, omitted from the brief.
- **`group_a…group_d` are REAL pressure-sensitive pads**, not just indicators
  (still one physical set of twelve numeric pads + four group pads = 16 pads).
- **Added `mic_port`** — confirmed built-in mic on the panel (non-interactive).
- **Added `ports_strip`** — all I/O is on the TOP EDGE (stereo/sync/midi in-out + USB-C).
- **`display_surface` is a segmented icon readout on the real unit, not a graphic
  LCD.** halo shows its OWN state there (Brief §6) so this is unaffected.

Contract is confirmed once, early, per Brief §6. Open physical items needing an
owner reference photo (do not treat placeholder proportions as measured): exact
control proportions on the 240×176 face, the pad→number cell mapping, top-edge
jack order, and confirmation the VOLUME knob is present on the EP-40 (confirmed on
the shared K.O. II chassis).

### DD-006a · RESOLVED — speaker fires from the FRONT
**2026-07-13.** Owner confirmed the speaker fires from the front (resolving the
research uncertainty). The brief §6 was right: a front grille, and the audio-reactive
"breathing" cue stays on the model. From TE reference imagery it is the distinctive
**round striped grille in the upper-right of the face**, not a rectangular patch —
placeholder updated accordingly. Real instanced perforations/stripes come with the
final model.

### DD-007 · Mechanical pad press-travel (RealityKit)
**2026-07-13.** `KeyTravelAnimator` presses the active pad ~1.2 mm into the top
plate (Brief §6: 55–75 ms ease-in down, 95–120 ms damped ease-out up) via
`move(to:relativeTo:parent)`. Driven from `EP40SceneController.applyDisplay` off
`EP40DisplayState.activePadIndex`, so it animates in BOTH preview and live with no
extra plumbing. `EP40Entity.padGridOrder` maps the display's grid index → pad entity
(kept consistent with `HaloAppModel.midiOffsetToGrid`). Single-active-pad for now
(matches the collapsed display state); polyphonic travel later by feeding raw
Note On/Off. Rest transforms captured once at bind time.
**Verified** end-to-end: a mock CoreMIDI source (name contains "EP-40") drove the app
to LIVE; with travel temporarily exaggerated, note 47 correctly depressed `pad_9`
(right pad, downward). Test driver: `scratchpad/mock_midi_send.swift` (cycles pad
notes) — a hardware-free way to exercise the reactive model; not yet in the repo.

### DD-006c · ORIENTATION CORRECTION — the EP-40 is PORTRAIT
**2026-07-13.** A clean straight-on official product shot shows the EP-40 is operated
**portrait** (taller than wide): **X width ≈ 176 mm, Z depth ≈ 240 mm**, thickness 16 mm.
The placeholder was built landscape — wrong. Face layout, far→near: ports (top edge);
branding (far-left) + round speaker (far-right); full-width green display band; knob
row (VOLUME left · SOUND/MAIN/TEMPO centre · orange X + green Y knobs right); left edge
KEYS/FADER/fader/SHIFT; pad matrix (4 icon group pads = left column, then numeric 3×4);
right function column (SAMPLE/FX/TIMING/ERASE, −/+); RECORD (orange) + PLAY (green) at
the near edge. This is the authoritative layout for the 1:1 model.

### DD-006d · Real model authored in Blender by this session (headless USDZ)
**2026-07-13.** Owner wants the final model to resemble the EP-40 1:1. Pipeline
validated: `tools/blender/build_ep40.py` builds the model headless
(`blender --background --python`) and exports **USDZ** → `Halo/Resources/EP40.usdz`.
Verified: Z-up→Y-up conversion (`convert_orientation`, up=Y, forward=NEGATIVE_Z),
meters scale, and **underscore prim names survive export** so the contract resolves.
Iteration loop: edit script → export → rebuild halo → screenshot vs reference.
Export note: clear the World so no stray `DomeLight` is baked in (halo owns lighting).

### DD-006e · Model fidelity pass 1 — legends, striped speaker, measured upper zone
**2026-07-13.** `tools/blender/build_ep40.py` now includes: geometry-text legends
(green numerals + A–D on pads; cap labels SOUND/MAIN/TEMPO/KEYS/SAMPLE/TIMING/FX/
ERASE/−/+/SHIFT; REC/PLAY as full pads; VOLUME/X/Y plate silkscreen — neutral face,
never TE's typeface); the round speaker rebuilt as cream slats over a dark opening
at measured proportions (~25% device width, tight in the far-right corner, fully
above the display band); a white `brand_panel` far-left reserved for halo's OWN
wordmark decal (never TE's RIDDIM artwork); knobs at measured u-positions. Static
legends are geometry (crisp, placed in-model); the live display remains a RealityKit
texture (`DisplayTextureRenderer`, Phase 1). Extra prims beyond the contract
(slats, rim, brand panel, legends) are fine — validation only requires contract
names to EXIST.

### DD-006f · GOTCHA — tiny text meshes make RealityKit render NOTHING
**2026-07-13.** Blender text converted to mesh at **< ~2 mm glyph size** exported to
a USDZ that RealityKit loaded "successfully" (entity returned, contract resolved, no
error/fault logged) but the **entire scene rendered blank** — not just the tiny
meshes. Diagnosed by bisect (single labels rendered; stacked labels with a 1.7 mm
secondary line did not; raising the secondary to 2.1 mm fixed it). Rule for all
future legend work in `tools/blender/build_ep40.py`: **no text below 2.1 mm**, and
any blank-scene regression should suspect degenerate/near-degenerate geometry first.
Dual-function stacked cap labels (SOUND/EDIT etc., shift-layer in orange) now work.

### DD-006b · Reference imagery, not physical photos
**2026-07-13.** Owner cannot photograph the physical unit; we work from **online TE
imagery + owner-supplied EP Sample Tool illustration** (proportion/style reference
ONLY — never traced, textured, or shipped, per Brief §6 licensing boundary).
Observations captured in `docs/research/01-hardware-layout.md`. Colourway confirmed:
**warm cream body, riddim-green + orange accents** (this leans toward Palette B, but
the owner still chooses at the Phase 1 gate — both ship).

### DD-007 · Blender USDZ is primary; procedural fallback never blocks
**2026-07-13.** Model authored in Blender → USDZ, honouring the entity contract.
Until it arrives, a labelled `PLACEHOLDER MODEL` from RealityKit primitives keeps
every other phase moving (Brief §6). Interactive logic stays independent of asset
origin.

### DD-008 · Sequencing this session
**2026-07-13.** EP-40 not connected → Phase 0A/0B deferred to a with-device
session. Proceeding on Phase 1 (visual north star, mock data), which by design
depends on neither the hardware nor the Blender asset.

### DD-009 · Verification harness + HaloTests unit-test target
**2026-07-13.** Established the loop's own functional gate (Brief §10). The MIDI
interpretation that drives the replica display (note→group range, velocity-0 ==
Note-Off, and the documented-order→physical-grid mapping) was extracted from
`HaloAppModel`/`EP40MIDIObserver` into a single pure namespace,
`Halo/Device/EP40MIDIMapping.swift`, so production code and tests agree by
construction (no duplicated tables). Added a `HaloTests`
`com.apple.product-type.bundle.unit-test` target by hand-editing
`project.pbxproj` (synchronized `HaloTests/` group, `TEST_HOST`/`BUNDLE_LOADER`
pointed at `Halo.app`, wired into the shared scheme's `TestAction`); with
objectVersion-77 synchronized groups new test files are auto-included. First 10
XCTest cases cover the three required invariants plus the pad-grid round-trip
against `EP40Entity.padGridOrder`; `xcodebuild … test` is green.
`tools/dev/mock_midi_send.swift` publishes a CoreMIDI **virtual source** named
"EP-40 Mock Source" (group-A notes 36…47) purely as a developer stimulus — the
app still reaches LIVE only because it observed real MIDI, preserving the §1/§4
honesty boundary. `tools/dev/verify.sh` runs build → ~5s launch → no-crash
assertion, optionally driving the mock source. No device-gated work was touched.

**Overseer addendum (same day).** `TEST_HOST` runs the full app binary, and the
window's async USDZ import (CoreRealityIO live-scene-update queue) raced the
test host's exit — XCTest quits milliseconds after the last test — segfaulting
inside `UsdSchemaRegistry::FindSchemaInfo` and depositing a `Halo-*.ips` crash
report on every `xcodebuild test` run (which would also poison the harness's
own crash-report gate). Fixed in `HaloApp`: when the process is the XCTest host
(`XCTestConfigurationFilePath`/`XCTestBundlePath`/`XCTestSessionIdentifier` in
the environment) the window shows a static placeholder instead of booting the
RealityKit stage. Unit tests exercise pure logic, never the scene, so nothing
real is hidden. Also observed: macOS can take ~25–40 s to flush a crash report,
so verify.sh's process-liveness check during the smoke window is the primary
signal; the report count is secondary coverage.

### DD-010 · Travel = observed depression; rim = latched/inferred state
**2026-07-13 (P1-buttons).** The mechanical button language (Brief §6) now covers
every model control, but split by provenance so it can never claim an unobserved
finger (Brief §1/§4):

- **Travel** (a −Y depression) means *a physical press was observed right now*.
  Only the numeric pads travel, driven by pad Note On/Off — the existing,
  unchanged behaviour. Pointer hover (halo's own observation) adds a tiny +0.15 mm
  lift; it is always honest.
- **Rim** (a thin orange focus outline, no travel) means *a latched or inferred
  state*: the mode button matching `EP40DisplayState.mode`
  (`.sound/.main/.tempo` → button; `.erase`/`.system` → dark, no verified button),
  the active group pad (`activeGroup` → group_a…d, a note-range inference), and the
  transport engaged state (`button_play` lit while `isPlaying`, sourced from
  observed MIDI Start/Continue/Stop — the Brief's sanctioned "transport
  indicator", NOT a held-down cap).
- **`button_record` gets no state-driven animation at all.** There is no observed
  record source on the documented USB MIDI surface (`EP40DisplayState` has no
  record field; the realtime set has no Record message). It keeps the mechanical
  hover/press affordance but is never lit or travelled by state. No `isRecording`
  field was added — the absence *is* the honesty guarantee, pinned by
  `EP40ControlProjectionTests.testProjectionExposesNoRecordChannel`. Recorded under
  needsDevice (see device-capabilities). Note: halo's own Phase-2 Mac-side recorder
  must NOT animate this button either — Mac recording is not device record.

Implementation: a pure, non-`@MainActor` `EP40ControlProjection.project(_:)`
(unit-testable) maps a display state to four honest channels; `.waiting` projects
to `.rest` (everything unlit) even with stale values. `EP40SceneController`
diffs the projection and drives `KeyTravelAnimator`, now a small state machine
composing `pressed`/`hovered`/`lit` through one `settle` function. Timing and
depth for 2D (`MechanicalButtonStyle`) and 3D (`KeyTravelAnimator`) come from one
shared `HaloMechanics` enum so they match by construction. The 3D focus rim is
halo-owned geometry (four thin `UnlitMaterial` bars, a 0.6 mm annotation, ≥ the
fallback's existing 0.6 mm prims — DD-006f concerns the Blender *text* generator,
not runtime primitives) added as a child of the button entity, so it follows
travel and never mutates USDZ materials. The palette switcher in `HaloStatusBar`
is the style's first real consumer (rest/hover/pressed/selected/keyboard-focus in
one place) and recolours the 3D rims via `setAccent` on palette flip.

**Deferred:** (1) 3D pointer *hover* is honest and specced but deferred to P2's
clickable-pads task — it needs a running-app verification of the camera
projection's FOV axis (vertical vs horizontal) that a flaky headless capture
can't give, and shipping unverified ray math risks a silently-offset feature.
The `KeyTravelAnimator.setHovered` channel is built and ready. (2) 3D
keyboard-focus is deferred — there is no 3D focus model yet; 2D covers keyboard
focus. (3) 3D "disabled" is defined as "no hover/press response + rim suppressed"
(no dimming of USDZ materials); no disabled model controls exist in Phase 1.

## DD-011 · Halo ring: 48-segment Halo-owned rig, luminance via OpacityComponent, state from connection truth

The `halo_ring` glow is a Halo-owned rig (`HaloRingRig`), a `halo_ring_glow`
parent with 48 `ModelEntity` segment boxes derived from the ring's `visualBounds`
so it works identically for the Blender USDZ (a thin elliptical ink annulus) and
the procedural fallback (a solid disc). It never mutates USDZ materials.
**All luminance runs through `OpacityComponent` only** — the parent's opacity is
the master luminance (one write for uniform states: connected, monitoring,
recording, error), each segment's opacity is the pattern (only written by the
discovering sweep and transfer progress). `OpacityComponent` composes
multiplicatively down the hierarchy, so uniform states cost exactly one component
write per ≤60 Hz tick. Per-state colour is a shared `UnlitMaterial`
(orange / orangeHot / warning) reassigned only on state-colour or palette change,
never per frame.

Ring **state is derived only from `HaloRingState.derive` over real inputs**
(observer running, endpoint connected, real error label; monitor/record/transfer
fields have no producers yet) — never from `EP40DisplayState` preview/demo frames
(Brief §1/§4). The only real error reachable today is CoreMIDI client setup
failure (`ringErrorLabel = "MIDI"`). The animation is driven off a
`SceneEvents.Update` subscription (render loop, not a timer); static states
early-out on `needsTick == false`. The error state pulses exactly once on a new
error, then holds a stable labelled state forever. Reduce Motion pauses the
discovering sweep and recording breath (the status-bar timer carries the
information). Audio-responsive `.monitoring` luminance is the ONLY audio→RealityKit
path and goes bridge (`AudioLevelBridge`, lock-free atomic) → main-actor tick
(`RingLuminanceSmoother`, 50 ms attack / 350 ms release) → `OpacityComponent`,
coalesced to ≤60 Hz and hard-capped at 0.55.

**OpacityComponent fallback:** if `OpacityComponent` proves inert over
`UnlitMaterial` on this OS, switch the parent to a transparent-blending material
whose opacity is patched at ≤60 Hz — still never per-segment material allocation
per frame. The disconnected state leaves the USDZ ink annulus untouched (glow
parent opacity 0); the optional 0.55 ink-softening was skipped because an
`OpacityComponent` on the ring entity would also scale its glow-parent child.

---

_Open decisions awaiting evidence:_
- Exact physical control inventory (confirm/adjust the contract) — research + owner photos.
- Palette A vs B — owner, at Phase 1 gate.
- Audio bridge topology (dual AUHAL + ring vs aggregate device) — Phase 0A prototype + research thread `coreaudio-routing`.
- EP-40 SysEx dialect — Phase 0B only.
