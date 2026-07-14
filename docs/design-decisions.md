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

## DD-012 · Velocity LED glow + polyphonic pad travel

**Velocity LED.** On an observed pad Note On, the struck pad gets a velocity-scaled
emissive "LED": a **Halo-owned static deck-skirt annotation** (a thin rounded
`UnlitMaterial` plate in the palette's `orangeHot`, driven by an
`OpacityComponent`) — the same doctrine as the focus rim (DD-010), never a USDZ
material edit. The skirt is parented to the pad's PARENT at the pad's REST
transform, so it does **not** travel: the keycap visibly sinks toward its own glow
(a mechanical read), instead of a cap-parented plate sinking into the top plate at
peak brightness (1.1–1.3 mm of travel). Intensity is a **quadratic** map of
observed velocity (`padLEDOpacity`, 0.16 … 0.90), so soft hits read soft. Rise is
**instantaneous** (a real LED has no attack); after the observed Note Off it
decays **exponentially** (`padLEDDecayTau` 0.09 s, ~0.25 s tail) on the render-loop
tick, which early-outs when nothing is decaying (ring-rig idle philosophy).

**Brief §6 asymmetry, pinned by a test.** Velocity drives LED intensity (~5.6x
span) far more than physical travel (~1.18x span, `travelDepth` 1.1–1.3 mm).
`HaloMechanicsVelocityTests` fails if that inequality ever regresses — same spirit
as the DD-010 reflection guard. LED colour is `orangeHot` (a momentary observed
event); the rim stays plain `orange` (latched/inferred) — a two-tier vocabulary.
A palette flip recolours live LEDs and rims together.

**Polyphonic travel.** Live pad travel is now driven by **raw Note On/Off** fed
straight from `HaloAppModel.receive(event)` to `EP40SceneController.padNoteOn/Off`,
alongside (not through) the display state. `PadHoldRegistry` (pure, unit-tested)
refcounts holds **per physical pad** using a set of `(channel, note)` keys — robust
to the real quirk that two group notes (e.g. 36 and 48) map to the **same** pad; it
releases only when the LAST hold ends. Policy: a duplicate strike on an already-held
key is a **restrike** (LED re-flash at the newly observed velocity, no further
travel); **latest observed velocity wins** (no max-hold — that would invent a level
the device never reported); notes outside 36…83 do nothing. Travel and display can
never disagree because both map through `EP40MIDIMapping.gridIndex` →
`EP40Entity.padGridOrder`.

