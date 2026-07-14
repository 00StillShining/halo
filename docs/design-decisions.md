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

_Open decisions awaiting evidence:_
- Exact physical control inventory (confirm/adjust the contract) — research + owner photos.
- Palette A vs B — owner, at Phase 1 gate.
- Audio bridge topology — decided (P2, DD-017): dual AUHAL + preallocated SPSC ring (not an aggregate
  device), so the user's Mac audio preferences stay intact. Live latency/stability still needs-device.
- EP-40 SysEx dialect — Phase 0B only.
