import AppKit
import Combine

final class AppDelegate: NSObject, NSApplicationDelegate {

    private let controller = DictationController()
    private var panels: PanelController!
    private var statusItem: StatusItemController!
    private var cancellables: Set<AnyCancellable> = []

    /// Press-and-hold tracking for ⌥Space, so a tap latches and a hold is momentary.
    private var toggleKeyDownAt: CFAbsoluteTime?
    private var startedByCurrentPress = false
    private let holdThreshold: CFTimeInterval = 0.35

    private static let welcomeShownKey = "welcomeShown"

    func applicationDidFinishLaunching(_ notification: Notification) {
        Log.startSession()
        PermissionMonitor.shared.start()
        Log.write("permissions: \(PermissionMonitor.shared.summary)")

        panels = PanelController(controller: controller)
        statusItem = StatusItemController(controller: controller)
        statusItem.onTogglePanel = { [weak self] in
            self?.panels.toggle(reposition: Settings.shared.followCaret)
        }

        controller.showPanel = { [weak self] in
            self?.panels.show(reposition: false)
        }
        controller.hidePanel = { [weak self] in
            self?.panels.hide()
        }
        controller.repositionPanel = { [weak self] in
            self?.panels.positionAtCaret()
        }
        controller.releaseFocus = { [weak self] in
            self?.panels.releaseFocus()
        }

        // Handy when iterating on the panel's layout without talking to it.
        if ProcessInfo.processInfo.environment["BTRVOICE_SHOW_PANEL"] == "1" {
            panels.show(reposition: false)
        }
        // Dev hook: start a listening session immediately, so the engine pipeline can
        // be exercised headlessly.
        if ProcessInfo.processInfo.environment["BTRVOICE_AUTOSTART"] == "1" {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                self?.controller.startListening()
            }
        }

        HotkeyManager.shared.handler = { [weak self] action, isDown in
            self?.handle(action, isDown: isDown)
        }
        HotkeyManager.shared.register()

        // Accessibility is the one gate we can't ask for lazily without the user
        // wondering why nothing was typed, so explain it once up front. After that
        // the menu-bar item and the panel banner carry the reminder — a modal on
        // every launch would be obnoxious.
        if !Permissions.accessibilityGranted, !UserDefaults.standard.bool(forKey: Self.welcomeShownKey) {
            UserDefaults.standard.set(true, forKey: Self.welcomeShownKey)
            promptForAccessibility()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        HotkeyManager.shared.unregister()
    }

    // MARK: - Hotkeys

    private func handle(_ action: HotkeyAction, isDown: Bool) {
        switch action {
        case .toggleDictation:
            if isDown {
                toggleKeyDownAt = CFAbsoluteTimeGetCurrent()
                startedByCurrentPress = !controller.isListening
                controller.toggleDictation()
            } else {
                let held = CFAbsoluteTimeGetCurrent() - (toggleKeyDownAt ?? 0)
                if startedByCurrentPress, held > holdThreshold, controller.isListening {
                    // Treated as push-to-talk. The buffer stays up for review.
                    controller.stopListening()
                }
                toggleKeyDownAt = nil
                startedByCurrentPress = false
            }

        case .commit:
            guard isDown else { return }
            controller.commit(send: false)

        case .cancel:
            guard isDown else { return }
            controller.cancel()
        }
    }

    // MARK: - First run

    private func promptForAccessibility() {
        let alert = NSAlert()
        alert.messageText = "Allow BtrVoice to type for you"
        alert.informativeText = """
        BtrVoice stages your dictation in its own window, then types it into whatever app \
        you're using — including ones Apple's dictation can't reach, like Telegram and Terminal.

        Typing into other apps needs Accessibility access. Add BtrVoice under \
        Privacy & Security › Accessibility, then relaunch it.
        """
        alert.addButton(withTitle: "Open Settings")
        alert.addButton(withTitle: "Later")
        if alert.runModal() == .alertFirstButtonReturn {
            Permissions.requestAccessibility()
            Permissions.openSettings(.accessibility)
        }
    }
}
