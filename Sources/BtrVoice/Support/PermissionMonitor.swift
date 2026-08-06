import AppKit
import Combine

/// Publishes TCC state so the UI reflects a grant the moment it happens.
///
/// There is no notification for this, and `AXIsProcessTrusted()` is cheap, so polling
/// is the honest solution. Without it the panel keeps insisting typing is disabled
/// long after you've enabled it, which is indistinguishable from the grant not working.
final class PermissionMonitor: ObservableObject {

    static let shared = PermissionMonitor()

    @Published private(set) var accessibility: Bool
    @Published private(set) var microphone: Bool
    @Published private(set) var speech: Bool

    private var timer: Timer?

    private init() {
        accessibility = Permissions.accessibilityGranted
        microphone = Permissions.microphoneGranted
        speech = Permissions.speechGranted
    }

    func start() {
        guard timer == nil else { return }
        // Idle cost is negligible; tolerance lets the timer coalesce with others.
        let timer = Timer(timeInterval: 1.5, repeats: true) { [weak self] _ in
            self?.refresh()
        }
        timer.tolerance = 0.5
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    func refresh() {
        let trusted = Permissions.accessibilityGranted
        if trusted != accessibility {
            accessibility = trusted
            Log.write("accessibility access \(trusted ? "granted" : "revoked")")
        }
        let mic = Permissions.microphoneGranted
        if mic != microphone { microphone = mic }
        let speechOK = Permissions.speechGranted
        if speechOK != speech { speech = speechOK }
    }

    /// One-line summary for the launch log, so a mis-scoped grant is diagnosable
    /// without guessing.
    var summary: String {
        "microphone=\(microphone) speech=\(speech) accessibility=\(accessibility)"
    }
}
