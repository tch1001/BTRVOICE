import Foundation

/// Computes small, grapheme-safe text-storage edits so cloud snapshots do not
/// replace an entire document, invalidate every line, or throw away selection.
struct TranscriptTextUpdate {
    private struct Grapheme: Hashable {
        let value: String
        init(_ character: Character) { value = String(character) }
        static func == (lhs: Self, rhs: Self) -> Bool {
            lhs.value.utf8.elementsEqual(rhs.value.utf8)
        }
        func hash(into hasher: inout Hasher) {
            for byte in value.utf8 { hasher.combine(byte) }
        }
    }
    struct Edit {
        let range: NSRange
        let replacement: String
    }

    let edits: [Edit]

    init(from old: String, to new: String) {
        guard !old.utf8.elementsEqual(new.utf8) else { edits = []; return }
        // Almost every live transcription update is an append. Avoid allocating
        // grapheme arrays for a long document on that high-frequency path.
        if new.utf8.starts(with: old.utf8) {
            let boundary = new.utf8.index(new.utf8.startIndex, offsetBy: old.utf8.count)
            if let index = boundary.samePosition(in: new) {
                edits = [Edit(range: NSRange(location: old.utf16.count, length: 0),
                              replacement: String(new[index...]))]
                return
            }
        }
        if old.utf8.starts(with: new.utf8) {
            let boundary = old.utf8.index(old.utf8.startIndex, offsetBy: new.utf8.count)
            if boundary.samePosition(in: old) != nil {
                edits = [Edit(range: NSRange(location: new.utf16.count,
                                            length: old.utf16.count - new.utf16.count), replacement: "")]
                return
            }
        }
        let before = old.map(Grapheme.init)
        let after = new.map(Grapheme.init)
        var prefix = 0
        while prefix < min(before.count, after.count), before[prefix] == after[prefix] {
            prefix += 1
        }
        var endBefore = before.count
        var endAfter = after.count
        while endBefore > prefix, endAfter > prefix,
              before[endBefore - 1] == after[endAfter - 1] {
            endBefore -= 1
            endAfter -= 1
        }
        let oldMiddle = Array(before[prefix..<endBefore])
        let newMiddle = Array(after[prefix..<endAfter])
        let start = before[..<prefix].reduce(0) { $0 + $1.value.utf16.count }

        // Append-only deltas take the cheap path. Bound the general diff's work
        // for a completely rewritten long speech; matching outer text still stays.
        guard !oldMiddle.isEmpty, !newMiddle.isEmpty,
              oldMiddle.count + newMiddle.count <= 4_096 else {
            edits = [Edit(range: NSRange(location: start,
                                        length: oldMiddle.reduce(0) { $0 + $1.value.utf16.count }),
                          replacement: newMiddle.map(\.value).joined())]
            return
        }

        let difference = newMiddle.difference(from: oldMiddle)
        var removed = Set<Int>()
        var inserted = Set<Int>()
        for change in difference {
            switch change {
            case .remove(let offset, _, _): removed.insert(offset)
            case .insert(let offset, _, _): inserted.insert(offset)
            }
        }
        var result: [Edit] = []
        var i = 0
        var j = 0
        var offset = start
        while i < oldMiddle.count || j < newMiddle.count {
            let editStart = offset
            var replacement = ""
            while i < oldMiddle.count, removed.contains(i) {
                offset += oldMiddle[i].value.utf16.count
                i += 1
            }
            while j < newMiddle.count, inserted.contains(j) {
                replacement += newMiddle[j].value
                j += 1
            }
            if offset != editStart || !replacement.isEmpty {
                result.append(Edit(range: NSRange(location: editStart, length: offset - editStart),
                                   replacement: replacement))
            }
            if i < oldMiddle.count, j < newMiddle.count {
                offset += oldMiddle[i].value.utf16.count
                i += 1
                j += 1
            }
        }
        edits = result
    }

    func selection(after range: NSRange) -> NSRange {
        func mapped(_ position: Int, followsInsertion: Bool = false) -> Int {
            var shift = 0
            for edit in edits {
                if position == edit.range.location, edit.range.length == 0, followsInsertion {
                    shift += edit.replacement.utf16.count
                    continue
                }
                if position <= edit.range.location { return position + shift }
                let newLength = edit.replacement.utf16.count
                if position < NSMaxRange(edit.range) {
                    var relative = min(position - edit.range.location, newLength)
                    if relative < newLength {
                        relative = (edit.replacement as NSString)
                            .rangeOfComposedCharacterSequence(at: relative).location
                    }
                    return edit.range.location + shift + relative
                }
                shift += newLength - edit.range.length
            }
            return position + shift
        }
        // Inserting just before a selected word must not select the inserted
        // words too. A caret (or the end of a selection) retains left affinity.
        let start = mapped(range.location, followsInsertion: range.length > 0)
        return NSRange(location: start, length: max(0, mapped(NSMaxRange(range)) - start))
    }
}
