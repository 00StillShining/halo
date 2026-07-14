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
| Pads **transmit** Note On/Off (all 12 × groups A–D) | UNKNOWN — mapping DOCUMENTED, direction unverified | Phase 0A | — |
| Velocity present on pad notes | UNKNOWN | Phase 0A | — |
| Per-note velocity → LED intensity mapping (DD-012) | Consumed AS OBSERVED (0–127 → 0–1, quadratic to opacity). No velocity *curve* is claimed as hardware behaviour — if the device sends velocity at all, halo simply reflects the number it received. | DD-012 | — |
| Note ranges 36–47=A … 72–83=D | DOCUMENTED (verbatim TE chart, both TX+RX columns) | research/02 | — |
| Internal pad order within a group (dot/0–9/ENTER vs other) | **UNKNOWN — assumption only** | not in TE chart (research/02); app code currently assumes `. 0 ENTER 1–9` in EP40EntityNames — verify on device (Phase 0A) | — |
| Play / Stop / Record **transmit** transport | UNKNOWN | Phase 0A | — |
| Hardware **record state** observable (for `button_record` lighting) | **NOT observable via documented USB MIDI** — no Record realtime message; `EP40DisplayState` has no record field. `button_record` stays unlit by design (DD-010). needsDevice: revisit in Phase 0B. | research/02, DD-010 | — |
| MIDI clock SEND (24 PPQN, stable) | UNKNOWN — needed for 5b | Phase 0A | — |
| Device transmits CC 12/13 when X/Y knobs move | UNKNOWN — likely NOT | Phase 0A | — |
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
