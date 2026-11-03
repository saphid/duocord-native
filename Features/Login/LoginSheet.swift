import SwiftUI
import WebKit

/// Discord's real login page in a web sheet, so captcha, passkeys and
/// two-factor are Discord's own. When the page stores its token, the sheet
/// hands it back with the super-properties header the page sent.
struct LoginSheet: View {
    let onSignedIn: (SessionCredentials) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var loading = true

    var body: some View {
        NavigationStack {
            LoginWebView(loading: $loading, onSignedIn: onSignedIn)
                .ignoresSafeArea(edges: .bottom)
                .overlay { if loading { ProgressView().controlSize(.large) } }
                .navigationTitle("Sign In to Discord")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel", systemImage: "xmark") { dismiss() }
                    }
                }
        }
        .interactiveDismissDisabled(false)
    }
}

private struct LoginWebView: UIViewRepresentable {
    @Binding var loading: Bool
    let onSignedIn: (SessionCredentials) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let content = configuration.userContentController
        content.addUserScript(WKUserScript(source: Self.captureScript, injectionTime: .atDocumentStart,
                                           forMainFrameOnly: true, in: .page))
        content.add(context.coordinator, contentWorld: .page, name: "duocordLogin")
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.customUserAgent = SessionCredentials.desktopSafariUA
        webView.navigationDelegate = context.coordinator
        webView.isInspectable = false
        webView.load(URLRequest(url: URL(string: "https://discord.com/login")!))
        context.coordinator.webView = webView
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {}

    static func dismantleUIView(_ webView: WKWebView, coordinator: Coordinator) {
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "duocordLogin", contentWorld: .page)
        webView.stopLoading()
    }

    /// Keeps a reference to localStorage before Discord hides it, reports the
    /// super-properties header from the page's own requests, and posts the
    /// token once the page has stored it.
    static let captureScript = """
    (() => {
      if (location.hostname !== 'discord.com') return;
      const storage = window.localStorage;
      const post = (m) => { try { window.webkit.messageHandlers.duocordLogin.postMessage(m); } catch (e) {} };
      const setHeader = XMLHttpRequest.prototype.setRequestHeader;
      XMLHttpRequest.prototype.setRequestHeader = function (name, value) {
        if (String(name).toLowerCase() === 'x-super-properties') post({ type: 'props', value: String(value) });
        return setHeader.apply(this, arguments);
      };
      const poll = () => {
        try {
          const raw = storage.getItem('token');
          if (raw) { post({ type: 'token', value: JSON.parse(raw), ua: navigator.userAgent }); return; }
        } catch (e) {}
        setTimeout(poll, 400);
      };
      poll();
    })();
    """

    final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        let parent: LoginWebView
        weak var webView: WKWebView?
        private var superProperties: String?
        private var finished = false
        private var filled = false

        init(parent: LoginWebView) { self.parent = parent }

        func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
            let origin = message.frameInfo.securityOrigin
            guard message.frameInfo.isMainFrame, origin.protocol == "https", origin.host == "discord.com",
                  let body = message.body as? [String: Any], let type = body["type"] as? String else { return }
            switch type {
            case "props":
                superProperties = body["value"] as? String
            case "token":
                guard !finished, let token = body["value"] as? String, token.count > 20 else { return }
                finished = true
                let ua = body["ua"] as? String ?? SessionCredentials.desktopSafariUA
                parent.onSignedIn(SessionCredentials(token: token, superProperties: superProperties, userAgent: ua))
            default:
                break
            }
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            parent.loading = false
            fillSavedLogin(webView)
        }

        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction) async -> WKNavigationActionPolicy {
            guard let url = action.request.url, let host = url.host else { return .cancel }
            // Discord, its captcha providers and Apple/Google sign-in pages.
            let allowed = ["discord.com", "hcaptcha.com", "recaptcha.net", "google.com", "gstatic.com", "apple.com"]
            if action.targetFrame?.isMainFrame == false { return .allow }
            return allowed.contains(where: { host == $0 || host.hasSuffix("." + $0) }) ? .allow : .cancel
        }

        /// Pre-fills (never submits) a login saved on this device.
        private func fillSavedLogin(_ webView: WKWebView) {
            guard !filled, webView.url?.host == "discord.com", webView.url?.path.hasPrefix("/login") == true,
                  let login = LoginStore.load() else { return }
            filled = true
            let script = """
            for (let i = 0; i < 40 && !document.querySelector('input[name="email"]'); i++) {
              await new Promise((r) => setTimeout(r, 250));
            }
            const email = document.querySelector('input[name="email"]');
            const password = document.querySelector('input[name="password"]');
            if (!email || !password || location.hostname !== 'discord.com') return 'no-form';
            const setter = Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, 'value').set;
            for (const [input, value] of [[email, e], [password, p]]) {
              input.focus();
              setter.call(input, value);
              input.dispatchEvent(new Event('input', { bubbles: true }));
              input.dispatchEvent(new Event('change', { bubbles: true }));
            }
            password.blur();
            if (submit) {
              const button = document.querySelector('form button[type="submit"]') || document.querySelector('button[type="submit"]');
              await new Promise((r) => setTimeout(r, 200));
              if (button) button.click();
            }
            return 'filled';
            """
            // Debug simulator runs may submit automatically; release builds only pre-fill.
            // Owner-provisioned installs sign in once on their own; otherwise
            // the form is only pre-filled (debug simulator runs may opt in).
            var submit = UserDefaults.standard.bool(forKey: LoginStore.autoSignInKey)
            UserDefaults.standard.removeObject(forKey: LoginStore.autoSignInKey)
            #if DEBUG
            submit = submit || UserDefaults.standard.bool(forKey: "DuocordAutoSubmitLogin")
            #endif
            webView.callAsyncJavaScript(script, arguments: ["e": login.email, "p": login.password, "submit": submit],
                                        in: nil, in: .defaultClient) { _ in }
        }
    }
}
