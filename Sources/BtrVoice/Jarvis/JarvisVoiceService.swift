import Combine
import Foundation

/// Starts and monitors the local trusted Jarvis gateway for BtrVoice.
///
/// The service is a direct process launch, not an LLM request. If another service is
/// already listening, BtrVoice simply reuses it. The native SwiftUI console uses its
/// JSON endpoints for unified history, named tools, tasks, and lifecycle recovery; no
/// browser or WKWebView is involved. Processes started here live for the BtrVoice app
/// lifetime and are terminated when BtrVoice quits.
@MainActor
final class JarvisVoiceService: ObservableObject {
    static let shared = JarvisVoiceService()

    enum State: Equatable {
        case idle
        case starting(String)
        case ready
        case failed(String)
    }

    @Published private(set) var state: State = .idle

    let pageURL: URL
    private let environment: [String: String]
    private let externallyConfigured: Bool
    private var startupTask: Task<Void, Never>?
    private var monitorTask: Task<Void, Never>?
    private var children: [Child] = []

    var statusMessage: String {
        if case .starting(let message) = state { return message }
        return "Preparing the local voice surface."
    }

    private init(environment: [String: String] = ProcessInfo.processInfo.environment) {
        self.environment = environment
        let explicit = environment["JARVIS_VOICE_URL"]?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.externallyConfigured = !(explicit ?? "").isEmpty
        self.pageURL = Self.voiceURL(explicit) ?? URL(string: "http://127.0.0.1:8765")!
    }

    func ensureRunning() {
        guard startupTask == nil, state != .ready else { return }
        state = .starting("Checking the Jarvis voice service…")
        startupTask = Task { [weak self] in
            guard let self else { return }
            if await self.probe() {
                // The page may have been started from a terminal. BtrVoice still owns
                // the local supporting services so history/task catch-up keeps working
                // after that terminal is closed.
                if !self.externallyConfigured && self.children.isEmpty {
                    try? self.launchLocalProviders(includeVoice: false)
                }
                self.didBecomeReady()
                return
            }

            if self.externallyConfigured {
                self.fail("No Jarvis Voice surface answered at \(self.pageURL.absoluteString). Check JARVIS_VOICE_URL and try again.")
                return
            }

            do {
                self.state = .starting("Starting task and Realtime providers…")
                try self.launchLocalProviders(includeVoice: true)
            } catch {
                self.fail(error.localizedDescription)
                return
            }

            for _ in 0..<50 {
                if Task.isCancelled { return }
                if await self.probe() {
                    self.didBecomeReady()
                    return
                }
                try? await Task.sleep(nanoseconds: 200_000_000)
            }
            self.fail("The Jarvis Voice process was launched but did not answer at \(self.pageURL.absoluteString). Open the BtrVoice log for its startup error.")
        }
    }

    func retry() {
        startupTask?.cancel()
        startupTask = nil
        monitorTask?.cancel()
        monitorTask = nil
        state = .idle
        ensureRunning()
    }

    /// A newly saved key only affects a process launched after it was saved.
    func credentialsDidChange() {
        guard let voice = children.first(where: { $0.name == "voice" }) else { return }
        monitorTask?.cancel()
        monitorTask = nil
        startupTask?.cancel()
        voice.output.fileHandleForReading.readabilityHandler = nil
        if voice.process.isRunning { voice.process.terminate() }
        // Keep `.ready` and the native window mounted. The OpenAI WebSocket is owned by
        // the app; replacing this gateway only refreshes tools and shared history.
        startupTask = Task { [weak self] in
            guard let self else { return }
            for _ in 0..<20 {
                if !voice.process.isRunning {
                    let oldListenerIsGone = !(await self.probe())
                    if oldListenerIsGone { break }
                }
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
            self.removeExitedChildren()
            let replacementAlreadyAvailable = await self.probe()
            if !voice.process.isRunning && !replacementAlreadyAvailable {
                do {
                    try self.launchVoiceOnly()
                    Log.write("jarvis voice: credentials changed; backend replaced without restarting the UI")
                } catch {
                    Log.write("jarvis voice: credential reload failed: \(error.localizedDescription)")
                }
            }
            self.startupTask = nil
            self.startMonitor()
        }
    }

    func shutdown() {
        startupTask?.cancel()
        startupTask = nil
        monitorTask?.cancel()
        monitorTask = nil
        stopChildren()
        state = .idle
    }

    private func probe() async -> Bool {
        guard var components = URLComponents(url: pageURL, resolvingAgainstBaseURL: false) else { return false }
        components.path = "/api/info"
        components.query = nil
        components.fragment = nil
        guard let url = components.url else { return false }

        var request = URLRequest(url: url)
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        request.timeoutInterval = 0.8
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { return false }
            let info = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            return info?["model"] is String && info?["controls"] is [Any]
        } catch {
            return false
        }
    }

