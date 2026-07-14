# halo — EP-40 device capabilities

Evidence log per Brief §3 and §11.5. Every capability records **status**,
**evidence**, **firmware**, and **test date**. Features stay disabled in code
(`DeviceCapabilities`) until their row is `OBSERVED`.

Status legend:
- `OBSERVED` — confirmed on the physical EP-40 in a halo session (with trace).
- `DOCUMENTED` — stated in official TE docs but not yet verified on this unit.
- `NOT-OBSERVED` — tested, did not occur.
- `UNKNOWN` — not yet tested.

**Firmware under test:** _(none yet — device not connected at project start)_
**Last device session:** _(none — Phase 0A pending a with-device session)_

---

## Audio (Core Audio)

| Capability | Status | Evidence | Date |
|---|---|---|---|
| EP-40 exposed as USB audio **input** (stereo) | UNKNOWN | Phase 0A | — |
| EP-40 exposed as USB audio **output** | UNKNOWN | Phase 0A | — |
| Input channel count / supported rates / buffer ranges | **MECHANISM IMPLEMENTED (P2, DD-016)** — `CoreAudioEnumerator` reads in/out channel counts, current + supported nominal rates and buffer-frame ranges for every device; verified against this Mac's real devices. The EP-40's *own* reported values still need the device. | DD-016 | 2026-07-14 |
| Stable device UID captured | **MECHANISM IMPLEMENTED (P2, DD-016)** — `kAudioDevicePropertyDeviceUID` captured and persisted (never the display name); verified against this Mac's devices. The EP-40's own UID still needs the device. | DD-016 | 2026-07-14 |
| Core Audio device-list / default-device / sample-rate change observation | **IMPLEMENTED (P2, DD-016)** — `AudioDeviceDiscovery` installs HAL property listeners and republishes a whole snapshot; read-only, never writes the system default. | DD-016 | 2026-07-14 |
| Production monitor route (dual AUHAL + ring + limiter) | **BUILT (P2, DD-017)** — input-only AUHAL + separate output AUHAL bridged through `AudioRingBuffer`, chain = gain → dub FX rack (P5a) → −1 dBFS `SafetyLimiter`, metered at 50 Hz; starts only on explicit action at −12 dB, never changes the system default. DSP core unit-tested; the LIVE route through the EP-40 is still needs-device. | DD-017 | 2026-07-14 |
| Dub FX rack (TAPE ECHO / SPRING / SWEEP / LOW END) | **BUILT (P5a, DD-028)** — custom RT-safe DSP at the monitor insert (post-gain/pre-limiter), bit-transparent bypass (NULL TEST), atomic param bridge, tempo-sync (MIDI clock) or tap-tempo echo, PRINT FX post-rack capture. Bypass/self-osc/no-click/tempo pinned by `DubRackTests` + `RackModelTests`. Live-clock sync feel, battery CPU and the 30-min rack-engaged stability soak are needs-device. | DD-028 | 2026-07-14 |
| EP-40 audio input resolved by name (`ep40AudioInput`) | ASSUMPTION — matches an input device whose name contains "EP-40"/"EP40". Documented inference; real confirmation needs the device. | DD-017 | 2026-07-14 |
| Cross-clock drift correction | **CONTROLLER BUILT, NOT YET WIRED (P2, DD-017)** — pure `DriftController` (±0.2% ratio from ring fill) + `DriftCompensatingConverter` are unit-tested, but the live render path does not apply them yet; wiring + tuning the varispeed stage needs two real clocks to observe (Phase 0A soak). Worst case today: bounded ring drop/silence-fill after long sessions, never a crash. | DD-017 | 2026-07-14 |
| Session recorder — raw pre-monitor capture to WAV | **BUILT (P2, DD-018)** — `CaptureTap` (RT-safe raw-input tap) → `RecordingDrain` thread → `WAVFileWriter` (24-bit LinearPCM `.wav`) in `~/Library/Application Support/Halo/Recordings`; gated on an active monitor route, ⌘R toggle, produces the honest `HaloRingState.recording`. Writer, drain body and `readTake` metadata are unit-tested headless. | DD-018 | 2026-07-14 |
| Real audio through hardware into the recorder (bytes verified end-to-end) | needsDevice — capturing an actual EP-40 signal to a WAV and confirming the file content requires the physical device + a live monitor route. The WAV writer, drain and metadata paths are unit-tested without hardware; the raw tap only fills while the input AUHAL runs (DD-018). | Phase 0A | — |
| End-to-end monitor latency @ Low/Balanced/Safe | UNKNOWN — profiles exposed (128/256/512, `MonitorProfile`); measurement needs-device. | Phase 0A | — |
| 30-min uninterrupted monitor stability | UNKNOWN | Phase 0A | — |
| 10× unplug/reconnect clean recovery | UNKNOWN | Phase 0A | — |

