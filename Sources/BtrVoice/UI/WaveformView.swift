import SwiftUI

/// Only this small view observes the audio stream; its parent observes task state.
struct LiveWaveformView: View {
    @ObservedObject var meter: MicrophoneLevel
    let active: Bool
    let processing: Bool

    init(meter: MicrophoneLevel, active: Bool, processing: Bool = false) {
        self.meter = meter
        self.active = active
        self.processing = processing
    }

    var body: some View {
        WaveformView(level: meter.level, active: active, processing: processing)
    }
}

/// Level meter drawn as a symmetric bar cluster. Each bar responds to a different
/// slice of the level range so quiet speech still animates instead of sitting flat.
struct WaveformView: View {

    let level: Float
    let active: Bool
    let processing: Bool

    private let barCount = 13

    init(level: Float, active: Bool, processing: Bool = false) {
        self.level = level; self.active = active; self.processing = processing
    }

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 24.0, paused: !processing)) { timeline in
            HStack(alignment: .center, spacing: 2.5) {
                ForEach(0..<barCount, id: \.self) { index in
                    Capsule(style: .continuous)
                        .fill(barColor)
                        .frame(width: 2.5, height: height(for: index, at: timeline.date))
                        .animation(processing ? nil : .easeOut(duration: 0.09), value: level)
                }
            }
            .frame(height: 22)
        }
        // Decorative bars have no touch action. Keep changing geometry out of the
        // accessibility tree while leaving the microphone button fully exposed.
        .accessibilityHidden(true)
    }

    private var barColor: Color {
        if processing { return Color.accentColor.opacity(0.68) }
        return active ? Color.accentColor : Color.secondary.opacity(0.35)
    }

    private func height(for index: Int, at date: Date) -> CGFloat {
        let minimum: CGFloat = 3
        if processing {
            // A travelling pulse is visibly deliberate but cannot be mistaken for
            // microphone input: it continues smoothly even in a silent room.
            let phase = date.timeIntervalSinceReferenceDate * 5.2 - Double(index) * 0.72
            let pulse = (sin(phase) + 1) / 2
            let centre = Double(barCount - 1) / 2
            let distance = abs(Double(index) - centre) / centre
            let envelope = 0.65 + (1 - distance) * 0.35
            return minimum + CGFloat(pulse * envelope) * 14
        }
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
