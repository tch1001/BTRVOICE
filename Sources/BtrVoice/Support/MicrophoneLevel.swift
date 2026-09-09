import Combine

/// Publishes meter changes separately so audio does not rebuild transcripts, menus
/// and history or delay the accessibility requests used by touchscreen software.
final class MicrophoneLevel: ObservableObject {
    @Published private(set) var level: Float = 0

    func update(_ value: Float) {
        guard value != level else { return }
        level = value
    }
}
