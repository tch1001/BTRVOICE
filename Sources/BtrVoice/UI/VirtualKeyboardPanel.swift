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
/// one for the next key or pointer gesture, tap again to lock it, and tap a third
/// time to release. Shift also flips the labels to show what a key will produce.
@MainActor
final class VirtualKeyboardModel: ObservableObject {

    enum Latch: Equatable {
        case off
        /// Applies to the next key or external pointer gesture, then releases.
        case once
        /// Applies until tapped off.
        case locked
    }

    @Published var shift: Latch = .off
    @Published var control: Latch = .off
    @Published var option: Latch = .off
    @Published var command: Latch = .off

    private let keyHandler: (CGKeyCode, CGEventFlags) -> Void
    private let modifiersChanged: (CGEventFlags) -> Void

    init(
        keyHandler: @escaping (CGKeyCode, CGEventFlags) -> Void,
        modifiersChanged: @escaping (CGEventFlags) -> Void = { _ in }
    ) {
        self.keyHandler = keyHandler
        self.modifiersChanged = modifiersChanged
    }

    var shifted: Bool { shift != .off }
    var activeModifierFlags: CGEventFlags {
        var flags: CGEventFlags = []
        if shift != .off { flags.insert(.maskShift) }
        if control != .off { flags.insert(.maskControl) }
        if option != .off { flags.insert(.maskAlternate) }
        if command != .off { flags.insert(.maskCommand) }
        return flags
    }

    func toggle(_ keyPath: ReferenceWritableKeyPath<VirtualKeyboardModel, Latch>) {
        let previousFlags = activeModifierFlags
        switch self[keyPath: keyPath] {
        case .off: self[keyPath: keyPath] = .once
        case .once: self[keyPath: keyPath] = .locked
        case .locked: self[keyPath: keyPath] = .off
        }
        publishModifiersIfChanged(from: previousFlags)
    }

    /// Presses one key with whatever modifiers are latched, then spends the
    /// one-shot latches. Fire and forget: a keyboard that popped an error dialog
    /// per failed key would be worse than one that quietly does nothing, and the
    /// failure that matters (no Accessibility grant) is already surfaced by the
    /// menu bar's permission warnings.
    func press(_ code: CGKeyCode) {
        keyHandler(code, activeModifierFlags)
        consumeOneShotModifiers()
    }

    /// A real click/drag completed outside BtrVoice. One-shot latches are spent by
    /// pointer actions just as they are by on-screen key presses; locked modifiers
    /// remain active until the user taps them again.
    func consumeOneShotModifiers() {
        let previousFlags = activeModifierFlags
        if shift == .once { shift = .off }
        if control == .once { control = .off }
        if option == .once { option = .off }
        if command == .once { command = .off }
        publishModifiersIfChanged(from: previousFlags)
    }

    func releaseAllModifiers() {
        let previousFlags = activeModifierFlags
        shift = .off
        control = .off
        option = .off
        command = .off
        publishModifiersIfChanged(from: previousFlags)
    }

