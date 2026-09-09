/// Records a stalled main run loop from an independent queue, so UI hangs leave
/// evidence even when no crash report is produced. One event per stall, not spam.
import Foundation

final class MainThreadWatchdog {
    private let queue = DispatchQueue(label: "com.btr.voice.ui-watchdog", qos: .utility)
    private var timer: DispatchSourceTimer?
    private var pendingSince: TimeInterval?
    private var reported = false
    private let trace: DesktopVoiceTrace
    private let threshold: TimeInterval
    private let interval: TimeInterval

    init(trace: DesktopVoiceTrace, threshold: TimeInterval = 3, interval: TimeInterval = 1) {
        self.trace = trace; self.threshold = threshold; self.interval = interval
    }

    func start() {
        guard timer == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: interval, leeway: .milliseconds(20))
        timer.setEventHandler { [weak self] in self?.tick() }
        self.timer = timer
        timer.resume()
    }

    deinit { timer?.cancel() }

    private func tick() {
        let now = ProcessInfo.processInfo.systemUptime
        if let pendingSince {
            if !reported, now - pendingSince >= threshold {
                reported = true
                trace.record("ui.unresponsive", turnID: nil, fields: ["blocked_ms": (now - pendingSince) * 1_000,
                    "pid": ProcessInfo.processInfo.processIdentifier])
            }
            return
        }
        pendingSince = now
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let acknowledged = ProcessInfo.processInfo.systemUptime
            self.queue.async { [weak self] in
                guard let self else { return }
                if self.reported, let since = self.pendingSince {
                    self.trace.record("ui.responsive_again", turnID: nil, fields: ["blocked_ms": (acknowledged - since) * 1_000])
                }
                self.pendingSince = nil
                self.reported = false
            }
        }
    }
}
