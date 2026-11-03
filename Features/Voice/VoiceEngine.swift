import AVFoundation
import UIKit
import WebKit
import os

/// Discord voice requires DAVE end-to-end encryption (MLS) on every call
/// since March 2026, which a native client could only provide by embedding
/// libdave with its own voice transport. Duocord instead keeps voice in a
/// contained engine: a hidden web view running Discord's own web client,
/// created only for a call and destroyed when it ends. The native UI never
/// reads this page; call state comes from the native gateway.
final class VoiceEngine: NSObject, WKUIDelegate, WKNavigationDelegate {
    private var webView: WKWebView?
    private let credentials: SessionCredentials
    private let log = Logger(subsystem: "com.saphid.duocord.native", category: "voice")
    private var joinTask: Task<Void, Never>?
    var onFailure: ((String) -> Void)?

    init(credentials: SessionCredentials) {
        self.credentials = credentials
    }

    var isRunning: Bool { webView != nil }

    func join(guild: Snowflake, channel: Snowflake) {
        let webView = webView ?? makeWebView()
        joinTask?.cancel()
        let url = URL(string: "https://discord.com/channels/\(guild)/\(channel)")!
        if webView.url?.host != "discord.com" { webView.load(URLRequest(url: url)) }
        joinTask = Task { [weak self] in
            // Wait for Discord's sidebar, then join with the channel row's own click.
            for _ in 0..<60 {
                try? await Task.sleep(for: .milliseconds(500))
                guard let self, !Task.isCancelled else { return }
                let script = """
                const row = document.querySelector('[data-list-item-id="channels___\(channel)"]');
                if (!row) return 'waiting';
                const panel = document.querySelector('[class*="sidebar"] [class*="panels"]');
                if (panel && panel.querySelector('[aria-label="Disconnect"]')) return 'joined';
                row.click();
                return 'clicked';
                """
                let result = try? await self.webView?.callAsyncJavaScript(script, contentWorld: .defaultClient) as? String
                if result == "joined" { return }
            }
            self?.onFailure?("Voice didn't connect.")
            self?.tearDown()
        }
    }

    func toggleMute() { press("button[role=\"switch\"][aria-label=\"Mute\"]") }
    func toggleDeafen() { press("button[role=\"switch\"][aria-label=\"Deafen\"]") }

    func leave() {
        joinTask?.cancel()
        press("[aria-label=\"Disconnect\"]")
        // Give the page a moment to send its voice state, then drop the engine.
        // Strong capture: the engine must live until it has torn itself down,
        // or a failed Disconnect could leave the call and microphone running.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { self.tearDown() }
    }

    func tearDown() {
        joinTask?.cancel()
        webView?.stopLoading()
        webView?.removeFromSuperview()
        webView = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
    }

    private func press(_ selector: String) {
        let script = """
        const panel = document.querySelector('[class*="sidebar"] [class*="panels"]') || document;
        const control = panel.querySelector(selector) || document.querySelector(selector);
        if (control) control.click();
        return !!control;
        """
        webView?.callAsyncJavaScript(script, arguments: ["selector": selector], in: nil, in: .defaultClient) { [weak self] result in
            if case .failure(let error) = result { self?.log.error("voice control: \(error.localizedDescription, privacy: .public)") }
        }
    }

    private func makeWebView() -> WKWebView {
        let configuration = WKWebViewConfiguration()
        // Nothing from the voice page persists between calls.
        configuration.websiteDataStore = .nonPersistent()
        configuration.allowsInlineMediaPlayback = true
        configuration.mediaTypesRequiringUserActionForPlayback = []
        let token = (try? JSONEncoder().encode(credentials.token)).flatMap { String(data: $0, encoding: .utf8) } ?? "\"\""
        let tokenScript = """
        if (location.hostname === 'discord.com') {
          try { window.localStorage.setItem('token', JSON.stringify(\(token))); } catch (e) {}
        }
        """
        configuration.userContentController.addUserScript(
            WKUserScript(source: tokenScript, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        let webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 1280, height: 800), configuration: configuration)
        webView.customUserAgent = credentials.userAgent
        webView.uiDelegate = self
        webView.navigationDelegate = self
        webView.isUserInteractionEnabled = false
        webView.accessibilityElementsHidden = true
        webView.alpha = 0.01
        // In a window (so WebKit keeps audio running), behind the app's views.
        if let window = UIApplication.shared.connectedScenes.compactMap({ ($0 as? UIWindowScene)?.keyWindow }).first {
            window.insertSubview(webView, at: 0)
        }
        try? AVAudioSession.sharedInstance().setCategory(.playAndRecord, mode: .voiceChat, options: [.allowBluetoothHFP, .defaultToSpeaker])
        try? AVAudioSession.sharedInstance().setActive(true)
        self.webView = webView
        return webView
    }

    // Only Discord itself gets the microphone.
    func webView(_ webView: WKWebView, requestMediaCapturePermissionFor origin: WKSecurityOrigin,
                 initiatedByFrame frame: WKFrameInfo, type: WKMediaCaptureType,
                 decisionHandler: @escaping (WKPermissionDecision) -> Void) {
        decisionHandler(origin.protocol == "https" && origin.host == "discord.com" && type == .microphone ? .grant : .deny)
    }

    // The engine never navigates away from Discord.
    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction) async -> WKNavigationActionPolicy {
        guard let host = action.request.url?.host else { return .cancel }
        if action.targetFrame?.isMainFrame == false { return .allow }
        return host == "discord.com" ? .allow : .cancel
    }
}