    private func publishModifiersIfChanged(from previousFlags: CGEventFlags) {
        let flags = activeModifierFlags
        if flags != previousFlags {
            modifiersChanged(flags)
        }
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
                latchKey("⇧", for: \.shift, width: 2.6, help: "Shift — tap for one key or click, tap twice to lock")
                row(Board.row4)
                latchKey("⇧", for: \.shift, width: 2.6, help: "Shift — tap for one key or click, tap twice to lock")
            }
            HStack(spacing: gap) {
                latchKey("⌃", for: \.control, width: 1.3, help: "Control — works with keys, clicks, drags, and scrolling")
                latchKey("⌥", for: \.option, width: 1.3, help: "Option — works with keys, clicks, drags, and scrolling")
                latchKey("⌘", for: \.command, width: 1.6, help: "Command — works with keys, clicks, drags, and scrolling")
                key(Board.space)
                latchKey("⌘", for: \.command, width: 1.6, help: "Command — works with keys, clicks, drags, and scrolling")
                latchKey("⌥", for: \.option, width: 1.3, help: "Option — works with keys, clicks, drags, and scrolling")
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

/// Construction-time properties that keep the keyboard out of the activation
/// transaction for the app or system surface receiving its keys.
enum VirtualKeyboardPanelPolicy {
    static let styleMask: NSWindow.StyleMask = [
        .titled, .closable, .utilityWindow, .nonactivatingPanel,
    ]
}

/// A keyboard that never takes focus. Overriding `canBecomeKey` to false is the whole
/// trick: a plain panel becomes the key window the instant you click a control in it,
/// and then the keystrokes this thing injects land on *itself* — a window with no text
/// field — which is the system beep the user heard, not typing. As a palette that can
/// never be key, clicks still reach its buttons but focus stays on the app underneath,
/// which is exactly where the injected keys should go.
private final class KeyboardPanel: NSPanel {
    /// `.nonactivatingPanel` must be present in the designated initializer. Adding
    /// it after `NSPanel(contentViewController:)` has already created the WindowServer
    /// window can leave the panel visually non-key without the prevent-activation
    /// behavior needed by Dock-owned surfaces such as Apps/Launchpad.
    init(nonactivatingContentViewController controller: NSViewController) {
        super.init(
            contentRect: .zero,
            styleMask: VirtualKeyboardPanelPolicy.styleMask,
            backing: .buffered,
            defer: false
        )
        contentViewController = controller
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is unavailable")
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Owns the keyboard panel so the menu can toggle it.
@MainActor
final class VirtualKeyboardController: NSObject, NSWindowDelegate {
    static let shared = VirtualKeyboardController()
    private var panel: NSPanel?
    private var model: VirtualKeyboardModel?
    private var keyHandler: ((CGKeyCode, CGEventFlags) -> Void)?
    private let pointerBridge = StickyModifierPointerBridge()
    private var pointerReleaseMonitor: Any?

    var isVisible: Bool { panel?.isVisible ?? false }

    func configureKeyHandler(_ handler: @escaping (CGKeyCode, CGEventFlags) -> Void) {
        keyHandler = handler
    }

    func toggle() {
        if let panel, panel.isVisible {
            stopPointerModifierSupport()
            panel.orderOut(nil)
            return
        }
        show()
    }

    private func show() {
        if let panel {
            startPointerModifierSupport()
            panel.orderFrontRegardless()
            return
        }
        let model = VirtualKeyboardModel(
            keyHandler: { [weak self] code, flags in
                guard let handler = self?.keyHandler else {
                    Log.write("keyboard: key suppressed because no target handler is configured")
                    return
                }
                handler(code, flags)
            },
            modifiersChanged: { [weak self] flags in
                self?.pointerBridge.update(activeModifiers: flags)
            }
        )
        self.model = model
        let hosting = NSHostingController(rootView: VirtualKeyboardView(model: model))

        // Titled so it can be dragged and closed natively, but non-activating and
        // never key (see KeyboardPanel): clicking a key must leave focus exactly where
        // it is. The window level and space behaviour mirror the dictation panel —
        // always on top, present on every desktop, never listed in the window switcher.
        let panel = KeyboardPanel(nonactivatingContentViewController: hosting)
        panel.title = "Keyboard"
        panel.becomesKeyOnlyIfNeeded = true
        panel.worksWhenModal = true
        panel.isFloatingPanel = true
        // The level the real Accessibility Keyboard uses. `.floating` sits *below*
        // Launchpad and Mission Control, so the keyboard would vanish under them; the
        // assistive-tech-high level floats above even those, which is what lets it drive
        // Launchpad's app search. `stationaryMoves` keeps it put when Spaces change.
        panel.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.assistiveTechHighWindow)))
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.isExcludedFromWindowsMenu = true
        panel.isReleasedWhenClosed = false
        panel.delegate = self

        // Force a layout pass before measuring: `fittingSize` is (0, 0) until the
        // SwiftUI hosting view has laid out, and a zero-size panel is on screen but
        // invisible — which is exactly why the keyboard "opened" yet nothing appeared.
        hosting.view.layoutSubtreeIfNeeded()
        var size = hosting.view.fittingSize
        if size.width < 100 || size.height < 60 {
            // Last-resort fallback so a measurement miss can never hide the window.
            size = NSSize(width: 760, height: 300)
        }
        panel.setContentSize(size)

        // Bottom-centre of the screen, where a keyboard belongs.
        if let screen = NSScreen.main {
            let frame = panel.frame
            panel.setFrameOrigin(NSPoint(
                x: screen.visibleFrame.midX - frame.width / 2,
                y: screen.visibleFrame.minY + 24
            ))
        }

        self.panel = panel
        startPointerModifierSupport()
        panel.orderFrontRegardless()
    }

    func shutdown() {
        stopPointerModifierSupport()
    }

    func windowWillClose(_ notification: Notification) {
        stopPointerModifierSupport()
    }

    private func startPointerModifierSupport() {
        pointerBridge.update(activeModifiers: model?.activeModifierFlags ?? [])
        if !pointerBridge.start() {
            Log.write("keyboard: could not install pointer modifier event tap")
        }
        guard pointerReleaseMonitor == nil else { return }
        pointerReleaseMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseUp, .rightMouseUp, .otherMouseUp]
        ) { [weak self] _ in
            DispatchQueue.main.async {
                self?.model?.consumeOneShotModifiers()
            }
        }
    }

    private func stopPointerModifierSupport() {
        model?.releaseAllModifiers()
        if let pointerReleaseMonitor {
            NSEvent.removeMonitor(pointerReleaseMonitor)
            self.pointerReleaseMonitor = nil
        }
        pointerBridge.stop()
    }
}
