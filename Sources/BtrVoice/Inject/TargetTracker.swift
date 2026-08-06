import AppKit

/// Remembers which application the text is destined for.
///
/// BtrVoice's panel is non-activating, so the target normally stays frontmost the
/// whole time — but clicking into the editor to fix a word does hand us focus, and
/// we must not then type the buffer into ourselves.
final class TargetTracker: ObservableObject {

    @Published private(set) var target: NSRunningApplication?

    private var observer: NSObjectProtocol?
    private let selfPID = ProcessInfo.processInfo.processIdentifier

    init() {
        adopt(NSWorkspace.shared.frontmostApplication)
        observer = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            self?.adopt(app)
        }
    }

    deinit {
        if let observer {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
    }

    var targetName: String? { target?.localizedName }

    private func adopt(_ app: NSRunningApplication?) {
        guard let app, app.processIdentifier != selfPID else { return }
        target = app
    }

    /// Brings the target forward and waits (briefly, on a background queue) until it
    /// really is frontmost, then calls back on main. Posting key events before the
    /// switch completes is the classic cause of text landing in the wrong window.
    func focusTarget(then completion: @escaping (Bool) -> Void) {
        guard let target, !target.isTerminated else {
            completion(false)
            return
        }
        if target.isActive {
            completion(true)
            return
        }

        target.activate(options: [])

        DispatchQueue.global(qos: .userInitiated).async {
            let deadline = Date().addingTimeInterval(0.6)
            while Date() < deadline {
                if NSWorkspace.shared.frontmostApplication?.processIdentifier == target.processIdentifier {
                    // Give the app a moment to actually take key focus in its window.
                    usleep(60_000)
                    DispatchQueue.main.async { completion(true) }
                    return
                }
                usleep(20_000)
            }
            DispatchQueue.main.async { completion(false) }
        }
    }
}
