import AppKit
import SwiftUI

/// A live feed of the GPT Editor's observable decision process: what it heard,
/// how it rewrote the transcript, which tools it called, what went wrong. The
/// model's internal reasoning isn't exposed by the API — this is everything it
/// *does*, which is the next best window into what it's thinking.
@MainActor
final class EditorActivityLog: ObservableObject {
    static let shared = EditorActivityLog()

    enum Kind {
        case heard      // raw speech recognition of the user
        case rewrote    // the editor produced a transcript revision
        case tool       // app_command / remember_rule call
        case info       // session lifecycle
        case error

        var tag: String {
            switch self {
            case .heard: return "HEARD"
            case .rewrote: return "WROTE"
            case .tool: return "TOOL"
            case .info: return "INFO"
            case .error: return "ERROR"
            }
        }

        var color: Color {
            switch self {
            case .heard: return .secondary
            case .rewrote: return .accentColor
            case .tool: return .orange
            case .info: return .green
            case .error: return .red
            }
        }
    }

    struct Entry: Identifiable {
        let id = UUID()
        let date = Date()
        let kind: Kind
        let text: String
    }

    @Published private(set) var entries: [Entry] = []

    func add(_ kind: Kind, _ text: String) {
        entries.append(Entry(kind: kind, text: text))
        if entries.count > 400 { entries.removeFirst(entries.count - 400) }
    }

    func clear() { entries.removeAll() }

    /// Thread-safe entry point for the engine's background callbacks.
    nonisolated static func post(_ kind: Kind, _ text: String) {
        DispatchQueue.main.async { EditorActivityLog.shared.add(kind, text) }
    }
}

struct EditorActivityView: View {
    @ObservedObject var log: EditorActivityLog

    private static let clock: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 6) {
                        Text("Editor brain")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.secondary)
                        if log.entries.isEmpty {
                            Text("What the editor hears, how it rewrites your transcript, the tools it invokes, and any errors — live, as it works.")
                                .font(.system(size: 10.5))
                                .foregroundStyle(.secondary)
                        }
                        ForEach(log.entries) { entry in
                            HStack(alignment: .top, spacing: 8) {
                                Text(Self.clock.string(from: entry.date))
                                    .font(.system(size: 10, design: .monospaced))
                                    .foregroundStyle(.tertiary)
                                Text(entry.kind.tag)
                                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                                    .foregroundStyle(.white)
                                    .padding(.horizontal, 5)
                                    .padding(.vertical, 2)
                                    .background(RoundedRectangle(cornerRadius: 4).fill(entry.kind.color))
                                Text(entry.text)
                                    .font(.system(size: 11.5))
                                    .textSelection(.enabled)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            .id(entry.id)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
                }
                .onChange(of: log.entries.count) {
                    if let last = log.entries.last {
                        proxy.scrollTo(last.id, anchor: .bottom)
                    }
                }
            }
            Divider()
            HStack {
                Text("\(log.entries.count) events")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Clear") { log.clear() }
                    .controlSize(.small)
                    .disabled(log.entries.isEmpty)
            }
            .padding(6)
        }
    }
}
