import SwiftUI

/// Level meter drawn as a symmetric bar cluster. Each bar responds to a different
/// slice of the level range so quiet speech still animates instead of sitting flat.
struct WaveformView: View {

    let level: Float
    let active: Bool

    private let barCount = 13

    var body: some View {
        HStack(alignment: .center, spacing: 2.5) {
            ForEach(0..<barCount, id: \.self) { index in
                Capsule(style: .continuous)
                    .fill(active ? Color.accentColor : Color.secondary.opacity(0.35))
                    .frame(width: 2.5, height: height(for: index))
                    .animation(.easeOut(duration: 0.09), value: level)
            }
        }
        .frame(height: 22)
    }

    private func height(for index: Int) -> CGFloat {
        let minimum: CGFloat = 3
        guard active else { return minimum }

        // Centre bars are tallest; the envelope tapers towards the edges.
        let centre = Double(barCount - 1) / 2
        let distance = abs(Double(index) - centre) / centre
        let envelope = 1 - pow(distance, 1.7) * 0.75

        // Stagger sensitivity so bars don't move in lockstep.
        let bias = 0.55 + 0.45 * (1 - distance)
        let amplitude = min(1, Double(level) * bias * 1.35)

        return minimum + CGFloat(amplitude * envelope) * 19
    }
}
