/// Keeps assistant replies readable in both conversation views using the system
/// Markdown parser. Formatting is only for display; saved and copied text stays intact.
import Foundation
import SwiftUI

struct DesktopVoiceReplyText: View, Equatable {
    private let source: String
    private let fontSize: CGFloat

    init(_ source: String, fontSize: CGFloat = 13) {
        self.source = source
        self.fontSize = fontSize
    }

    var body: some View {
        Text(Self.render(source, fontSize: fontSize)).fixedSize(horizontal: false, vertical: true)
    }

    // SwiftUI Text displays inline Markdown attributes, but does not lay out the
    // parser's block intents. Supply their spacing, markers, and fonts explicitly.
    static func render(_ source: String, fontSize: CGFloat) -> AttributedString {
        guard let parsed = try? AttributedString(markdown: source) else {
            return AttributedString(source)
        }
        var result = AttributedString()
        var seenItems = Set<Int>()
        var previousWasList = false
        var previousTableRow: Int?

        for (intent, range) in parsed.runs[\.presentationIntent] {
            let components = intent?.components ?? []
            var block = AttributedString(parsed[range])
            block.presentationIntent = nil
            block.font = .system(size: fontSize)
            var prefix = ""
            var listDepth = 0
            var tableRow: Int?
            var isCode = false

            for component in components {
                switch component.kind {
                case .header(let level):
                    block.font = .system(size: fontSize + CGFloat(max(1, 5 - level)), weight: .bold)
                case .codeBlock:
                    isCode = true
                case .orderedList, .unorderedList:
                    listDepth += 1
                case .blockQuote:
                    prefix += "▏ "
                    block.foregroundColor = .secondary
                case .tableHeaderRow:
                    tableRow = component.identity
                    block.font = .system(size: fontSize, weight: .bold)
                case .tableRow:
                    tableRow = component.identity
                default:
                    break
                }
            }

            // Components are innermost first, so a nested item uses its own list
            // style. Continuation paragraphs do not acquire another bullet.
            if let item = components.first(where: { if case .listItem = $0.kind { return true }; return false }),
               case .listItem(let ordinal) = item.kind {
                let ordered = components.first(where: { $0.kind == .orderedList || $0.kind == .unorderedList })?.kind == .orderedList
                let marker = seenItems.insert(item.identity).inserted ? (ordered ? "\(ordinal). " : "• ") : "  "
                prefix += String(repeating: "  ", count: max(0, listDepth - 1)) + marker
            }

            if !result.characters.isEmpty {
                let separator: String
                if let tableRow, tableRow == previousTableRow {
                    separator = "  │  "
                } else if (tableRow != nil && previousTableRow != nil) || (listDepth > 0 && previousWasList) {
                    separator = "\n"
                } else {
                    separator = "\n\n"
                }
                result.append(AttributedString(separator))
            }
            result.append(AttributedString(prefix))
            for run in block.runs {
                if isCode || run.inlinePresentationIntent?.contains(.code) == true {
                    block[run.range].font = .system(size: fontSize, design: .monospaced)
                    block[run.range].backgroundColor = Color.secondary.opacity(0.10)
                }
            }
            result.append(block)
            previousWasList = listDepth > 0
            previousTableRow = tableRow
        }
        return result.characters.isEmpty ? AttributedString(source) : result
    }
}
