/// Takes one fresh view of the user's active display for a spoken screen question.
/// Images stay in memory and travel only with the current model conversation.
import AppKit
import ApplicationServices
import ScreenCaptureKit

struct DesktopScreenSnapshot {
    let jpeg: Data?
    let width: Int
    let height: Int
    let displayID: CGDirectDisplayID
    let application: String
    let capturedAt: Date
    var accessibility: DesktopAccessibilityContext = .empty
    var imageUnavailable: String?

    var metadata: [String: Any] {
        ["captured": true, "width": width, "height": height,
         "display_id": displayID, "application": application,
         "has_image": jpeg != nil, "accessibility_elements": accessibility.elementCount,
         "accessibility_truncated": accessibility.truncated,
         "captured_at": ISO8601DateFormatter().string(from: capturedAt)]
    }

    var imageContent: [String: Any]? {
        guard let jpeg else { return nil }
        return ["type": "input_image", "image_url": "data:image/jpeg;base64,\(jpeg.base64EncodedString())"]
    }

}

/// Starts semantic reads immediately. Screenshots are lazy, and must still belong
/// to the pinned task app when captured; switching apps cannot relabel an image.
@MainActor
final class DesktopScreenRead {
    private let application: NSRunningApplication?
    private let accessibilityTask: Task<DesktopAccessibilityContext, Never>
    private var imageTask: Task<DesktopScreenSnapshot, Error>?
    private let capturedAt = Date()

    init(preferredApplication: NSRunningApplication?, scope: DesktopUIScope = .window,
         root: AXUIElement? = nil, offset: Int = 0) {
        let frontmost = NSWorkspace.shared.frontmostApplication
        let app = preferredApplication ?? (frontmost?.processIdentifier == ProcessInfo.processInfo.processIdentifier ? nil : frontmost)
        application = app
        let pid = app?.processIdentifier
        accessibilityTask = Task.detached(priority: .userInitiated) {
            guard let pid else { return .empty }
            return DesktopAccessibilityReader.read(processIdentifier: pid, scope: scope, root: root, offset: offset)
        }
        // Start image capture only when actually requested. Most semantic reads
        // need no image, and speculative capture adds load to every action.
    }

    func snapshot(includeImage: Bool = false) async throws -> DesktopScreenSnapshot {
        let accessible = await accessibilityTask.value
        try Task.checkCancellation()
        var text = DesktopScreenSnapshot(jpeg: nil, width: 0, height: 0, displayID: 0,
                                        application: application?.localizedName ?? "Unknown", capturedAt: capturedAt)
        text.accessibility = accessible
        if !includeImage, !accessible.text.isEmpty { return text }
        if imageTask == nil {
            let app = application
            guard let app, NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier else {
                text.imageUnavailable = "The task app is no longer in front; no image of the other app was captured."
                return text
            }
            imageTask = Task { try await DesktopScreenReader.captureImage(application: app) }
        }
        do {
            var image = try await imageTask!.value
            try Task.checkCancellation()
            guard NSWorkspace.shared.frontmostApplication?.processIdentifier == application?.processIdentifier else {
                text.imageUnavailable = "Focus changed during capture; that image was discarded."
                return text
            }
            image.accessibility = accessible
            return image
        } catch {
            try Task.checkCancellation()
            guard !accessible.text.isEmpty else { throw error }
            text.imageUnavailable = error.localizedDescription
            return text
        }
    }

    func cancel() {
        accessibilityTask.cancel()
        imageTask?.cancel()
    }
}

enum DesktopScreenReader {
    enum CaptureError: LocalizedError {
        case permissionRequired, unavailable, timedOut, encodingFailed

        var errorDescription: String? {
            switch self {
            case .permissionRequired:
                return "A screen image needs Screen Recording access. Enable BtrVoice in System Settings → Privacy & Security → Screen & System Audio Recording, then ask again. Accessibility access can provide text and controls without an image. macOS may require an app restart."
            case .unavailable: return "No visible display is available to read."
            case .timedOut: return "Screen capture took too long. Please try again."
            case .encodingFailed: return "The screen image could not be prepared."
            }
        }
    }

