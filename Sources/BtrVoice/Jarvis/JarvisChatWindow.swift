import AppKit
import SwiftUI
#if canImport(FoundationModels)
import FoundationModels
#endif

/// A testing window for talking to the on-device model directly — raw
/// multi-turn chat, no Jarvis persona, no notes, no sanitising. What the model
/// says is exactly what you see.
@available(macOS 26.0, *)
@MainActor
final class JarvisChatModel: ObservableObject {
    struct Turn: Identifiable, Equatable {
        let id = UUID()
        let isUser: Bool
        var text: String
    }

    @Published var turns: [Turn] = []
    @Published var busy = false

    #if canImport(FoundationModels)
    private var session = LanguageModelSession()
    #endif

    func send(_ prompt: String) {
        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !busy else { return }
        turns.append(Turn(isUser: true, text: trimmed))
        busy = true
        Task {
            defer { busy = false }
            #if canImport(FoundationModels)
            do {
                let reply = try await session.respond(to: trimmed).content
                turns.append(Turn(isUser: false, text: reply))
            } catch {
                turns.append(Turn(isUser: false, text: "⚠️ \(error.localizedDescription)"))
            }
            #endif
        }
    }

    /// Fresh session: the model forgets the conversation.
    func reset() {
        #if canImport(FoundationModels)
        session = LanguageModelSession()
        #endif
        turns.removeAll()
    }
}

@available(macOS 26.0, *)
struct JarvisChatView: View {
    @ObservedObject var model: JarvisChatModel
    @State private var input = ""

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        if model.turns.isEmpty {
                            Text("Raw chat with the on-device Apple Intelligence model. No Jarvis persona, no saved notes — exactly what the model says, multi-turn.")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                                .padding(.top, 8)
                        }
                        ForEach(model.turns) { turn in
                            HStack {
                                if turn.isUser { Spacer(minLength: 40) }
                                Text(turn.text)
                                    .font(.system(size: 12.5))
                                    .textSelection(.enabled)
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 7)
                                    .background(
                                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                                            .fill(turn.isUser ? Color.accentColor.opacity(0.25) : Color.primary.opacity(0.07))
                                    )
                                if !turn.isUser { Spacer(minLength: 40) }
                            }
                            .id(turn.id)
                        }
                        if model.busy {
                            HStack(spacing: 6) {
                                ProgressView().controlSize(.small)
                                Text("Thinking…").font(.system(size: 11)).foregroundStyle(.secondary)
                            }
                        }
                    }
                    .padding(12)
                }
                .onChange(of: model.turns) {
                    if let last = model.turns.last {
                        withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
                    }
                }
            }

            Divider()

            HStack(spacing: 8) {
                TextField("Ask the model anything…", text: $input)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { submit() }
                Button("Send") { submit() }
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(model.busy || input.trimmingCharacters(in: .whitespaces).isEmpty)
                Button("Reset") { model.reset() }
                    .disabled(model.turns.isEmpty && !model.busy)
                    .help("Start a fresh session — the model forgets this conversation")
            }
            .padding(10)
        }
        .frame(minWidth: 420, minHeight: 320)
    }

    private func submit() {
        model.send(input)
        input = ""
    }
}

/// Owns the chat window so the menu can summon it repeatedly.
@MainActor
final class JarvisChatWindowController {
    static let shared = JarvisChatWindowController()
    private var window: NSWindow?

    func show() {
        guard #available(macOS 26.0, *) else { return }
        if let window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let model = JarvisChatModel()
        let hosting = NSHostingController(rootView: JarvisChatView(model: model))
        let win = NSWindow(contentViewController: hosting)
        win.title = "On-Device AI — Test Chat"
        win.setContentSize(NSSize(width: 480, height: 400))
        win.styleMask = [.titled, .closable, .resizable]
        win.isReleasedWhenClosed = false
        win.center()
        window = win
        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