    private func launchLocalProviders(includeVoice: Bool) throws {
        guard let plugins = JarvisVoiceInstallation.findPlugins(
            environment: environment,
            bundleURL: Bundle.main.bundleURL,
            homeDirectory: URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
        ) else {
            throw ServiceError.installNotFound
        }
        guard let python = JarvisVoiceInstallation.findPython(
            environment: environment,
            pluginsDirectory: plugins,
            homeDirectory: URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
        ) else {
            throw ServiceError.pythonNotFound(plugins.path)
        }

        // Durable tasks, event judgement, and supervised development are independent
        // providers so all surfaces see one fleet state. Duplicate exclusive providers
        // exit harmlessly when one is already registered.
        children.append(try spawn(name: "tasks", module: "jarvis.tasks", python: python, workingDirectory: plugins))
        children.append(try spawn(name: "notify", module: "jarvis.notify", python: python, workingDirectory: plugins))
        children.append(try spawn(name: "development", module: "jarvis.development", python: python, workingDirectory: plugins))
        if includeVoice {
            children.append(try spawn(name: "voice", module: "jarvis.voice", python: python, workingDirectory: plugins))
        }
    }

    private func launchVoiceOnly() throws {
        guard let plugins = JarvisVoiceInstallation.findPlugins(
            environment: environment,
            bundleURL: Bundle.main.bundleURL,
            homeDirectory: URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
        ) else {
            throw ServiceError.installNotFound
        }
        guard let python = JarvisVoiceInstallation.findPython(
            environment: environment,
            pluginsDirectory: plugins,
            homeDirectory: URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
        ) else {
            throw ServiceError.pythonNotFound(plugins.path)
        }
        children.append(try spawn(name: "voice", module: "jarvis.voice", python: python, workingDirectory: plugins))
    }

    private func didBecomeReady() {
        state = .ready
        startupTask = nil
        startMonitor()
    }