## MIDI (Core MIDI)

| Capability | Status | Evidence | Date |
|---|---|---|---|
| Identity request/reply | UNKNOWN | Phase 0A | — |
| Pads **transmit** Note On/Off (all 12 × groups A–D) | **OBSERVED** — one-shot pads TX Note On/Off; the app depresses the correct on-screen pad. (Loop-play-mode pads: see below.) | Phase 0A session 1 (owner) | 2026-07-14 |
| Velocity present on pad notes | **OFF BY DEFAULT** — pad velocity is a device SYSTEM setting (`300 pad›vel›off` default). Enable `301` (hi / soft touch) or `302` (lo). TE chart shows Note-On velocity 0–127 TX. Soft-vs-hard produced no difference with it off (correct/honest); re-test with `301`. | Phase 0A session 1 + owner guide §14 | 2026-07-14 |
| Per-note velocity → LED intensity mapping (DD-012) | Consumed AS OBSERVED (0–127 → 0–1, quadratic to opacity). No velocity *curve* is claimed as hardware behaviour — if the device sends velocity at all, halo simply reflects the number it received. | DD-012 | — |
| Note ranges 36–47=A … 72–83=D | DOCUMENTED (verbatim TE chart, both TX+RX columns) | research/02 | — |
| Internal pad order within a group (dot/0–9/ENTER) | **OBSERVED — CONFIRMED CORRECT** ✅ owner pressed pads on the real EP-40: `dot=36, 0=37, ENTER=38, 1=39, 2=40, 3=41, 5=43, 9=47` — EXACTLY the app's assumed `. 0 ENTER 1–9` (`EP40EntityNames.padGridOrder` / `midiOffsetToGrid`). The build-long assumption is verified; no code change needed. | Phase 0A session 1 (owner) | 2026-07-14 |
| Play / Stop / Record **transmit** transport | **GATED ON DEVICE SETTING** — transport TX rides MIDI clock, which is `100 mid›clk›off` by default. Set `102 mid›clk›out`. Also per-pad/per-project MIDI-channel config (`110` default = send ch1; `127` = only if channel assigned) explains why transport reacted then died on a project change. Re-test with `102`. | Phase 0A session 1 + owner guide §14 | 2026-07-14 |
| Hardware **record state** observable (for `button_record` lighting) | **NOT observable via documented USB MIDI** — no Record realtime message; `EP40DisplayState` has no record field. `button_record` stays unlit by design (DD-010). needsDevice: revisit in Phase 0B. | research/02, DD-010 | — |
| MIDI clock SEND (24 PPQN, stable) | **AVAILABLE, OFF BY DEFAULT** — `100 mid›clk›off` default; set `102 mid›clk›out` (send only) to emit clock + transport. Stability/24-PPQN trackability re-tested with `102` on. | Phase 0A session 1 + owner guide §14 | 2026-07-14 |
| GRAB rolling raw history (60 s @ 48 k, fixed 32 MiB ring) | **Mac-side FACT** (DD-029) — an always-on `RollingCaptureBuffer` captures the raw pre-FX monitor input while a route runs; grab freezes the last 4/8/16 bars (clocked) or 5/10/30 s (no clock, EST bpm), zero-cross-trimmed. Pure math unit-tested. | Brief §5b, DD-029 | 2026-07-14 |
| GRAB bar-accurate loop *feel* through hardware | needsDevice — bar boundaries are anchored from the delivered downbeat tick, subject to MIDI + callback latency; the seamless-loop feel is verified on-device (Phase 0A clock). | Brief §5b, DD-029 | — |
| GRAB print-through of PRINT-FX (post-rack) loop | needsDevice-adjacent — deferred by SPSC single-producer safety (DD-029), not device-gated. The always-on ring stays RAW; a post-FX grab would need a second ring/producer. | DD-029 | 2026-07-14 |
| Device transmits CC 12/13 when X/Y knobs move | **OBSERVED — DOES NOT TRANSMIT** ✅ owner turned X and Y, no app reaction. The physical X/Y knobs are pad-parameter editors (play mode / root note in sound edit), not MIDI CC senders. Matches the brief's expectation; the app correctly never rotated them. | Phase 0A session 1 (owner) | 2026-07-14 |
| Loop-play-mode pads transmit MIDI when triggered | **NOT-OBSERVED (needs re-test)** — a loop-sample pad produced no app reaction. Loops "run in the background" (owner guide §10.5) and may not emit a standard Note On, or the pad/project MIDI channel differed. Re-test: watch the on-screen display number when pressing the loop pad — if it doesn't change, the device emits no note for loop pads (record as device behaviour); if it changes but no pad lights, it's an app bug. | Phase 0A session 1 (owner) | 2026-07-14 |
| CC inputs recognised (1,12,13,64) | DOCUMENTED | Brief §3 | — |
| Bank Select + PC selects sounds 1–999 (exact scheme) | DOCUMENTED, scheme unverified | Phase 0A read-only | — |

