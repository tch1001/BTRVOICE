import AppKit

if CommandLine.arguments.contains("--self-test") {
    exit(SelfTest.run())
}

// BtrVoice runs as an accessory (menu-bar only) app: no Dock icon, no main window.
let app = NSApplication.shared
app.setActivationPolicy(.accessory)

let delegate = AppDelegate()
app.delegate = delegate
app.run()
