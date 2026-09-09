/// Drives the real SwiftUI overlay through the stop/partial/resize transition that
/// hung the main thread. The microphone, model and desktop actions are all fake.
import AppKit
import AVFoundation
import SwiftUI

enum DesktopVoicePanelSelfTest {
    final class Transcriber: TranscriptionEngine {
        var onPartial: ((String) -> Void)?
        var onSegmentFinal: ((String) -> Void)?
        var onFinished: (() -> Void)?
        var onError: ((Error) -> Void)?
        var onStatus: ((String) -> Void)?
        let isAvailable = true
        let displayName = "Fixture"
        let isOnDevice = true
        let segmentDuration: TimeInterval = 0
        var cancellations = 0
        func start() throws {}
        func append(_ buffer: AVAudioPCMBuffer) {}
        func rotate() {}
        func discardUtterance() {}
        func finish() { onFinished?() }
        func cancel() {
            cancellations += 1
            // Cancellation is allowed to synchronously notify the caller.
            onError?(DesktopAXError.invalid("Retired stream"))
            onFinished?()
        }
        func lateCallbacks() {
            onPartial?("retired partial")
            onSegmentFinal?("retired command")
            onStatus?("retired status")
            onError?(DesktopAXError.invalid("Retired stream"))
            onFinished?()
        }
    }

    @MainActor static func run() async -> Int32 {
        var failures = 0
        func check(_ name: String, _ passed: Bool) {
            print("\(passed ? "PASS" : "FAIL"): \(name)")
            if !passed { failures += 1 }
        }
        let fixture = DesktopVoiceFlowSelfTest.Fixture()
        defer { fixture.clean() }
        var streams: [Transcriber] = []
        var starts = 0
        var stops = 0
        fixture.makeTranscriber = { let stream = Transcriber(); streams.append(stream); return stream }
        fixture.startAudio = { starts += 1 }
        fixture.stopAudio = { stops += 1 }
        fixture.respond = { request, _, _, _ in
            .answer("## \(request)\n\n" + String(repeating: "- **Example folder**: a long, wrapping synthetic answer with `inline code`.\n", count: 8))
        }
        let coordinator = fixture.coordinator()
        let hosting = NSHostingController(rootView: DesktopVoicePanelView(coordinator: coordinator))
        hosting.sizingOptions = []
        let panel = FloatingPanel()
        panel.title = "BtrVoice regression fixture"
        panel.contentViewController = hosting
        panel.setContentSize(NSSize(width: 520, height: 290))
        panel.orderFrontRegardless()
        defer { coordinator.stop(); coordinator.history.trace.flush(); panel.orderOut(nil) }
        for index in 0..<24 {
            coordinator.submit("Explain synthetic example \(index)")
            while coordinator.isCommandRunning { try? await Task.sleep(nanoseconds: 1_000_000) }
        }
        check("the rendered activity list stays bounded", coordinator.activities.count == 40)
        for cycle in 0..<12 {
            coordinator.start(target: nil)
            guard let stream = streams.last else { check("a fixture stream starts", false); break }
            for revision in 0..<4 {
                stream.onPartial?(String(repeating: "Unconfirmed example \(revision). ", count: 10))
                panel.setContentSize(NSSize(width: cycle.isMultiple(of: 2) ? 340 : 720, height: 290))
                try? await Task.sleep(nanoseconds: 12_000_000)
            }
            let count = coordinator.history.entries.count
            coordinator.stop()
            stream.lateCallbacks()
            check("stop \(cycle) remains idle and ignores retired speech", coordinator.phase == .idle && coordinator.partialTranscript.isEmpty && coordinator.history.entries.count == count)
            let stopped = stops
            coordinator.start(target: nil)
            stream.lateCallbacks()
            check("retired callbacks cannot stop a replacement stream", coordinator.phase == .listening && stops == stopped && coordinator.partialTranscript.isEmpty)
            coordinator.stop()
            coordinator.stop()
            try? await Task.sleep(nanoseconds: 12_000_000)
        }
        check("all requested microphone starts were simulated", starts == 24 && streams.allSatisfy { $0.cancellations == 1 })
        coordinator.history.trace.flush()
        let trace = DesktopVoiceTrace.recent(directory: fixture.directory)
        check("stop requests and completion durations are retained", trace.contains("listening.stop_requested") && trace.contains("listening.stopped"))
        let watchdog = MainThreadWatchdog(trace: coordinator.history.trace, threshold: 0.1, interval: 0.025)
        watchdog.start()
        try? await Task.sleep(nanoseconds: 80_000_000)
        withExtendedLifetime(watchdog) { stallFixtureRunLoop() }
        try? await Task.sleep(nanoseconds: 120_000_000)
        coordinator.history.trace.flush()
        let watchdogTrace = DesktopVoiceTrace.recent(directory: fixture.directory)
        check("a blocked UI and its recovery are logged off the main thread", watchdogTrace.contains("ui.unresponsive") && watchdogTrace.contains("ui.responsive_again"))
        print(failures == 0 ? "Voice Control panel and lifecycle replay passed." : "\(failures) checks failed.")
        return failures == 0 ? 0 : 1
    }

    private static func stallFixtureRunLoop() { Thread.sleep(forTimeInterval: 0.35) }
}
