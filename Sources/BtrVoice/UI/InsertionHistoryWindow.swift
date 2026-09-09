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
                HistoryActionButton(title: "Clear History…", destructive: true) {
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
            return "Retry actions type into \(name). Click the destination field, then click Insert here—no need to focus this window."
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
                HistoryActionButton(title: "Insert", symbol: "text.insert") {
                    controller.reinsertHistory(entry, send: false)
                }
                HistoryActionButton(title: "Insert & Send", symbol: "paperplane", prominent: true) {
                    controller.reinsertHistory(entry, send: true)
                }
            }
            .controlSize(.small)
            .disabled(!controller.canReinsertHistory)
            .help(controller.canReinsertHistory
                  ? "Insert this saved text into the destination app without changing your current dictation."
                  : "Wait for the current insertion, finalization, or command to finish.")
        }
        .padding(.vertical, 7)
    }
}

/// A non-activating utility panel keeps the destination app's insertion caret live
/// while history remains visible above it, matching the dictation overlay.
final class InsertionHistoryPanel: NSPanel {
    init(contentViewController: NSViewController) {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 760, height: 600),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        self.contentViewController = contentViewController
        isFloatingPanel = true
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = true
        isReleasedWhenClosed = false
        animationBehavior = .utilityWindow
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// Owns the floating history panel without changing the current target app.
final class InsertionHistoryWindowController {
    static let shared = InsertionHistoryWindowController()

    private var window: InsertionHistoryPanel?

    private init() {}

    func releaseFocus() {
        window?.makeFirstResponder(nil)
        if window?.isKeyWindow == true { window?.resignKey() }
    }

    func show(controller: DictationController) {
        if window == nil {
            let root = InsertionHistoryView(store: .shared, controller: controller)
            let hosting = NSHostingController(rootView: root)
            let created = InsertionHistoryPanel(contentViewController: hosting)
            created.title = "BtrVoice Insertion History"
            created.setContentSize(NSSize(width: 760, height: 600))
            created.minSize = NSSize(width: 680, height: 500)
            created.center()
            window = created
        }

        window?.orderFrontRegardless()
    }
}
