import AppKit
import WebKit
import SwiftUI
import Observation
import GrokCore

@MainActor @Observable
final class LoginBrowser: NSObject, WKNavigationDelegate, WKUIDelegate {
    let webView: WKWebView
    private(set) var isLoading = false
    private(set) var failure: String?
    private(set) var location = "https://grok.com"
    @ObservationIgnored private var started = false
    @ObservationIgnored private var popups: [NSWindow] = []

    override init() {
        let configuration = WKWebViewConfiguration()
        // Cookies persist only in Keychain after the user connects the session.
        configuration.websiteDataStore = .nonPersistent()
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = true
        webView = WKWebView(frame: .zero, configuration: configuration)
        super.init()
        webView.navigationDelegate = self
        webView.uiDelegate = self
    }

    func start() {
        guard !started else { return }
        started = true
        webView.load(URLRequest(url: URL(string: "https://grok.com/")!))
    }

    func reload() {
        failure = nil
        if webView.url == nil { started = false; start() } else { webView.reload() }
    }

    func seed(_ credentials: SessionCredentials) async {
        webView.customUserAgent = credentials.userAgent
        for (name, value) in credentials.cookies {
            if let cookie = HTTPCookie(properties: [.domain: ".grok.com", .path: "/", .name: name, .value: value, .secure: "TRUE"]) {
                await webView.configuration.websiteDataStore.httpCookieStore.setCookie(cookie)
            }
        }
    }

    func credentials() async throws -> SessionCredentials {
        let cookies = await webView.configuration.websiteDataStore.httpCookieStore.allCookies()
        var values: [String: String] = [:]
        for cookie in cookies where SessionCredentials.isGrokDomain(cookie.domain) {
            guard cookie.expiresDate.map({ $0 > Date() }) ?? true else { continue }
            values[cookie.name] = cookie.value
        }
        let userAgent = (try? await webView.evaluateJavaScript("navigator.userAgent")) as? String
        return try SessionCredentials(cookies: values, userAgent: userAgent ?? SessionCredentials.defaultUserAgent)
    }

    func closePopups() { popups.forEach { $0.close() }; popups.removeAll() }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        isLoading = true
        failure = nil
        location = webView.url?.absoluteString ?? location
    }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        isLoading = false
        location = webView.url?.absoluteString ?? location
    }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        isLoading = false
        if (error as NSError).code != NSURLErrorCancelled { failure = error.localizedDescription }
    }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        isLoading = false
        failure = error.localizedDescription
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let url = navigationAction.request.url else { decisionHandler(.cancel); return }
        if ["https", "about"].contains(url.scheme?.lowercased() ?? "") {
            decisionHandler(.allow)
        } else {
            // External identity-provider apps may handle their own callback schemes.
            if navigationAction.navigationType == .linkActivated { NSWorkspace.shared.open(url) }
            decisionHandler(.cancel)
        }
    }

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        let popup = WKWebView(frame: .zero, configuration: configuration)
        popup.navigationDelegate = self
        popup.uiDelegate = self
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 760),
                              styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.title = L10n.text("Sign in to Grok")
        window.contentView = popup
        window.center()
        window.makeKeyAndOrderFront(nil)
        popups.append(window)
        return popup
    }

    func webViewDidClose(_ webView: WKWebView) {
        popups.first { $0.contentView === webView }?.close()
        popups.removeAll { $0.contentView === webView }
    }
}

@MainActor struct BrowserView: NSViewRepresentable {
    let browser: LoginBrowser
    func makeNSView(context: Context) -> WKWebView { browser.webView }
    func updateNSView(_ nsView: WKWebView, context: Context) {}
}