**Projection is now PREVIEW-only.** `EP40ControlProjection.pressedPad` →
`previewPressedPad`, set only in `.preview`; in `.live` it is nil (raw notes own
travel), `.waiting` stays at rest. The deterministic PREVIEW demo remains the only
projection-driven travel and is still labelled PREVIEW — it also shows the LED
language now (pressed at the frame's velocity). Disconnect / reconnect calls
`scene.releaseAllPads()` in both branches (clears every hold, travel, and LED)
before presenting, so nothing survives a connection change.

**Accepted risk:** the `bufferingNewest(512)` observation stream can drop a Note
Off under pathological flood, potentially leaving a hold until the next connection
change — identical exposure to the existing `heldMIDIKeys` display readout; no new
mitigation invented. Out of scope: the 2D `MechanicalButtonStyle` (no 2D velocity
producer) and group-pad/button LEDs (no observed per-control velocity source) — the
animator API supports them for free later.

## DD-013 · P1 shell — modes, contextual rail, mode bar, Escape/Return

**2026-07-13.** The persistent window (Brief §7) is now: top status strip + reactive
stage + a contextual right rail + a bottom mode bar. Six modes
(`HaloMode`: play/load/edit/capture/rack/backups); RACK is hidden until Phase 5a.

**Mode is UI-only state.** `HaloAppModel.mode` never touches `displayState`,
`ringState`, or any MIDI path, so a mode switch cannot disturb PREVIEW / WAIT /
LIVE provenance (Brief §1/§4). `select(_:)` guards no-ops and any mode not in the
visible bar, and calls `scene.focusCamera(for:)` only — it never calls
`releaseAllPads()` or presents a display frame.

**Camera move, not screen replacement.** A mode change animates the rail width
and glides the hero camera between subtle framings (`EP40SceneController.framing`,
all within a few degrees of the hero view; `.play` equals the original
0.70/28/42 so the default view is pixel-identical). The rail-width animation and
the `move(to:relativeTo:duration:timingFunction:)` camera move share one
`HaloMechanics.modeChangeDuration` (0.45 s) so the whole gesture reads as one
mechanical motion. Under Reduce Motion both jump-cut. This is halo presentation,
not a hardware claim — no honesty concern. `move(to:)` (not the macOS-26-only
`Entity.animate`) per project facts; `pendingMode` applies a pre-load selection
when the USDZ finishes, mirroring `pendingDisplay` / `pendingRing`.

**⌘1…N indexes the VISIBLE mode-bar order.** So today ⌘5 = BACKUPS and ⌘6 is
unbound; when RACK ships at Phase 5a, ⌘5 = RACK and ⌘6 = BACKUPS by design. Both
the mode bar and the `CommandMenu("Mode")` enumerate `HaloMode.visible(...)`, so
they renumber together — pinned by `HaloShellTests`.

**Escape = transient LIFO stack that structurally cannot reach audio.**
`TransientCoordinator` is a pure LIFO register of UI dismiss closures. `handleEscape()`
pops the top entry and calls it (popping before dismiss so a repeated Escape can
never re-fire the same closure; the view's own `onDisappear` unregister is then a
harmless no-op). It holds no audio handle and calls nothing on the audio path, so
Escape can never stop audio — and **audio controls must NEVER register as
transients** (review contract, not a runtime check). When nothing is registered
Escape returns `.ignored` and falls through. The rail is furniture, not a
transient — Escape never collapses it.

**Return is `haloSafeDefault()` only.** The single sanctioned, grep-able way to
bind Return (`.keyboardShortcut(.defaultAction)`); forbidden on
overwrite/delete/send-to-device so "never a destructive default" is enforceable at
review time. No shell control needs it yet.

**Manufactured surface, not SaaS cards.** The rail uses one `HaloPanel` primitive
(tracked mono header strip, hairline rule, 4 px radius, hairline ink outline, hard
offset shadow at blur 0 — the extrusion read) and a leading hairline + 2 px metal
extrusion strip. Per-mode scaffolds (`Halo/Features/<Mode>/…Rail.swift`) show
**honest rest states only**: disabled placeholder controls with mono captions
stating the real reason (AUDIO ENGINE — PHASE 2 / DEVICE READ — NEEDS VERIFIED
PROTOCOL (PHASE 0B) / CAPTURE ENGINE — PHASE 3), em-dash rest values, no invented
data, no orange (reserved for selected/engaged/focus). Meter tracks rest at zero
with no motion because no audio truth exists yet.

**Play collapse.** Play defaults to a collapsed 28 pt spine (model is the hero);
it expands to a 300 pt utility column. Data-heavy modes take
`HaloMetrics.dataRailWidth` — clamped into the 0.34–0.40 band (0.37 target).

---

## DD-014 — Play + Load layouts on deterministic MOCK data (P1-play-load)

Phase 1 *layout* work (Brief §7 Play/Load). The honesty lines held:

**Mock-data provenance is explicit and everywhere.** `MockDeviceLibrary`
(`Halo/Samples/`) is the ONE seeded source of truth — a `SplitMix64`-driven
`generate(seed: 0x0E40)` with no `Date()` / `UUID()` / unseeded randomness, so the
loop's headless screenshots are byte-stable. LOAD carries a persistent `[MOCK]`
provenance strip above both tabs (`MOCK DEVICE DATA — REAL READ NEEDS VERIFIED
PROTOCOL (PHASE 0B)`), and every mock value keeps a `(MOCK)` suffix. This is a UI
layer entirely separate from the status-bar PREVIEW/WAIT/LIVE provenance — `LoadSession`
is UI-only state (same class as `mode`, DD-013) and touches nothing on the
display/ring/MIDI channels, so a mode round-trip through LOAD cannot disturb
hardware-truth provenance.

**Slots and pad assignments are separated by type, never conflated** (Brief §3).
`SampleSlotID` (labelled `SLOT 042`) and `MockPadAssignment` (labelled
`PAD 7 · GROUP A`) are distinct types; assignments *reference* slots. "Usage" is
always *derived* through one function — `library.assignments(referencing:)` — so
the SOUNDS `USE` column is computed from PADS data and the two can never silently
disagree (pinned by `MockDeviceLibraryTests`). Board legends come from `PadGrid.legends`,
zipped against `EP40Entity.padGridOrder` in `PadsBoardTests`, so board / travel /
display share one order.

**Play meters rest at true silence.** `StereoMeter` builds the full peak/RMS
anatomy now (metal track, RMS fill, ink peak-hold tick, unlit clip dot, labelled
scale) driven by a `StereoLevels` value; the running app always feeds `.silence`.
Non-silent levels appear ONLY in `#Preview` — a meter that moved in the app would be
a faked hardware state. Phase 2 wires `AudioLevelBridge` values into this exact
view with no other change. The `fraction(dB:)` mapping is pure and piecewise so
each tick sits on its label (`StereoMeterTests`).

**The gain fader is enabled; the output picker lists LIVE Core Audio devices; transport is disabled.**
`HaloFader` (DesignSystem, reusable for RACK) sets a real *local* −12 dB preference
and claims nothing about hardware — same honesty class as palette selection, caption
states when it takes effect. The output picker lists the machine's real Core Audio
output devices from `AudioDeviceDiscovery` and binds the selection to a STABLE device
UID, not a display name (DD-016) — persisted through `AudioOutputSelection`. The layer
is read-only: it never writes the system default, a fallback tag names the exact rule
that fired (`SYSTEM DEFAULT`, or `AUTO FALLBACK` when no usable system default exists
and the first output was chosen), and the caption keeps it honest — routing is Phase 2, so selecting
only records the UID the monitor path *will* target and nothing is animated or claimed
about hardware. The list renders via an inline disclosure (no stock `Picker`/`Menu`/
popover); the expanded list registers as a transient so Escape collapses it.
MONITOR/RECORD/GRAB are disabled keycaps with real-reason captions.

**Pad file drops = presentation, not a hardware claim.** Numeric pads get trigger
colliders in a dedicated `CollisionGroup.haloDropTargets`, installed in
`makeScene()`'s generation-guarded block from `visualBounds` (USDZ + procedural
fallback alike). The drop reticle is a dedicated Halo-owned hairline frame entity —
**never** `keyAnimator.setLit` (that channel means observed/inferred hardware state,
DD-010). The pick ray (`dropRay`, pure/`nonisolated`, `PadDropRayTests`) is built
from the **settled** target framing `framing(for: pendingMode)`, not the animating
camera: a drop during the 0.45 s camera glide resolves against where the camera is
*going*, matching where the reticle lands — an accepted edge.

**Preparation sheet.** A custom transient panel (not stock `.sheet`), Escape-cancel
via the transient stack. The FILE block is REAL (decoded via `AVAudioFile`;
non-decodable files are rejected before the sheet opens — no invented metadata); the
DESTINATION block is MOCK (project/next-free-slot/previous-assignment). Group is a UI
concept here (pads are one physical set) so a pad drop sets the grid index but the
group follows the rail. Treatment size estimates are pure, `EST`-labelled functions.
`SEND + ASSIGN` is disabled (`DEVICE TRANSFER — NEEDS VERIFIED PROTOCOL (PHASE 0B)`)
and never gets `haloSafeDefault()` (device write — the grep-able rule); Return is
unbound in the sheet.

