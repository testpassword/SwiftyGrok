import Foundation
import Observation
import GrokCore
import CoreSpotlight
import UniformTypeIdentifiers

@MainActor @Observable
final class AppModel {
    private(set) var store: ChatStore?
    private(set) var projects: ProjectStore?
    private(set) var isRestoring = true
    private(set) var isConnecting = false
    var showLogin = false
    var confirmSignOut = false
    private(set) var sharedConversations: SharedConversationStore?
    var loginError: String?
    private(set) var browser = LoginBrowser()
    @ObservationIgnored let quickInput = QuickInputController()
    @ObservationIgnored private var settingsWindow: SettingsWindowController?
    @ObservationIgnored private var sharedConversationsWindow: SharedConversationsWindowController?
    @ObservationIgnored private var retiringStores: [ChatStore] = []
    @ObservationIgnored private let keychain = KeychainStore()
    @ObservationIgnored private(set) var media: MessageMediaLoader?
    @ObservationIgnored private var didRestore = false
    @ObservationIgnored private var generation = UUID()
    @ObservationIgnored private let attachmentInbox = AttachmentInbox()
    @ObservationIgnored private var attachmentImportTask: Task<Void, Never>?
    @ObservationIgnored private var screenshotTask: Task<Void, Never>?
    @ObservationIgnored private var pendingNotificationConversationID: String?
    @ObservationIgnored private var pendingPublicChatLink: PublicChatLink?
    @ObservationIgnored private let replyNotifications = ReplyNotifications.shared
    @ObservationIgnored private let spotlight = ConversationSpotlight()
    @ObservationIgnored private var sessionService: GrokService?
    private var pendingSpotlightConversation: ConversationSpotlight.Target?

    var canOpenNotificationConversation: Bool {
        canOpenPublicChat
    }

    var canOpenPublicChat: Bool {
        !isRestoring && !isConnecting && !showLogin && sharedConversations == nil && store?.requiresLogin == false &&
        store?.isSending == false && store?.isReadingFiles == false && store?.isDictating == false &&
        store?.isContinuingPublicChat == false && store?.updatingConversations.isEmpty == true
    }

    func receivePublicChat(_ link: PublicChatLink) {
        pendingPublicChatLink = link
        quickInput.hide()
        quickInput.openMain()
        if store?.requiresLogin == true { showLogin = true }
        openPendingPublicChat()
    }

    func openPendingPublicChat() {
        guard canOpenPublicChat, let link = pendingPublicChatLink, let store else { return }
        pendingPublicChatLink = nil
        store.selectPublicChat(link)
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

    func receiveSpotlightConversation(_ target: ConversationSpotlight.Target) {
        pendingSpotlightConversation = target
        quickInput.hide()
        quickInput.openMain()
        if store?.requiresLogin == true { showLogin = true }
        openPendingSpotlightConversation()
    }

    func openPendingSpotlightConversation() {
        guard canOpenPublicChat, let target = pendingSpotlightConversation, let store else { return }
        pendingSpotlightConversation = nil
        store.select(target.id, projectID: target.projectID)
    }

    func refreshSpotlight() {
        if let sessionService { spotlight.refresh(using: sessionService) }
    }

    func openSharedConversations() {
        guard !isRestoring, !isConnecting, !showLogin, sharedConversations == nil, let sessionService else { return }
        quickInput.hide()
        quickInput.openMain()
        let store = SharedConversationStore(service: sessionService)
        let controller = SharedConversationsWindowController(store: store)
        sharedConversations = store
        sharedConversationsWindow = controller
        defer {
            store.shutdown()
            if sharedConversations === store { sharedConversations = nil }
            if sharedConversationsWindow === controller { sharedConversationsWindow = nil }
        }
        controller.show()
    }

    private func configureStoreCallbacks(for store: ChatStore) {
        store.onConversationUpdated = { [weak self] chat in self?.projects?.updateConversation(chat) }
        store.onConversationDeleted = { [weak self] id in self?.projects?.removeConversation(id: id) }
        store.onProjectConversationCreated = { [weak self] id in self?.projects?.conversationCreated(in: id) }
        store.onSendStarted = { [weak self] in self?.replyNotifications.prepareAuthorization() }
        store.onReplyCompleted = { [weak self] reply in
            self?.replyNotifications.show(reply)
            self?.refreshSpotlight()
            Task { await UsageMonitor.shared.refresh() }
        }
    }

    var canImportAttachments: Bool {
        !isRestoring && !isConnecting && !showLogin && sharedConversations == nil && store?.requiresLogin == false && store?.canAttachFiles == true
    }

    func receiveFiles(_ urls: [URL]) {
        attachmentInbox.enqueue(urls)
        guard !attachmentInbox.isEmpty else { return }
        quickInput.hide()
        quickInput.openMain()
        if store?.requiresLogin == true { showLogin = true }
        if store?.publicChatLink != nil { store?.newChat() }
        importPendingAttachments()
    }

    func receiveSharedFiles(_ files: [SharedFile]) {
        guard !files.isEmpty else { return }
        let drafts = files.map { DraftFile(name: $0.name, mimeType: $0.mimeType, data: $0.data) }
        guard attachmentInbox.enqueue(files: drafts) else {
            let error = DisplayError(ClientFailure.filesTooLarge)
            if let store { store.error = error } else { loginError = error.message }
            quickInput.openMain()
            return
        }
        quickInput.hide()
        quickInput.openMain()
        if store?.requiresLogin == true { showLogin = true }
        if store?.publicChatLink != nil { store?.newChat() }
        importPendingAttachments()
    }

    func importPendingAttachments() {
        guard canImportAttachments, attachmentImportTask == nil, !attachmentInbox.isEmpty, let store else { return }
        attachmentImportTask = Task { [weak self, attachmentInbox] in
            await attachmentInbox.deliver(to: store)
            guard let self else { return }
            attachmentImportTask = nil
            importPendingAttachments()
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
        Task { await UsageMonitor.shared.refreshWidgets() }
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
            pendingSpotlightConversation = nil
            spotlight.clear()
        }
        stopConversations()
        sessionService = service
        spotlight.refresh(using: service)
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
            attachmentInbox.removeAll()
            replyNotifications.reset()
            pendingNotificationConversationID = nil
            pendingSpotlightConversation = nil
            sessionService = nil
            spotlight.clear()
            generation = UUID()
            pendingPublicChatLink = nil
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
        sharedConversationsWindow?.close()
        sharedConversationsWindow = nil
        sharedConversations?.shutdown()
        sharedConversations = nil
        screenshotTask?.cancel()
        projects?.shutdown()
        projects = nil
        quickInput.reset()
        store?.shutdown()
        retiringStores.forEach { $0.shutdown() }
        retiringStores = []
    }
}

@MainActor
final class ConversationSpotlight {
    struct Target: Codable {
        let id: String
        let projectID: String?
    }

