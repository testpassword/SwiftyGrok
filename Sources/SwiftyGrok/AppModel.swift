import Foundation
import Observation
import GrokCore

@MainActor @Observable
final class AppModel {
    private(set) var store: ChatStore?
    private(set) var projects: ProjectStore?
    private(set) var isRestoring = true
    private(set) var isConnecting = false
    var showLogin = false
    var loginError: String?
    private(set) var browser = LoginBrowser()
    @ObservationIgnored let quickInput = QuickInputController()
    @ObservationIgnored private var settingsWindow: SettingsWindowController?
    @ObservationIgnored private var retiringStores: [ChatStore] = []
    @ObservationIgnored private let keychain = KeychainStore()
    @ObservationIgnored private(set) var media: MessageMediaLoader?
    @ObservationIgnored private var didRestore = false
    @ObservationIgnored private var generation = UUID()
    @ObservationIgnored private let finderAttachments = FinderAttachmentInbox()
    @ObservationIgnored private var finderImportTask: Task<Void, Never>?
    @ObservationIgnored private var screenshotTask: Task<Void, Never>?
    @ObservationIgnored private var pendingNotificationConversationID: String?
    @ObservationIgnored private let replyNotifications = ReplyNotifications.shared

    var canOpenNotificationConversation: Bool {
        canImportFinderFiles && store?.updatingConversations.isEmpty == true
    }

    func openReplyNotification(_ conversationID: String?) {
        pendingNotificationConversationID = conversationID
        quickInput.hide()
        quickInput.openMain()
        if store?.requiresLogin == true { showLogin = true }
        openPendingNotificationConversation()
    }

    func openPendingNotificationConversation() {
        guard canOpenNotificationConversation, let id = pendingNotificationConversationID, let store else { return }
        pendingNotificationConversationID = nil
        store.select(id)
    }

    private func configureStoreCallbacks(for store: ChatStore) {
        store.onConversationUpdated = { [weak self] chat in self?.projects?.updateConversation(chat) }
        store.onConversationDeleted = { [weak self] id in self?.projects?.removeConversation(id: id) }
        store.onProjectConversationCreated = { [weak self] id in self?.projects?.conversationCreated(in: id) }
        store.onSendStarted = { [weak self] in self?.replyNotifications.prepareAuthorization() }
        store.onReplyCompleted = { [weak self] reply in
            self?.replyNotifications.show(reply)
            Task { await UsageMonitor.shared.refresh() }
        }
    }

    var canImportFinderFiles: Bool {
        !isRestoring && !isConnecting && !showLogin && store?.requiresLogin == false && store?.canAttachFiles == true
    }

    func receiveFinderFiles(_ urls: [URL]) {
        finderAttachments.enqueue(urls)
        guard !finderAttachments.isEmpty else { return }
        quickInput.hide()
        quickInput.openMain()
        if store?.requiresLogin == true { showLogin = true }
        importPendingFinderFiles()
    }

    func importPendingFinderFiles() {
        guard canImportFinderFiles, finderImportTask == nil, !finderAttachments.isEmpty, let store else { return }
        finderImportTask = Task { [weak self, finderAttachments] in
            await finderAttachments.deliver(to: store)
            guard let self else { return }
            finderImportTask = nil
            importPendingFinderFiles()
        }
    }

    func captureWindowScreenshot() {
        guard screenshotTask == nil else { return }
        guard !isRestoring, !isConnecting, !showLogin,
              let destination = quickInput.attachmentStore ?? store, !destination.requiresLogin else {
            quickInput.openMain()
            if store?.requiresLogin == true { showLogin = true }
            return
        }
        do {
            guard destination.canAttachFiles else { throw WindowScreenshotError.draftBusy }
            let target = try WindowScreenshotTarget.frontmost()
            screenshotTask = Task { [weak self] in
                defer { self?.screenshotTask = nil }
                await destination.importFiles(resolvingDraftFiles: { [target] in
                    [try await target.capture()]
                })
                guard let self, !Task.isCancelled else { return }
                if store === destination {
                    quickInput.hide()
                    quickInput.openMain()
                } else if quickInput.attachmentStore === destination { quickInput.show() }
            }
        } catch {
            destination.error = DisplayError(error)
            if store === destination { quickInput.hide(); quickInput.openMain() }
        }
    }