`needsDevice` (recorded, not attempted): real 001–999 library read + device-reported
capacity (Phase 0B); on-device audition via the Bank Select/PC scheme (verify Phase
0A); the `SEND + ASSIGN` upload/verify/assign transaction (Phase 0B / Phase 3). No
`device-capabilities.md` change — no new hardware claims were made.

---

## DD-015 — Phase 1 visual gate captured via DEBUG-only env hooks (P1-gate)

The Phase 1 owner gate set (Brief §9) is produced by `tools/dev/capture_gate.sh`, which
drives the app through `Halo/Diagnostics/GateCaptureSupport.swift` — a `#if DEBUG`,
env-var-gated helper installed on one `.onAppear` in `HaloApp.swift`. Three hooks:
`HALO_GATE_PALETTE` (A/B) calls the real `model.selectPalette`, `HALO_GATE_MODE` calls
the real `model.select`, `HALO_GATE_WINDOW` (`1440x900`/`1180x720`) `setContentSize`s the
NSWindow (both sizes ≥ the SwiftUI 1180×720 minimum, so AppKit doesn't fight it). Because
every hook goes through the same code paths a user click would, nothing captured is faked —
provenance (PREVIEW/WAIT/LIVE) is whatever the app itself derives (Brief §1/§4). The helper
is compiled out of Release and inert without the env vars.

Capture mechanics: the app is launched with `open -n "$APP" --env …`, **not** the raw
binary — a directly-exec'd binary registers no WindowServer window in a non-Aqua shell, so
`screencapture` would have nothing to scope to; `open` gives a real on-screen window.
Screenshots are window-scoped (`screencapture -o -l <windowID>`, id from
`tools/dev/window_id.swift` reading only `kCGWindowOwnerName`, no screen-recording grant),
with a file-size retry heuristic for asleep-display black frames. Two honest provenance
states are shot per size×palette: `preview` (no MIDI source → self-declared PREVIEW) and
`mock-live` (`mock_midi_send.swift` virtual source → LIVE with pads travelling). 8 PNGs in
`docs/gate/`, indexed by `docs/gate/phase1-gate.md`. Captures are `@2x` (Retina); the
`1180×720` frames measure `2360×1504px` — width is exactly 1180@2x and the extra 64px of
height is the hidden-titlebar strip `screencapture -l` includes, not extra content.

No palette deleted (both exercised through the real path and verified rendering). No
device-gated work, no USDZ/generator change, no new target (no pbxproj edit).

## DD-016 — Core Audio device discovery + honest output picker (P2-discovery)

Brief §8 needs an output picker bound to STABLE device UIDs, plus observation of device-list /
default-device / sample-rate changes. Split into a pure, tested core and a thin real-hardware
shell:

- `AudioDevice` / `AudioDeviceSnapshot` (`Halo/Audio/AudioDeviceModel.swift`) are pure value types
  carrying only persistable facts (UID, name, in/out channels, current + supported nominal rates,
  buffer-frame range) — never live `AudioObjectID`s (not stable, never persisted).
- `AudioOutputResolver.resolve(preferredUID:snapshot:)` is a pure, non-isolated function: persisted
  UID present → `.preferred`; else system default output → `.fallbackDefault`; else first output →
  `.fallbackFirst`; no outputs → `.none`. Input-only devices are never chosen as an output. This is
  the whole selection brain and is exhaustively unit-tested (`AudioOutputSelectionTests`, 10 cases)
  with **zero** Core Audio dependency.
- `AudioOutputSelection` (@MainActor @Observable) persists ONLY the UID through an `AudioPreferenceStore`
  seam (UserDefaults in production, in-memory double in tests). Keys on UID, not display name.
- `AudioDeviceDiscovery` (@MainActor @Observable) is the real HAL shell: enumerates devices, captures
  facts via `CoreAudioEnumerator`, and installs property listeners (device list, default in/out, and a
  per-device nominal-sample-rate listener reconciled on every device-list change). Listener blocks reach
  the actor through a weak box + `Task { @MainActor }` hop (mirrors the MIDI observer). `start()`/`stop()`
  are idempotent; listeners are removed with the exact blocks they were added with.

Honesty (Brief §1/§4): the layer is **read-only** — it reflects real Core Audio truth and NEVER writes
the system default input/output (a fallback row is tagged with the exact rule that fired —
`SYSTEM DEFAULT` for the default-output fallback, `AUTO FALLBACK` when no usable system default
exists and the first output was chosen — so the UI never implies the user picked it, and never
labels a first-device fallback as the system default). The picker in `PlayRail` now lists LIVE devices
instead of the old MOCK list, but the caption keeps it honest: routing itself is Phase 2 and selecting
only records the UID the monitor path *will* target — nothing is animated or claimed about hardware.
The EP-40's own audio input/output verification stays needs-device (Phase 0A); the enumeration MECHANISM
is verified against this Mac's real devices. No palette touched; no device-gated protocol invented; no
new target (both `Halo/` and `HaloTests/` are synchronized groups). MONITOR/METERS/RECORD/GRAB stay at
their honest Phase 2 rest state.

---

## DD-017 — Monitor route: dual-AUHAL + ring buffer + limiter + honest meters (P2-route)

Brief §8 wants the production monitor path: an input-only AUHAL for the EP-40 and a separate output
AUHAL for the chosen Mac output, bridged through a preallocated SPSC ring buffer, drift-handled,
metered at 30–60 Hz, and run through monitor gain → (Phase 5 FX insert, bypassed) → a transparent
−1 dBFS safety limiter. Built as a pure, exhaustively-tested DSP core plus a thin real-hardware router.

Pure, real-time-safe, unit-tested building blocks (no allocation / locks / logging on the hot path):
- `AudioRingBuffer` — preallocated single-producer/single-consumer float bridge; power-of-two capacity,
  monotonic `Atomic` head/tail with acquire/release ordering, partial write/read on overrun/underrun,
  lossless across wrap (`AudioRingBufferTests`, incl. a 2000-step wrap stream).
- `SafetyLimiter` — stereo-linked, zero-lookahead −1 dBFS brick wall. Two pinned guarantees: output
  never exceeds the ceiling (even on ±9.0 impulses), and it is **bit-transparent** below/at the ceiling
  (gain stays exactly 1.0) so it colours nothing until it must (`SafetyLimiterTests`).
- `MonitorGain` — smoothed −12 dB-default gain; dB→linear with a true-silence floor at −60 dB, unity is
  bit-transparent (`MonitorPathTests`).
- `AudioMeter` / `MeterMath` — peak/RMS with fast-attack/slow-release ballistics, published as atomic
  bit-patterns (single writer = audio thread, single reader = main actor) and read back as a dBFS
  `StereoLevels` snapshot with a latched, self-clearing clip flag. A fresh/stopped meter reads
  `.silence` (`AudioMeterTests`). Fixed an inverted ballistic formula found by the tests.
- `DriftController` — pure, gentle (±0.2% max) sample-rate ratio from ring fill vs a half-full target;
  `>1` when too full, `<1` when too empty, clamped so pitch stays imperceptible (`MonitorPathTests`).
  Wrapped by `DriftCompensatingConverter` (AudioConverter, passthrough when formats match).
  **Honest limit (Overseer sweep): the drift stage is NOT yet applied to the live stream** — nothing in
  the render path calls it. Wiring a varispeed stage into the output callback and tuning it needs two
  real clocks to observe (needs-device, Phase 0A soak). Until then ppm clock drift degrades, worst
  case, to a bounded ring drop / silence-fill after many minutes — never a crash, never a faked
  correction, and the router comment says exactly this.
- `MonitorProfile` — LOW 128 / BALANCED 256 (default) / SAFE 512, clamped to the device's buffer range.
- `FeedbackGuard` — pure check: routing the EP-40 input to the EP-40 as output would howl.

Real-hardware shell (production path; **live audio = needs-device**):
- `MonitorRenderContext` — the shared preallocated RT state handed to both callbacks as an *unretained*
  pointer (no ARC on the audio thread). Canonical interleaved Float32 stereo; UI→RT gain crosses a
  single `Atomic<UInt32>` seam. Output callback: read ring → gain → (FX bypass) → limiter → publish
  meter + ring-glow level. Input callback: `AudioUnitRender` the EP-40 into scratch → write ring.
- `EP40AudioRouter` (`MonitorEngine`) — builds the two `kAudioUnitSubType_HALOutput` units, sets their
  current devices by UID (never the system default), installs the callbacks, and starts/stops. Throws
  honest `MonitorRouteError`s (no input device, config/start failures) rather than crashing when the
  EP-40 audio input is absent.
- `MonitorController` (@MainActor @Observable) — owns lifecycle + the 50 Hz meter poll. Monitoring
  starts ONLY on explicit `start` and defaults to −12 dB; the meter drops to `.silence` on stop. Its
  state machine is unit-tested with a mock engine (`MonitorPathTests`). USB removal stops the route
  promptly (wired in `HaloAppModel.receive(_ connection:)`).

Honesty (Brief §1/§4): the meter shows only levels the output callback ACTUALLY rendered — no route,
no movement. `PlayRail` now drives the real route: MONITOR is enabled only when a real EP-40 audio
input and an output device are both present, captions state the real reason otherwise, and the
feedback-risk warning surfaces when the chosen output *is* the EP-40 input. Both palettes untouched; no
device-gated protocol invented; both `Halo/` and `HaloTests/` are synchronized groups (no pbxproj edit).
Live audio through hardware, end-to-end latency and the 30-minute soak remain needs-device (Phase 0A).

Overseer sweep (same task, before commit):
- **Clip flag was inert** — `publish` received the post-limiter buffer (peaks capped at ≈0.891), so the
  latched clip could never fire. The output callback now measures the RAW pre-limiter peaks and passes
  them to `publish(_:frames:rawPeakL:rawPeakR:)`; clip = a real overload attempt the limiter caught
  (pinned by `testClipLatchesFromRawPeaksOnLimitedBuffer`). Shown levels stay post-limiter (the caption
  says so).
- **Ring-glow bridge was a dead end** — `MonitorController()` default-built its own `AudioLevelBridge`
  while `HaloRingRig` read a different instance, and `monitorEngaged` was never fed, so a genuinely
  running route showed neither the MON ring state nor the glow. `HaloAppModel.init` now hands the
  scene's rig bridge to the controller, and start/stop go through `startMonitor`/`stopMonitor` wrappers
  that refresh `ringState` (`monitorEngaged: monitor.isRunning`) — the ring/`HALO MON` chip now shows
  only an actually-running route.
- **AudioUnit leak on failed start** — a `makeOutputUnit` failure leaked the already-created input unit;
  units/context now register the moment they exist so the failure path disposes everything, and each
  factory disposes its instance if configuration throws mid-way.

---

## DD-018 — Session recorder taps the raw pre-monitor input; recording requires an active route (P2-recorder)

**Decision.** The session recorder (Brief §7 Capture) records the RAW EP-40 input *before* halo's
monitor gain/limiter/FX — exactly the stream `monitorInputRender` bridges into the monitor ring. Rather
than open a second, competing input AUHAL, it taps the existing running route through a shared
`CaptureTap` (its own SPSC ring + a raw pre-gain `AudioMeter` + an `armed` atomic). The input callback,
when the tap is armed, best-effort-writes the same interleaved block into the tap's ring and publishes
raw peaks — one relaxed atomic load per block when idle, RT-safe throughout (Brief §8).

**Consequences / honesty (Brief §1/§4).**
- Recording is **gated on `monitor.isRunning`**: the raw stream only exists while the input AUHAL runs.
  `HaloAppModel.toggleRecording()` / ⌘R refuse honestly (no-op) with a real disabled reason
  ("MONITOR OFF — START MONITORING TO RECORD") when no route is live — the "absent input" path, never a
  fabricated silent take.
- **Silent-but-live input** → the input callback writes zeros → a valid, honestly-silent WAV.
- **Route drops mid-record** (USB yank / `stopMonitor`) → `recorder.finishIfRecording()` finalizes the
  take with whatever was captured (valid WAV) before `monitor.stop()`.
- `HaloRingState.recording` finally has its **real producer**: `SessionRecorder.startedAt` is non-nil
  only while the drain thread runs, wired into `refreshRingState()`. `HaloRingRig` already rendered
  `.recording` (breathing) — it was unreachable purely for lack of this producer.

**Mechanics.** A dedicated `RecordingDrain` owns the sole consumer thread (drains the ring → `WAVFileWriter`,
a testable `AVAudioFile`-backed 24-bit LinearPCM `.wav` writer); `finish()` joins before the take is
ingested so the file is fully flushed. Takes are **files on disk** (no separate DB) under
`~/Library/Application Support/Halo/Recordings`; `TakesStore` scans that dir on init and reads REAL
metadata via `AVAudioFile` — an unreadable/partial/foreign file is dropped, never invented. Drag-to-pad
registers the take's file URL, reusing the existing `StageDropDelegate` prep flow verbatim (opens the
prep sheet preselected to the pad); `SEND + ASSIGN` stays device-gated (Phase 0B). The WAV writer, the
extracted `drainAvailable` drain body, and `TakesStore.readTake` are unit-tested headless
(`WAVFileWriterTests`, `CaptureTapTests`); real audio through hardware into the file end-to-end is
needs-device. `NSMicrophoneUsageDescription` belongs to the monitor route's device layer (the AUHAL
input), not the WAV writer — recording without a route never trips it.

