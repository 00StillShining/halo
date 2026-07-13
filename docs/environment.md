# halo — environment

Verified per Brief §2 ("Verify, then pin"). This is the recorded machine truth;
the build targets **only this machine**.

**Verified:** 2026-07-13

## Machine

| Item | Value |
|---|---|
| Model | MacBook Air (`Mac15,13`), Model Number MXD13B/A |
| Chip | Apple M3 — 8 cores (4 performance + 4 efficiency) |
| Memory | 16 GB |
| macOS | 26.5 (build 25F71) |

## Toolchain

| Item | Value |
|---|---|
| Xcode | 26.4.1 (build 17E202) |
| Swift | 6.3.1 (swiftlang-6.3.1.1.2, clang-2100.0.123.102) |
| Default target triple | arm64-apple-macosx26.0 |
| `xcode-select -p` | /Applications/Xcode.app/Contents/Developer |
| Blender | present at /Applications/Blender.app (USDZ authoring path) |

## Pinned build settings (consequences of the above)

- **Deployment target:** `MACOSX_DEPLOYMENT_TARGET = 26.0` (installed macOS major).
- **Swift language mode:** `SWIFT_VERSION = 6.0`.
- **Architectures:** Apple silicon only (`arm64`); no Intel/universal build.
- **Signing:** ad-hoc (`CODE_SIGN_IDENTITY = "-"`, manual) for private local use;
  no team, no notarisation, no App Store. Hardened runtime off during development.
- **Project format:** Xcode `objectVersion = 77`, synchronized file-system groups —
  files added on disk under `Halo/` are picked up without editing `project.pbxproj`.

## EP-40 device — status at verification time

- **Not connected** at project start (checked via `system_profiler SPUSBDataType`
  and `SPAudioDataType` — no Teenage Engineering device present).
- Consequence: **Phase 0A (hardware truth)** and **Phase 0B (protocol)** require a
  "with-device" session and are deferred. Visual work (Phase 1) proceeds now, as the
  brief's sequencing explicitly allows.
- Firmware requirement (from brief, to confirm on the physical unit): **OS ≥ 2.5**,
  develop/verify against **2.5.1**. halo never updates firmware; it links to TE's
  official updater if an older OS is reported.

## Verification commands (for re-running)

```bash
sw_vers
xcodebuild -version
swift --version
system_profiler SPHardwareDataType | head -14
system_profiler SPUSBDataType | grep -iE "teenage|ep-?40"   # device presence
```
