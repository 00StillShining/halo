import AVFoundation
import Foundation

/// Microphone-authorisation state for the monitor/record input (Brief §8: handle
/// "audio permission states"). The EP-40 enumerates as a USB audio INPUT, so
/// capturing it goes through the same TCC gate as any microphone. Halo must reflect
/// this honestly: a denied device would feed silence, and a moving meter / "LIVE"
/// claim over that silence would be a faked hardware state (Brief §1/§4).
enum AudioPermissionStatus: Equatable, Sendable {
    case notDetermined   // never asked — the OS will prompt on first capture
    case authorized      // capture allowed
    case denied          // user declined — must be enabled in System Settings
    case restricted      // policy-restricted (MDM / parental) — not user-fixable

    /// Only `.authorized` allows Halo to open a capturing route honestly.
    var allowsCapture: Bool { self == .authorized }

    /// Short status word for the strip.
    var word: String {
        switch self {
        case .notDetermined: return "ASK"
        case .authorized:    return "OK"
        case .denied:        return "DENIED"
        case .restricted:    return "BLOCKED"
        }
    }

    static func from(_ status: AVAuthorizationStatus) -> AudioPermissionStatus {
        switch status {
        case .authorized:    return .authorized
        case .denied:        return .denied
        case .restricted:    return .restricted
        case .notDetermined: return .notDetermined
        @unknown default:    return .notDetermined
        }
    }
}

/// Injectable seam over `AVCaptureDevice` so the permission model is unit-tested
/// with a deterministic double (the real TCC state on a build machine is not
/// controllable). Sendable: the probe holds no mutable state.
protocol AudioPermissionProbe: Sendable {
    func currentStatus() -> AudioPermissionStatus
    func requestAccess(_ completion: @escaping @Sendable (Bool) -> Void)
}

/// Production probe backed by AVFoundation.
struct SystemAudioPermissionProbe: AudioPermissionProbe {
    func currentStatus() -> AudioPermissionStatus {
        .from(AVCaptureDevice.authorizationStatus(for: .audio))
    }

    func requestAccess(_ completion: @escaping @Sendable (Bool) -> Void) {
        AVCaptureDevice.requestAccess(for: .audio, completionHandler: completion)
    }
}

/// UI-facing, observable microphone-permission holder. Read-only reflection plus a
/// single request path used to gate an explicit monitor start. It never opens a
/// route itself — it only reports the truth the system grants.
@MainActor
@Observable
final class AudioPermission {
    private let probe: AudioPermissionProbe
    private(set) var status: AudioPermissionStatus

    init(probe: AudioPermissionProbe = SystemAudioPermissionProbe()) {
        self.probe = probe
        status = probe.currentStatus()
    }

    /// Re-read the live authorisation (e.g. after returning from System Settings).
    func refresh() {
        status = probe.currentStatus()
    }

    /// Ensure capture is authorised for an explicit user action, requesting access
    /// exactly once when the state is undetermined. The completion runs on the main
    /// actor with the final grant decision so the caller can open (or honestly
    /// refuse) the route. Never prompts for an already-denied device — that only
    /// changes in System Settings.
    func ensureAuthorized(_ completion: @escaping @MainActor (Bool) -> Void) {
        refresh()
        switch status {
        case .authorized:
            completion(true)
        case .denied, .restricted:
            completion(false)
        case .notDetermined:
            probe.requestAccess { granted in
                Task { @MainActor in
                    self.refresh()
                    completion(granted)
                }
            }
        }
    }
}
