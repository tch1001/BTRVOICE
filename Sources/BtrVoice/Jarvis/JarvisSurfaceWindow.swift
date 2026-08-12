import AppKit
import SwiftUI
import WebKit

/// The fleet's realtime voice console embedded inside BtrVoice.
///
/// Audio capture, turn detection, speech playback, interruptions, captions, task
/// visibility, and text fallback all belong to the Jarvis Voice web surface. Keeping
/// that pipeline in one place means BtrVoice no longer transcribes a sentence, waits
/// for a text answer, and speaks it back with the system synthesizer. The ordinary
/// BtrVoice dictation controller remains completely separate.
struct JarvisSurfaceView: View {
    @ObservedObject private var service = JarvisVoiceService.shared

    var body: some View {
        ZStack {
            Color(nsColor: .windowBackgroundColor)
                .ignoresSafeArea()

            switch service.state {
            case .ready:
                JarvisVoiceWebView(url: service.pageURL)
            case .idle, .starting:
                startupView
            case .failed(let message):
                failureView(message)
            }
        }
        .frame(minWidth: 680, minHeight: 620)
        .onAppear { service.ensureRunning() }
    }

    private var startupView: some View {
        VStack(spacing: 14) {
            ProgressView()
                .controlSize(.large)
            Text("Starting Jarvis Voice…")
                .font(.title3.weight(.semibold))
            Text(service.statusMessage)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(28)
    }

    private func failureView(_ message: String) -> some View {
        VStack(spacing: 14) {
            Image(systemName: "waveform.slash")
                .font(.system(size: 38, weight: .light))
                .foregroundStyle(.orange)
            Text("Jarvis Voice could not start")
                .font(.title3.weight(.semibold))
            Text(message)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .textSelection(.enabled)
                .frame(maxWidth: 520)
            HStack {
                Button("Retry") { service.retry() }
                    .keyboardShortcut(.defaultAction)
                Button("Open BtrVoice Log") { NSWorkspace.shared.open(Log.fileURL) }
            }
        }
        .padding(28)
    }
}

/// A narrowly-scoped web view: Jarvis may navigate within its configured voice
/// origin, while ordinary links leave the app and open in the user's browser. Only
/// that origin can receive microphone permission from WebKit.
private struct JarvisVoiceWebView: NSViewRepresentable {
    let url: URL

    func makeCoordinator() -> Coordinator {
        Coordinator(allowedOrigin: url)
    }

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        configuration.mediaTypesRequiringUserActionForPlayback = []

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.uiDelegate = context.coordinator
        webView.allowsMagnification = true
        webView.load(URLRequest(url: url))
        context.coordinator.loadedURL = url
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        guard context.coordinator.loadedURL != url else { return }
        context.coordinator.loadedURL = url
        webView.load(URLRequest(url: url))
    }

    static func dismantleNSView(_ webView: WKWebView, coordinator: Coordinator) {
        coordinator.cancelRetry()
        webView.stopLoading()
        webView.navigationDelegate = nil
        webView.uiDelegate = nil
    }

    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
        let allowedOrigin: URL
        var loadedURL: URL?
        private var retry: DispatchWorkItem?

        init(allowedOrigin: URL) {
            self.allowedOrigin = allowedOrigin
        }

        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction,
            decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
        ) {
            guard let destination = navigationAction.request.url else {
                decisionHandler(.cancel)
                return
            }
            if sameOrigin(destination, allowedOrigin) {
                decisionHandler(.allow)
            } else {
                if navigationAction.navigationType == .linkActivated {
                    NSWorkspace.shared.open(destination)
                }
                decisionHandler(.cancel)
            }
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            cancelRetry()
        }

        func webView(
            _ webView: WKWebView,
            didFailProvisionalNavigation navigation: WKNavigation!,
            withError error: Error
        ) {
            scheduleRetry(webView)
        }

        func webView(
            _ webView: WKWebView,
            didFail navigation: WKNavigation!,
            withError error: Error
        ) {
            scheduleRetry(webView)
        }

        func cancelRetry() {
            retry?.cancel()
            retry = nil
        }

        private func scheduleRetry(_ webView: WKWebView) {
            guard retry == nil, let loadedURL else { return }
            let work = DispatchWorkItem { [weak self, weak webView] in
                guard let self, let webView else { return }
                self.retry = nil
                webView.load(URLRequest(url: loadedURL, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData))
            }
            retry = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0, execute: work)
        }

        func webView(
            _ webView: WKWebView,
            requestMediaCapturePermissionFor origin: WKSecurityOrigin,
            initiatedByFrame frame: WKFrameInfo,
            type: WKMediaCaptureType,
            decisionHandler: @escaping (WKPermissionDecision) -> Void
        ) {
            let originMatches = origin.host.caseInsensitiveCompare(allowedOrigin.host ?? "") == .orderedSame
            let microphoneOnly = type == .microphone
            decisionHandler(originMatches && microphoneOnly ? .grant : .deny)
        }

        private func sameOrigin(_ left: URL, _ right: URL) -> Bool {
            left.scheme?.lowercased() == right.scheme?.lowercased()
                && left.host?.lowercased() == right.host?.lowercased()
                && effectivePort(left) == effectivePort(right)
        }

        private func effectivePort(_ url: URL) -> Int? {
            if let port = url.port { return port }
            if url.scheme?.lowercased() == "https" { return 443 }
            if url.scheme?.lowercased() == "http" { return 80 }
            return nil
        }
    }
}

/// Owns the window so the menu can summon the same Realtime surface repeatedly.
@MainActor
final class JarvisSurfaceWindowController: NSObject, NSWindowDelegate {
    static let shared = JarvisSurfaceWindowController()
    private var window: NSWindow?

    func show() {
        if let window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let hosting = NSHostingController(rootView: JarvisSurfaceView())
        let win = NSWindow(contentViewController: hosting)
        win.title = "Jarvis Voice"
        win.setContentSize(NSSize(width: 900, height: 760))
        win.minSize = NSSize(width: 680, height: 620)
        win.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        win.isReleasedWhenClosed = false
        win.delegate = self
        win.center()
        window = win
        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func windowWillClose(_ notification: Notification) {
        window = nil
    }
}
