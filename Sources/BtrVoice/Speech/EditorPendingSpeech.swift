import Foundation

/// Tracks recognition by audio item. Finishing an older editor response must not
/// consume a newer utterance, and late transcription must not resurrect old words.
struct EditorPendingSpeech {
    private struct Item {
        let id: String
        var text = ""
        var ended = false
    }
    private var items: [Item] = []
    private var resolved: [String] = []
    private var currentID: String?
    private var responseIDs = Set<String>()

    var text: String { joined(items) }
    var responseText: String { joined(items.filter { responseIDs.contains($0.id) }) }

    mutating func started(id: String?) {
        let id = id ?? UUID().uuidString
        currentID = id
        ensure(id)
    }

    mutating func stopped(id: String?) {
        let id = id ?? currentID ?? UUID().uuidString
        ensure(id)
        if let index = items.firstIndex(where: { $0.id == id }) { items[index].ended = true }
    }

    mutating func transcribed(id: String?, text: String, completed: Bool) {
        let id = id ?? currentID ?? UUID().uuidString
        guard !resolved.contains(id) else { return }
        if currentID == nil { currentID = id }
        ensure(id)
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        if completed {
            // An empty cleanup event cannot erase words already recognised.
            if !text.isEmpty { items[index].text = text }
            items[index].ended = true
        } else {
            items[index].text += text
        }
    }

    mutating func beganResponse() {
        responseIDs = Set(items.filter(\.ended).map(\.id))
    }

    mutating func confirmedResponse() {
        resolved.append(contentsOf: responseIDs)
        if resolved.count > 256 { resolved.removeFirst(resolved.count - 256) }
        items.removeAll { responseIDs.contains($0.id) }
        responseIDs.removeAll()
    }

    private mutating func ensure(_ id: String) {
        guard !resolved.contains(id), !items.contains(where: { $0.id == id }) else { return }
        items.append(Item(id: id))
    }

    private func joined(_ items: [Item]) -> String {
        items.map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }.joined(separator: " ")
    }
}
