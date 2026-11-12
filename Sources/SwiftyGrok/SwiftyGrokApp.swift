import SwiftUI
import AppKit
import GrokCore
import CoreSpotlight

@main
@MainActor
struct SwiftyGrokApp: App {
    @NSApplicationDelegateAdaptor(GrokAppDelegate.self) private var delegate
    @State private var app = AppModel()
    @FocusedValue(\.chatSearch) private var searchChats
    @FocusedBinding(\.chatSelection) private var chatSelection: Bool?
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
                    Label(L10n.text("Settings…"), appSymbol: "gearshape")
                }
                .keyboardShortcut(",", modifiers: .command)
                .disabled(app.showLogin || app.sharedConversations != nil)
            }
            CommandGroup(replacing: .newItem) {
                Button(L10n.text("New chat")) { app.store?.newChat(); app.quickInput.openMain() }
                    .keyboardShortcut("n", modifiers: .command)
                    .disabled(app.store == nil || app.store?.isSending == true || app.store?.isContinuingPublicChat == true || app.sharedConversations != nil)
                Button(L10n.text("New private chat")) {
                    guard let store = app.store else { return }
                    store.newPrivateChat()
                    app.quickInput.hide()
                    app.quickInput.openMain()
                }
                .keyboardShortcut("n", modifiers: [.command, .shift])
                .disabled(app.store == nil || app.store?.isSending == true || app.store?.isContinuingPublicChat == true || app.store?.updatingConversations.isEmpty == false || app.showLogin || app.sharedConversations != nil)
            }
            CommandGroup(after: .textEditing) {
                Button(L10n.text("Search chats")) { searchChats?() }
                    .keyboardShortcut("f", modifiers: .command)
                    .disabled(searchChats == nil || app.showLogin || app.sharedConversations != nil)
            }
            CommandGroup(after: .newItem) {
                Toggle(L10n.text("Select chats"), isOn: Binding(
                    get: { chatSelection ?? false }, set: { chatSelection = $0 }
                ))
                .disabled(chatSelection == nil || app.showLogin || app.sharedConversations != nil)
                Button { app.openSharedConversations() } label: {
                    Label(L10n.text("Shared conversations"), appSymbol: "link")
                }
                .disabled(app.store == nil || app.showLogin || app.isConnecting || app.sharedConversations != nil)
                Divider()
                if let error = app.quickInput.shortcutError { Text(error) }
                Button(L10n.text("Refresh chat")) { Task { await app.store?.loadSelectedConversation() } }
                    .keyboardShortcut("r", modifiers: .command)
                    .disabled(app.store?.selectionID == nil || app.store?.isSending == true || app.store?.isContinuingPublicChat == true || app.sharedConversations != nil)
                Button(L10n.text("Refresh history")) { Task { await app.store?.refreshHistory() } }
                    .keyboardShortcut("r", modifiers: [.command, .shift])
                    .disabled(app.store == nil || app.sharedConversations != nil)
            }
            CommandMenu(L10n.text("Account")) {
                Button(L10n.text("Refresh session…")) {
                    app.quickInput.openMain()
                    app.showLogin = true
                }
                .disabled(app.store == nil || app.store?.isSending == true || app.showLogin || app.sharedConversations != nil)
                Divider()
                Button(L10n.text("Sign out…")) {
                    app.quickInput.openMain()
                    app.confirmSignOut = true
                }
                .disabled(app.store == nil || app.store?.isSending == true || app.showLogin || app.sharedConversations != nil)
            }
        }
    }
}

@MainActor final class GrokAppDelegate: NSObject, NSApplicationDelegate {
    weak var quickInput: QuickInputController?
    private weak var app: AppModel?
    private var pendingFileURLs: [URL] = []
    private var pendingPublicChatLink: PublicChatLink?
    private var pendingSharedFiles: [SharedFile] = []
    private var pendingWidgetRefresh = false
    private var pendingSpotlightTarget: ConversationSpotlight.Target?
    private var appearanceObservation: NSKeyValueObservation?

    func configure(app: AppModel) {
        self.app = app
        if let target = pendingSpotlightTarget {
            pendingSpotlightTarget = nil
            app.receiveSpotlightConversation(target)
        }
        quickInput = app.quickInput
        ReplyNotifications.shared.configure { [weak app] id in app?.openReplyNotification(id) }
        WindowScreenshotShortcut.shared.configure { [weak app] in app?.captureWindowScreenshot() }
        if pendingWidgetRefresh { pendingWidgetRefresh = false; app.openWidgetSettings() }
        if let link = pendingPublicChatLink {
            pendingPublicChatLink = nil
            app.receivePublicChat(link)
        }
        if !pendingFileURLs.isEmpty {
            let urls = pendingFileURLs
            pendingFileURLs.removeAll()
            app.receiveFiles(urls)
        }
        if !pendingSharedFiles.isEmpty {
            let files = pendingSharedFiles
            pendingSharedFiles.removeAll()
            app.receiveSharedFiles(files)
        }
    }

