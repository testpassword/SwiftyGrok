import Foundation
import Observation

@MainActor @Observable
public final class ChatStore {
    public private(set) var conversations: [ChatSummary]
    public private(set) var messages: [ChatMessage] = []
    public private(set) var branches: [ChatBranch] = []
    public private(set) var selectedLeafID: String?
    public private(set) var selectedConversationID: String?
    public private(set) var publicChatLink: PublicChatLink?
    public private(set) var isContinuingPublicChat = false
    public private(set) var selectedProjectID: String?
    public private(set) var isLoadingHistory = false
    public private(set) var isLoadingMessages = false
    public private(set) var isSending = false
    public private(set) var isThinking = false
    public private(set) var isUploadingFiles = false
    public private(set) var isReadingFiles = false
    public private(set) var isDictating = false
    public private(set) var isTranscribing = false
    public private(set) var draftFiles: [DraftFile] = []
    public private(set) var isTemporary = false
    public private(set) var needsReload = false
    public private(set) var requiresLogin = false
    public private(set) var hasMoreHistory = false
    public private(set) var modes = ChatMode.fallback
    public private(set) var isLoadingModes = false
    public private(set) var accountName: String?
    public private(set) var accountEmail: String?
    public private(set) var accountImageURL: URL?
    public private(set) var updatingConversations = Set<String>()
    public var modeID = "fast"
    public var search = ""
    public var draft = ""
    public var error: DisplayError?
    public private(set) var recoveryText: String?
    @ObservationIgnored public var onSendStarted: (() -> Void)?
    @ObservationIgnored public var onReplyCompleted: ((ReplyCompletion) -> Void)?
    @ObservationIgnored public var onConversationUpdated: ((ChatSummary) -> Void)?
    @ObservationIgnored public var onConversationDeleted: ((String) -> Void)?
    @ObservationIgnored public var onProjectConversationCreated: ((String) -> Void)?
    private var projectConversationMetadata: [String: ChatSummary] = [:]

    @ObservationIgnored private let service: any GrokServing
    @ObservationIgnored private var thread: ChatThread?
    @ObservationIgnored private var drafts: [String: String] = [:]
    @ObservationIgnored private var fileDrafts: [String: [DraftFile]] = [:]
    @ObservationIgnored private var uploadedFileIDs: [UUID: String] = [:]
    @ObservationIgnored private var sendTask: Task<Void, Never>?
    @ObservationIgnored private var dictationTask: Task<Void, Never>?
    @ObservationIgnored private var dictationID: UUID?
    @ObservationIgnored private var loadGeneration = UUID()
    @ObservationIgnored private var historyGeneration = UUID()
    @ObservationIgnored private var nextPageToken: String?
    @ObservationIgnored private var historyQuery = ""
    @ObservationIgnored private var consumedPageTokens = Set<String>()
    @ObservationIgnored private var sessionGeneration = UUID()
    @ObservationIgnored private var temporaryConversationIDs = Set<String>()
    @ObservationIgnored private var fileImportGeneration = UUID()
    private var selectedTitle = L10n.text("New chat")

    public init(service: any GrokServing, conversations: [ChatSummary] = [], nextPageToken: String? = nil) {
        self.service = service
        self.conversations = Self.ordered(conversations)
        self.nextPageToken = nextPageToken
        self.hasMoreHistory = nextPageToken != nil
    }

    public var title: String {
        if isTemporary { return L10n.text("Private conversation") }
        return selectedConversationID.flatMap { summary(id: $0)?.title } ?? selectedTitle
    }

    public var selectionID: String? { publicChatLink.map { "public:\($0.id)" } ?? selectedConversationID }

    public func summary(id: String) -> ChatSummary? {
        conversations.first { $0.id == id } ?? projectConversationMetadata[id]
    }

