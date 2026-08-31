import AppKit
import SwiftUI

/// A compact, resizable, non-activating overlay for live desktop commands. It
/// mirrors dictation's screen-level presence while keeping focus in the app the
/// user intends to control.
private struct DesktopVoicePanelView: View {
    private static let activityBottomID = "desktop-voice-activity-bottom"

    @ObservedObject var coordinator: DesktopVoiceCoordinator
    @State private var manualCommand = ""

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                DesktopVoiceDragHandle()
                VStack(alignment: .leading, spacing: 0) {
                    header
                    Divider().opacity(0.5)
                    activity
                    Divider().opacity(0.5)
                    commandBar
                }
                .frame(
                    width: geometry.size.width,
                    height: geometry.size.height,
                    alignment: .topLeading
                )
            }
        }
        .frame(minWidth: 340, minHeight: 190)
        .background {
            let shape = RoundedRectangle(cornerRadius: 14, style: .continuous)
            ZStack {
                shape.fill(.regularMaterial)
                shape.fill(Color(nsColor: .windowBackgroundColor).opacity(0.64))
            }
        }
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.12), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private var header: some View {
        ZStack {
            HStack(spacing: 10) {
                Button {
                    let target = NSWorkspace.shared.frontmostApplication
                    coordinator.toggle(target: target)
                } label: {
                    Image(systemName: coordinator.isListening ? "stop.circle.fill" : "waveform.circle.fill")
                        .font(.system(size: 21))
                        .foregroundStyle(coordinator.isListening ? Color.red : Color.accentColor)
                }
                .buttonStyle(.plain)
                .help(coordinator.isListening ? "Stop voice control" : "Start voice control")

                WaveformView(level: coordinator.level, active: coordinator.isListening)
                    .frame(width: 72)

                VStack(alignment: .leading, spacing: 1) {
                    Text(coordinator.status)
                        .font(.system(size: 11, weight: .medium))
                        .lineLimit(1)
                    if let target = coordinator.targetName {
                        Text("Controlling \(target)")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }

                Spacer(minLength: 4)

                Button {
                    coordinator.clearActivity()
                } label: {
                    Image(systemName: "trash")
                        .font(.system(size: 12, weight: .medium))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Clear voice context and activity")

                Button {
                    DesktopVoiceWindowController.shared.stopAndHide()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 13))
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .help("Stop and close")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
        }
        .frame(height: 46)
    }

    private var activity: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    if coordinator.activities.isEmpty, coordinator.partialTranscript.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            Label("Try “Open the browser”", systemImage: "bolt.fill")
                                .font(.system(size: 13, weight: .semibold))
                            Text("Also try “Open Brave and create a new tab.” Familiar commands run through the native fast path.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 8)
                    }

                    ForEach(coordinator.activities) { entry in
                        activityRow(entry)
                    }

                    if !coordinator.partialTranscript.isEmpty {
                        HStack(alignment: .top, spacing: 9) {
                            Image(systemName: "waveform")
                                .foregroundStyle(.secondary)
                                .frame(width: 16)
                            Text(coordinator.partialTranscript)
                                .font(.system(size: 13))
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .padding(9)
                        .background(Color.secondary.opacity(0.07), in: RoundedRectangle(cornerRadius: 9))
                    }

                    Color.clear
                        .frame(height: 1)
                        .id(Self.activityBottomID)
                }
                .padding(12)
            }
            .onAppear {
                proxy.scrollTo(Self.activityBottomID, anchor: .bottom)
            }
            .onChange(of: coordinator.activities.last?.id) {
                withAnimation(.easeOut(duration: 0.16)) {
                    proxy.scrollTo(Self.activityBottomID, anchor: .bottom)
                }
            }
            .onChange(of: coordinator.partialTranscript) {
                proxy.scrollTo(Self.activityBottomID, anchor: .bottom)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // Activity is read-only, so the entire body is useful window chrome. The
        // editable command field and all buttons live outside this overlay.
        .overlay(DesktopVoiceDragHandle())
    }

    private func activityRow(_ entry: DesktopVoiceCoordinator.Activity) -> some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: symbol(for: entry.kind))
                .foregroundStyle(color(for: entry.kind))
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.title)
                    .font(.system(size: 12.5, weight: entry.kind == .heard ? .regular : .medium))
                    .frame(maxWidth: .infinity, alignment: .leading)
                if let detail = entry.detail {
                    Text(detail)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    private var commandBar: some View {
        HStack(spacing: 8) {
            TextField("Type a command without using the microphone", text: $manualCommand)
                .textFieldStyle(.roundedBorder)
                .onSubmit { submitManualCommand() }
            Button {
                hardSubmit()
            } label: {
                Label("Hard Submit", systemImage: "bolt.fill")
                    .font(.system(size: 11, weight: .semibold))
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .disabled(
                manualCommand.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    && coordinator.partialTranscript
                        .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            )
            .help("Immediately run the typed command or the visible live transcript")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
    }

    private func submitManualCommand() {
        let command = manualCommand
        manualCommand = ""
        coordinator.submit(command)
    }

    private func hardSubmit() {
        let typed = manualCommand.trimmingCharacters(in: .whitespacesAndNewlines)
        if typed.isEmpty {
            coordinator.submitPartialNow()
        } else {
            manualCommand = ""
            coordinator.submit(typed)
        }
    }

    private func symbol(for kind: DesktopVoiceCoordinator.Activity.Kind) -> String {
        switch kind {
        case .heard: return "quote.bubble"
        case .plan: return "bolt.fill"
        case .success: return "checkmark.circle.fill"
        case .notice: return "info.circle"
        case .failure: return "exclamationmark.triangle.fill"
        }
    }

    private func color(for kind: DesktopVoiceCoordinator.Activity.Kind) -> Color {
        switch kind {
        case .heard, .notice: return .secondary
        case .plan: return .accentColor
        case .success: return .green
        case .failure: return .orange
        }
    }
}

/// Lets the panel header move the window without making the panel key.
private struct DesktopVoiceDragHandle: NSViewRepresentable {
    final class DragView: NSView {
        override var needsPanelToBecomeKey: Bool { false }

        override func mouseDown(with event: NSEvent) {
            window?.performDrag(with: event)
        }

        /// Keep trackpad/mouse-wheel scrolling useful when this drag surface sits
        /// over the read-only activity list: temporarily reveal the underlying
        /// SwiftUI scroll view and forward the wheel event to it.
        override func scrollWheel(with event: NSEvent) {
            guard let contentView = window?.contentView else {
                super.scrollWheel(with: event)
                return
            }
            isHidden = true
            let underlying = contentView.hitTest(event.locationInWindow)
            isHidden = false
            if let underlying, underlying !== self {
                underlying.scrollWheel(with: event)
            } else {
                super.scrollWheel(with: event)
            }
        }
    }

    func makeNSView(context: Context) -> DragView { DragView() }
    func updateNSView(_ nsView: DragView, context: Context) {}
}

/// Owns the overlay window, remembers its independent size and position, and keeps
/// it non-activating so commands and shortcuts continue to target the user's app.
final class DesktopVoiceWindowController {
    static let shared = DesktopVoiceWindowController()

    private static let frameKey = "DesktopVoicePanelPersistedFrame"
    private let coordinator = DesktopVoiceCoordinator.shared
    private let panel = FloatingPanel()
    private let hosting: NSHostingController<DesktopVoicePanelView>
    private var frameObservers: [NSObjectProtocol] = []

    private init() {
        hosting = NSHostingController(rootView: DesktopVoicePanelView(coordinator: coordinator))
        hosting.sizingOptions = []
        panel.contentViewController = hosting
        panel.installResizeTracking()
        panel.title = "BtrVoice Voice Control"
        panel.setFrameAutosaveName("BtrVoiceDesktopVoicePanel")
        panel.onCancel = { [weak self] in self?.stopAndHide() }
        panel.onFrameChangeFinished = { [weak self] in self?.saveFrame() }

        if let saved = UserDefaults.standard.string(forKey: Self.frameKey) {
            let frame = NSRectFromString(saved)
            if frame.width >= 340, frame.height >= 190 {
                panel.setFrame(frame, display: false)
            }
        } else {
            panel.setContentSize(NSSize(width: 520, height: 290))
        }
        panel.contentMinSize = NSSize(width: 340, height: 190)
        panel.minSize = NSSize(width: 340, height: 190)

        for name in [NSWindow.didMoveNotification, NSWindow.didResizeNotification] {
            frameObservers.append(NotificationCenter.default.addObserver(
                forName: name,
                object: panel,
                queue: .main
            ) { [weak self] _ in self?.saveFrame() })
        }
    }

    deinit {
        for observer in frameObservers {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    var isVisible: Bool { panel.isVisible }

    func show(target: NSRunningApplication?, startListening: Bool) {
        coordinator.setTarget(target)
        if !panel.isVisible {
            if UserDefaults.standard.string(forKey: Self.frameKey) == nil {
                positionAtBottomCentre()
            }
            panel.orderFrontRegardless()
        }
        if startListening {
            coordinator.start(target: target)
        }
    }

    func hide() {
        panel.orderOut(nil)
    }

    func stopAndHide() {
        coordinator.stop()
        hide()
    }

    private func positionAtBottomCentre() {
        let screen = NSScreen.screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) })
            ?? NSScreen.main
        guard let visible = screen?.visibleFrame else { return }
        let frame = panel.frame
        panel.setFrameOrigin(NSPoint(
            x: visible.midX - frame.width / 2,
            y: visible.minY + 24
        ))
    }

    private func saveFrame() {
        UserDefaults.standard.set(NSStringFromRect(panel.frame), forKey: Self.frameKey)
    }
}
