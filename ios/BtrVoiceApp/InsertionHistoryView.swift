// A durable record of text explicitly inserted from the Better Voice keyboard.

import SwiftUI

struct InsertionHistoryView: View {
  let onRestore: (SharedInsertionHistoryEntry) -> Void

  @Environment(\.dismiss) private var dismiss
  @State private var entries: [SharedInsertionHistoryEntry] = []
  @State private var confirmingClear = false

  var body: some View {
    NavigationStack {
      Group {
        if entries.isEmpty {
          ContentUnavailableView(
            "No Insert History",
            systemImage: "clock.arrow.circlepath",
            description: Text("Text appears here after you tap Insert in the Better Voice keyboard.")
          )
        } else {
          List {
            Section {
              ForEach(entries) { entry in
                Button {
                  onRestore(entry)
                  dismiss()
                } label: {
                  VStack(alignment: .leading, spacing: 7) {
                    Text(entry.text)
                      .foregroundStyle(.primary)
                      .multilineTextAlignment(.leading)
                      .lineLimit(5)
                    Text(entry.insertedAt, format: .dateTime.month().day().hour().minute())
                      .font(.caption)
                      .foregroundStyle(.secondary)
                  }
                  .frame(maxWidth: .infinity, alignment: .leading)
                  .padding(.vertical, 3)
                }
                .buttonStyle(.plain)
                .accessibilityHint("Restores this text as the current Better Voice draft")
                .swipeActions {
                  Button(role: .destructive) {
                    SharedTranscriptStore.deleteInsertionHistoryEntry(id: entry.id)
                    reload()
                  } label: {
                    Label("Delete", systemImage: "trash")
                  }
                }
              }
            } header: {
              Text("Tap an entry to restore it as the current draft")
            }
          }
        }
      }
      .navigationTitle("Insert History")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Done") { dismiss() }
        }
        ToolbarItem(placement: .primaryAction) {
          Button(role: .destructive) {
            confirmingClear = true
          } label: {
            Image(systemName: "trash")
          }
          .disabled(entries.isEmpty)
          .accessibilityLabel("Clear insert history")
        }
      }
      .confirmationDialog(
        "Clear all insert history?",
        isPresented: $confirmingClear,
        titleVisibility: .visible
      ) {
        Button("Clear History", role: .destructive) {
          SharedTranscriptStore.clearInsertionHistory()
          reload()
        }
        Button("Cancel", role: .cancel) {}
      } message: {
        Text("This cannot be undone.")
      }
      .onAppear(perform: reload)
    }
  }

  private func reload() {
    entries = SharedTranscriptStore.loadInsertionHistory()
  }
}