### DD-019 · Connection lifecycle & resilience (P2-lifecycle)
**2026-07-14.** Brief §8 "safety & resilience" made concrete without inventing any hardware state.

**Honest lifecycle phase.** `HaloLifecyclePhase` (pure, `HaloLifecycle.swift`) derives one coarse
connection word — STARTING / WAIT / READY / LIVE / SLEEP / ERROR — from the same observed truths as the
halo ring (observer running, endpoint connected, live feed, monitor engaged, system asleep, real error
label). Priority: `error > suspended > live > ready > waiting > starting`. Surfaced as a new `STATE` chip
in `HaloStatusBar` (tinted green on LIVE, warning on ERROR, muted on SLEEP). The observable write is kept
off the per-note hot path — `refreshLifecycle()` runs on connection/monitor/sleep transitions and once on
the transition *into* a live feed, never per MIDI message.

**Held-key release (no stuck notes).** A single `releaseAllHeldKeys()` clears the frontmost-held display
stack (`heldMIDIKeys`) and the polyphonic scene travel/LEDs (`scene.releaseAllPads()`). It fires on every
event after which Halo can no longer guarantee it will observe the matching Note Off: **disconnect** (USB
removal), **sleep** (`NSWorkspace.willSleepNotification`), and **background** (`scenePhase == .background`
— App Nap can throttle MIDI delivery). Mere key-window focus loss (`.inactive`) does **not** release —
events keep flowing there, so the held state stays honest; and SwiftUI resets `isPressed` on pointer
cancel, so mechanical buttons never stick on their own.

