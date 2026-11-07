import SwiftUI
import AppKit
import GrokCore

@main
@MainActor
struct SwiftyGrokApp: App {
    @NSApplicationDelegateAdaptor(GrokAppDelegate.self) private var delegate
    @State private var app = AppModel()
    @State private var behavior = BehaviorSettings.shared
    var body: some Scene {
        Window("SwiftyGrok", id: "main") {
            RootView(app: app)
                .frame(minWidth: 600, minHeight: 420)
                .task { delegate.configure(app: app); await app.restore() }
        }
        .defaultSize(width: 1120, height: 780)
        .windowResizability(.contentMinSize)
        .windowStyle(.titleBar)
        .commands {
            CommandGroup(replacing: .appInfo) {
                Button(L10n.text("About SwiftyGrok")) { AboutPanel.show() }
            }
            CommandGroup(replacing: .appSettings) {
                Button { app.openSettings() } label: {
                    Label(L10n.text("Settings…"), systemImage: "gearshape")
                }
                .keyboardShortcut(",", modifiers: .command)
                .disabled(app.showLogin)
            }
            CommandGroup(replacing: .newItem) {
                Button(L10n.text("New chat")) { app.store?.newChat(); app.quickInput.openMain() }
                    .keyboardShortcut("n", modifiers: .command)
                    .disabled(app.store == nil || app.store?.isSending == true)
            }
            CommandGroup(after: .newItem) {
                Button(L10n.text("Quick input…")) { app.quickInput.show() }
                    .disabled(!behavior.quickInputEnabled)
                if let error = app.quickInput.shortcutError { Text(error) }
                Button(L10n.text("Refresh chat")) { Task { await app.store?.loadSelectedConversation() } }
                    .keyboardShortcut("r", modifiers: .command)
                    .disabled(app.store?.selectedConversationID == nil || app.store?.isSending == true)
                Button(L10n.text("Refresh history")) { Task { await app.store?.refreshHistory() } }
                    .keyboardShortcut("r", modifiers: [.command, .shift])
                    .disabled(app.store == nil)
            }
        }
    }
}

@MainActor final class GrokAppDelegate: NSObject, NSApplicationDelegate {
    weak var quickInput: QuickInputController?
    private weak var app: AppModel?
    private var pendingFileURLs: [URL] = []
    private var pendingWidgetRefresh = false
    private var appearanceObservation: NSKeyValueObservation?

    func configure(app: AppModel) {
        self.app = app
        quickInput = app.quickInput
        ReplyNotifications.shared.configure { [weak app] id in app?.openReplyNotification(id) }
        if pendingWidgetRefresh { pendingWidgetRefresh = false; app.openWidgetSettings() }
        if !pendingFileURLs.isEmpty {
            let urls = pendingFileURLs
            pendingFileURLs.removeAll()
            app.receiveFinderFiles(urls)
        }
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        if urls.contains(where: { $0.scheme == "swiftygrok" && $0.host == "widgets" && $0.path == "/refresh" }) {
            if let app { app.openWidgetSettings() } else { pendingWidgetRefresh = true }
        }
        let files = urls.filter(\.isFileURL)
        guard !files.isEmpty else { return }
        if let app { app.receiveFinderFiles(files) }
        else { pendingFileURLs.append(contentsOf: files) }
    }
    private lazy var settingsMenuIcon: NSImage? = {
        let image = NSImage(systemSymbolName: "gearshape", accessibilityDescription: L10n.text("Settings"))
        image?.size = NSSize(width: 16, height: 16)
        return image
    }()
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        quickInput?.openMain()
        return false
    }
    func applicationWillTerminate(_ notification: Notification) {
        appearanceObservation?.invalidate()
        appearanceObservation = nil
        NotificationCenter.default.removeObserver(self)
        quickInput?.stop()
        UsageMonitor.shared.stop()
    }
    func applicationWillFinishLaunching(_ notification: Notification) {
        ReplyNotifications.shared.start()
        AppearanceSettings.shared.apply()
        refreshApplicationIcon()
        for name in [NSWindow.willMiniaturizeNotification, NSWindow.didMiniaturizeNotification] {
            NotificationCenter.default.addObserver(self, selector: #selector(refreshWindowBadge(_:)), name: name, object: nil)
        }
        // SwiftUI can recreate command items. Apply AppKit's explicit image
        // visibility both during menu construction and when a menu opens.
        for name in [NSMenu.didAddItemNotification, NSMenu.didBeginTrackingNotification] {
            NotificationCenter.default.addObserver(self, selector: #selector(menuNeedsIcon(_:)), name: name, object: nil)
        }
    }
    func applicationDidFinishLaunching(_ notification: Notification) {
        appearanceObservation = NSApp.observe(\.effectiveAppearance, options: [.new]) { [weak self] _, _ in
            Task { @MainActor [weak self] in self?.refreshApplicationIcon() }
        }
        refreshApplicationIcon()
        refreshSettingsMenuIcon()
        DispatchQueue.main.async { [weak self] in self?.refreshSettingsMenuIcon() }
    }

    @objc private func menuNeedsIcon(_ notification: Notification) { refreshSettingsMenuIcon() }

    private func refreshSettingsMenuIcon() {
        guard let menu = NSApp.mainMenu?.items.first?.submenu,
              let item = menu.items.first(where: { $0.keyEquivalent == "," && $0.keyEquivalentModifierMask.contains(.command) }) else { return }
        item.image = settingsMenuIcon
        if #available(macOS 27.0, *) { item.preferredImageVisibility = .visible }
    }

    private func refreshApplicationIcon() {
        ApplicationIcon.apply()
    }

    @objc private func refreshWindowBadge(_ notification: Notification) {
        guard let window = notification.object as? NSWindow, !(window is NSPanel) else { return }
        refreshApplicationIcon()
        window.dockTile.showsApplicationBadge = true
        window.dockTile.display()
    }
}

@MainActor struct RootView: View {
    @Bindable var app: AppModel
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        Group {
            if app.isRestoring {
                VStack(spacing: 16) { ProgressView(); Text(L10n.text("Connecting your Grok account…")).foregroundStyle(.secondary) }
            } else if let store = app.store {
                ChatView(store: store, app: app).id(ObjectIdentifier(store))
            } else {
                LoginView(app: app, canDismiss: false)
            }
        }
        .onAppear {
            let action = openWindow
            app.quickInput.configure(app: app, showMain: { action(id: "main") })
        }
        .onChange(of: app.canImportFinderFiles, initial: true) { _, ready in
            if ready { app.importPendingFinderFiles() }
        }
        .onChange(of: app.canOpenNotificationConversation, initial: true) { _, ready in
            if ready { app.openPendingNotificationConversation() }
        }
        .sheet(isPresented: $app.showLogin) { LoginView(app: app, canDismiss: true).frame(width: 920, height: 760) }
        .modifier(CopyFeedbackOverlay())
        .modifier(AppAppearance())
    }
}
