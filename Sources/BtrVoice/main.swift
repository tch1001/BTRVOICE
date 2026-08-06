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
    guard JarvisEngine.isAvailable else {
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

// BtrVoice runs as an accessory (menu-bar only) app: no Dock icon, no main window.
let app = NSApplication.shared
app.setActivationPolicy(.accessory)

let delegate = AppDelegate()
app.delegate = delegate
app.run()
