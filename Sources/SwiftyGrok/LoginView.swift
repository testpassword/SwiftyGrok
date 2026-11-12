import SwiftUI
import AppKit
import GrokCore
import UniformTypeIdentifiers

@MainActor struct LoginView: View {
    @Bindable var app: AppModel
    let canDismiss: Bool
    @State private var importText = ""
    @State private var userAgent = SessionCredentials.defaultUserAgent
    @State private var showImport = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 14) {
                Image(appSymbol: "sparkle").font(.system(size: 30, weight: .light))
                VStack(alignment: .leading, spacing: 4) {
                    Text(L10n.text("Connect Grok")).font(.title2.bold())
                    Text(L10n.text("Sign in at grok.com, then click “Connect session”."))
                        .font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                if canDismiss { Button(L10n.text("Close")) { app.showLogin = false }.disabled(app.isConnecting) }
            }
            .padding(20)
            Divider()
            HStack {
                Image(appSymbol: "lock.shield").foregroundStyle(.secondary)
                Text(app.browser.location).font(.caption).lineLimit(1).textSelection(.enabled)
                Spacer()
                if app.browser.isLoading { ProgressView().controlSize(.small) }
                Button { app.browser.reload() } label: { Image(appSymbol: "arrow.clockwise") }
                    .help(L10n.text("Reload sign-in page"))
            }
            .padding(.horizontal, 20).padding(.vertical, 8)
            BrowserView(browser: app.browser)
                .id(ObjectIdentifier(app.browser))
                .task { app.browser.start() }
            if let error = app.loginError ?? app.browser.failure {
                Text(error).font(.callout).foregroundStyle(.red).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(12)
            }
            Divider()
            VStack(spacing: 12) {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(L10n.text("Your session is stored in macOS Keychain.")).font(.callout)
                        Text(L10n.text("If sign-in fails, import cookies from your browser."))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button(L10n.text("Import cookies…")) { showImport = true }.disabled(app.isConnecting)
                    Button {
                        Task { await app.connectBrowser() }
                    } label: {
                        HStack {
                            if app.isConnecting { ProgressView().controlSize(.small) }
                            Text(L10n.text("Connect session"))
                        }
                    }
                    .buttonStyle(.borderedProminent).disabled(app.isConnecting)
                }
            }
            .padding(16)
        }
        .sheet(isPresented: $showImport) { importSheet }
    }

    private var importSheet: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(L10n.text("Import browser session")).font(.title2.bold())
            Text(L10n.text("On grok.com, open DevTools → Network, select a request to /rest/app-chat/conversations, and copy the Cookie header value. You can also import swift-grok JSON or exported cookies for grok.com."))
                .font(.callout).foregroundStyle(.secondary)
            SecureField("sso=…; sso-rw=…; cf_clearance=…", text: $importText)
                .textFieldStyle(.roundedBorder)
            HStack {
                Button(L10n.text("Open JSON…"), action: readFile)
                Text(importText.isEmpty ? L10n.text("No session provided") : L10n.text("Session data entered")).font(.caption).foregroundStyle(.secondary)
            }
            Text(L10n.text("User-Agent from the same browser")).font(.headline)
            TextField("User-Agent", text: $userAgent).textFieldStyle(.roundedBorder)
            Text(L10n.text("Run navigator.userAgent in the browser console. For cf_clearance, use the same User-Agent and network connection."))
                .font(.caption).foregroundStyle(.secondary)
            if let error = app.loginError { Text(error).foregroundStyle(.red).font(.callout) }
            HStack {
                Spacer()
                Button(L10n.text("Cancel")) { importText = ""; showImport = false }.disabled(app.isConnecting)
                Button(L10n.text("Connect")) {
                    Task {
                        await app.connectImport(importText, userAgent: userAgent)
                        if app.loginError == nil { importText = ""; showImport = false }
                    }
                }
                .buttonStyle(.borderedProminent).disabled(importText.isEmpty || app.isConnecting)
            }
        }
        .padding(24).frame(width: 640)
        .interactiveDismissDisabled(app.isConnecting)
    }

    private func readFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { importText = try String(contentsOf: url, encoding: .utf8) }
        catch { app.loginError = L10n.format("Could not read JSON: %@", error.localizedDescription) }
    }
}