    private let index = CSSearchableIndex.default()
    private let domain = "app.swiftygrok.conversations"
    private var scan: Task<Void, Never>?
    private var write: Task<Void, Never>?
    private var generation = UUID()

    static func target(for identifier: String) -> Target? {
        guard let data = Data(base64Encoded: identifier),
              let target = try? JSONDecoder().decode(Target.self, from: data), !target.id.isEmpty else { return nil }
        return target
    }

    func refresh(using service: GrokService) {
        scan?.cancel()
        let current = UUID()
        generation = current
        scan = Task {
            do {
                try await Task.sleep(for: .seconds(1))
                var entries: [(ChatSummary, String?)] = []
                func collect(projectID: String?) async throws {
                    var token: String?
                    var seen = Set<String>()
                    repeat {
                        try Task.checkCancellation()
                        let page: HistoryPage
                        if let projectID {
                            page = try await service.projectConversations(id: projectID, pageToken: token)
                        } else {
                            page = try await service.history(pageToken: token, search: "")
                        }
                        entries += page.items.map { ($0, projectID) }
                        token = page.nextPageToken
                        if let token, !seen.insert(token).inserted { throw CancellationError() }
                    } while token != nil
                }
                try await collect(projectID: nil)
                for project in try await service.projects() { try await collect(projectID: project.id) }
                try Task.checkCancellation()
                guard current == generation else { return }
                let items = entries.compactMap { chat, projectID -> CSSearchableItem? in
                    guard !chat.id.isEmpty,
                          let data = try? JSONEncoder().encode(Target(id: chat.id, projectID: projectID)) else { return nil }
                    let attributes = CSSearchableItemAttributeSet(contentType: .text)
                    attributes.title = chat.title
                    attributes.contentModificationDate = chat.modifiedAt
                    return CSSearchableItem(uniqueIdentifier: data.base64EncodedString(), domainIdentifier: domain, attributeSet: attributes)
                }
                enqueue(items, generation: current)
            } catch { /* Keep the previous index if history could not be loaded completely. */ }
        }
    }

    func clear() {
        scan?.cancel()
        generation = UUID()
        enqueue([], generation: generation, forceClear: true)
    }

    private func enqueue(_ items: [CSSearchableItem], generation current: UUID, forceClear: Bool = false) {
        let previous = write
        write = Task {
            await previous?.value
            guard forceClear || current == generation else { return }
            do {
                try await index.deleteSearchableItems(withDomainIdentifiers: [domain])
                guard current == generation, !items.isEmpty else { return }
                try await index.indexSearchableItems(items)
            } catch { NSLog("Spotlight indexing failed: %@", error.localizedDescription) }
        }
    }
}