    /// Quartz window and display coordinates share a top-left origin, including
    /// displays above or left of the main display. Never mix these with NSEvent points.
    static func displayIndex(frames: [CGRect], window: CGRect?, mainIndex: Int) -> Int? {
        guard !frames.isEmpty else { return nil }
        if let window {
            let areas = frames.map { frame -> CGFloat in
                let overlap = frame.intersection(window)
                return overlap.isNull ? 0 : overlap.width * overlap.height
            }
            if let largest = areas.max(), largest > 0 { return areas.firstIndex(of: largest) }
        }
        return frames.indices.contains(mainIndex) ? mainIndex : 0
    }

    static func imageSize(width: Int, height: Int) -> (width: Int, height: Int) {
        let scale = min(1, 2560.0 / Double(max(1, max(width, height))))
        return (max(1, Int(Double(width) * scale)), max(1, Int(Double(height) * scale)))
    }

    @MainActor
    static func capture(preferredApplication: NSRunningApplication? = nil,
                        includeImage: Bool = false) async throws -> DesktopScreenSnapshot {
        let read = DesktopScreenRead(preferredApplication: preferredApplication)
        defer { read.cancel() }
        return try await read.snapshot(includeImage: includeImage)
    }

    @MainActor
    static func captureImage(application app: NSRunningApplication?) async throws -> DesktopScreenSnapshot {
        try Task.checkCancellation()
        // Request only in response to the user's screen tool, never at app startup.
        guard CGPreflightScreenCaptureAccess() || CGRequestScreenCaptureAccess() else {
            throw CaptureError.permissionRequired
        }
        let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
            as? [[String: Any]] ?? []
        let front = windows.first {
            ($0[kCGWindowOwnerPID as String] as? Int32) == app?.processIdentifier
                && ($0[kCGWindowLayer as String] as? Int) == 0
        }
        let bounds = (front?[kCGWindowBounds as String] as? NSDictionary)
            .flatMap { CGRect(dictionaryRepresentation: $0) }
        let content: SCShareableContent = try await bounded { completion in
            SCShareableContent.getExcludingDesktopWindows(true, onScreenWindowsOnly: true) {
                value, error in completion(value, error)
            }
        }
        try Task.checkCancellation()
        guard let index = displayIndex(
            frames: content.displays.map(\.frame), window: bounds,
            mainIndex: content.displays.firstIndex { $0.displayID == CGMainDisplayID() } ?? 0
        ) else { throw CaptureError.unavailable }
        let display = content.displays[index]
        let overlay = content.applications.filter {
            $0.processID == ProcessInfo.processInfo.processIdentifier
        }
        let filter = SCContentFilter(display: display, excludingApplications: overlay, exceptingWindows: [])
        let config = SCStreamConfiguration()
        let size = imageSize(width: display.width, height: display.height)
        config.width = size.width
        config.height = size.height
        config.showsCursor = true
        config.capturesAudio = false
        let image: CGImage = try await bounded { completion in
            SCScreenshotManager.captureImage(contentFilter: filter, configuration: config) {
                value, error in completion(value, error)
            }
        }
        try Task.checkCancellation()
        guard let jpeg = NSBitmapImageRep(cgImage: image).representation(
            using: .jpeg, properties: [.compressionFactor: 0.85]
        ), jpeg.count <= 5_000_000 else { throw CaptureError.encodingFailed }
        return DesktopScreenSnapshot(
            jpeg: jpeg, width: image.width, height: image.height,
            displayID: display.displayID, application: app?.localizedName ?? "Unknown",
            capturedAt: Date()
        )
    }

    /// A late OS callback must neither hang voice nor resume a continuation twice.
    private static func bounded<T>(
        _ operation: (@escaping (T?, Error?) -> Void) -> Void
    ) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            let reply = ScreenCaptureReply(continuation)
            DispatchQueue.global().asyncAfter(deadline: .now() + 8) {
                reply.finish(nil, CaptureError.timedOut)
            }
            operation { reply.finish($0, $1) }
        }
    }
}

private final class ScreenCaptureReply<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T, Error>?

    init(_ continuation: CheckedContinuation<T, Error>) { self.continuation = continuation }

    func finish(_ value: T?, _ error: Error?) {
        lock.lock()
        let pending = continuation
        continuation = nil
        lock.unlock()
        if let error { pending?.resume(throwing: error) }
        else if let value { pending?.resume(returning: value) }
        else { pending?.resume(throwing: DesktopScreenReader.CaptureError.unavailable) }
    }
}
