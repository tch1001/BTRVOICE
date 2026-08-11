import AppKit

/// Reading the system pasteboard, and lifting the current selection out of
/// another app by pressing ⌘C in it.
///
/// There is no supported way to read another application's selected text on
/// macOS — the accessibility API exposes it only for apps that cooperate, which
/// is the same limitation BtrVoice exists to route around. Pressing ⌘C works
/// everywhere for the same reason synthetic keystrokes do: the app cannot tell
/// it from the user.
enum Clipboard {

    /// The pasteboard's current string, if it holds one.
    static var text: String? {
        let value = NSPasteboard.general.string(forType: .string)
        guard let value, !value.isEmpty else { return nil }
        return value
    }

    /// How long to wait for the target app to service the ⌘C. Copy is normally
    /// instant; a slow Electron app occasionally needs a beat.
    private static let copyTimeout: TimeInterval = 0.6
    private static let pollInterval: TimeInterval = 0.03

    /// Presses ⌘C in the frontmost app and returns whatever landed on the
    /// pasteboard. `nil` means nothing was selected (or the app ignored the
    /// copy) — detected by the pasteboard's `changeCount` never moving, which
    /// distinguishes "no selection" from "selection identical to what was
    /// already copied".
    ///
    /// The caller is expected to have focused the target app first. This
    /// deliberately does NOT restore the previous pasteboard contents: the
    /// selection genuinely becomes the clipboard, which is what the user asked
    /// for when they said "read what I highlighted", and restoring it would race
    /// against anything else reading the pasteboard in the meantime.
    static func captureSelection(completion: @escaping (String?) -> Void) {
        let pasteboard = NSPasteboard.general
        let before = pasteboard.changeCount

        TextInjector.pressShortcut(.copy) { result in
            if case .failure(let error) = result {
                Log.write("clipboard: copy keystroke failed — \(error.localizedDescription)")
                completion(nil)
                return
            }
            waitForChange(since: before, deadline: Date().addingTimeInterval(copyTimeout)) { changed in
                // Without the changeCount check this would hand back whatever was
                // already on the clipboard and call it "the selection".
                completion(changed ? text : nil)
            }
        }
    }

    private static func waitForChange(
        since before: Int, deadline: Date, completion: @escaping (Bool) -> Void
    ) {
        if NSPasteboard.general.changeCount != before {
            completion(true)
            return
        }
        guard Date() < deadline else {
            Log.write("clipboard: nothing was copied — assuming no selection")
            completion(false)
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + pollInterval) {
            waitForChange(since: before, deadline: deadline, completion: completion)
        }
    }
}