    public func registerProjectConversations(_ chats: [ChatSummary]) {
        for chat in chats where !temporaryConversationIDs.contains(chat.id) { projectConversationMetadata[chat.id] = chat }
        let ids = Set(chats.map(\.id))
        if conversations.contains(where: { ids.contains($0.id) }) {
            historyGeneration = UUID()
            isLoadingHistory = false
            conversations.removeAll { ids.contains($0.id) }
        }
    }
    public var canSend: Bool {
        publicChatLink == nil && !isContinuingPublicChat && !isSending && !isReadingFiles && !isDictating && updatingConversations.isEmpty && !isLoadingMessages && !needsReload && !requiresLogin &&
        modes.contains(where: { $0.id == modeID && $0.isAvailable }) && (!draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !draftFiles.isEmpty)
    }
    public var canAttachFiles: Bool { publicChatLink == nil && !isContinuingPublicChat && !isSending && !isReadingFiles && !isDictating }
    public var canDictate: Bool {
        publicChatLink == nil && !isContinuingPublicChat && !isSending && !isReadingFiles && !isDictating && !isLoadingMessages && !needsReload && !requiresLogin && updatingConversations.isEmpty
    }

    /// Reserve this draft before asking for microphone access. Recognition only
    /// appends text; it never sends a message or creates an audio attachment.
    public func startDictation(record: @escaping @MainActor () async throws -> Data) {
        guard canDictate else { return }
        let id = UUID()
        dictationID = id
        isDictating = true
        dictationTask = Task {
            defer {
                if dictationID == id {
                    dictationID = nil
                    dictationTask = nil
                    isDictating = false
                    isTranscribing = false
                }
            }
            do {
                let audio = try await record()
                try Task.checkCancellation()
                guard dictationID == id, !requiresLogin else { return }
                isTranscribing = true
                let text = try await service.transcribe(audio: audio).trimmingCharacters(in: .whitespacesAndNewlines)
                try Task.checkCancellation()
                guard dictationID == id, !requiresLogin else { return }
                guard !text.isEmpty else { throw ClientFailure.noSpeech }
                // Preserve edits made while recording or waiting for Grok.
                let separator = draft.isEmpty || draft.last?.isWhitespace == true ? "" : " "
                draft += separator + text
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled, dictationID == id else { return }
                presentError(error)
            }
        }
    }

    public func cancelDictation() {
        dictationID = nil
        dictationTask?.cancel()
        dictationTask = nil
        isDictating = false
        isTranscribing = false
    }

    public func waitForDictation() async { await dictationTask?.value }

    private var draftKey: String {
        selectedConversationID ?? selectedProjectID.map { "__project:\($0)" } ?? "__new"
    }

    public func importFiles(_ urls: [URL]) async {
        await importFiles(resolvingURLs: { urls })
    }

    /// Reserve the draft before asynchronous drop resolution or file reading.
    public func importFiles(resolvingURLs resolve: @MainActor () async throws -> [URL]) async {
        let generation = fileImportGeneration
        let session = sessionGeneration
        let remaining = DraftFile.maximumTotalSize - draftFiles.reduce(0) { $0 + $1.data.count }
        await importFiles(resolvingDraftFiles: {
            let urls = try await resolve()
            try Task.checkCancellation()
            guard generation == fileImportGeneration, session == sessionGeneration else { throw CancellationError() }
            return try await Task.detached(priority: .userInitiated) {
                try DraftFileReader.read(urls, maximumBytes: remaining)
            }.value
        })
    }

    /// Import generated attachments with the same draft/session guards as files.
    public func importFiles(resolvingDraftFiles resolve: @MainActor () async throws -> [DraftFile]) async {
        guard canAttachFiles else { return }
        let generation = fileImportGeneration
        let session = sessionGeneration
        isReadingFiles = true
        defer { isReadingFiles = false }
        do {
            let files = try await resolve()
            try Task.checkCancellation()
            guard generation == fileImportGeneration, session == sessionGeneration else { return }
            addFiles(files)
        } catch is CancellationError {
            return
        } catch {
            guard !Task.isCancelled, generation == fileImportGeneration, session == sessionGeneration else { return }
            presentError(error)
        }
    }

