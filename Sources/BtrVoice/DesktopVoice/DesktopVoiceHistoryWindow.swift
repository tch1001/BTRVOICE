/// Presents saved conversation as readable, searchable turns without replaying
/// actions or changing the user's current desktop target.
import AppKit
import SwiftUI

private struct DesktopVoiceHistoryView: View {
    @ObservedObject var store: DesktopVoiceHistoryStore
    @State var query: String
    @State private var copied = false
    var close: () -> Void

    private var matches: [DesktopVoiceHistoryEntry] { store.search(query) }
    private var orderedEntries: [DesktopVoiceHistoryEntry] {
        let groups = Dictionary(grouping: matches, by: \.turnID)
        var seen = Set<UUID>()
        return matches.reversed().filter { seen.insert($0.turnID).inserted }
            .flatMap { groups[$0.turnID] ?? [] }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Voice Control History").font(.title2.bold())
                    .background(HistoryDragHandle())
                Spacer()
                Button("Copy conversation", systemImage: "doc.on.doc") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(store.transcript(query: query, maxCharacters: 100_000), forType: .string)
                    copied = true
                }
                .disabled(matches.isEmpty)
                Button(action: close) { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.plain).help("Close history")
            }
            TextField("Search transcripts, replies, or applications", text: $query)
                .textFieldStyle(.roundedBorder)
            if let error = store.saveError { Text(error).font(.caption).foregroundStyle(.orange) }
            if matches.isEmpty {
                ContentUnavailableView("No saved transcripts", systemImage: "text.bubble",
                    description: Text("New Voice Control conversations are saved here. Earlier conversations weren't recorded."))
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 14) {
                        ForEach(orderedEntries) { entry in
                            VStack(alignment: .leading, spacing: 5) {
                                HStack {
                                    Text(label(entry.kind)).font(.caption.bold())
                                    Text(entry.at.formatted(date: .abbreviated, time: .shortened))
                                        .font(.caption).foregroundStyle(.secondary)
                                    if let target = entry.target { Text(target).font(.caption).foregroundStyle(.secondary) }
                                    Spacer()
                                    Button {
                                        NSPasteboard.general.clearContents()
                                        NSPasteboard.general.setString(entry.text, forType: .string)
                                    } label: { Image(systemName: "doc.on.doc") }
                                    .buttonStyle(.plain).help("Copy this transcript")
                                }
                                Group {
                                    if entry.kind == .assistant {
                                        DesktopVoiceReplyText(entry.text)
                                            .equatable()
                                    } else {
                                        Text(entry.text)
                                    }
                                }
                                .textSelection(.enabled)
                                if let detail = entry.detail {
                                    Text(detail).font(.caption).foregroundStyle(.secondary)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(10)
                            .background(entry.kind == .user ? Color.accentColor.opacity(0.08) : Color.secondary.opacity(0.06),
                                        in: RoundedRectangle(cornerRadius: 8))
                        }
                    }
                }
            }
            HStack {
                Text(copied ? "Conversation copied." : "Saved on this Mac. Clearing the live panel keeps history.")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Diagnostics") {
                    store.trace.flush()
                    NSWorkspace.shared.activateFileViewerSelecting([store.trace.fileURL])
                }.help("Local request/response and Accessibility traces. May contain private page or chat text.")
                Button("Show saved files") { NSWorkspace.shared.activateFileViewerSelecting([store.directory]) }
            }
        }
        .padding(18)
        .frame(minWidth: 560, minHeight: 360)
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private func label(_ kind: DesktopVoiceHistoryEntry.Kind) -> String {
        switch kind {
        case .user: return "You"
        case .assistant: return "BtrVoice"
        case .plan: return "Requested action"
        case .result: return "Action result"
        case .failure: return "Error"
        case .interrupted: return "Interrupted"
        case .contextReset: return "New conversation"
        case .observation: return "Result check"
        }
    }
}

final class DesktopVoiceHistoryWindowController {
    static let shared = DesktopVoiceHistoryWindowController()
    private var panel: FloatingPanel?

    func show(query: String = "") {
        if panel == nil {
            let created = FloatingPanel()
            created.title = "BtrVoice Voice Control History"
            created.setContentSize(NSSize(width: 680, height: 540))
            created.contentMinSize = NSSize(width: 560, height: 360)
            created.installResizeTracking()
            created.center()
            created.onCancel = { [weak created] in created?.orderOut(nil) }
            panel = created
        }
        panel?.contentViewController = NSHostingController(rootView:
            DesktopVoiceHistoryView(store: .shared, query: query, close: { [weak self] in self?.panel?.orderOut(nil) }))
        panel?.orderFrontRegardless()
    }
}

private struct HistoryDragHandle: NSViewRepresentable {
    final class DragView: NSView {
        override var needsPanelToBecomeKey: Bool { false }
        override func mouseDown(with event: NSEvent) { window?.performDrag(with: event) }
    }
    func makeNSView(context: Context) -> DragView { DragView() }
    func updateNSView(_ nsView: DragView, context: Context) {}
}