    /// Health monitoring never changes `.ready`, because doing so would dismantle the
    /// SwiftUI console and drop an otherwise healthy native Realtime conversation.
    private func startMonitor() {
        monitorTask?.cancel()
        monitorTask = Task { [weak self] in
            guard let self else { return }
            var misses = 0
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                if Task.isCancelled { return }
                if await self.probe() {
                    misses = 0
                    self.removeExitedChildren()
                    continue
                }
                misses += 1
                guard misses >= 4 else { continue }
                Log.write("jarvis voice: backend unavailable; the open UI is staying mounted")
                if !self.externallyConfigured {
                    self.removeExitedChildren()
                    if let stalled = self.children.first(where: { $0.name == "voice" && $0.process.isRunning }) {
                        Log.write("jarvis voice: terminating the unresponsive owned backend")
                        stalled.output.fileHandleForReading.readabilityHandler = nil
                        stalled.process.terminate()
                        for _ in 0..<10 where stalled.process.isRunning {
                            try? await Task.sleep(nanoseconds: 100_000_000)
                        }
                        if stalled.process.isRunning {
                            Log.write("jarvis voice: owned backend did not exit yet; recovery will retry")
                            misses = 0
                            continue
                        }
                        self.removeExitedChildren()
                    }
                    do {
                        try self.launchVoiceOnly()
                        Log.write("jarvis voice: launched a replacement backend without restarting the UI")
                    } catch {
                        Log.write("jarvis voice: backend recovery failed: \(error.localizedDescription)")
                    }
                }
                misses = 0
            }
        }
    }

    private func spawn(name: String, module: String, python: URL, workingDirectory: URL) throws -> Child {
        let process = Process()
        process.executableURL = python
        process.arguments = ["-m", module]
        process.currentDirectoryURL = workingDirectory

        var childEnvironment = environment
        if let key = OpenAIKeyStore.read() {
            childEnvironment["OPENAI_API_KEY"] = key
        }
        let usefulPath = [
            URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".local/bin").path,
            "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin",
        ].joined(separator: ":")
        childEnvironment["PATH"] = [usefulPath, childEnvironment["PATH"]].compactMap { $0 }.joined(separator: ":")
        process.environment = childEnvironment

        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        output.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty, let line = String(data: data, encoding: .utf8) else { return }
            Log.write("jarvis \(name): \(line.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
        process.terminationHandler = { process in
            Log.write("jarvis \(name): exited \(process.terminationStatus)")
        }

        do {
            try process.run()
        } catch {
            output.fileHandleForReading.readabilityHandler = nil
            throw ServiceError.launchFailed(name, error.localizedDescription)
        }
        Log.write("jarvis \(name): launched pid \(process.processIdentifier) with \(python.path)")
        return Child(name: name, process: process, output: output)
    }

    private func stopChildren() {
        for child in children {
            child.output.fileHandleForReading.readabilityHandler = nil
            if child.process.isRunning { child.process.terminate() }
        }
        children.removeAll()
    }

    private func removeExitedChildren() {
        for child in children where !child.process.isRunning {
            child.output.fileHandleForReading.readabilityHandler = nil
        }
        children.removeAll(where: { !$0.process.isRunning })
    }

    private func fail(_ message: String) {
        monitorTask?.cancel()
        monitorTask = nil
        state = .failed(message)
        startupTask = nil
        Log.write("jarvis voice: \(message)")
    }

    private final class Child {
        let name: String
        let process: Process
        let output: Pipe

        init(name: String, process: Process, output: Pipe) {
            self.name = name
            self.process = process
            self.output = output
        }
    }

    private enum ServiceError: LocalizedError {
        case installNotFound
        case pythonNotFound(String)
        case launchFailed(String, String)

        var errorDescription: String? {
            switch self {
            case .installNotFound:
                return "Could not find the Jarvis plugins checkout. Expected ~/jarvis/plugins, or set JARVIS_PLUGIN_DIR."
            case .pythonNotFound(let plugins):
                return "Could not find a Python 3 runtime for Jarvis Voice in \(plugins). Set JARVIS_PYTHON to its executable."
            case .launchFailed(let name, let detail):
                return "Could not launch the Jarvis \(name) provider: \(detail)"
            }
        }
    }

    private static func voiceURL(_ raw: String?) -> URL? {
        guard let raw, let url = URL(string: raw),
              ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
              url.host != nil else { return nil }
        return url
    }
}

/// Pure filesystem discovery kept outside the service actor so self-tests can protect
/// the portable launch contract without starting a process or touching the network.
enum JarvisVoiceInstallation {
    static func findPlugins(
        environment: [String: String],
        bundleURL: URL,
        homeDirectory: URL,
        fileExists: (String) -> Bool = FileManager.default.fileExists(atPath:)
    ) -> URL? {
        var candidates: [URL] = []
        if let configured = environment["JARVIS_PLUGIN_DIR"], !configured.isEmpty {
            candidates.append(URL(fileURLWithPath: configured, isDirectory: true))
        }
        candidates.append(homeDirectory.appendingPathComponent("jarvis/plugins", isDirectory: true))

        // Development bundles live at btr_voice/build/BtrVoice.app, making the
        // Jarvis checkout an ordinary sibling of the BtrVoice repository.
        let workspace = bundleURL
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        candidates.append(workspace.appendingPathComponent("jarvis/plugins", isDirectory: true))

        return candidates.first { candidate in
            fileExists(candidate.appendingPathComponent("jarvis/voice/__main__.py").path)
        }
    }

    static func findPython(
        environment: [String: String],
        pluginsDirectory: URL,
        homeDirectory: URL,
        isExecutable: (String) -> Bool = FileManager.default.isExecutableFile(atPath:)
    ) -> URL? {
        var candidates: [URL] = []
        if let configured = environment["JARVIS_PYTHON"], !configured.isEmpty {
            candidates.append(URL(fileURLWithPath: configured))
        }
        candidates.append(pluginsDirectory.appendingPathComponent(".venv/bin/python"))
        candidates.append(homeDirectory.appendingPathComponent("miniforge3/bin/python3"))
        candidates.append(contentsOf: [
            URL(fileURLWithPath: "/opt/homebrew/bin/python3"),
            URL(fileURLWithPath: "/usr/local/bin/python3"),
            URL(fileURLWithPath: "/usr/bin/python3"),
        ])
        return candidates.first { isExecutable($0.path) }
    }
}