    /// A separate unsent draft for the global input; it never inherits a reply parent.
    public func makeNewConversationStore() -> ChatStore {
        let fresh = ChatStore(service: service, conversations: conversations, nextPageToken: nextPageToken)
        fresh.modes = modes
        fresh.modeID = modeID
        fresh.accountName = accountName
        fresh.accountEmail = accountEmail
        fresh.accountImageURL = accountImageURL
        fresh.temporaryConversationIDs = temporaryConversationIDs
        fresh.projectConversationMetadata = projectConversationMetadata
        fresh.requiresLogin = requiresLogin
        if requiresLogin { fresh.error = error }
        return fresh
    }

    /// Called after starting a quick-input send, preserving the previous workspace's drafts.
    public func inheritDrafts(from previous: ChatStore) {
        temporaryConversationIDs.formUnion(previous.temporaryConversationIDs)
        drafts.merge(previous.drafts) { _, old in old }
        fileDrafts.merge(previous.fileDrafts) { _, old in old }
        uploadedFileIDs.merge(previous.uploadedFileIDs) { _, old in old }
        if !previous.isTemporary && previous.publicChatLink == nil {
            let key = previous.draftKey
            drafts[key] = previous.draft
            fileDrafts[key] = previous.draftFiles
        }
    }

    public func addFiles(_ files: [DraftFile]) {
        guard publicChatLink == nil, !isContinuingPublicChat, !isSending else { return }
        guard (draftFiles + files).reduce(0, { $0 + $1.data.count }) <= DraftFile.maximumTotalSize else {
            presentError(ClientFailure.filesTooLarge); return
        }
        draftFiles += files
    }

    public func removeFile(_ id: UUID) {
        guard !isSending else { return }
        draftFiles.removeAll { $0.id == id }
        uploadedFileIDs[id] = nil
    }

    public func refreshHistory(loadMore: Bool = false) async {
        if loadMore && (isLoadingHistory || nextPageToken == nil || search.trimmingCharacters(in: .whitespacesAndNewlines) != historyQuery) { return }
        let generation = UUID()
        historyGeneration = generation
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        let token = loadMore ? nextPageToken : nil
        isLoadingHistory = true
        defer { if historyGeneration == generation { isLoadingHistory = false } }
        do {
            let result = try await service.history(pageToken: token, search: query)
            try Task.checkCancellation()
            guard historyGeneration == generation, search.trimmingCharacters(in: .whitespacesAndNewlines) == query else { return }
            var seen = Set<String>()
            conversations = Self.ordered(((loadMore ? conversations : []) + result.items).filter {
                !temporaryConversationIDs.contains($0.id) && seen.insert($0.id).inserted
            })
            if !loadMore { consumedPageTokens = [] }
            if let token { consumedPageTokens.insert(token) }
            nextPageToken = result.nextPageToken
            // Avoid an infinite "load more" loop if the server repeats a cursor.
            if let nextPageToken, consumedPageTokens.contains(nextPageToken) { self.nextPageToken = nil }
            historyQuery = query
            hasMoreHistory = nextPageToken != nil
            if let selected = conversations.first(where: { $0.id == selectedConversationID }) { selectedTitle = selected.title }
        } catch {
            guard !Task.isCancelled, historyGeneration == generation else { return }
            presentError(error)
        }
    }

    public func loadModes() async {
        guard !isLoadingModes else { return }
        let generation = sessionGeneration
        isLoadingModes = true
        defer { isLoadingModes = false }
        if let result = try? await service.modes(), generation == sessionGeneration, !Task.isCancelled {
            modes = result
            if !result.contains(where: { $0.id == modeID && $0.isAvailable }), let available = result.first(where: \.isAvailable) {
                modeID = available.id
            }
        }
    }

    public func selectMode(_ id: String) {
        guard !isSending, modes.contains(where: { $0.id == id && $0.isAvailable }) else { return }
        modeID = id
    }

    public func loadProfile() async {
        let generation = sessionGeneration
        if let profile = try? await service.profile(), generation == sessionGeneration, !Task.isCancelled {
            accountName = profile.name
            accountEmail = profile.email
            accountImageURL = profile.imageURL
        }
    }

