import AppKit
import SwiftUI

/// Lets a user recover any finalized text that previously crossed the Insert
/// boundary, without exposing live drafts or requiring another dictation pass.
private struct InsertionHistoryView: View {
    @ObservedObject var store: InsertionHistoryStore
    @ObservedObject var controller: DictationController
    @ObservedObject var targets: TargetTracker

    @State private var confirmingClear = false
    @State private var errorMessage: String?

    init(store: InsertionHistoryStore, controller: DictationController) {
        self.store = store
        self.controller = controller
        self.targets = controller.targets
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 5) {
                Text("Insertion History")
                    .font(.title2.weight(.semibold))
                Text(targetDescription)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .padding(20)

            Divider()

            if store.entries.isEmpty {
                ContentUnavailableView(
                    "No Insertions Yet",
                    systemImage: "clock.arrow.circlepath",
                    description: Text("Text appears here after you choose Insert or Insert & Send.")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(store.entries) { entry in
                    entryRow(entry)
                }
                .listStyle(.inset)
            }

            Divider()

            HStack {
                Text("Newest \(InsertionHistoryStore.defaultMaximumEntries) insertions are kept on this Mac.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Clear History…", role: .destructive) {
                    confirmingClear = true
                }
                .disabled(store.entries.isEmpty)
            }
            .padding(14)
        }
        .frame(minWidth: 680, minHeight: 500)
        .alert("Clear insertion history?", isPresented: $confirmingClear) {
            Button("Cancel", role: .cancel) {}
            Button("Clear All", role: .destructive) {
                do {
                    try store.clear()
                } catch {
                    errorMessage = error.localizedDescription
                }
            }
        } message: {
            Text("This permanently removes every saved insertion from this Mac.")
        }
        .alert("Couldn't clear history", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("OK") { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "Unknown error")
        }
    }

    private var targetDescription: String {
        if let name = targets.targetName {
            return "Retry actions type into \(name). To change it, focus another app, then return here."
        }
        return "Focus the destination app before retrying an insertion."
    }

    private func entryRow(_ entry: InsertionHistoryEntry) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(alignment: .firstTextBaseline) {
                Label(entry.action.label, systemImage: entry.sendsAfterInsertion ? "paperplane" : "text.insert")
                    .font(.caption.weight(.medium))
                Text("·")
                    .foregroundStyle(.tertiary)
                Text(entry.createdAt.formatted(date: .abbreviated, time: .shortened))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let targetName = entry.targetName {
                    Text("· originally \(targetName)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }

            Text(entry.text)
                .font(.body)
                .lineLimit(5)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)

            HStack {
                Spacer()
                Button("Insert", systemImage: "text.insert") {
                    controller.reinsertHistory(entry, send: false)
                }
                Button("Insert & Send", systemImage: "paperplane") {
                    controller.reinsertHistory(entry, send: true)
                }
                .buttonStyle(.borderedProminent)
            }
            .controlSize(.small)
            .disabled(controller.phase != .idle)
        }
        .padding(.vertical, 7)
    }
}

/// Owns the ordinary, activating history window. Activating BtrVoice does not
/// overwrite TargetTracker, so retry can still restore the last external app.
final class InsertionHistoryWindowController {
    static let shared = InsertionHistoryWindowController()

    private var window: NSWindow?

    private init() {}

    func show(controller: DictationController) {
        if window == nil {
            let root = InsertionHistoryView(store: .shared, controller: controller)
            let hosting = NSHostingController(rootView: root)
            let created = NSWindow(contentViewController: hosting)
            created.title = "BtrVoice Insertion History"
            created.styleMask = [.titled, .closable, .miniaturizable, .resizable]
            created.setContentSize(NSSize(width: 760, height: 600))
            created.minSize = NSSize(width: 680, height: 500)
            created.isReleasedWhenClosed = false
            created.center()
            window = created
        }

        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}
