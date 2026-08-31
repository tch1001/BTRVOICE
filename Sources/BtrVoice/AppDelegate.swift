import AppKit
import Combine

final class AppDelegate: NSObject, NSApplicationDelegate {

    private let controller = DictationController()
    private var panels: PanelController!
    private var statusItem: StatusItemController!
    private var cancellables: Set<AnyCancellable> = []

    /// Press-and-hold tracking for ⌥Space, so a tap latches and a hold is momentary.
    /// How long counts as a hold lives on the controller, which is the only thing
    /// that knows when the microphone actually went live.
    private var startedByCurrentPress = false

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
        statusItem.onHidePanel = { [weak self] in
            self?.panels.hide()
        }
        statusItem.onResetPanelPosition = { [weak self] in
            self?.panels.resetPosition()
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
        VirtualKeyboardController.shared.configureKeyHandler { [weak self] code, flags in
            self?.controller.pressVirtualKeyboardKey(code, flags: flags)
        }

        // Handy when iterating on the panel's layout without talking to it.
        if ProcessInfo.processInfo.environment["BTRVOICE_SHOW_PANEL"] == "1" {
            panels.show(reposition: false)
        }
        // Dev hook: open the native Realtime console without navigating the menu.
        if ProcessInfo.processInfo.environment["BTRVOICE_SHOW_JARVIS"] == "1" {
            DispatchQueue.main.async { JarvisSurfaceWindowController.shared.show() }
        }
        // Dev hook retained under its original name for existing launch scripts: it
        // now opens the replacement desktop voice overlay without starting the mic.
        if ProcessInfo.processInfo.environment["BTRVOICE_SHOW_COMPUTER_USE"] == "1" {
            let target = NSWorkspace.shared.frontmostApplication
            DispatchQueue.main.async {
                DesktopVoiceWindowController.shared.show(target: target, startListening: false)
            }
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
        panels?.persistFrameNow()
        HotkeyManager.shared.unregister()
        DesktopVoiceCoordinator.shared.shutdown()
        JarvisVoiceService.shared.shutdown()
    }

    // MARK: - Hotkeys

    private func handle(_ action: HotkeyAction, isDown: Bool) {
        switch action {
        case .toggleDictation:
            if isDown {
                startedByCurrentPress = !controller.isListening
                controller.toggleDictation()
            } else {
                // Push-to-talk ends only when the *microphone* was live long enough
                // to have heard something. Timing the keypress instead meant an
                // ordinary tap — held past 0.35s while a cloud engine was still
                // connecting — stopped the session before any audio was captured,
                // which is why dictation appeared to start and immediately finish.
                if startedByCurrentPress, controller.isListening, controller.holdHasCapturedAudio {
                    // Treated as push-to-talk. The buffer stays up for review.
                    controller.stopListening()
                }
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
