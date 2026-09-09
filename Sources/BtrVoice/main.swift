import AppKit

if let index = CommandLine.arguments.firstIndex(of: "--voice-trace") {
    let turnID = CommandLine.arguments.dropFirst(index + 1).first
    let trace = DesktopVoiceTrace.recent(directory: DesktopVoiceHistoryStore.shared.directory, turnID: turnID)
    print(trace.isEmpty ? "No saved diagnostics match yet." : trace)
    exit(0)
}

if CommandLine.arguments.contains("--self-test") {
    exit(SelfTest.run())
}

// Render the real overlay and exercise Stop with synthetic transcripts only.
if CommandLine.arguments.contains("--self-test-voice-panel") {
    let testApp = NSApplication.shared
    testApp.setActivationPolicy(.accessory)
    DispatchQueue.global().asyncAfter(deadline: .now() + 30) {
        fputs("FAIL: Voice Control panel blocked the main run loop.\n", stderr)
        _exit(1)
    }
    Task { @MainActor in exit(await DesktopVoicePanelSelfTest.run()) }
    testApp.run()
}

if CommandLine.arguments.contains("--self-test-reading") || CommandLine.arguments.contains("--self-test-reading-model") {
    let testApp = NSApplication.shared
    testApp.setActivationPolicy(.prohibited)
    Task { @MainActor in exit(await DesktopReadingSelfTest.run(model: CommandLine.arguments.contains("--self-test-reading-model"))) }
    testApp.run()
}

// Replay the real coordinator with fake desktop effects; never opens a fixture window.
if CommandLine.arguments.contains("--self-test-voice-flow") || CommandLine.arguments.contains("--self-test-voice-flow-model") {
    let testApp = NSApplication.shared
    testApp.setActivationPolicy(.prohibited)
    Task { @MainActor in
        let result = CommandLine.arguments.contains("--self-test-voice-flow-model")
            ? await DesktopVoiceFlowSelfTest.runModel() : await DesktopVoiceFlowSelfTest.run()
        exit(result)
    }
    testApp.run()
}

// Real cross-process Accessibility checks use only a disposable fixture window.
if CommandLine.arguments.contains("--accessibility-fixture") {
    MainActor.assumeIsolated { DesktopAccessibilityIntegrationTest.showFixture() }
    exit(0)
}
if CommandLine.arguments.contains("--self-test-accessibility") || CommandLine.arguments.contains("--self-test-accessibility-model") {
    let testApp = NSApplication.shared
    testApp.setActivationPolicy(.prohibited)
    Task { @MainActor in exit(await DesktopAccessibilityIntegrationTest.run(
        checkModel: CommandLine.arguments.contains("--self-test-accessibility-model"))) }
    testApp.run()
}

// Local, read-only access for coding assistants and terminal users.
if let index = CommandLine.arguments.firstIndex(of: "--voice-history") {
    let query = CommandLine.arguments.dropFirst(index + 1).joined(separator: " ")
    let transcript = DesktopVoiceHistoryStore.shared.transcript(query: query)
    print(transcript.isEmpty ? "No saved Voice Control transcripts match yet." : transcript)
    exit(0)
}

// Uses the actual slow-path model and validator without executing any returned plan.
if let index = CommandLine.arguments.firstIndex(of: "--check-voice-intent") {
    let utterance = CommandLine.arguments.dropFirst(index + 1).joined(separator: " ")
    guard !utterance.isEmpty else { print("Provide a voice request to interpret."); exit(2) }
    let checkApp = NSApplication.shared
    checkApp.setActivationPolicy(.prohibited)
    Task { @MainActor in
        do {
            let assistant = DesktopVoiceAssistant(resolveApplication: { DesktopApplicationResolver.shared.resolve($0) })
            let context = DesktopVoiceAssistant.Context(targetName: nil,
                recentActivity: DesktopVoiceHistoryStore.shared.contextLines())
            print(try await assistant.respond(to: utterance, context: context))
            exit(0)
        } catch { print("Intent check failed: \(error.localizedDescription)"); exit(1) }
    }
    checkApp.run()
}

// Exercise the actual macOS permission/capture path without audio or an API call.
// Only dimensions and capture metadata are printed; no image is saved or uploaded.
if CommandLine.arguments.contains("--check-screen") || CommandLine.arguments.contains("--check-screen-image") {
    let checkApp = NSApplication.shared
    checkApp.setActivationPolicy(.prohibited)
    Task { @MainActor in
        do {
            let snapshot = try await DesktopScreenReader.capture(
                includeImage: CommandLine.arguments.contains("--check-screen-image")
            )
            let data = try JSONSerialization.data(withJSONObject: snapshot.metadata, options: [.sortedKeys])
            print(String(decoding: data, as: UTF8.self))
            exit(0)
        } catch {
            print("Screen capture unavailable: \(error.localizedDescription)")
            exit(1)
        }
    }
    checkApp.run()
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
