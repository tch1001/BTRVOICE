import AppKit
import SwiftUI

/// The rules Jarvis and the GPT Editor live by — a real management UI, not a
/// menu. Edit a wrong rule in place (bumping its version), instead of deleting
/// and re-teaching; every save keeps the superseded text in the rule's history.
struct JarvisNotesView: View {
    @ObservedObject var store: JarvisNotes
    @State private var editingID: UUID?
    @State private var draft = ""

    private static let stamp: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        return formatter
    }()

    var body: some View {
        VStack(spacing: 0) {
            if store.notes.isEmpty {
                Text("No rules yet. Say “Jarvis, remember …” while dictating, or teach the GPT Editor a pattern — everything lands here.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(20)
            } else {
                List {
                    ForEach(Array(store.notes.enumerated()), id: \.element.id) { number, note in
                        row(number: number + 1, note: note)
                            .padding(.vertical, 3)
                    }
                }
            }

            Divider()
            HStack {
                Text("\(store.notes.count) rule\(store.notes.count == 1 ? "" : "s")")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Delete All…") {
                    let alert = NSAlert()
                    alert.messageText = "Delete all rules?"
                    alert.informativeText = "Jarvis and the GPT Editor will forget everything they've been taught. This cannot be undone."
                    alert.addButton(withTitle: "Delete All")
                    alert.addButton(withTitle: "Cancel")
                    if alert.runModal() == .alertFirstButtonReturn {
                        store.deleteAll()
                    }
                }
                .disabled(store.notes.isEmpty)
            }
            .padding(10)
        }
        .frame(minWidth: 420, minHeight: 300)
    }

    @ViewBuilder
    private func row(number: Int, note: JarvisNote) -> some View {
        if editingID == note.id {
            VStack(alignment: .leading, spacing: 6) {
                TextField("Rule text", text: $draft, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12.5))
                    .lineLimit(2...8)
                HStack {
                    Spacer()
                    Button("Cancel") { editingID = nil }
                        .keyboardShortcut(.escape, modifiers: [])
                    Button("Save as v\(note.version + 1)") {
                        store.update(id: note.id, text: draft)
                        editingID = nil
                    }
                    .keyboardShortcut(.return, modifiers: .command)
                    .buttonStyle(.borderedProminent)
                    .disabled(draft.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                .controlSize(.small)
            }
        } else {
            HStack(alignment: .top, spacing: 10) {
                Text("\(number).")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .padding(.top, 1)
                VStack(alignment: .leading, spacing: 2) {
                    Text(note.text)
                        .font(.system(size: 12.5))
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 6) {
                        Text("v\(note.version)")
                            .font(.system(size: 9.5, weight: .semibold, design: .monospaced))
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(RoundedRectangle(cornerRadius: 3).fill(Color.accentColor.opacity(0.18)))
                        Text(Self.stamp.string(from: note.updatedAt))
                            .font(.system(size: 10))
                            .foregroundStyle(.tertiary)
                        if !note.history.isEmpty {
                            Text("↺ \(note.history.count) earlier version\(note.history.count == 1 ? "" : "s")")
                                .font(.system(size: 10))
                                .foregroundStyle(.tertiary)
                                .help(note.history.enumerated()
                                    .map { "v\($0.offset + 1): \($0.element)" }
                                    .joined(separator: "\n"))
                        }
                    }
                }
                Spacer(minLength: 8)
                Button {
                    draft = note.text
                    editingID = note.id
                } label: {
                    Image(systemName: "pencil")
                }
                .buttonStyle(.borderless)
                .help("Edit this rule (saves as v\(note.version + 1))")
                Button {
                    store.delete(id: note.id)
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
                .help("Delete this rule")
            }
        }
    }
}

@MainActor
final class JarvisNotesWindowController {
    static let shared = JarvisNotesWindowController()
    private var window: NSWindow?

    func show() {
        if let window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let hosting = NSHostingController(rootView: JarvisNotesView(store: .shared))
        let win = NSWindow(contentViewController: hosting)
        win.title = "Jarvis Rules"
        win.setContentSize(NSSize(width: 480, height: 380))
        win.styleMask = [.titled, .closable, .resizable]
        win.isReleasedWhenClosed = false
        win.center()
        window = win
        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
