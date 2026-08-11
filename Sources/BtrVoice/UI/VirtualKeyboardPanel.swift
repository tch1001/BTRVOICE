import AppKit
import SwiftUI

/// An on-screen keyboard, modelled on macOS's Accessibility Keyboard: a floating
/// panel of clickable keys that types into whatever app has focus.
///
/// The one property everything else hangs off: the panel is **non-activating**.
/// Clicking a key must not move focus, or the keystroke would land in this panel
/// instead of the document the user is writing — the same invariant the dictation
/// panel lives by, enforced the same way. Keys go out through `TextInjector`'s
/// CGEvent path, so to the target app they are indistinguishable from real presses.
///
/// Modifiers are sticky, exactly like the Accessibility Keyboard: tap once to hold
/// it for the next key, tap again to lock it, tap a third time to release. Shift
/// also flips the key labels so the board shows what a press will produce.
@MainActor
final class VirtualKeyboardModel: ObservableObject {

    enum Latch {
        case off
        /// Applies to the next key, then releases.
        case once
        /// Applies until tapped off.
        case locked
    }

    @Published var shift: Latch = .off
    @Published var control: Latch = .off
    @Published var option: Latch = .off
    @Published var command: Latch = .off

    var shifted: Bool { shift != .off }

    func toggle(_ keyPath: ReferenceWritableKeyPath<VirtualKeyboardModel, Latch>) {
        switch self[keyPath: keyPath] {
        case .off: self[keyPath: keyPath] = .once
        case .once: self[keyPath: keyPath] = .locked
        case .locked: self[keyPath: keyPath] = .off
        }
    }

    /// Presses one key with whatever modifiers are latched, then releases the
    /// one-shot latches. Fire and forget: a keyboard that popped an error dialog
    /// per failed key would be worse than one that quietly does nothing, and the
    /// failure that matters (no Accessibility grant) is already surfaced by the
    /// menu bar's permission warnings.
    func press(_ code: CGKeyCode) {
        var flags: CGEventFlags = []
        if shift != .off { flags.insert(.maskShift) }
        if control != .off { flags.insert(.maskControl) }
        if option != .off { flags.insert(.maskAlternate) }
        if command != .off { flags.insert(.maskCommand) }

        TextInjector.pressCombo(key: code, flags: flags) { _ in }

        if shift == .once { shift = .off }
        if control == .once { control = .off }
        if option == .once { option = .off }
        if command == .once { command = .off }
    }
}

// MARK: - Layout

/// One physical key: its keycode plus the labels the board shows for it.
private struct Key: Identifiable {
    let id = UUID()
    let label: String
    let shiftedLabel: String
    let code: CGKeyCode
    /// Width in units of a standard letter key.
    var width: CGFloat = 1

    init(_ label: String, _ shifted: String? = nil, _ code: CGKeyCode, width: CGFloat = 1) {
        self.label = label
        self.shiftedLabel = shifted ?? label.uppercased()
        self.code = code
        self.width = width
    }
}

/// ANSI rows, matching the Accessibility Keyboard's arrangement. Codes are the
/// same virtual keycodes `TextInjector` uses for combo parsing.
private enum Board {
    static let row1: [Key] = [
        Key("esc", "esc", 53, width: 1.3), Key("`", "~", 50),
        Key("1", "!", 18), Key("2", "@", 19), Key("3", "#", 20), Key("4", "$", 21),
        Key("5", "%", 23), Key("6", "^", 22), Key("7", "&", 26), Key("8", "*", 28),
        Key("9", "(", 25), Key("0", ")", 29), Key("-", "_", 27), Key("=", "+", 24),
        Key("⌫", "⌫", 51, width: 1.7),
    ]
    static let row2: [Key] = [
        Key("⇥", "⇥", 48, width: 1.7),
        Key("q", nil, 12), Key("w", nil, 13), Key("e", nil, 14), Key("r", nil, 15),
        Key("t", nil, 17), Key("y", nil, 16), Key("u", nil, 32), Key("i", nil, 34),
        Key("o", nil, 31), Key("p", nil, 35),
        Key("[", "{", 33), Key("]", "}", 30), Key("\\", "|", 42, width: 1.3),
    ]
    static let row3: [Key] = [
        Key("a", nil, 0), Key("s", nil, 1), Key("d", nil, 2), Key("f", nil, 3),
        Key("g", nil, 5), Key("h", nil, 4), Key("j", nil, 38), Key("k", nil, 40),
        Key("l", nil, 37), Key(";", ":", 41), Key("'", "\"", 39),
        Key("⏎", "⏎", 36, width: 2.1),
    ]
    static let row4: [Key] = [
        Key("z", nil, 6), Key("x", nil, 7), Key("c", nil, 8), Key("v", nil, 9),
        Key("b", nil, 11), Key("n", nil, 45), Key("m", nil, 46),
        Key(",", "<", 43), Key(".", ">", 47), Key("/", "?", 44),
    ]
    static let space = Key("space", "space", 49, width: 6)
    static let arrows: [Key] = [
        Key("←", "←", 123), Key("↑", "↑", 126), Key("↓", "↓", 125), Key("→", "→", 124),
    ]
}