**Sleep/wake.** `startLifecycleObservers()` watches `NSWorkspace` will-sleep / did-wake on `.main`.
Sleep finalizes any take into a valid WAV, stops the monitor units promptly, releases held keys and drops
a stale live display to WAIT → phase `.suspended`. Wake clears the flag and re-reads the lifecycle but
**never auto-restarts monitoring** (Brief §8: monitoring begins only after an explicit user action).

**Running-route reconcile.** `MonitorRouteReconciler.shouldStop` (pure) stops a *running* route when the
input or output UID it opened disappears from a fresh Core Audio snapshot (headphones unplugged, EP-40
yanked on the audio side, a device removed alongside a default-output change). Wired via a new
`AudioDeviceDiscovery.onChange` callback. Halo never silently re-points a live route at a different device
— it stops and lets the operator re-engage (Brief §8: do not silently switch devices).

**Audio permission.** Capturing the EP-40 USB-audio input trips the same TCC mic gate as a microphone, so
`AudioPermission` (+ injectable `AudioPermissionProbe` over `AVCaptureDevice`) gates an explicit
`startMonitor`: authorized opens the route; undetermined prompts once and opens only on grant; denied /
restricted is refused honestly via `MonitorController.fail(.micPermission)` (new `MonitorRouteError` case)
— no route opens, meters rest at silence, and `PlayRail` shows "MICROPHONE ACCESS DENIED — ENABLE IN
SYSTEM SETTINGS". A denied device is never shown as monitoring.

**Tested headless** (`HaloLifecycleTests`, 22 cases): phase priority + words, reconciler decisions,
permission-status mapping + `ensureAuthorized` (authorized / denied / undetermined-grant), model gating
(denied refused, authorized passes the gate), and held-key release + status transitions on
connect→live→disconnect, sleep→wake, and background — all via a `model.ingest(_:)` seam that mirrors the
live CoreMIDI delivery Task, so no MIDI/audio hardware is required. Real sleep/wake + real device-removal
timing through hardware remain needs-device.

### DD-020 · Local sample import & waveform cache (P3-import)
**2026-07-14.** Brief §8 sample processing, LOCAL only (no device). Four files under `Halo/Samples/`:

