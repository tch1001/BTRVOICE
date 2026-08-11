import AppKit
import SwiftUI

/// The hover window: level meter, editable transcript, live partial, commit controls.
struct DictationPanelView: View {

    @ObservedObject var controller: DictationController
    @ObservedObject private var buffer: TextBuffer
    @ObservedObject private var targets: TargetTracker
    @ObservedObject private var settings = Settings.shared
    @ObservedObject private var permissions = PermissionMonitor.shared

    init(controller: DictationController) {
        self.controller = controller
        self.buffer = controller.buffer
        self.targets = controller.targets
    }

    private var isListening: Bool { controller.isListening }

    /// The "brain" column only makes sense while the GPT Editor engine is active.
    private var editorEngineActive: Bool {
        DictationController.resolveEngine(from: settings.engineChoice) == .gptEditor
    }

    var body: some View {
        GeometryReader { geometry in
            VStack(alignment: .leading, spacing: 0) {
                header
                Divider().opacity(0.5)
                transcript
                if let error = controller.errorMessage {
                    errorBanner(error)
                }
                Divider().opacity(0.5)
                footer
                if settings.biggerBottomButtons {
                    Divider().opacity(0.5)
                    bigBottomBar
                }
            }
            // Several compact footer controls have fixed ideal widths. At a narrow
            // window they can overflow, but they must not make the *entire* stack
            // wider and centre it behind the panel's clip boundary. Pin the root
            // stack to the AppKit content width so the large bottom buttons retain
            // their leading inset and stay fully clickable.
            .frame(
                width: geometry.size.width,
                height: geometry.size.height,
                alignment: .topLeading
            )
        }
        .frame(minHeight: 170)
        // Vibrancy alone leaves the transcript competing with the wallpaper, so the
        // material sits over a translucent window-coloured base for real contrast.
        .background {
            let shape = RoundedRectangle(cornerRadius: 14, style: .continuous)
            ZStack {
                shape.fill(.regularMaterial)
                shape.fill(Color(nsColor: .windowBackgroundColor).opacity(0.6))
            }
        }
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.12), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    // MARK: Header

    private var header: some View {
        ZStack {
            WindowDragHandle()
            HStack(spacing: 10) {
                Button {
                    controller.toggleDictation()
                } label: {
                    Image(systemName: isListening ? "stop.circle.fill" : "mic.circle.fill")
                        .font(.system(size: 20))
                        .foregroundStyle(isListening ? Color.red : Color.accentColor)
                }
                .buttonStyle(.plain)
                .help(isListening ? "Stop listening (⌥Space)" : "Start listening (⌥Space)")

                WaveformView(level: controller.level, active: isListening)
                    .frame(width: 78)

                VStack(alignment: .leading, spacing: 1) {
                    Text(statusLine)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                    if let name = targets.targetName {
                        Text("→ \(name)")
                            .font(.system(size: 10))
                            .foregroundStyle(.tertiary)
                    }
                }

                Spacer(minLength: 4)

                if !permissions.accessibility {
                    Button {
                        Permissions.requestAccessibility()
                        Permissions.openSettings(.accessibility)
                    } label: {
                        Label("Enable typing", systemImage: "exclamationmark.triangle.fill")
                            .font(.system(size: 10, weight: .medium))
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.orange)
                    .help("Accessibility access is needed to type into other apps")
                }

                Button {
                    controller.cancel()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 13))
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .help("Discard and close (⌥⎋)")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
        }
        .frame(height: 44)
    }

    private var statusLine: String {
        if !controller.status.isEmpty { return controller.status }
        if buffer.isEmpty { return "Press ⌥Space to dictate" }
        return "\(buffer.displayText.count) characters staged"
    }

    // MARK: Transcript

