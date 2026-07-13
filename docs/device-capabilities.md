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
| End-to-end monitor latency @ Low/Balanced/Safe | UNKNOWN | Phase 0A | — |
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

## Firmware / general

| Capability | Status | Evidence | Date |
|---|---|---|---|
| Reports OS ≥ 2.5 (verify 2.5.1) | UNKNOWN | Phase 0A | — |
| Nine user projects | DOCUMENTED | Brief §3 | — |
| Mode 1 (OMNI ON, POLY) | DOCUMENTED | Brief §3 | — |

---

_Note: sample-library slots and project pad assignments are **separate concepts**
and must never be conflated in code or labels (Brief §3)._