- **`CanonicalAudioBuffer`** (in `SampleProcessor.swift`) — the single internal representation: non-interleaved
  Float32 per channel at the source's own sample rate. Every edit/summary/export stage reads from this; the
  container/codec is decoded away exactly once. `monoMixdown()` is equal-average (Brief §8 forbids naïve
  channel discard).
- **`SampleProcessor`** — `enum` with `async` entry points (`decode`, `importSample`), so `AVAudioFile`'s
  blocking reads run off `@MainActor` on the cooperative pool (Brief §2). `AVAudioFile.processingFormat` gives
  deinterleaved Float32 for every accepted container — this is where MP3/M4A become linear PCM. File read is
  chunked (`readChunkFrames = 65_536`) to bound scratch memory on long files. Accept list = WAV/AIFF/CAF/MP3/M4A
  via `SampleSourceFormat(pathExtension:)`; an unsupported extension is rejected **before** touching disk.
- **`WaveformSummary`** — cached min/max buckets over the mono mixdown (Brief §8 "never render a long file
  sample-by-sample on the main thread"). Ceil-divide tiling guarantees the buckets cover the whole signal and
  the last short bucket is still summarised; `bucketCount = min(targetBuckets, frameCount)` so no bucket is ever
  empty/invented. Per-bucket extrema via vDSP (`vDSP_minv`/`vDSP_maxv`). Empty input → empty summary (honest,
  never a fabricated shape).
- **`SampleAsset`** — lightweight UI model (metadata + summary, NOT the heavy buffer) so an `@Observable`
  library stays cheap to diff. A local import is explicitly NOT a device slot; Brief §3 slot/pad separation is
  preserved in the doc contract.
- **`SampleMemoryEstimator`** — device byte figure `frames × channels × 2` (16-bit LinearPCM) + a **measured**
  container overhead, defaulting to 0 because the EP-40's real header size is device-gated (needs-device) and
  must not be invented.

Tested headless (`SampleProcessorTests`, 16 cases): decode preserves rate/channels/frames on a generated WAV
fixture, chunk-boundary long file loses no frames, unsupported extension rejected pre-disk, unreadable file
throws, import builds asset+summary, and the pure bucketing math (min/max per bucket, ceil-divide tiling,
one-bucket-per-frame cap, empty input, peak from trough/crest) plus mono mixdown and the memory formula. Real
MP3/M4A round-trips through hardware codecs and on-device byte acceptance remain needs-device.

### DD-021 · Non-destructive prep, export treatments & size estimate (P3-prep)
**2026-07-14.** Brief §8 sample processing, LOCAL only. Three additions under `Halo/Samples/`:

- **`SamplePrep`** — a `Sendable`/`Equatable` value type describing an edit (trim window, equal-power fades,
  gain, opt-in normalise, channel mode); it never mutates the source. `apply(to:)` reads a
  `CanonicalAudioBuffer` and returns a NEW buffer in the float domain at the source rate. Documented,
  deterministic order: **trim → channels → gain → fades → normalise**. Normalise runs LAST so the output peak
  lands exactly on target regardless of prior stages. All maths is vDSP over real decoded samples.
  - **Equal-power fades**: fade-in `g[i]=sin(½π·i/(F−1))` (g[0]=0…g[F−1]=1), fade-out `cos` mirror. `F<2` is a
    safe no-op; fade lengths clamp to the buffer so overlap never overruns.
  - **Channel conversion** (Brief §8 "equal-power or documented, never a naïve discard"): mono downmix is the
    equal-power sum `Σ ch / √N` (RMS-preserving for uncorrelated channels; a correlated full-scale pair can
    exceed unity and is caught by opt-in normalise / the 16-bit export clamp — chosen over ÷N so downmix RMS is
    honest). Mono→stereo copies the channel to both L/R (documented copy, not attenuated). Note: this differs
    from `CanonicalAudioBuffer.monoMixdown` (equal-**average** ÷N), which is only a display-summary mixdown, not
    an export path — the two are intentionally distinct and both documented.
  - **Normalise** defaults to −1 dBFS, opt-in; a zero-peak (silent) buffer is never scaled up (no invented gain).
- **`SampleTreatment`** + **`SampleTreatmentEncoder`** — the treatment enum is purely the OUTPUT sample-rate
  policy (all treatments 16-bit LinearPCM, the device native depth): `ORIGINAL` preserves the source rate when
  ≤46,875 Hz and clamps (never upsamples) above it; `HIGH`=46,875, `BALANCED`=32,000, `LO-FI`=22,050/11,025.
  Kept separate from `SamplePrep` so prep shapes audio at source rate, then the treatment resamples+quantises.
  The offline encoder is `nonisolated async` (runs off `@MainActor`, Brief §2), resamples via `AVAudioConverter`
  at `AVAudioQuality.max` so LO-FI downsamples are anti-aliased (honest quality, no hand-rolled filter), trims/pads
  the converter output to the exact arithmetic frame count so encode size matches the estimate deterministically,
  then quantises to interleaved Int16 (clamp [−1,1], ×32767, round-to-nearest, no dither — documented).
  `encodeToWAV` writes a real re-openable 16-bit WAV and returns the **measured** container overhead
  (`fileSize − payloadBytes`), never a guessed header constant.
- **`SampleMemoryEstimator.estimate(…)`** — prep+treatment-aware, pure arithmetic on measured counts (decodes
  nothing): `SampleSizeEstimate{ frames, channels, sampleRate, payloadBytes, containerOverhead }` where frames =
  round(preppedFrames · targetRate/sourceRate), payload = frames×channels×2. Satisfies the Phase 3 exit criterion
  "same source prepared with different treatments reports predictable sizes".

Tested headless (`SamplePrepTests`, 22 cases): trim window + source-immutability, clamp/empty selection, identity
passthrough, gain, equal-power fade endpoints/curve/clamp, normalise to −1 dBFS + silence-stays-silent, equal-power
mono downmix (uncorrelated power preserved, not a discard) + mono→stereo copy, treatment rate resolution
(preserve/clamp/fixed), predictable+monotonic sizes across all five treatments, trim+mono+overhead estimate,
Int16 quantise clamp/interleave, and the real encoder (no-resample round-trip through a reopened WAV, 44.1k→LO-FI
downsample frame count, honest empty encode, measured WAV overhead). On-device slot acceptance of any produced
file remains **needs-device** (Phase 0B) — the encoders are verified LOCALLY only.

---

### DD-022 · Edit mode UI + local library + audition (P3-editui)
**2026-07-14.** Brief §7 Edit. The mode fuses **two provenance classes** and keeps them structurally distinct —
that separation is the whole honesty story (Brief §1/§4):

- **LOCAL sample (REAL)** — an imported file decoded to a `CanonicalAudioBuffer`. Its waveform, trim/fade/gain/
  normalise/channel/rate treatment, byte estimate and audition are all real, computed by the existing
  `SamplePrep`/`SampleTreatment`/`WaveformSummary`/`SampleMemoryEstimator` (DD-020/DD-021). No mock.
- **PAD TARGET (MOCK)** — which device pad this edit is *destined for*. Drives the camera ease and shows the
  current mock assignment from `MockDeviceLibrary.standard` (the SAME static value `LoadSession` reads — no
  divergence). Tagged `MOCK`; `SEND CHANGES` is disabled (device transfer = Phase 0B, needsDevice).

Consequence, stated honestly in the UI: **a device sample has no waveform** — halo has never downloaded its
audio — so a pad holding a mock sound shows a `WAVEFORM UNAVAILABLE — DEVICE SAMPLE (NEEDS DEVICE)` caption, and
the real waveform editor appears only for a LOCAL sample the user selected. Pad selection sets destination +
camera; local-sample selection sets the edit subject.

Pieces added under `Halo/Features/Edit/`:
- **`EditSession`** (`@MainActor @Observable`, UI-only, DD-013 honesty class): local `library` (newest first),
  a **cache-of-1** heavy-buffer store (only the selected asset's `CanonicalAudioBuffer` is resident; others
  evict on selection change and re-decode lazily via `ensureBuffer` from `sourceURL`), per-asset **non-destructive**
  `preps`/`treatments` (mutating a recipe never touches the asset or buffer), pad target, `isRenaming` gate, and
  a `selectedEstimate` that wires the real `SampleMemoryEstimator` through. `auditionBuffer()` applies the prep
  and resamples to the treatment rate **off `@MainActor`** (so a LO-FI preset actually sounds lo-fi) and hands
  back Sendable `[[Float]]`.
- **`AuditionPlayer`** (`@MainActor @Observable`): LOCAL playback of the prepared buffer to the **system default
  output** via `AVAudioEngine` + `AVAudioPlayerNode` — ordinary file preview, **deliberately separate** from the
  EP-40 monitor AUHAL route (DD-017) and claiming nothing about the device. No custom render callback (a prebuilt
  buffer is handed to `scheduleBuffer`), so the RT-callback rules don't apply. Playhead progress is derived from
  the node's **real render clock** (`playerTime(forNodeTime:)`) — never fake motion; hidden when idle. Stopped on
  the recorder's safety edges (sleep, background, USB disconnect); Escape does **not** stop it (Brief §7).
- **`WaveformStrip`** — a `Canvas` min/max envelope with mechanical trim handles (the `HaloFader` cap language),
  triangular fade wedges, dimmed out-of-window buckets, and the audition playhead. Geometry (`frameToX`/`xToFrame`/
  `clampTrim`) is pure and unit-tested.
- **`EditRail`** rewrite — vertical `HaloPanel` stack (LIBRARY / DESTINATION / WAVEFORM / TRIM·FADE / GAIN·LEVEL /
  FORMAT / MEMORY IMPACT / SEND CHANGES) over a `MOCK DEVICE CONTEXT · LOCAL EDIT IS REAL` strip. Import via
  `NSOpenPanel`; the global Finder drop is now **mode-aware** (EDIT imports locally, otherwise LOAD prep sheet).
  All mechanical controls/tokens — fades and gain are `HaloFader`s (no stock `Slider`); rename is the single
  text field and drives `isRenaming`.

Camera: `EP40SceneController.focusCamera(onPadGridIndex:)` (+ generalised `lookAtTransform(from:to:)`) eases the
hero camera gently toward a pad (~40% look-at bias, ~6% radius pull-in, small side slide) so the chassis stays
framed — halo presentation (DD-013), never a hardware claim, never releases pads. Space-to-audition is gated in
`HaloRootView` via the pure `EditSession.shouldAudition(mode:isRenaming:hasSelection:)`.

Honest limitation (needsDevice): device samples have **no** waveform (never downloaded); `SEND CHANGES` is a
Phase 0B device write and is disabled with a plain-language intent line (`WOULD CREATE SLOT … / WOULD REPLACE
SLOT …`). Tested headless (`EditSessionTests`, 15 cases): import/skip/newest-first, cache-of-1 evict+re-decode,
per-asset non-destructive prep + source-immutability, reset, wired memory estimate, rename trim/blank-guard, mock
pad-target consistency, the Space gate predicate, `WaveformGeometry` round-trip/clamp, and pure `makeBuffer`.
`AuditionPlayer` engine playback is **needs-device** (real output) and left untested, exactly as the AUHAL route is.

### DD-023 · Storage authority, backup snapshots & operation journal (P4-storage)
**2026-07-14.** Brief §2/§7/§8 local data. New `Halo/Storage/`:
- **`HaloFileStore`** is the single filesystem authority — the five canonical folders
  (`Library`, `Backups`, `Recordings`, `Manifests`, `Diagnostics`) under
  `~/Library/Application Support/Halo/` are named in exactly one place and created
  on demand (`ensureAll()` at model init). `Take.swift`'s hardcoded recordings path
  now delegates here (no behaviour change; recorder tests still green). `HaloJSON`
  provides one pretty-printed, sorted-key, ISO-8601 coder pair so every manifest on
  disk is human-readable and diffable — the Brief §2 rule that samples are *never
  recoverable only through halo*.
- **`BackupManifest`** — versioned (`schemaVersion`) `Codable` snapshot descriptor:
  reasons `beforeWrite`/`manual`/`daily`, entries carrying device slot, pad
  reference (nil ⇒ **REFERENCES UNKNOWN**, never assumed absent), recovery filename,
  byte count, SHA-256, and a `provenance` enum whose only case is `.device`.
  **`BackupStore`** (@MainActor @Observable) writes each snapshot as a self-contained
  `Backups/<date-reason-id>/` folder (`manifest.json` beside its recovery copies) and
  rescans on init — persistence IS the folder tree, unreadable folders dropped, never
  faked (parity with `TakesStore`). Injectable `backupsDir` for tests.
- **`OperationJournal`** (@MainActor @Observable) — append-only recoverable-writes log
  at `Manifests/operation-journal.json`. An op is journalled `.pending` before the
  write and flipped `.committed` only after read-back verify; a crash leaves the
  pending entry + its recovery path on disk so the user recovers instead of losing a
  sample. Versioned document wrapper.

**needsDevice:** creating a snapshot PAYLOAD (reading samples off the EP-40) and
restoring one (writing them back) are the proprietary protocol (Phase 0B). So the
BACKUPS rail's `NEW SNAPSHOT` is disabled with the real reason, and restore goes
through the `BackupRestoring` seam whose honest default (`DeviceUnavailableRestorer`)
reports `.deviceRequired` and changes nothing. The list rests at `NO SNAPSHOTS` until
a verified device layer exists. Restore is gated behind a plain-language
`confirmationDialog` (Brief §7); there is **no** delete control anywhere in the rail —
old backups are never silently deleted. Tested headless (`StorageManifestTests`, 12
cases): manifest round-trip + versioning + human-readability, reason labels, SHA-256
stability, store write→reload + newest-first + drop-unreadable, restorer honesty,
journal begin/commit/rollback/resolve + crash-reload recovery, journal-document
versioning, and the five-folder layout.

### DD-024 — Diagnostics drawer + two-axis capability model (P4-diagnostics)

A global, read-only **Diagnostics drawer** (⌘D, or click the leading status-chip
cluster) surfaces three honest things: the app's **live status** now, the seeded
**capability matrix**, and an **empty-by-construction protocol-trace scaffold**. Plus
an **EXPORT LOG** action writing a human-readable plaintext snapshot to the canonical
`Diagnostics/` folder and revealing it in Finder (Brief §7/§8; a local, non-destructive
write into halo's own transparent folder — no safety gate).

- **Two orthogonal axes = the honesty.** `CapabilityStatus` (OBSERVED / DOCUMENTED /
  NOT-OBSERVED / UNKNOWN) is device truth about the PHYSICAL EP-40; `CapabilityReadiness`
  (BUILT / PARTIAL / ABSENT) is how far halo's OWN Mac-side mechanism is built. A
  mechanism can be BUILT + unit-tested on this Mac while the device fact is UNKNOWN.
- **Green (`riddimGreen`) is reserved for observed device truth.** The EP-40 has never
  connected in a halo session, so **no catalogue row is `.observed`** and nothing in
  the matrix is green. A BUILT readiness chip is always **muted** (inkSoft outline,
  no fill) — a working mechanism is not a device confirmation (Brief §1/§3/§4). The
  load-bearing guard is `DeviceCapabilitiesTests.testNoCapabilityIsObserved`, which may
  only change alongside a real with-device session that updates BOTH the doc and the
  catalogue together.
- **HOST audio vs DEVICE, verbally separated.** The `STATUS · HOST AUDIO` panel carries
  the subtitle *"this Mac, not the EP-40"* so "this Mac has an output device" is never
  misread as "the EP-40 is connected" (the doc's standing warning).
- **Feature gate.** `DeviceCapabilities.isConfirmed(_:)` is the honest gate the brief
  asks for — a device feature is enabled only when its backing capability is observed
  (today: none). Existing device features (Edit `SEND CHANGES`, the transfer ring)
  already disable themselves honestly; that logic was **not** refactored.
- **Protocol trace = one seam, unused.** `ProtocolTrace.record(_:)` is the sole append
  path; a future `EP40SysExTransport` (Phase 0B) is its only caller. Until then the
  trace is empty and the drawer says so — halo never fabricates a frame.
- **DD-013 preserved.** The drawer registers as a transient (Escape closes it via the
  existing stack) but holds **no audio handle** — Escape can never stop audio. The
  `isDiagnosticsOpen` flag touches no audio/MIDI/display path. `DiagnosticsReport` is a
  pure `String` builder taking plain snapshot values (not the `@MainActor` model), so
  the export is unit-tested headless. Tested (`DeviceCapabilitiesTests`, 8 cases): no
  row observed, feature gate shut for every id (+ unknown id), only-observed-unlocks,
  unique ids, every domain non-empty, report renders each domain header + `(none` for
  the empty trace with **no standalone OBSERVED token**, live-block values present, and
  the trace scaffold's empty→record→clear seam.

---

_Open decisions awaiting evidence:_
- Exact physical control inventory (confirm/adjust the contract) — research + owner photos.
- Palette A vs B — owner, at Phase 1 gate.
- Audio bridge topology — decided (P2, DD-017): dual AUHAL + preallocated SPSC ring (not an aggregate
  device), so the user's Mac audio preferences stay intact. Live latency/stability still needs-device.
- EP-40 SysEx dialect — Phase 0B only.