    func openSettings() {
        guard !showLogin else { return }
        quickInput.hide()
        if settingsWindow == nil { settingsWindow = SettingsWindowController() }
        settingsWindow?.show()
    }

    func openWidgetSettings() {
        quickInput.hide()
        if settingsWindow == nil { settingsWindow = SettingsWindowController() }
        Task { await UsageMonitor.shared.refresh() }
        settingsWindow?.showWidgets()
    }

    func restore() async {
        guard !didRestore else { return }
        didRestore = true
        UsageMonitor.shared.start()
        defer { isRestoring = false }
        do {
            if let credentials = try keychain.load() {
                await browser.seed(credentials)
                try await connect(credentials, persist: false)
            }
        } catch { loginError = DisplayError(error).message }
    }

    func connectBrowser() async {
        guard !isConnecting else { return }
        isConnecting = true
        loginError = nil
        defer { isConnecting = false }
        do { try await connect(try await browser.credentials()) }
        catch { loginError = DisplayError(error).message }
    }

    func connectImport(_ text: String, userAgent: String) async {
        guard !isConnecting else { return }
        isConnecting = true
        loginError = nil
        defer { isConnecting = false }
        do {
            let credentials = try SessionCredentials.importing(text, userAgent: userAgent)
            try await connect(credentials)
            await browser.seed(credentials)
        } catch { loginError = DisplayError(error).message }
    }

    private func connect(_ credentials: SessionCredentials, persist: Bool = true) async throws {
        let current = generation
        let service = try GrokService(credentials: credentials)
        // A cookie's presence is not proof of authorization: test the actual history endpoint.
        let history = try await service.history(pageToken: nil, search: "")
        try Task.checkCancellation()
        guard current == generation else { throw CancellationError() }
        if persist { try keychain.save(credentials) }
        if persist {
            replyNotifications.reset()
            pendingNotificationConversationID = nil
        }
        stopConversations()
        media = MessageMediaLoader(credentials: credentials)
        store = ChatStore(service: service, conversations: history.items, nextPageToken: history.nextPageToken)
        projects = ProjectStore(service: service)
        UsageMonitor.shared.setChatService(service)
        if let store { configureStoreCallbacks(for: store) }
        browser.closePopups()
        showLogin = false
    }

    func signOut() {
        do {
            try keychain.delete()
            UsageMonitor.shared.setChatService(nil)
            finderAttachments.removeAll()
            replyNotifications.reset()
            pendingNotificationConversationID = nil
            generation = UUID()
            stopConversations()
            store = nil
            media = nil
            browser.closePopups()
            browser = LoginBrowser()
            loginError = nil
            showLogin = false
        } catch { loginError = error.localizedDescription; showLogin = true }
    }

    func sendQuickConversation(_ fresh: ChatStore) {
        guard let previous = store, fresh.canSend else { return }
        configureStoreCallbacks(for: fresh)
        fresh.send()
        fresh.inheritDrafts(from: previous)
        store = fresh
        if previous.isSending {
            retiringStores.append(previous)
            Task { [weak self] in
                await previous.waitForSend()
                previous.shutdown()
                self?.retiringStores.removeAll { $0 === previous }
            }
        } else { previous.shutdown() }
    }

    private func stopConversations() {
        screenshotTask?.cancel()
        projects?.shutdown()
        projects = nil
        quickInput.reset()
        store?.shutdown()
        retiringStores.forEach { $0.shutdown() }
        retiringStores = []
    }
}
