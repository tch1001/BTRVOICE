import AppKit

/// Checks the inactive-panel contract without sending text to a real application
/// or opening a microphone: native click handling and the shared replay gate.
enum HistoryInteractionSelfTest {
    static func run() -> Int {
        var failures = 0
        func check(_ name: String, _ condition: @autoclosure () -> Bool) {
            if condition() { print("  ok   \(name)") }
            else { print("  FAIL \(name)"); failures += 1 }
        }
        print("History interaction")
        for phase: DictationController.Phase in [.idle, .listening] {
            check("history stays usable while dictation is \(phase)",
                  DictationController.historyRetryIsAvailable(phase: phase, insertingText: false, awaitingCommand: false))
            check("a second insertion is blocked while dictation is \(phase)",
                  !DictationController.historyRetryIsAvailable(phase: phase, insertingText: true, awaitingCommand: false))
            check("history waits for an explicit pending command while dictation is \(phase)",
                  !DictationController.historyRetryIsAvailable(phase: phase, insertingText: false, awaitingCommand: true))
        }
        for phase: DictationController.Phase in [.finishing, .committing] {
            check("history cannot interrupt an active \(phase) action",
                  !DictationController.historyRetryIsAvailable(phase: phase, insertingText: false, awaitingCommand: false))
        }

        _ = NSApplication.shared
        let viewController = NSViewController()
        let button = HistoryActionControl()
        button.title = "Insert & Send"
        viewController.view = button
        let panel = InsertionHistoryPanel(contentViewController: viewController)
        defer { panel.close() }
        check("history floats without activating the target or hiding on deactivation",
              panel.styleMask.contains(.nonactivatingPanel) && panel.isFloatingPanel
              && panel.level == .floating && !panel.hidesOnDeactivate)
        check("history only requests keyboard focus for editing or selection",
              panel.becomesKeyOnlyIfNeeded && !panel.canBecomeMain && !button.needsPanelToBecomeKey)
        check("an enabled history action accepts the first mouse click",
              button.acceptsFirstMouse(for: nil) && !button.mouseDownCanMoveWindow)
        var presses = 0
        button.onPress = { presses += 1 }
        button.performClick(nil)
        check("one action on an inactive history panel fires once without making it key",
              presses == 1 && !panel.isKeyWindow)
        button.isEnabled = false
        button.performClick(nil)
        check("a disabled action neither accepts a first click nor replays again",
              !button.acceptsFirstMouse(for: nil) && presses == 1)
        button.isEnabled = true
        button.performClick(nil)
        check("history remains usable after another insertion has finished", presses == 2)
        return failures
    }
}
