import AppKit
import SwiftUI

/// Hosts Jarvis Voice as a compact native SwiftUI console.
///
/// Only the conversation scrolls. Voice controls, the owner filter, output mode, and
/// a small current-work summary stay visible in one quarter-screen window.
struct JarvisSurfaceView: View {
    @ObservedObject var service: JarvisVoiceService
    @ObservedObject var controller: JarvisVoiceController

    var body: some View {
        ZStack {
            Color(nsColor: .windowBackgroundColor).ignoresSafeArea()
            switch service.state {
            case .ready:
                JarvisNativeConsole(controller: controller)
                    .onAppear { controller.boot() }
            case .idle, .starting:
                startupView
            case .failed(let message):
                failureView(message)
            }
        }
        .frame(minWidth: 650, minHeight: 500)
        .onAppear { service.ensureRunning() }
    }

    private var startupView: some View {
        VStack(spacing: 12) {
            ProgressView().controlSize(.large)
            Text("Starting Jarvis Voice")
                .font(.title3.weight(.semibold))
            Text(service.statusMessage)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(28)
    }

    private func failureView(_ message: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "waveform.slash")
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(.orange)
            Text("Jarvis Voice could not start")
                .font(.title3.weight(.semibold))
            Text(message)
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .textSelection(.enabled)
                .frame(maxWidth: 500)
            HStack {
                Button("Retry") { service.retry() }
                    .keyboardShortcut(.defaultAction)
                Button("Open Log") { NSWorkspace.shared.open(Log.fileURL) }
            }
        }
        .padding(28)
    }
}

private struct JarvisNativeConsole: View {
    @ObservedObject var controller: JarvisVoiceController
    @State private var draft = ""
    @State private var showingAudioRoute = false

    var body: some View {
        HStack(spacing: 0) {
            controlRail
                .frame(width: 226)
            Divider()
            conversation
        }
        .background {
            LinearGradient(
                colors: [Color(nsColor: .windowBackgroundColor), Color.accentColor.opacity(0.025)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        }
    }

    private var controlRail: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                ZStack {
                    Circle().fill(Color.accentColor.opacity(0.15))
                    Image(systemName: "waveform")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Color.accentColor)
                }
                .frame(width: 28, height: 28)
                VStack(alignment: .leading, spacing: 0) {
                    Text("JARVIS").font(.system(size: 11, weight: .bold, design: .rounded))
                    Text("Native voice console").font(.system(size: 9)).foregroundStyle(.secondary)
                }
                Spacer()
                Circle()
                    .fill(phaseColor)
                    .frame(width: 7, height: 7)
                    .shadow(color: phaseColor.opacity(0.6), radius: 4)
            }

            VStack(spacing: 8) {
                Button(action: controller.toggleConnection) {
                    ZStack {
                        Circle()
                            .stroke(Color.accentColor.opacity(0.12), lineWidth: 10)
                            .frame(width: 112, height: 112)
                        Circle()
                            .fill(
                                RadialGradient(
                                    colors: [Color.accentColor.opacity(0.28), Color.accentColor.opacity(0.08)],
                                    center: .center,
                                    startRadius: 5,
                                    endRadius: 56
                                )
                            )
                            .overlay(Circle().stroke(Color.accentColor.opacity(0.35), lineWidth: 1))
                            .frame(width: 92, height: 92)
                        VStack(spacing: 4) {
                            Image(systemName: controller.connected ? "waveform.circle.fill" : "play.fill")
                                .font(.system(size: 24, weight: .medium))
                            Text(controller.connected ? "Live" : "Start")
                                .font(.system(size: 11, weight: .semibold))
                        }
                        .foregroundStyle(Color.primary)
                    }
                }
                .buttonStyle(.plain)
                .accessibilityLabel(controller.connected ? "Stop voice session" : "Start voice session")

                Text(controller.phase.label)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(phaseColor)
                Text(controller.activity)
                    .font(.system(size: 9.5))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .frame(height: 25)

                JarvisMicrophoneMeterView(
                    meter: controller.microphoneMeter,
                    muted: controller.muted
                )
                .frame(height: 4)
            }
            .frame(maxWidth: .infinity)