    public func renameConversation(id: String, title: String) async {
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return }
        await updateConversation(id: id) {
            try await self.service.renameConversation(id: id, title: title)
        } commit: {
            if let index = self.conversations.firstIndex(where: { $0.id == id }) { self.conversations[index].title = title }
            self.projectConversationMetadata[id]?.title = title
            if self.selectedConversationID == id { self.selectedTitle = title }
            if let chat = self.summary(id: id) { self.onConversationUpdated?(chat) }
        }
    }

    public func pinConversation(id: String, pinned: Bool) async {
        await updateConversation(id: id) {
            try await self.service.pinConversation(id: id, pinned: pinned)
        } commit: {
            if let index = self.conversations.firstIndex(where: { $0.id == id }) { self.conversations[index].isPinned = pinned }
            self.projectConversationMetadata[id]?.isPinned = pinned
            self.conversations = Self.ordered(self.conversations)
            if let chat = self.summary(id: id) { self.onConversationUpdated?(chat) }
        }
    }

    @discardableResult public func deleteConversation(id: String) async -> Bool {
        await updateConversation(id: id) {
            try await self.service.deleteConversation(id: id)
        } commit: {
            if self.selectedConversationID == id { self.select(nil) }
            self.drafts[id] = nil
            self.fileDrafts[id] = nil
            self.conversations.removeAll { $0.id == id }
            self.projectConversationMetadata[id] = nil
            self.onConversationDeleted?(id)
        }
    }

    /// Use the existing soft-delete endpoint sequentially, retaining failed and
    /// unattempted chats so the user can retry them explicitly.
    @discardableResult public func deleteConversations(ids: [String]) async -> Set<String> {
        let generation = sessionGeneration
        var seen = Set<String>(), deleted = Set<String>()
        for id in ids where seen.insert(id).inserted {
            guard !Task.isCancelled, generation == sessionGeneration else { break }
            guard summary(id: id) != nil || selectedConversationID == id else { continue }
            guard await deleteConversation(id: id) else { break }
            deleted.insert(id)
        }
        return deleted
    }

    public func moveConversation(id: String, to projectID: String, projects: ProjectStore) async -> Bool {
        guard !isSending, !requiresLogin, !temporaryConversationIDs.contains(id),
              !(isTemporary && id == selectedConversationID),
              id == selectedConversationID || summary(id: id) != nil,
              updatingConversations.insert(id).inserted else { return false }
        let generation = sessionGeneration
        defer { updatingConversations.remove(id) }
        let moved = await projects.moveConversation(id: id, to: projectID)
        guard generation == sessionGeneration else { return false }
        if moved {
            if let chat = summary(id: id) { projectConversationMetadata[id] = chat }
            historyGeneration = UUID()
            isLoadingHistory = false
            conversations.removeAll { $0.id == id }
        }
        if moved, selectedConversationID == id { selectedProjectID = projectID }
        return moved
    }

    public func removeConversation(id: String, from projectID: String, projects: ProjectStore) async -> Bool {
        guard !isSending, !requiresLogin, !temporaryConversationIDs.contains(id),
              !(isTemporary && id == selectedConversationID),
              id == selectedConversationID || summary(id: id) != nil,
              updatingConversations.insert(id).inserted else { return false }
        let generation = sessionGeneration
        defer { updatingConversations.remove(id) }
        let removed = await projects.removeConversation(id: id, from: projectID)
        guard generation == sessionGeneration else { return false }
        if removed, selectedConversationID == id, selectedProjectID == projectID { selectedProjectID = nil }
        if removed { await refreshHistory() }
        return removed
    }

    public func shareConversation(id: String, responseID: String? = nil) async -> URL? {
        guard !isSending, !requiresLogin, responseID?.isEmpty != true,
              !temporaryConversationIDs.contains(id), !(isTemporary && id == selectedConversationID),
              id == selectedConversationID || summary(id: id) != nil,
              updatingConversations.insert(id).inserted else { return nil }
        let generation = sessionGeneration
        defer { updatingConversations.remove(id) }
        do {
            let leafID: String
            if let responseID {
                leafID = responseID
            } else {
                // Resolve a history row independently of the currently displayed chat.
                let loaded = try await service.thread(id: id)
                try Task.checkCancellation()
                guard generation == sessionGeneration, !requiresLogin else { return nil }
                guard let last = try loaded.path().last else { throw ClientFailure.emptyConversation }
                leafID = last.id
            }
            let url = try await service.shareConversation(id: id, responseID: leafID)
            try Task.checkCancellation()
            guard generation == sessionGeneration else { return nil }
            return url
        } catch {
            guard !Task.isCancelled, generation == sessionGeneration else { return nil }
            presentError(error)
            return nil
        }
    }

    @discardableResult private func updateConversation(id: String, request: () async throws -> Void, commit: () -> Void) async -> Bool {
        guard !isSending, !requiresLogin, !temporaryConversationIDs.contains(id), !(isTemporary && id == selectedConversationID),
              id == selectedConversationID || summary(id: id) != nil, updatingConversations.insert(id).inserted else { return false }
        let generation = sessionGeneration
        defer { updatingConversations.remove(id) }
        do {
            try await request()
            try Task.checkCancellation()
            guard generation == sessionGeneration else { return false }
            // A history request started before this update must not restore stale metadata.
            historyGeneration = UUID()
            isLoadingHistory = false
            commit()
            return true
        } catch {
            guard !Task.isCancelled, generation == sessionGeneration else { return false }
            presentError(error)
            return false
        }
    }

    private static func ordered(_ chats: [ChatSummary]) -> [ChatSummary] {
        chats.enumerated().sorted {
            if $0.element.isPinned != $1.element.isPinned { return $0.element.isPinned }
            let a = $0.element.modifiedAt ?? .distantPast, b = $1.element.modifiedAt ?? .distantPast
            return a == b ? $0.offset < $1.offset : a > b
        }.map(\.element)
    }

    public func select(_ id: String?, projectID: String? = nil) {
        guard !isSending, !isContinuingPublicChat, publicChatLink != nil || id != selectedConversationID || isTemporary || projectID != selectedProjectID,
              id.map({ !temporaryConversationIDs.contains($0) }) ?? true else { return }
        if let id, id == selectedConversationID, !isTemporary {
            selectedProjectID = projectID
            return
        }
        if !isTemporary && publicChatLink == nil {
            drafts[draftKey] = draft
            fileDrafts[draftKey] = draftFiles
        }
        publicChatLink = nil
        isTemporary = false
        selectedConversationID = id
        selectedProjectID = projectID
        selectedTitle = id.flatMap { summary(id: $0)?.title } ?? (id == nil ? L10n.text("New chat") : L10n.text("Chat"))
        draft = drafts[draftKey] ?? ""
        draftFiles = fileDrafts[draftKey] ?? []
        clearThread()
    }

    public func selectProject(_ id: String) {
        guard !id.isEmpty else { return }
        select(nil, projectID: id)
    }

    public func leaveProject(_ id: String) {
        guard selectedProjectID == id else { return }
        if selectedConversationID == nil { select(nil) }
        else { selectedProjectID = nil }
    }

    public func newChat() {
        guard !isSending, !isContinuingPublicChat else { return }
        if publicChatLink != nil { select(nil); return }
        if isTemporary {
            selectedConversationID = nil
            draft = ""
            draftFiles = []
            clearThread()
            return
        }
        if selectedConversationID != nil || selectedProjectID != nil { select(nil) }
        else { clearThread() }
    }

    public func newPrivateChat() {
        guard !isSending, !isContinuingPublicChat, updatingConversations.isEmpty else { return }
        if !isTemporary && publicChatLink == nil {
            drafts[draftKey] = draft
            fileDrafts[draftKey] = draftFiles
        }
        publicChatLink = nil
        isTemporary = true
        selectedConversationID = nil
        selectedProjectID = nil
        selectedTitle = L10n.text("New chat")
        draft = ""
        draftFiles = []
        clearThread()
    }

    public func setTemporary(_ enabled: Bool) {
        guard publicChatLink == nil, !isContinuingPublicChat, !isSending, updatingConversations.isEmpty, enabled != isTemporary else { return }
        let wasEmpty = selectedConversationID == nil && selectedProjectID == nil && messages.isEmpty
        let unsent = draft
        let unsentFiles = draftFiles
        if !isTemporary {
            drafts[draftKey] = draft
            fileDrafts[draftKey] = draftFiles
        }
        isTemporary = enabled
        selectedConversationID = nil
        selectedProjectID = nil
        selectedTitle = L10n.text("New chat")
        if enabled {
            draft = wasEmpty ? unsent : ""
            draftFiles = wasEmpty ? unsentFiles : []
            if wasEmpty { drafts["__new"] = nil; fileDrafts["__new"] = nil }
        } else {
            draft = drafts["__new"] ?? ""
            draftFiles = fileDrafts["__new"] ?? []
        }
        clearThread()
    }

    private func clearThread() {
        cancelDictation()
        fileImportGeneration = UUID()
        loadGeneration = UUID()
        isLoadingMessages = false
        thread = nil
        messages = []
        branches = []
        selectedLeafID = nil
        needsReload = selectedConversationID != nil
        if !requiresLogin { error = nil }
        recoveryText = nil
    }

    public func loadSelectedConversation() async {
        if let publicChatLink { await loadPublicChat(publicChatLink); return }
        await loadSelectedConversation(allowDuringSend: false)
    }

    public func selectPublicChat(_ link: PublicChatLink) {
        guard !isSending, !isReadingFiles, !isContinuingPublicChat, !requiresLogin, publicChatLink != link else { return }
        if !isTemporary && publicChatLink == nil {
            drafts[draftKey] = draft
            fileDrafts[draftKey] = draftFiles
        }
        clearThread()
        publicChatLink = link
        selectedConversationID = nil
        selectedProjectID = nil
        selectedTitle = L10n.text("Public chat")
        isTemporary = false
        draft = ""
        draftFiles = []
        needsReload = true
    }

    private func loadPublicChat(_ link: PublicChatLink) async {
        guard !isContinuingPublicChat else { return }
        let generation = UUID()
        loadGeneration = generation
        isLoadingMessages = true
        needsReload = true
        defer { if loadGeneration == generation { isLoadingMessages = false } }
        do {
            let preview = try await service.publicChat(link)
            try Task.checkCancellation()
            guard loadGeneration == generation, publicChatLink == link else { return }
            let path = try preview.thread.path()
            thread = preview.thread
            messages = path
            branches = preview.thread.branches
            selectedLeafID = path.last?.id
            selectedTitle = preview.summary.title
            needsReload = false
            error = nil
        } catch {
            guard !Task.isCancelled, loadGeneration == generation, publicChatLink == link else { return }
            presentError(error)
        }
    }

    public func continuePublicChat() async {
        guard let link = publicChatLink, !isLoadingMessages, !needsReload, !requiresLogin,
              !isContinuingPublicChat, !messages.isEmpty else { return }
        let generation = sessionGeneration
        isContinuingPublicChat = true
        defer { isContinuingPublicChat = false }
        do {
            let owned = try await service.continuePublicChat(link)
            // Commit the new ID before loading its thread. A failed load must
            // offer refresh on the owned chat, never another clone request.
            guard generation == sessionGeneration, publicChatLink == link else { return }
            publicChatLink = nil
            selectedConversationID = owned.id
            selectedTitle = owned.title
            conversations.removeAll { $0.id == owned.id }
            conversations = Self.ordered([owned] + conversations)
            historyGeneration = UUID()
            isLoadingHistory = false
            clearThread()
        } catch {
            guard !Task.isCancelled, generation == sessionGeneration, publicChatLink == link else { return }
            presentError(error)
        }
    }

    private func loadSelectedConversation(allowDuringSend: Bool) async {
        guard !isTemporary, let id = selectedConversationID, !isSending || allowDuringSend else { return }
        let generation = UUID()
        loadGeneration = generation
        isLoadingMessages = true
        needsReload = true
        defer { if loadGeneration == generation { isLoadingMessages = false } }
        do {
            let loaded = try await service.thread(id: id)
            try Task.checkCancellation()
            guard selectedConversationID == id, loadGeneration == generation else { return }
            if allowDuringSend, let selectedLeafID,
               !loaded.responses.contains(where: { $0.id == selectedLeafID }) {
                throw ClientFailure.interruptedReply
            }
            let preferred = loaded.branches.contains { $0.id == selectedLeafID } ? selectedLeafID : nil
            let path = try loaded.path(to: preferred)
            thread = loaded
            messages = path
            branches = loaded.branches
            selectedLeafID = path.last?.id
            needsReload = false
            if !requiresLogin { error = nil }
            recoveryText = nil
        } catch {
            guard !Task.isCancelled, selectedConversationID == id, loadGeneration == generation else { return }
            presentError(error)
        }
    }

    public func selectBranch(_ id: String) {
        guard !isSending, let thread else { return }
        do {
            messages = try thread.path(to: id)
            selectedLeafID = id
        } catch { presentError(error) }
    }

    public func send() {
        guard canSend else { return }
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        let files = draftFiles
        let conversationID = selectedConversationID
        let parentID = messages.last?.id
        let mode = modeID
        let temporary = isTemporary
        let projectID = temporary ? nil : selectedProjectID
        let generation = sessionGeneration
        let userID = UUID().uuidString
        let assistantID = UUID().uuidString
        draft = ""
        draftFiles = []
        if !temporary { drafts[draftKey] = ""; fileDrafts[draftKey] = nil }
        error = nil
        recoveryText = nil
        isSending = true
        isUploadingFiles = !files.isEmpty
        isThinking = files.isEmpty
        onSendStarted?()
        messages.append(ChatMessage(id: userID, parentID: parentID, role: .user, text: text, createdAt: Date(),
                                   attachments: files.map { MessageAttachment(id: $0.id.uuidString, name: $0.name, url: nil, kind: .file) }))
        messages.append(ChatMessage(id: assistantID, parentID: userID, role: .assistant, text: "", createdAt: Date()))
        sendTask = Task { [weak self] in
            guard let self else { return }
            defer {
                isSending = false; isThinking = false; isUploadingFiles = false; sendTask = nil
                if generation == sessionGeneration, conversationID == nil, selectedConversationID != nil, let projectID {
                    onProjectConversationCreated?(projectID)
                }
            }
            var finalReceived = false
            var serverResponseID = ""
            var finalEvent: ReplyEvent?
            var replyStarted = false
            do {
                var fileIDs: [String] = []
                for file in files {
                    try Task.checkCancellation()
                    let id: String
                    if let cached = uploadedFileIDs[file.id] { id = cached }
                    else { id = try await service.upload(file: file) }
                    try Task.checkCancellation()
                    guard generation == sessionGeneration else { return }
                    uploadedFileIDs[file.id] = id
                    fileIDs.append(id)
                }
                try Task.checkCancellation()
                isUploadingFiles = false
                isThinking = true
                replyStarted = true
                let stream = try await service.reply(conversationID: conversationID, parentID: parentID, text: text, modeID: mode, temporary: temporary, fileIDs: fileIDs, projectID: projectID)
                for try await event in stream {
                    try Task.checkCancellation()
                    guard generation == sessionGeneration else { return }
                    if !event.conversationID.isEmpty, selectedConversationID == nil {
                        selectedConversationID = event.conversationID
                        if temporary {
                            temporaryConversationIDs.insert(event.conversationID)
                            conversations.removeAll { $0.id == event.conversationID }
                        } else {
                            selectedTitle = String((text.isEmpty ? files.first?.name ?? L10n.text("New chat") : text).prefix(70))
                            let chat = ChatSummary(id: event.conversationID, title: selectedTitle, modifiedAt: Date())
                            if projectID != nil {
                                projectConversationMetadata[event.conversationID] = chat
                            } else {
                                conversations.insert(chat, at: 0)
                                conversations = Self.ordered(conversations)
                            }
                        }
                    }
                    if !event.responseID.isEmpty { serverResponseID = event.responseID }
                    isThinking = event.isThinking
                    if let index = messages.firstIndex(where: { $0.id == assistantID }) {
                        if event.isFinal { messages[index].text = event.text }
                        else if !event.isThinking { messages[index].text += event.text }
                        if let reasoning = event.reasoning { messages[index].reasoning = reasoning }
                        else if event.isThinking { messages[index].reasoning = (messages[index].reasoning ?? "") + event.text }
                        if let duration = event.reasoningDuration { messages[index].reasoningDuration = duration }
                        if event.isFinal { messages[index].contentBlocks = event.contentBlocks }
                    }
                    if event.isFinal { finalReceived = true; finalEvent = event; break }
                }
                guard finalReceived, let completedConversationID = selectedConversationID, !serverResponseID.isEmpty else { throw ClientFailure.interruptedReply }
                guard messages.last?.text.isEmpty == false || finalEvent?.attachments.isEmpty == false else { throw ClientFailure.emptyReply }
                selectedLeafID = serverResponseID
                isThinking = false
                if let finalEvent, finalEvent.failure == nil {
                    onReplyCompleted?(ReplyCompletion(requestID: userID, conversationID: completedConversationID,
                                                     responseID: serverResponseID, isTemporary: temporary, text: finalEvent.text))
                }
                guard !Task.isCancelled, generation == sessionGeneration else { return }
                if temporary, let finalEvent, let index = messages.firstIndex(where: { $0.id == assistantID }) {
                    // Temporary chats have no reloadable history. The final event
                    // acknowledges the response ID used as the next turn's parent.
                    messages[index] = ChatMessage(id: serverResponseID, parentID: userID, role: .assistant, text: finalEvent.text,
                        createdAt: Date(), sources: finalEvent.sources, attachments: finalEvent.attachments,
                        reasoning: finalEvent.reasoning ?? messages[index].reasoning, reasoningDuration: finalEvent.reasoningDuration ?? messages[index].reasoningDuration, failure: finalEvent.failure,
                        contentBlocks: finalEvent.contentBlocks)
                    needsReload = false
                } else {
                    // Reconcile server IDs and topology before allowing another turn.
                    needsReload = true
                    await loadSelectedConversation(allowDuringSend: true)
                    await refreshHistory()
                }
            } catch {
                guard generation == sessionGeneration else { return }
                if !replyStarted {
                    messages.removeAll { $0.id == userID || $0.id == assistantID }
                    draft = text
                    draftFiles = files
                    if !Task.isCancelled { presentError(error) }
                    return
                }
                needsReload = true
                recoveryText = text
                if temporary && !DisplayError(error).needsLogin { presentError(ClientFailure.temporaryReplyInterrupted) }
                else { presentError(Task.isCancelled ? ClientFailure.interruptedReply : error) }
            }
        }
    }

    public func stopSending() { sendTask?.cancel() }

    private func presentError(_ underlying: Error) {
        let display = DisplayError(underlying)
        requiresLogin = requiresLogin || display.needsLogin
        error = display
    }

    /// Call on logout/replacement so in-flight callbacks cannot update a later session.
    public func shutdown() {
        cancelDictation()
        sessionGeneration = UUID()
        sendTask?.cancel()
        loadGeneration = UUID()
        historyGeneration = UUID()
        projectConversationMetadata = [:]
        draftFiles = []
        fileDrafts = [:]
        uploadedFileIDs = [:]
        if isTemporary {
            selectedConversationID = nil
            draft = ""
            clearThread()
        }
    }

    public func waitForSend() async { await sendTask?.value }
}