// MARK: - View

struct VirtualKeyboardView: View {
    @ObservedObject var model: VirtualKeyboardModel

    private let unit: CGFloat = 36
    private let gap: CGFloat = 5

    var body: some View {
        VStack(spacing: gap) {
            row(Board.row1)
            row(Board.row2)
            HStack(spacing: gap) {
                latchKey("⇪", for: \.shift, width: 2.1, help: "Shift lock")
                row(Board.row3)
            }
            HStack(spacing: gap) {
                latchKey("⇧", for: \.shift, width: 2.6, help: "Shift — tap for one key, tap twice to lock")
                row(Board.row4)
                latchKey("⇧", for: \.shift, width: 2.6, help: "Shift — tap for one key, tap twice to lock")
            }
            HStack(spacing: gap) {
                latchKey("⌃", for: \.control, width: 1.3, help: "Control")
                latchKey("⌥", for: \.option, width: 1.3, help: "Option")
                latchKey("⌘", for: \.command, width: 1.6, help: "Command")
                key(Board.space)
                latchKey("⌘", for: \.command, width: 1.6, help: "Command")
                latchKey("⌥", for: \.option, width: 1.3, help: "Option")
                ForEach(Board.arrows) { key($0) }
            }
        }
        .padding(10)
        .background(.regularMaterial)
    }

    private func row(_ keys: [Key]) -> some View {
        HStack(spacing: gap) {
            ForEach(keys) { key($0) }
        }
    }

    private func key(_ key: Key) -> some View {
        Button {
            model.press(key.code)
        } label: {
            Text(model.shifted ? key.shiftedLabel : key.label)
                .font(.system(size: key.label.count > 1 ? 11 : 13, design: .rounded))
                .frame(width: unit * key.width + gap * (key.width - 1), height: unit)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Color.primary.opacity(0.08))
                )
                .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    private func latchKey(
        _ label: String,
        for keyPath: ReferenceWritableKeyPath<VirtualKeyboardModel, VirtualKeyboardModel.Latch>,
        width: CGFloat,
        help: String
    ) -> some View {
        let state = model[keyPath: keyPath]
        return Button {
            model.toggle(keyPath)
        } label: {
            Text(label)
                .font(.system(size: 13, design: .rounded))
                .frame(width: unit * width + gap * (width - 1), height: unit)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(fillFor(state))
                )
                .overlay(
                    // A locked modifier gets a rim, so "held for one key" and
                    // "staying on" are told apart at a glance — same cue the
                    // Accessibility Keyboard uses.
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .strokeBorder(
                            state == .locked ? Color.accentColor : .clear, lineWidth: 1.5
                        )
                )
                .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
        .buttonStyle(.plain)
        .help(help)
    }

    private func fillFor(_ state: VirtualKeyboardModel.Latch) -> Color {
        switch state {
        case .off: return Color.primary.opacity(0.08)
        case .once: return Color.accentColor.opacity(0.35)
        case .locked: return Color.accentColor.opacity(0.5)
        }
    }
}

// MARK: - Panel

/// Owns the keyboard panel so the menu can toggle it.
@MainActor
final class VirtualKeyboardController {
    static let shared = VirtualKeyboardController()
    private var panel: NSPanel?

    var isVisible: Bool { panel?.isVisible ?? false }

    func toggle() {
        if let panel, panel.isVisible {
            panel.orderOut(nil)
            return
        }
        show()
    }

    private func show() {
        if let panel {
            panel.orderFrontRegardless()
            return
        }
        let hosting = NSHostingController(rootView: VirtualKeyboardView(model: VirtualKeyboardModel()))

        // Titled so it can be dragged and closed natively, but non-activating and
        // never key: clicking a key must leave focus exactly where it is. The
        // window level and space behaviour mirror the dictation panel — always on
        // top, present on every desktop, never listed in the window switcher.
        let panel = NSPanel(contentViewController: hosting)
        panel.styleMask = [.titled, .closable, .utilityWindow, .nonactivatingPanel]
        panel.title = "Keyboard"
        panel.becomesKeyOnlyIfNeeded = true
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isExcludedFromWindowsMenu = true
        panel.isReleasedWhenClosed = false
        panel.setContentSize(hosting.view.fittingSize)

        // Bottom-centre of the screen, where a keyboard belongs.
        if let screen = NSScreen.main {
            let frame = panel.frame
            panel.setFrameOrigin(NSPoint(
                x: screen.visibleFrame.midX - frame.width / 2,
                y: screen.visibleFrame.minY + 24
            ))
        }

        self.panel = panel
        panel.orderFrontRegardless()
    }
}