    func application(_ application: NSApplication, continue userActivity: NSUserActivity,
                     restorationHandler: @escaping ([any NSUserActivityRestoring]) -> Void) -> Bool {
        guard userActivity.activityType == CSSearchableItemActionType,
              let identifier = userActivity.userInfo?[CSSearchableItemActivityIdentifier] as? String,
              let target = ConversationSpotlight.target(for: identifier) else { return false }
        if let app { app.receiveSpotlightConversation(target) } else { pendingSpotlightTarget = target }
        return true
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        if let link = urls.compactMap({ PublicChatLink(handoffURL: $0) }).last {
            if let app { app.receivePublicChat(link) } else { pendingPublicChatLink = link }
        }
        if urls.contains(where: { $0.scheme == "swiftygrok" && $0.host == "widgets" && $0.path == "/refresh" }) {
            if let app { app.openWidgetSettings() } else { pendingWidgetRefresh = true }
        }
        let files = urls.filter(\.isFileURL)
        if !files.isEmpty {
            if let app { app.receiveFiles(files) }
            else { pendingFileURLs.append(contentsOf: files) }
        }
        let shared = urls.flatMap { ShareAttachmentHandoff.takeFiles(from: $0) }
        if !shared.isEmpty {
            if let app { app.receiveSharedFiles(shared) }
            else if (pendingSharedFiles + shared).reduce(0, { $0 + $1.data.count }) <= ShareAttachmentHandoff.maximumTotalSize {
                pendingSharedFiles.append(contentsOf: shared)
            }
        }
    }
    private lazy var settingsMenuIcon: NSImage? = {
        let image = AppSymbols.image("gearshape", accessibilityDescription: L10n.text("Settings"))
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
        VoiceDictation.shared.stop()
        WindowScreenshotShortcut.shared.stop()
        UsageMonitor.shared.stop()
    }
    func applicationWillFinishLaunching(_ notification: Notification) {
        ReplyNotifications.shared.start()
        AppearanceSettings.shared.apply()
        refreshApplicationIcon()
        NotificationCenter.default.addObserver(self, selector: #selector(prepareMinimizedWindow(_:)), name: NSWindow.willMiniaturizeNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(restoreWindowTile(_:)), name: NSWindow.didDeminiaturizeNotification, object: nil)
        // SwiftUI can recreate menus. Restore their custom titles and images
        // both during construction and when a menu opens.
        for name in [NSMenu.didAddItemNotification, NSMenu.didBeginTrackingNotification] {
            NotificationCenter.default.addObserver(self, selector: #selector(menuNeedsAppearanceUpdate(_:)), name: name, object: nil)
        }
    }
    func applicationDidFinishLaunching(_ notification: Notification) {
        appearanceObservation = NSApp.observe(\.effectiveAppearance, options: [.new]) { [weak self] _, _ in
            Task { @MainActor [weak self] in self?.refreshApplicationIcon() }
        }
        refreshApplicationIcon()
        refreshMenuAppearance()
        DispatchQueue.main.async { [weak self] in self?.refreshMenuAppearance() }
    }

    @objc private func menuNeedsAppearanceUpdate(_ notification: Notification) { refreshMenuAppearance() }

    private func refreshMenuAppearance() {
        refreshSettingsMenuIcon()
        // Find the standard File menu by our New Chat command, independently
        // of the system language or the position of other top-level menus.
        guard let item = NSApp.mainMenu?.items.first(where: { item in
            item.submenu?.items.contains {
                $0.keyEquivalent.lowercased() == "n" && $0.keyEquivalentModifierMask == .command
            } == true
        }), let menu = item.submenu else { return }
        let title = L10n.text("Chats")
        if item.title != title { item.title = title }
        if menu.title != title { menu.title = title }
    }

    private func refreshSettingsMenuIcon() {
        guard let menu = NSApp.mainMenu?.items.first?.submenu,
              let item = menu.items.first(where: { $0.keyEquivalent == "," && $0.keyEquivalentModifierMask.contains(.command) }) else { return }
        item.image = settingsMenuIcon
        if #available(macOS 27.0, *) { item.preferredImageVisibility = .visible }
    }

    private func refreshApplicationIcon() {
        ApplicationIcon.apply()
    }

    @objc private func prepareMinimizedWindow(_ notification: Notification) {
        guard let window = notification.object as? NSWindow, !(window is NSPanel) else { return }
        ApplicationIcon.prepareMinimizedWindow(window)
    }

    @objc private func restoreWindowTile(_ notification: Notification) {
        guard let window = notification.object as? NSWindow, !(window is NSPanel) else { return }
        window.dockTile.contentView = nil
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
        .onChange(of: app.canImportAttachments, initial: true) { _, ready in
            if ready { app.importPendingAttachments() }
        }
        .onChange(of: app.canOpenNotificationConversation, initial: true) { _, ready in
            if ready { app.openPendingNotificationConversation(); app.openPendingSpotlightConversation() }
        }
        .onChange(of: app.store?.conversations) { _, _ in app.refreshSpotlight() }
        .onChange(of: app.projects?.items) { _, _ in app.refreshSpotlight() }
        .onChange(of: app.projects?.conversations) { _, _ in app.refreshSpotlight() }
        .onChange(of: app.canOpenPublicChat, initial: true) { _, ready in
            if ready { app.openPendingPublicChat() }
        }
        .sheet(isPresented: $app.showLogin) { LoginView(app: app, canDismiss: true).frame(width: 920, height: 760) }
        .confirmationDialog(L10n.text("Sign out of Grok? The session will be removed from Keychain."), isPresented: $app.confirmSignOut) {
            Button(L10n.text("Sign out"), role: .destructive) { app.signOut() }
        }
        .modifier(CopyFeedbackOverlay())
        .modifier(AppAppearance())
    }
}
