import AppKit

if CommandLine.arguments.contains("--self-test") {
    exit(SelfTest.run())
}

// Direct line to the on-device model, for testing from a terminal:
//   BtrVoice --ask "your prompt here"
if let askIndex = CommandLine.arguments.firstIndex(of: "--ask") {
    let prompt = CommandLine.arguments.dropFirst(askIndex + 1).joined(separator: " ")
    guard !prompt.isEmpty else {
        print("usage: BtrVoice --ask \"your prompt\"")
        exit(2)
    }
    guard JarvisEngine.onDeviceAvailable else {
        print("On-device model unavailable (needs Apple Intelligence on macOS 26+).")
        exit(1)
    }
    let semaphore = DispatchSemaphore(value: 0)
    Task {
        do {
            let reply = try await JarvisEngine.ask(prompt)
            print(reply)
        } catch {
            print("error: \(error.localizedDescription)")
        }
        semaphore.signal()
    }
    semaphore.wait()
    exit(0)
}

// Diagnostic: log every scroll/magnify/gesture event system-wide for N seconds.
// Used to see what the UPDD touchscreen driver actually synthesizes.
//   BtrVoice --monitor [seconds]
if let monitorIndex = CommandLine.arguments.firstIndex(of: "--monitor") {
    let seconds = Double(CommandLine.arguments.dropFirst(monitorIndex + 1).first ?? "15") ?? 15
    let app = NSApplication.shared
    app.setActivationPolicy(.prohibited)
    print("monitoring scroll/magnify/gesture events for \(Int(seconds))s — pinch now")
    let mask: NSEvent.EventTypeMask = [.scrollWheel, .magnify, .gesture, .smartMagnify]
    NSEvent.addGlobalMonitorForEvents(matching: mask) { event in
        var line = "type=\(event.type.rawValue)"
        switch event.type {
        case .scrollWheel:
            line = "scrollWheel dy=\(String(format: "%.2f", event.scrollingDeltaY)) dx=\(String(format: "%.2f", event.scrollingDeltaX)) phase=\(event.phase.rawValue) momentum=\(event.momentumPhase.rawValue)"
        case .magnify:
            line = "magnify magnification=\(String(format: "%.4f", event.magnification)) phase=\(event.phase.rawValue)"
        case .smartMagnify:
            line = "smartMagnify"
        default:
            line = "gesture type=\(event.type.rawValue)"
        }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        var mods: [String] = []
        if flags.contains(.control) { mods.append("ctrl") }
        if flags.contains(.command) { mods.append("cmd") }
        if flags.contains(.shift) { mods.append("shift") }
        if flags.contains(.option) { mods.append("opt") }
        print("\(line) mods=[\(mods.joined(separator: ","))]")
    }
    DispatchQueue.main.asyncAfter(deadline: .now() + seconds) {
        print("monitor done")
        exit(0)
    }
    app.run()
}

// BtrVoice runs as an accessory (menu-bar only) app: no Dock icon, no main window.
let app = NSApplication.shared
app.setActivationPolicy(.accessory)

let delegate = AppDelegate()
app.delegate = delegate
app.run()