    // One editor holds everything: committed text (editable — select, retype,
    // cursor anywhere) with the live grey tail appended in place. It fills whatever
    // size the user resizes the window to, scrolling on overflow, and never resizes
    // itself mid-sentence.
    private var transcript: some View {
        HStack(spacing: 0) {
            ZStack {
                // While the editor streams a full-transcript rewrite, show it as the
                // in-flight (grey) text in place of everything else.
                BufferTextView(
                    text: buffer.replacementPreview == nil ? buffer.text : "",
                    partial: buffer.replacementPreview ?? buffer.partial,
                    revision: buffer.revision,
                    placeholder: "Dictated text stages here. Nothing is typed into the app until you insert it.",
                    onEdit: { buffer.userDidEdit($0) },
                    onAdoptAll: { controller.adoptEditedText($0) },
                    onCommit: { controller.commit(send: false) },
                    onCancel: { controller.cancel() }
                )
                if let pending = controller.pendingCommand {
                    pendingCommandOverlay(pending)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.horizontal, 8)
            .padding(.vertical, 6)

            // The editor's brain, inline: what it hears, writes, and does.
            if editorEngineActive, settings.showEditorBrain {
                brainResizeHandle
                EditorActivityView(log: .shared)
                    .frame(width: CGFloat(settings.editorBrainWidth))
            }
        }
    }

    /// Draggable divider for the brain column. Drag left to widen, right to
    /// shrink; clamped so neither side can be crushed.
    @State private var brainDragStartWidth: Double?
    @State private var brainHandleHovered = false

    private var brainResizeHandle: some View {
        ZStack {
            // The panel moves on background drags; the resize strip must not
            // double as a window-move handle.
            WindowDragBlocker()
            // A visible track + grip so it reads as "drag me", not just a line.
            Rectangle()
                .fill(brainHandleHovered ? Color.accentColor.opacity(0.16) : Color.primary.opacity(0.05))
            Capsule()
                .fill(Color.secondary.opacity(brainHandleHovered ? 0.9 : 0.45))
                .frame(width: 3, height: 36)
        }
        .frame(width: 10)
        .animation(.easeOut(duration: 0.12), value: brainHandleHovered)
        .contentShape(Rectangle())
        .onHover { inside in
            brainHandleHovered = inside
            if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
        }
        .gesture(
            // Global coordinate space: the handle itself shifts as the width
            // changes, so measuring translation locally double-counts every
            // delta and jitters. Global translation tracks the actual cursor.
            DragGesture(minimumDistance: 1, coordinateSpace: .global)
                .onChanged { value in
                    let start = brainDragStartWidth ?? settings.editorBrainWidth
                    if brainDragStartWidth == nil { brainDragStartWidth = start }
                    let range = Settings.editorBrainWidthRange
                    let proposed = start - Double(value.translation.width)
                    settings.editorBrainWidth = min(max(proposed, range.lowerBound), range.upperBound)
                }
                .onEnded { _ in brainDragStartWidth = nil }
        )
        .help("Drag to resize the brain panel")
    }

    /// A heard command about to fire. Covers the whole transcript region so it's
    /// impossible to miss, with targets big enough to hit without aiming: the left
    /// half fires it now, the right half cancels, and the middle names the action.
    private func pendingCommandOverlay(_ pending: DictationController.PendingCommand) -> some View {
        HStack(spacing: 0) {
            Button {
                controller.firePendingCommand()
            } label: {
                VStack(spacing: 6) {
                    Image(systemName: "bolt.fill")
                        .font(.system(size: 26))
                    Text("Now")
                        .font(.system(size: 15, weight: .semibold))
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .background(Color.green.opacity(0.22))

            VStack(spacing: 3) {
                Text("About to")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                Text(pending.label)
                    .font(.system(size: 13, weight: .semibold))
                    .multilineTextAlignment(.center)
                Text(timerInterval: min(Date(), pending.firesAt)...pending.firesAt, countsDown: true)
                    .font(.system(size: 12).monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            .frame(width: 120)
            .frame(maxHeight: .infinity)
            .background(.regularMaterial)

            Button {
                controller.cancelPendingCommand()
            } label: {
                VStack(spacing: 6) {
                    Image(systemName: "xmark")
                        .font(.system(size: 24, weight: .semibold))
                    Text("Cancel")
                        .font(.system(size: 15, weight: .semibold))
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .background(Color.red.opacity(0.18))
            .keyboardShortcut(.escape, modifiers: [])
        }
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.15), lineWidth: 1)
        )
    }

    private func errorBanner(_ message: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text(message)
                .font(.system(size: 11))
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            Button("Dismiss") { controller.dismissError() }
                .buttonStyle(.borderless)
                .font(.system(size: 11))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(Color.orange.opacity(0.12))
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: 8) {
            // Enabled the moment *anything* is visible, live partial included: a
            // mid-dictation Insert stops listening, waits for the tail to land, then
            // types. Requiring finalised text first reads as a broken grey button.
            Button {
                controller.commit(send: false)
            } label: {
                Label("Insert", systemImage: "text.cursor")
            }
            .keyboardShortcut(.return, modifiers: .command)
            .disabled(buffer.isEmpty)
            .help("Type the staged text into \(targets.targetName ?? "the focused app") (⌥↩)")

            Button {
                controller.commit(send: true)
            } label: {
                Label("Insert & Send", systemImage: "paperplane.fill")
            }
            .disabled(buffer.isEmpty)
            .help("Type the text, then press Return in the target app")

            // A real Backspace keypress in the target app, at its own cursor — for
            // fixing what's already been inserted. The staged text above is edited
            // directly by clicking into it.
            Button {
                controller.pressBackspaceInTarget(wordwise: NSEvent.modifierFlags.contains(.option))
            } label: {
                Image(systemName: "delete.left")
            }
            .disabled(!permissions.accessibility)
            .help("Press Backspace in \(targets.targetName ?? "the focused app") (⌥-click: delete a word)")

            Button {
                controller.copyBufferToPasteboard()
            } label: {
                Image(systemName: "doc.on.doc")
            }
            .disabled(buffer.isEmpty)
            .help("Copy to clipboard")

            Button {
                controller.clearBuffer()
            } label: {
                Image(systemName: "trash")
            }
            .disabled(buffer.isEmpty)
            .help("Clear the buffer")

            Spacer(minLength: 0)

            if editorEngineActive {
                Button {
                    settings.showEditorBrain.toggle()
                } label: {
                    Image(systemName: settings.showEditorBrain ? "brain.head.profile.fill" : "brain.head.profile")
                }
                .help(settings.showEditorBrain ? "Hide the editor's brain" : "Show the editor's brain — what it hears, writes, and does")
            }

            Picker("", selection: $settings.newlineMode) {
                ForEach(NewlineMode.allCases, id: \.self) { mode in
                    Text(mode.label).tag(mode)
                }
            }
            .labelsHidden()
            .frame(width: 168)
            .help("How newlines are typed. Use Shift-Return in chat apps so Return doesn't send early.")
        }
        .controlSize(.small)
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
    }

    /// Optional, oversized duplicates of the high-frequency controls. The compact
    /// header/footer remain untouched; this row is an easier target when the panel is
    /// parked at the bottom-left of a large external display.
    private var bigBottomBar: some View {
        HStack(spacing: 10) {
            Button {
                controller.toggleDictation()
            } label: {
                ZStack {
                    Circle()
                        .fill(isListening ? Color.red : Color.accentColor)
                    Image(systemName: isListening ? "stop.fill" : "mic.fill")
                        .font(.system(size: 22, weight: .semibold))
                        .foregroundStyle(.white)
                }
                .frame(width: 58, height: 58)
                .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(isListening ? "Stop listening" : "Start listening")
            .help(isListening ? "Stop listening (⌥Space)" : "Start listening (⌥Space)")

            Button {
                controller.commit(send: true)
            } label: {
                ZStack {
                    Circle()
                        .fill(Color.accentColor)
                    Image(systemName: "paperplane.fill")
                        .font(.system(size: 21, weight: .semibold))
                        .foregroundStyle(.white)
                }
                .frame(width: 58, height: 58)
                .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .disabled(buffer.isEmpty)
            .opacity(buffer.isEmpty ? 0.4 : 1)
            .accessibilityLabel("Insert and send")
            .help("Type the text, then press Return in the target app")

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 7)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// An AppKit view that refuses window-background dragging, for regions where a
/// drag means something else (like resizing the brain column).
private struct WindowDragBlocker: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { Blocker() }
    func updateNSView(_ nsView: NSView, context: Context) {}

    private final class Blocker: NSView {
        override var mouseDownCanMoveWindow: Bool { false }
    }
}

/// Lets the user drag the borderless panel by its header. SwiftUI swallows the
/// window-background drag, so the handle is an explicit AppKit view underneath.
private struct WindowDragHandle: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { DragView() }
    func updateNSView(_ nsView: NSView, context: Context) {}

    private final class DragView: NSView {
        override func mouseDown(with event: NSEvent) {
            window?.performDrag(with: event)
        }
    }
}
