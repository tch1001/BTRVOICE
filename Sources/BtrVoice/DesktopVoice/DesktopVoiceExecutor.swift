import AppKit
import Foundation

/// Executes fast desktop plans with native macOS application launching and the
/// existing focus-safe synthetic-key path. Screenshot-driven Computer Use will be
/// a fallback executor later; common commands never need to wait for it.
struct DesktopVoiceExecutionResult {
    let message: String
    let target: NSRunningApplication?
}

final class DesktopVoiceExecutor {
    private let workspace = NSWorkspace.shared
    private let selfPID = ProcessInfo.processInfo.processIdentifier

    func execute(
        _ plan: DesktopVoicePlan,
        preferredTarget: NSRunningApplication?,
        completion: @escaping (Result<DesktopVoiceExecutionResult, Error>) -> Void
    ) {
        execute(
            plan.actions,
            index: 0,
            target: usable(preferredTarget),
            finalMessage: plan.summary,
            completion: completion
        )
    }

    private func execute(
        _ actions: [DesktopVoiceAction],
        index: Int,
        target: NSRunningApplication?,
        finalMessage: String,
        completion: @escaping (Result<DesktopVoiceExecutionResult, Error>) -> Void
    ) {
        guard index < actions.count else {
            completion(.success(DesktopVoiceExecutionResult(message: finalMessage, target: target)))
            return
        }

        switch actions[index] {
        case .openApplication(let application):
            open(application) { [weak self] result in
                guard let self else { return }
                switch result {
                case .failure(let error):
                    completion(.failure(error))
                case .success(let launched):
                    self.waitUntilActive(launched, deadline: Date().addingTimeInterval(1.4)) {
                        self.execute(
                            actions,
                            index: index + 1,
                            target: launched,
                            finalMessage: finalMessage,
                            completion: completion
                        )
                    }
                }
            }

        case .pressShortcut(let combo):
            guard Permissions.accessibilityGranted else {
                completion(.failure(DesktopVoiceExecutionError.accessibilityRequired))
                return
            }
            guard let parsed = TextInjector.parseCombo(combo) else {
                completion(.failure(DesktopVoiceExecutionError.invalidShortcut(combo)))
                return
            }

            let resolvedTarget = usable(target)
                ?? usable(workspace.frontmostApplication)
            if let resolvedTarget, !resolvedTarget.isActive {
                resolvedTarget.activate(options: [])
            }
            TextInjector.pressCombo(key: parsed.key, flags: parsed.flags) { [weak self] result in
                guard let self else { return }
                switch result {
                case .failure(let error):
                    completion(.failure(error))
                case .success:
                    self.execute(
                        actions,
                        index: index + 1,
                        target: resolvedTarget,
                        finalMessage: finalMessage,
                        completion: completion
                    )
                }
            }
        }
    }

    private func open(
        _ target: DesktopVoiceApplicationTarget,
        completion: @escaping (Result<NSRunningApplication, Error>) -> Void
    ) {
        if let bundleID = target.bundleIdentifier,
           let running = workspace.runningApplications.first(where: {
               $0.bundleIdentifier == bundleID && !$0.isTerminated
           }) {
            running.activate(options: [])
            completion(.success(running))
            return
        }

        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        configuration.addsToRecentItems = false
        workspace.openApplication(at: target.applicationURL, configuration: configuration) { application, error in
            DispatchQueue.main.async {
                if let error {
                    completion(.failure(error))
                } else if let application {
                    completion(.success(application))
                } else {
                    completion(.failure(DesktopVoiceExecutionError.applicationDidNotLaunch(target.displayName)))
                }
            }
        }
    }

    private func waitUntilActive(
        _ application: NSRunningApplication,
        deadline: Date,
        completion: @escaping () -> Void
    ) {
        guard !application.isActive, Date() < deadline else {
            completion()
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            self?.waitUntilActive(application, deadline: deadline, completion: completion)
        }
    }

    private func usable(_ application: NSRunningApplication?) -> NSRunningApplication? {
        guard let application,
              application.processIdentifier != selfPID,
              !application.isTerminated else { return nil }
        return application
    }
}

enum DesktopVoiceExecutionError: LocalizedError {
    case accessibilityRequired
    case invalidShortcut(String)
    case applicationDidNotLaunch(String)

    var errorDescription: String? {
        switch self {
        case .accessibilityRequired:
            return "Accessibility access is required for keyboard shortcuts in other apps."
        case .invalidShortcut(let shortcut):
            return "The shortcut \(shortcut) is not supported."
        case .applicationDidNotLaunch(let name):
            return "macOS did not launch \(name)."
        }
    }
}
