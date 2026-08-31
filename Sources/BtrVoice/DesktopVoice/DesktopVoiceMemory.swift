import AppKit
import Foundation

/// Persists semantic application preferences separately from raw voice history.
/// This is the first durable piece of the future desktop world model: concepts
/// such as "browser" keep their meaning without storing everything the user says.
final class DesktopVoiceMemory {
    static let shared = DesktopVoiceMemory()

    private struct State: Codable {
        var preferredApplications: [String: String]
    }

    private static var url: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("BtrVoice", isDirectory: true)
            .appendingPathComponent("desktop-voice-memory.json")
    }

    private let lock = NSLock()
    private var state: State

    private init() {
        if let data = try? Data(contentsOf: Self.url),
           let decoded = try? JSONDecoder().decode(State.self, from: data) {
            state = decoded
        } else {
            state = State(preferredApplications: ["browser": "com.brave.Browser"])
        }
    }

    func preferredBundleIdentifier(for role: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        return state.preferredApplications[Self.normalize(role)]
    }

    func remember(bundleIdentifier: String, for role: String) {
        lock.lock()
        state.preferredApplications[Self.normalize(role)] = bundleIdentifier
        let snapshot = state
        lock.unlock()
        save(snapshot)
    }

    private func save(_ snapshot: State) {
        let directory = Self.url.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(snapshot)
            try data.write(to: Self.url, options: .atomic)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: Self.url.path
            )
        } catch {
            Log.write("desktop-voice: could not save memory — \(error.localizedDescription)")
        }
    }

    private static func normalize(_ value: String) -> String {
        value.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// Resolves spoken names and semantic roles into installed macOS applications.
/// Common roles are deterministic; ordinary app names are matched against a small
/// cached catalog of standard application folders and currently-running apps.
final class DesktopApplicationResolver {
    static let shared = DesktopApplicationResolver()

    private struct CatalogEntry {
        let normalizedNames: Set<String>
        let target: DesktopVoiceApplicationTarget
    }

    private let memory = DesktopVoiceMemory.shared
    private lazy var catalog: [CatalogEntry] = buildCatalog()

    func resolve(_ spokenName: String) -> DesktopVoiceApplicationTarget? {
        let normalized = Self.normalize(spokenName)
        guard !normalized.isEmpty else { return nil }

        if Self.browserAliases.contains(normalized) {
            return resolveBrowser()
        }

        if let knownIDs = Self.knownBundleIdentifiers[normalized] {
            for bundleID in knownIDs {
                if let target = target(bundleIdentifier: bundleID) { return target }
            }
        }

        if let running = NSWorkspace.shared.runningApplications.first(where: {
            Self.normalize($0.localizedName ?? "") == normalized
        }), let url = running.bundleURL {
            return DesktopVoiceApplicationTarget(
                displayName: running.localizedName ?? spokenName,
                bundleIdentifier: running.bundleIdentifier,
                applicationURL: url
            )
        }

        if let exact = catalog.first(where: { $0.normalizedNames.contains(normalized) }) {
            return exact.target
        }
        let prefixMatches = catalog.filter { entry in
            entry.normalizedNames.contains { $0.hasPrefix(normalized) || normalized.hasPrefix($0) }
        }
        return prefixMatches.count == 1 ? prefixMatches[0].target : nil
    }

    private func resolveBrowser() -> DesktopVoiceApplicationTarget? {
        if let preferred = memory.preferredBundleIdentifier(for: "browser"),
           let target = target(bundleIdentifier: preferred) {
            return target
        }
        for bundleID in ["com.brave.Browser", "com.google.Chrome", "com.apple.Safari"] {
            if let target = target(bundleIdentifier: bundleID) { return target }
        }
        guard let url = URL(string: "https://example.com"),
              let applicationURL = NSWorkspace.shared.urlForApplication(toOpen: url) else {
            return nil
        }
        return target(applicationURL: applicationURL)
    }

    private func target(bundleIdentifier: String) -> DesktopVoiceApplicationTarget? {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier) else {
            return nil
        }
        return target(applicationURL: url)
    }

    private func target(applicationURL: URL) -> DesktopVoiceApplicationTarget? {
        let bundle = Bundle(url: applicationURL)
        let name = (bundle?.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
            ?? (bundle?.object(forInfoDictionaryKey: "CFBundleName") as? String)
            ?? applicationURL.deletingPathExtension().lastPathComponent
        return DesktopVoiceApplicationTarget(
            displayName: name,
            bundleIdentifier: bundle?.bundleIdentifier,
            applicationURL: applicationURL
        )
    }

    private func buildCatalog() -> [CatalogEntry] {
        var urls: [URL] = []
        let homeApplications = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Applications", isDirectory: true)
        for directory in [
            URL(fileURLWithPath: "/Applications", isDirectory: true),
            URL(fileURLWithPath: "/Applications/Utilities", isDirectory: true),
            URL(fileURLWithPath: "/System/Applications", isDirectory: true),
            URL(fileURLWithPath: "/System/Applications/Utilities", isDirectory: true),
            homeApplications,
        ] {
            let contents = (try? FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            )) ?? []
            urls.append(contentsOf: contents.filter { $0.pathExtension.lowercased() == "app" })
        }

        var seen = Set<String>()
        return urls.compactMap { url in
            guard let target = target(applicationURL: url) else { return nil }
            let identity = target.bundleIdentifier ?? url.path
            guard seen.insert(identity).inserted else { return nil }
            let fileName = url.deletingPathExtension().lastPathComponent
            return CatalogEntry(
                normalizedNames: [Self.normalize(target.displayName), Self.normalize(fileName)],
                target: target
            )
        }
    }

    private static let browserAliases: Set<String> = [
        "browser", "web browser", "internet browser",
    ]

    private static let knownBundleIdentifiers: [String: [String]] = [
        "brave": ["com.brave.Browser"],
        "brave browser": ["com.brave.Browser"],
        "safari": ["com.apple.Safari"],
        "chrome": ["com.google.Chrome"],
        "google chrome": ["com.google.Chrome"],
        "telegram": ["ru.keepcoder.Telegram", "org.telegram.desktop"],
        "terminal": ["com.apple.Terminal"],
        "finder": ["com.apple.finder"],
        "mail": ["com.apple.mail"],
        "messages": ["com.apple.MobileSMS"],
        "notes": ["com.apple.Notes"],
        "visual studio code": ["com.microsoft.VSCode"],
        "vs code": ["com.microsoft.VSCode"],
    ]

    private static func normalize(_ value: String) -> String {
        value.lowercased()
            .replacingOccurrences(of: ".app", with: "")
            .split(whereSeparator: \Character.isWhitespace)
            .joined(separator: " ")
    }
}