## Storage / proprietary protocol (SysEx)

| Capability | Status | Evidence | Date |
|---|---|---|---|
| 999 sample slots; ~122 MB usable | DOCUMENTED — prefer device-reported | Brief §3 | — |
| Read-only sample listing via halo impl | UNKNOWN | Phase 0B | — |
| Download one sample (byte/metadata compare) | UNKNOWN | Phase 0B | — |
| Guarded upload round-trip (verify by read-back) | UNKNOWN | Phase 0B | — |
| Pad-assignment read | UNKNOWN | Phase 0B | — |
| Pad-assignment write | UNKNOWN | Phase 0B | — |
| SysEx framing / device ID / checksum / ack | UNKNOWN — community EP-133/1320 notes are orientation only | Phase 0B | — |
| halo-ring `.transfer` state — real progress | needsDevice — requires the proprietary transfer protocol (Phase 0B). UI complete (`HaloRingRig` renders the clockwise progress ring + `HALO` chip `TX %`), producer absent. | Phase 0B | 2026-07-13 |
| Edit a/replace an existing device sample | needsDevice — requires sample **download** (halo never has a device sample's audio, so it cannot draw its waveform or edit it) plus verified upload/assign (Phase 0B). Edit mode `SEND CHANGES` is shown but disabled; the byte estimate's container overhead stays measured-as-0 until the device header is known. | Phase 0B | 2026-07-14 |
| CHOP onset detection + slicing (local) | **BUILT (P5c, DD-030)** — spectral-flux onset detection (`OnsetDetector`, vDSP real FFT + adaptive peak-pick) over the real decoded mono mixdown; editable `SliceSet`, per-slice micro-fades, LOCAL slice audition. Silent/short input yields no slices. Deterministic, unit-tested (`OnsetDetectorTests`). | DD-030 | 2026-07-14 |
| CHOP → pads serialised upload+assign transaction | needsDevice — the `SendToPadsPlan` preview (pads/slots/bytes/overflow) is REAL local arithmetic over MOCK device context, but the actual write is the proprietary protocol (Phase 0B). `ChopSending` default (`DeviceUnavailableChopSender`) returns `.needsDevice`; `SEND TO PADS` is shown but disabled and never Return-bound. No protocol bytes invented. | Phase 0B | 2026-07-14 |

## Firmware / general

| Capability | Status | Evidence | Date |
|---|---|---|---|
| Reports OS ≥ 2.5 (verify 2.5.1) | UNKNOWN | Phase 0A | — |
| Nine user projects | DOCUMENTED | Brief §3 | — |
| Mode 1 (OMNI ON, POLY) | DOCUMENTED | Brief §3 | — |

---

## Diagnostics (DD-024)

The in-app **Diagnostics drawer** (⌘D) renders a **capability matrix** seeded from
`DeviceCapabilities.catalogue`, which **mirrors this file** — this doc is canonical;
the code is its mirror. Each row carries two orthogonal axes: `CapabilityStatus`
(OBSERVED / DOCUMENTED / NOT-OBSERVED / UNKNOWN — device truth about the physical
EP-40) and `CapabilityReadiness` (BUILT / PARTIAL / ABSENT — how far halo's own
Mac-side mechanism is built). A mechanism can be BUILT + unit-tested on this Mac
while the device fact is still UNKNOWN; readiness is never shown green.

**Honesty test:** `DeviceCapabilitiesTests.testNoCapabilityIsObserved` pins that **no
row is `OBSERVED`** — the EP-40 has never connected in a halo session. A row may only
flip to `OBSERVED` when a real with-device session updates **both** this file and the
catalogue together; doing so in code alone is a Brief §1/§4 honesty failure. The
feature gate `DeviceCapabilities.isConfirmed(_:)` unlocks a device-touching feature
only for an observed row (today: none).

_Note: sample-library slots and project pad assignments are **separate concepts**
and must never be conflated in code or labels (Brief §3)._

---

## What remains — owner checklist (post-P5c final sweep, DD-031)

The hardware-independent build is complete: all six modes, Capture/Edit/Play/Load,
the monitor route + dub FX rack + GRAB + CHOP, storage/backups/journal, diagnostics,
and the full non-happy-path state vocabulary are BUILT and unit-tested (286 tests).
What is left falls into three buckets.

### A. Owner sign-off — **no device required**
- **Palette pick — A (cool) vs B (warm).** Both are kept fully working; the loop never
  deletes a palette. Owner chooses at the Phase 1 gate. _(Open decision, DD-013/DD-015.)_
- **Phase 1 visual gate approval.** Gate screenshots are captured via DEBUG-only env hooks
  (DD-015). The owner needs to eyeball and sign off the Phase 1 look before it is "locked."
- **§10 Instruments profiling.** The brief gates "Phase 2 and 5a complete" on an Instruments
  profiling pass (audio-thread allocations, CPU, energy). This is a **manual owner-side step
  the loop cannot perform** — the DSP is RT-safe by construction and unit-tested, but the
  profiler run is outstanding verification, not a code gap.
- **Optional §5a XY-pad mapping** (X→SWEEP freq, Y→ECHO feedback) — not built (DD-031). Brief
  marks it optional; request it if wanted.

### B. Needs-device — **Phase 0A (with device, read-only / non-destructive)**
Mechanisms are BUILT + unit-tested on this Mac; these rows confirm the EP-40's own truth:
- EP-40 exposed as USB audio **input/output**; its own channel counts, supported rates,
  buffer ranges and stable UID (rows above: audio §, DD-016).
- **Live monitor route through the EP-40** (DD-017): end-to-end latency @ Low/Balanced/Safe,
  30-min stability, 10× unplug/reconnect recovery, and **wiring + tuning the drift corrector**
  (`DriftController`/`DriftCompensatingConverter` are built + tested but not yet in the live
  render path — needs two real clocks to observe).
- **Real EP-40 audio into the recorder**, byte-verified end-to-end (DD-018).
- **MIDI truth** (MIDI §): identity reply; pads transmit Note On/Off (all 12 × A–D); velocity
  present; **internal pad order within a group** (currently an assumption — DD, EP40EntityNames);
  transport transmit; **MIDI clock send 24 PPQN** (needed for GRAB bar-lock + rack tempo-sync);
  CC 12/13 on X/Y knob move; Bank/PC sound-select scheme.
- **Feel checks** that only a real signal can confirm: GRAB bar-accurate loop feel (DD-029),
  rack live-clock sync feel + battery CPU + 30-min rack-engaged soak (DD-028).

### C. Needs-device — **Phase 0B (proprietary SysEx, includes destructive writes) — OUT OF SCOPE for the loop**
No protocol bytes are invented anywhere; every device write is a disabled seam returning
`.needsDevice`:
- SysEx framing / device ID / checksum / ack (the dialect itself).
- Read-only sample listing; download one sample (byte/metadata compare); guarded upload
  round-trip (verify by read-back); pad-assignment read + write.
- `halo-ring .transfer` real progress producer (UI complete, producer absent).
- Edit-mode **SEND CHANGES** (needs sample download + verified upload/assign).
- CHOP **SEND TO PADS** serialised upload+assign transaction (`ChopSending` seam, DD-030).
- Hardware record-state observability — revisit in Phase 0B (DD-010).

**Honesty invariant:** `DeviceCapabilitiesTests.testNoCapabilityIsObserved` pins that **no
row is `OBSERVED`** today. A row may flip to `OBSERVED` only when a real with-device session
updates **both** this file and `DeviceCapabilities.catalogue` together.