            HStack(spacing: 6) {
                compactButton(
                    controller.muted ? "mic.slash.fill" : "mic.fill",
                    label: controller.muted ? "Unmute" : "Mute",
                    disabled: !controller.connected,
                    action: controller.toggleMute
                )
                compactButton(
                    controller.paused ? "play.fill" : "pause.fill",
                    label: controller.paused ? "Resume" : "Pause",
                    disabled: !controller.connected,
                    action: controller.togglePause
                )
                compactButton(
                    "stop.fill",
                    label: "Stop reply",
                    disabled: !controller.connected,
                    tint: .red,
                    action: controller.stopResponse
                )
            }

            HStack(spacing: 6) {
                Picker("Output", selection: $controller.outputMode) {
                    ForEach(JarvisVoiceOutputMode.allCases) { mode in
                        Text(mode.label).tag(mode)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .frame(maxWidth: .infinity)

                Button {
                    showingAudioRoute.toggle()
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "hifispeaker.and.homepodmini")
                        Circle()
                            .fill(controller.audioRouteAvailable ? Color.green : Color.orange)
                            .frame(width: 5, height: 5)
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help("Choose microphone and speakers")
                .popover(isPresented: $showingAudioRoute, arrowEdge: .trailing) {
                    audioRoutePopover
                }
            }

            speakerCard

            Divider()

            VStack(alignment: .leading, spacing: 5) {
                HStack {
                    Label("Current work", systemImage: "checklist")
                        .font(.system(size: 10, weight: .semibold))
                    Spacer()
                    Button {
                        Task { await controller.refreshTasks() }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .buttonStyle(.plain)
                    .help("Refresh current work")
                }
                Text(controller.taskSummary)
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                ForEach(controller.tasks.prefix(3)) { task in
                    HStack(spacing: 5) {
                        Circle()
                            .fill(priorityColor(task.priority))
                            .frame(width: 5, height: 5)
                        Text(task.summary)
                            .font(.system(size: 9.5))
                            .lineLimit(1)
                        Spacer(minLength: 2)
                        Text(task.state)
                            .font(.system(size: 8))
                            .foregroundStyle(.tertiary)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Spacer(minLength: 0)

            Text("\(controller.nodeName) · \(controller.modelName)")
                .font(.system(size: 8.5))
                .foregroundStyle(.tertiary)
                .lineLimit(1)
        }
        .padding(12)
    }

    private var audioRoutePopover: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Jarvis audio route")
                        .font(.headline)
                    Text("App-specific devices; macOS defaults stay unchanged.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    controller.rescanAudioDevices()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.plain)
                .help("Refresh audio devices")
            }

            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 9) {
                GridRow {
                    Label("Microphone", systemImage: "mic")
                        .font(.caption)
                    Picker("Microphone", selection: Binding(
                        get: { controller.selectedInputUID },
                        set: { controller.selectInputDevice($0) }
                    )) {
                        ForEach(controller.inputDevices) { device in
                            Text(device.pickerLabel(forInput: true)).tag(device.uid)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 215)
                }
                GridRow {
                    Label("Speakers", systemImage: "speaker.wave.2")
                        .font(.caption)
                    Picker("Speakers", selection: Binding(
                        get: { controller.selectedOutputUID },
                        set: { controller.selectOutputDevice($0) }
                    )) {
                        ForEach(controller.outputDevices) { device in
                            Text(device.pickerLabel(forInput: false)).tag(device.uid)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 215)
                }
            }
            Toggle("Keep music playing", isOn: $controller.keepOtherAudioPlaying)
                .font(.caption)
                .disabled(controller.connected)

            HStack(alignment: .top, spacing: 7) {
                Image(systemName: controller.audioRouteAvailable
                    ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .foregroundStyle(controller.audioRouteAvailable ? Color.green : Color.orange)
                Text(controller.audioRouteGuidance)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if !controller.echoRouteLikelyCompatible,
               let recommendation = controller.recommendedInputDevice {
                Button("Select \(recommendation.name)") {
                    controller.useRecommendedEchoRoute()
                }
            }

            if controller.echoCancellationReady {
                Label("Apple echo cancellation available", systemImage: "waveform.badge.mic")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            if let detail = controller.audioIssueDetail {
                Text("Last audio issue: \(detail)")
                    .font(.caption2)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Text(controller.connected
                ? "Changing either device restarts only Jarvis audio; the conversation stays connected."
                : "Jarvis will not change the microphone or speakers used by other apps.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(14)
        .frame(width: 365)
    }

    private var speakerCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 5) {
                Image(systemName: controller.speakerEnabled && controller.speakerHasProfile
                    ? "person.wave.2.fill"
                    : "person.wave.2")
                    .foregroundStyle(controller.speakerEnabled && controller.speakerHasProfile
                        ? Color.green : Color.secondary)
                Text("My voice only")
                    .font(.system(size: 10, weight: .semibold))
                Spacer()
                if controller.speakerBusy {
                    ProgressView().controlSize(.mini)
                } else {
                    Text(controller.speakerHasProfile
                        ? (controller.speakerEnabled ? "ON" : "OFF")
                        : "SETUP")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(controller.speakerEnabled && controller.speakerHasProfile
                            ? Color.green : Color.secondary)
                }
            }
            Text(controller.speakerDetail)
                .font(.system(size: 8.5))
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .frame(height: 22, alignment: .topLeading)
            if controller.speakerPhase == "enrolling" {
                ProgressView(value: controller.enrollmentProgress)
                    .controlSize(.small)
            }
            HStack(spacing: 7) {
                Button(controller.speakerHasProfile ? "Re-enroll" : "Enroll") {
                    controller.beginSpeakerEnrollment()
                }
                .disabled(!controller.connected || controller.speakerBusy)
                if controller.speakerHasProfile {
                    Button(controller.speakerEnabled ? "Turn off" : "Turn on") {
                        controller.toggleSpeakerFilter()
                    }
                    .disabled(controller.speakerBusy)
                    Button {
                        controller.forgetSpeakerProfile()
                    } label: {
                        Image(systemName: "trash")
                    }
                    .buttonStyle(.plain)
                    .disabled(controller.speakerBusy)
                    .help("Forget saved voice")
                }
            }
            .font(.system(size: 9))
            .buttonStyle(.borderless)
        }
        .padding(9)
        .background(Color.secondary.opacity(0.055), in: RoundedRectangle(cornerRadius: 10))
        .overlay {
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color.secondary.opacity(0.1), lineWidth: 1)
        }
    }

    private var conversation: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 5) {
                HStack {
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Conversation")
                            .font(.system(size: 15, weight: .semibold))
                        Text("Telegram, TUI, and Voice history")
                            .font(.system(size: 9))
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    if !controller.bridgeOnline {
                        Label("Reconnecting", systemImage: "arrow.triangle.2.circlepath")
                            .font(.system(size: 9, weight: .medium))
                            .foregroundStyle(.orange)
                    }
                }
                if let notice = controller.restartNotice ?? controller.catchupNotice {
                    HStack(spacing: 5) {
                        Image(systemName: "info.circle.fill")
                        Text(notice).lineLimit(2)
                    }
                    .font(.system(size: 9.5))
                    .foregroundStyle(Color.accentColor)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(Color.accentColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 7))
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)

            Divider()

            if controller.outputMode.showsCaptions {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 8) {
                            if controller.messages.isEmpty {
                                ContentUnavailableView(
                                    "No conversation yet",
                                    systemImage: "bubble.left.and.bubble.right",
                                    description: Text("Start Voice or type below.")
                                )
                                .frame(maxWidth: .infinity, minHeight: 290)
                            }
                            ForEach(controller.messages) { message in
                                conversationRow(message)
                                    .id(message.id)
                            }
                        }
                        .padding(14)
                    }
                    .onChange(of: controller.messages.count) { _, _ in
                        if let last = controller.messages.last?.id {
                            withAnimation(.easeOut(duration: 0.18)) {
                                proxy.scrollTo(last, anchor: .bottom)
                            }
                        }
                    }
                }
            } else {
                VStack(spacing: 10) {
                    Image(systemName: "waveform.circle")
                        .font(.system(size: 36, weight: .light))
                        .foregroundStyle(Color.accentColor)
                    Text("Voice-only mode")
                        .font(.headline)
                    Text("The shared transcript is still being saved. Switch Output to Voice + text whenever you want to see it.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 300)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            Divider()

            HStack(spacing: 8) {
                TextField("Type when speaking is not convenient", text: $draft)
                    .textFieldStyle(.plain)
                    .onSubmit(sendDraft)
                Button(action: sendDraft) {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.system(size: 20))
                }
                .buttonStyle(.plain)
                .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(Color.secondary.opacity(0.035))
        }
    }

    @ViewBuilder
    private func conversationRow(_ message: JarvisVoiceMessage) -> some View {
        if message.role == .system {
            Text(message.text)
                .font(.system(size: 9.5))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 3)
        } else {
            HStack {
                if message.role == .user { Spacer(minLength: 50) }
                VStack(alignment: .leading, spacing: 4) {
                    Text(message.role == .assistant ? "Jarvis" : "You")
                        .font(.system(size: 8.5, weight: .semibold))
                        .foregroundStyle(.secondary)
                    Text(message.text)
                        .font(.system(size: 11.5))
                        .textSelection(.enabled)
                    if !message.detail.isEmpty {
                        Text(message.detail)
                            .font(.system(size: 8))
                            .foregroundStyle(.tertiary)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .background(
                    message.role == .user ? Color.accentColor.opacity(0.13) : Color.secondary.opacity(0.075),
                    in: RoundedRectangle(cornerRadius: 11)
                )
                if message.role == .assistant { Spacer(minLength: 50) }
            }
        }
    }

    private func compactButton(
        _ icon: String,
        label: String,
        disabled: Bool,
        tint: Color = .primary,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .frame(maxWidth: .infinity)
                .frame(height: 24)
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .tint(tint)
        .disabled(disabled)
        .help(label)
    }

    private func sendDraft() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        draft = ""
        controller.submitText(text)
    }

    private var phaseColor: Color {
        switch controller.phase {
        case .ready, .listening: return .green
        case .connecting, .loadingFilter, .working: return .orange
        case .error: return .red
        case .offline: return .secondary
        }
    }

    private func priorityColor(_ priority: String) -> Color {
        switch priority {
        case "urgent": return .red
        case "high": return .orange
        case "low": return .secondary
        default: return .blue
        }
    }
}

/// The only view invalidated by the roughly 24 Hz input-level stream.
private struct JarvisMicrophoneMeterView: View {
    @ObservedObject var meter: JarvisMicrophoneMeter
    let muted: Bool

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.secondary.opacity(0.12))
                Capsule()
                    .fill(muted ? Color.secondary : Color.accentColor)
                    .frame(width: max(3, proxy.size.width * CGFloat(meter.level)))
            }
        }
    }
}

/// Owns one native window and one native voice controller at a time.
@MainActor
final class JarvisSurfaceWindowController: NSObject, NSWindowDelegate {
    static let shared = JarvisSurfaceWindowController()

    private var window: NSWindow?
    private var voiceController: JarvisVoiceController?

    func show() {
        if let window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let service = JarvisVoiceService.shared
        let voice = JarvisVoiceController(baseURL: service.pageURL)
        voiceController = voice
        let hosting = NSHostingController(rootView: JarvisSurfaceView(
            service: service,
            controller: voice
        ))
        let window = NSWindow(contentViewController: hosting)
        window.title = "Jarvis Voice"
        window.setContentSize(NSSize(width: 720, height: 550))
        window.minSize = NSSize(width: 650, height: 500)
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.center()
        self.window = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func windowWillClose(_ notification: Notification) {
        voiceController?.shutdown()
        voiceController = nil
        window = nil
    }
}
