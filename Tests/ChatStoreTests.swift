import XCTest
import GrokClient
@testable import GrokCore

@MainActor
private final class FakeService: GrokServing {
    var history = [ChatSummary(id: "chat", title: "Test")]
    var loaded = try! ChatThread(responses: [ChatMessage(id: "previous", role: .assistant, text: "Before")])
    var events: [ReplyEvent] = []
    var replyError: Error?
    var uploadError: Error?
    var uploads: [String] = []
    var replyFiles: [[String]] = []
    var replyProjects: [String?] = []
    var uploadHook: (() async -> Void)?
    var calls: [(String?, String?, String, String, Bool)] = []
    var threadCalls = 0
    var historyCalls = 0
    var loadHook: ((String) async throws -> ChatThread)?
    var historyHook: ((String) async throws -> [ChatSummary])?
    var pageHook: ((String?, String) async throws -> HistoryPage)?
    var streamHook: (() -> AsyncThrowingStream<ReplyEvent, Error>)?
    var mutationError: Error?
    var mutations: [String] = []
    var mutationHook: (() async -> Void)?
    var modeCatalog = ChatMode.fallback
    var modeHook: (() async -> Void)?
    func shareConversation(id: String, responseID: String) async throws -> URL {
        if let mutationError { throw mutationError }
        await mutationHook?()
        mutations.append("share:\(id):\(responseID)")
        return URL(string: "https://grok.com/share/public-fixture")!
    }

    func profile() async throws -> AccountProfile { AccountProfile(name: "Test User", imageURL: "https://assets.grok.com/avatar.jpg") }
    func renameConversation(id: String, title: String) async throws {
        if let mutationError { throw mutationError }
        await mutationHook?()
        mutations.append("rename:\(id):\(title)")
    }
    func pinConversation(id: String, pinned: Bool) async throws {
        if let mutationError { throw mutationError }
        mutations.append("pin:\(id):\(pinned)")
    }
    func deleteConversation(id: String) async throws {
        if let mutationError { throw mutationError }
        mutations.append("delete:\(id)")
    }

    func history(pageToken: String?, search: String) async throws -> HistoryPage {
        historyCalls += 1
        if let pageHook { return try await pageHook(pageToken, search) }
        if let historyHook { return HistoryPage(items: try await historyHook(search)) }
        return HistoryPage(items: history)
    }
    func thread(id: String) async throws -> ChatThread {
        threadCalls += 1
        if let loadHook { return try await loadHook(id) }
        return loaded
    }
    func modes() async throws -> [ChatMode] { await modeHook?(); return modeCatalog }
    func upload(file: DraftFile) async throws -> String {
        await uploadHook?()
        if let uploadError { throw uploadError }
        uploads.append(file.name)
        return "uploaded-\(file.name)"
    }
    func reply(conversationID: String?, parentID: String?, text: String, modeID: String, temporary: Bool, fileIDs: [String], projectID: String?) async throws -> AsyncThrowingStream<ReplyEvent, Error> {
        calls.append((conversationID, parentID, text, modeID, temporary))
        replyFiles.append(fileIDs)
        replyProjects.append(projectID)
        if let replyError { throw replyError }
        if let streamHook { return streamHook() }
        return AsyncThrowingStream { continuation in
            events.forEach { continuation.yield($0) }
            continuation.finish()
        }
    }
}

final class ChatStoreTests: XCTestCase {
    @MainActor func testUnavailableModeCannotBeSelectedOrSentAndCatalogFallsBackToAvailableMode() async {
        let service = FakeService()
        service.modeCatalog = [ChatMode(id: "fast", name: "Fast", isAvailable: false), ChatMode(id: "expert", name: "Expert")]
        let store = ChatStore(service: service)
        await store.loadModes()
        XCTAssertEqual(store.modes.count, 2)
        XCTAssertEqual(store.modeID, "expert")
        store.selectMode("fast")
        XCTAssertEqual(store.modeID, "expert")
        store.draft = "Question"
        store.modeID = "fast"
        XCTAssertFalse(store.canSend)
        store.send()
        XCTAssertTrue(service.calls.isEmpty)
        store.selectMode("expert")
        XCTAssertTrue(store.canSend)
    }

    @MainActor func testModeCatalogWithNoAvailableModesDisablesSending() async {
        let service = FakeService()
        service.modeCatalog = [ChatMode(id: "heavy", name: "Heavy", isAvailable: false)]
        let store = ChatStore(service: service)
        await store.loadModes()
        store.draft = "Question"
        XCTAssertFalse(store.canSend)
        store.selectMode("heavy")
        XCTAssertEqual(store.modeID, "fast")
        XCTAssertEqual(store.modes.count, 1)
    }

    @MainActor func testLateModeCatalogDoesNotUpdateRetiredSession() async {
        let service = FakeService()
        service.modeCatalog = [ChatMode(id: "other", name: "Other")]
        var release: CheckedContinuation<Void, Never>?
        service.modeHook = { await withCheckedContinuation { release = $0 } }
        let store = ChatStore(service: service)
        let load = Task { await store.loadModes() }
        while release == nil { await Task.yield() }
        store.shutdown()
        release?.resume()
        await load.value
        XCTAssertEqual(store.modes, ChatMode.fallback)
        XCTAssertEqual(store.modeID, "fast")
    }

    @MainActor func testProjectDraftsAndFilesAreSeparateFromOrdinaryAndQuickInputDrafts() {
        let store = ChatStore(service: FakeService())
        store.draft = "Ordinary"
        store.addFiles([DraftFile(name: "ordinary.txt", mimeType: "text/plain", data: Data("ordinary".utf8))])
        store.selectProject("one")
        XCTAssertTrue(store.draft.isEmpty)
        XCTAssertTrue(store.draftFiles.isEmpty)
        store.draft = "Project one"
        store.addFiles([DraftFile(name: "one.txt", mimeType: "text/plain", data: Data("one".utf8))])
        store.selectProject("two")
        XCTAssertTrue(store.draft.isEmpty)
        XCTAssertTrue(store.draftFiles.isEmpty)
        store.draft = "Project two"
        store.selectProject("one")
        XCTAssertEqual(store.draft, "Project one")
        XCTAssertEqual(store.draftFiles.map(\.name), ["one.txt"])
        let quick = store.makeNewConversationStore()
        XCTAssertNil(quick.selectedProjectID)
        XCTAssertTrue(quick.draft.isEmpty)
        XCTAssertTrue(quick.draftFiles.isEmpty)
        quick.inheritDrafts(from: store)
        quick.selectProject("one")
        XCTAssertEqual(quick.draft, "Project one")
        store.newChat()
        XCTAssertNil(store.selectedProjectID)
        XCTAssertEqual(store.draft, "Ordinary")
        XCTAssertEqual(store.draftFiles.map(\.name), ["ordinary.txt"])
    }

    @MainActor func testProjectSendUsesWorkspaceAndRefreshesOnlyItsList() async throws {
        let service = FakeService()
        service.events = [ReplyEvent(conversationID: "created", responseID: "answer", text: "Done", isFinal: true)]
        service.loaded = try ChatThread(responses: [ChatMessage(id: "answer", role: .assistant, text: "Done")])
        let store = ChatStore(service: service)
        var createdIn: [String] = []
        store.onProjectConversationCreated = { createdIn.append($0) }
        store.selectProject("one")
        store.draft = "Question"
        store.send()
        await store.waitForSend()
        XCTAssertEqual(service.replyProjects, ["one"])
        XCTAssertEqual(createdIn, ["one"])
        XCTAssertEqual(store.selectedProjectID, "one")
        XCTAssertEqual(store.selectedConversationID, "created")
        store.selectProject("two")
        store.setTemporary(true)
        XCTAssertNil(store.selectedProjectID)
        XCTAssertTrue(store.isTemporary)
    }

    @MainActor func testRemovingProjectMembershipKeepsOpenChatAndDraft() async {
        let service = FakeService()
        let projectsService = ProjectFixture()
        let projects = ProjectStore(service: projectsService)
        await projects.load()
        let store = ChatStore(service: service, conversations: service.history)
        store.select("chat", projectID: "one")
        await store.loadSelectedConversation()
        store.draft = "Keep this"
        let messages = store.messages
        projectsService.failure = URLError(.notConnectedToInternet)
        let failed = await store.removeConversation(id: "chat", from: "one", projects: projects)
        XCTAssertFalse(failed)
        XCTAssertEqual(store.selectedProjectID, "one")
        projectsService.failure = nil
        let removed = await store.removeConversation(id: "chat", from: "one", projects: projects)
        XCTAssertTrue(removed)
        XCTAssertNil(store.selectedProjectID)
        XCTAssertEqual(store.selectedConversationID, "chat")
        XCTAssertEqual(store.draft, "Keep this")
        XCTAssertEqual(store.messages, messages)
        XCTAssertEqual(store.conversations.map(\.id), ["chat"])
        XCTAssertTrue(service.mutations.isEmpty)
    }

    @MainActor func testProjectOnlyChatKeepsTitleAndSupportsHistoryActions() async {
        let service = FakeService()
        let store = ChatStore(service: service, conversations: service.history)
        store.registerProjectConversations([ChatSummary(id: "project-only", title: "Project chat")])
        store.select("project-only")
        XCTAssertEqual(store.title, "Project chat")
        XCTAssertEqual(store.conversations.map(\.id), ["chat"])
        var updated: ChatSummary?
        var deleted: String?
        store.onConversationUpdated = { updated = $0 }
        store.onConversationDeleted = { deleted = $0 }
        await store.renameConversation(id: "project-only", title: "Renamed")
        XCTAssertEqual(store.title, "Renamed")
        XCTAssertEqual(updated?.title, "Renamed")
        await store.deleteConversation(id: "project-only")
        XCTAssertEqual(deleted, "project-only")
        XCTAssertNil(store.summary(id: "project-only"))
        XCTAssertNil(store.selectedConversationID)
    }

    @MainActor func testMoveConversationPreservesSelectionDraftAndMessages() async {
        let service = FakeService()
        let projectsService = ProjectFixture()
        let projects = ProjectStore(service: projectsService)
        await projects.load()
        let store = ChatStore(service: service, conversations: service.history)
        store.select("chat")
        await store.loadSelectedConversation()
        store.draft = "Keep my draft"
        let messages = store.messages
        let moved = await store.moveConversation(id: "chat", to: "one", projects: projects)
        XCTAssertTrue(moved)
        XCTAssertEqual(projectsService.mutations, ["move:chat:one"])
        XCTAssertTrue(store.conversations.isEmpty)
        XCTAssertEqual(store.selectedConversationID, "chat")
        XCTAssertEqual(store.draft, "Keep my draft")
        XCTAssertEqual(store.messages, messages)
        XCTAssertTrue(store.updatingConversations.isEmpty)
        let missing = await store.moveConversation(id: "missing", to: "one", projects: projects)
        XCTAssertFalse(missing)
        XCTAssertEqual(projectsService.mutations.count, 1)
    }

    @MainActor func testReplyCompletionIsEmittedOnceAfterTheFinalAnswer() async throws {
        let service = FakeService()
        service.events = [
            ReplyEvent(conversationID: "chat", responseID: "answer", text: "Partial"),
            ReplyEvent(conversationID: "chat", responseID: "answer", text: "**Final answer**", isFinal: true)
        ]
        service.loaded = try ChatThread(responses: [ChatMessage(id: "answer", role: .assistant, text: "**Final answer**")])
        let store = ChatStore(service: service)
        var starts = 0
        var completions: [ReplyCompletion] = []
        let history = service.history
        service.historyHook = { _ in
            // Background history refresh must not delay the ready notification.
            XCTAssertEqual(completions.count, 1)
            return history
        }
        store.onSendStarted = { starts += 1 }
        store.onReplyCompleted = { completions.append($0) }
        store.draft = "Question"
        store.send()
        store.send()
        await store.waitForSend()
        XCTAssertEqual(starts, 1)
        XCTAssertEqual(completions.count, 1)
        XCTAssertEqual(completions.first?.conversationID, "chat")
        XCTAssertEqual(completions.first?.responseID, "answer")
        XCTAssertEqual(completions.first?.preview, "Final answer")
        XCTAssertEqual(completions.first?.isTemporary, false)
        XCTAssertNotNil(completions.first.flatMap { UUID(uuidString: $0.requestID) })
    }

    @MainActor func testInterruptedEmptyAndFailedRepliesDoNotEmitCompletion() async {
        let cases: [[ReplyEvent]] = [
            [ReplyEvent(conversationID: "private", responseID: "answer", text: "Partial")],
            [ReplyEvent(conversationID: "private", responseID: "answer", text: "", isFinal: true)],
            [ReplyEvent(conversationID: "private", responseID: "answer", text: "Failed", isFinal: true, failure: "Stream error")]
        ]
        for events in cases {
            let service = FakeService()
            service.events = events
            let store = ChatStore(service: service)
            store.setTemporary(true)
            var completions: [ReplyCompletion] = []
            store.onReplyCompleted = { completions.append($0) }
            store.draft = "Question"
            store.send()
            await store.waitForSend()
            XCTAssertTrue(completions.isEmpty)
        }
    }

    @MainActor func testShutdownBeforeFinalReplyDoesNotEmitCompletion() async {
        let service = FakeService()
        var continuation: AsyncThrowingStream<ReplyEvent, Error>.Continuation?
        service.streamHook = { AsyncThrowingStream { continuation = $0 } }
        let store = ChatStore(service: service)
        var completions: [ReplyCompletion] = []
        store.onReplyCompleted = { completions.append($0) }
        store.draft = "Question"
        store.send()
        while continuation == nil { await Task.yield() }
        store.shutdown()
        continuation?.yield(ReplyEvent(conversationID: "chat", responseID: "answer", text: "Answer", isFinal: true))
        continuation?.finish()
        await store.waitForSend()
        XCTAssertTrue(completions.isEmpty)
    }

    @MainActor func testQuickPrivateImageReplyEmitsCompletionWithoutHistoryReload() async {
        let service = FakeService()
        let image = MessageAttachment(id: "image", name: "render.png", url: URL(string: "https://assets.grok.com/generated/render.png"),
                                      kind: .image, isGenerated: true)
        service.events = [ReplyEvent(conversationID: "private", responseID: "image-answer", text: "", isFinal: true, attachments: [image])]
        let original = ChatStore(service: service)
        let fresh = original.makeNewConversationStore()
        fresh.setTemporary(true)
        var completions: [ReplyCompletion] = []
        fresh.onReplyCompleted = { completions.append($0) }
        fresh.draft = "Generate an image"
        fresh.send()
        await fresh.waitForSend()
        XCTAssertEqual(completions.count, 1)
        XCTAssertEqual(completions.first?.conversationID, "private")
        XCTAssertEqual(completions.first?.isTemporary, true)
        XCTAssertEqual(completions.first?.preview, "")
        XCTAssertEqual(fresh.messages.last?.attachments, [image])
        XCTAssertEqual(service.threadCalls, 0)
        XCTAssertEqual(service.historyCalls, 0)
    }

    private func makeFinderFile() throws -> (directory: URL, file: URL) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("Finder — вложение.txt")
        try Data("File bytes from Finder".utf8).write(to: file)
        return (directory, file)
    }

    @MainActor func testFinderFilesAttachToOpenChatAndPreserveItsDraft() async throws {
        let (directory, file) = try makeFinderFile()
        defer { try? FileManager.default.removeItem(at: directory) }
        let service = FakeService()
        let store = ChatStore(service: service, conversations: service.history)
        store.select("chat")
        await store.loadSelectedConversation()
        store.draft = "Keep the current draft"
        store.addFiles([DraftFile(name: "existing.txt", mimeType: "text/plain", data: Data("Existing".utf8))])
        let inbox = FinderAttachmentInbox()
        inbox.enqueue([URL(string: "https://example.com/not-a-file")!, file, file])
        await inbox.deliver(to: store)
        XCTAssertEqual(store.selectedConversationID, "chat")
        XCTAssertEqual(store.messages.map(\.id), ["previous"])
        XCTAssertEqual(store.draft, "Keep the current draft")
        XCTAssertEqual(store.draftFiles.map(\.name), ["existing.txt", file.lastPathComponent])
        XCTAssertEqual(store.draftFiles.last?.data, Data("File bytes from Finder".utf8))
        XCTAssertTrue(inbox.isEmpty)
        XCTAssertTrue(service.uploads.isEmpty)
        XCTAssertTrue(service.calls.isEmpty)
    }

    @MainActor func testFinderFilesUseNewDraftWhenNoChatIsSelected() async throws {
        let (directory, file) = try makeFinderFile()
        defer { try? FileManager.default.removeItem(at: directory) }
        let service = FakeService()
        let store = ChatStore(service: service)
        store.draft = "A new conversation"
        let inbox = FinderAttachmentInbox()
        inbox.enqueue([file])
        await inbox.deliver(to: store)
        XCTAssertNil(store.selectedConversationID)
        XCTAssertTrue(store.messages.isEmpty)
        XCTAssertEqual(store.draft, "A new conversation")
        XCTAssertEqual(store.draftFiles.first?.data, Data("File bytes from Finder".utf8))
        XCTAssertTrue(service.uploads.isEmpty)
        XCTAssertTrue(service.calls.isEmpty)
    }

    @MainActor func testFinderFilesWaitWhileAnotherFileImportIsReading() async throws {
        let (directory, file) = try makeFinderFile()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ChatStore(service: FakeService())
        var resolver: CheckedContinuation<[URL], Never>?
        let reading = Task {
            await store.importFiles(resolvingURLs: {
                await withCheckedContinuation { resolver = $0 }
            })
        }
        while resolver == nil { await Task.yield() }
        let inbox = FinderAttachmentInbox()
        inbox.enqueue([file])
        await inbox.deliver(to: store)
        XCTAssertFalse(inbox.isEmpty)
        XCTAssertTrue(store.draftFiles.isEmpty)
        resolver?.resume(returning: [])
        await reading.value
        await inbox.deliver(to: store)
        XCTAssertTrue(inbox.isEmpty)
        XCTAssertEqual(store.draftFiles.map(\.name), [file.lastPathComponent])
    }

    @MainActor func testFinderFilesStayQueuedUntilSignInSucceeds() async throws {
        let (directory, file) = try makeFinderFile()
        defer { try? FileManager.default.removeItem(at: directory) }
        let service = FakeService()
        service.historyHook = { _ in throw GrokError.unauthorized }
        let expired = ChatStore(service: service)
        await expired.refreshHistory()
        XCTAssertTrue(expired.requiresLogin)
        let inbox = FinderAttachmentInbox()
        inbox.enqueue([file])
        await inbox.deliver(to: expired)
        XCTAssertFalse(inbox.isEmpty)
        XCTAssertTrue(expired.draftFiles.isEmpty)
        let connected = ChatStore(service: FakeService())
        await inbox.deliver(to: connected)
        XCTAssertTrue(inbox.isEmpty)
        XCTAssertEqual(connected.draftFiles.map(\.name), [file.lastPathComponent])
    }

    @MainActor func testGeneratedAttachmentPreservesDraftAndWaitsForExplicitSend() async {
        let service = FakeService()
        let store = ChatStore(service: service)
        store.draft = "Question about this window"
        let file = DraftFile(name: "Screenshot.png", mimeType: "image/png", data: Data([1, 2, 3]))
        await store.importFiles(resolvingDraftFiles: { [file] })
        XCTAssertEqual(store.draft, "Question about this window")
        XCTAssertEqual(store.draftFiles, [file])
        XCTAssertTrue(service.calls.isEmpty)
        XCTAssertTrue(service.uploads.isEmpty)
        XCTAssertFalse(store.isReadingFiles)
    }

    @MainActor func testGeneratedAttachmentCannotLeakIntoAnotherDraft() async {
        let store = ChatStore(service: FakeService())
        var pending: CheckedContinuation<[DraftFile], Never>?
        let importing = Task {
            await store.importFiles(resolvingDraftFiles: {
                await withCheckedContinuation { pending = $0 }
            })
        }
        while pending == nil { await Task.yield() }
        XCTAssertTrue(store.isReadingFiles)
        store.newChat()
        pending?.resume(returning: [DraftFile(name: "old-window.png", mimeType: "image/png", data: Data([1]))])
        await importing.value
        XCTAssertTrue(store.draftFiles.isEmpty)
        XCTAssertNil(store.error)
        XCTAssertFalse(store.isReadingFiles)
    }

    @MainActor func testCancelledGeneratedAttachmentDoesNotChangeTheDraft() async {
        let store = ChatStore(service: FakeService())
        store.draft = "Keep this text"
        await store.importFiles(resolvingDraftFiles: { throw CancellationError() })
        XCTAssertEqual(store.draft, "Keep this text")
        XCTAssertTrue(store.draftFiles.isEmpty)
        XCTAssertNil(store.error)
        XCTAssertFalse(store.isReadingFiles)
    }

    @MainActor func testImportedFilesKeepBytesAndWaitForExplicitSend() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("note.txt")
        let data = Data("An attachment, not a filename in the editor.".utf8)
        try data.write(to: url)
        let service = FakeService()
        let store = ChatStore(service: service)
        store.draft = "Keep my text"
        await store.importFiles([url])
        XCTAssertEqual(store.draft, "Keep my text")
        XCTAssertEqual(store.draftFiles.map(\.name), ["note.txt"])
        XCTAssertEqual(store.draftFiles.first?.data, data)
        XCTAssertTrue(service.uploads.isEmpty)
        XCTAssertFalse(store.isReadingFiles)
        XCTAssertTrue(store.canSend)
    }

    @MainActor func testPendingFileDropCannotLeakIntoAnotherNewChat() async {
        let store = ChatStore(service: FakeService())
        store.draft = "Question"
        var resolver: CheckedContinuation<[URL], Never>?
        let importing = Task {
            await store.importFiles(resolvingURLs: {
                await withCheckedContinuation { resolver = $0 }
            })
        }
        while resolver == nil { await Task.yield() }
        XCTAssertTrue(store.isReadingFiles)
        XCTAssertFalse(store.canSend)
        XCTAssertFalse(store.canAttachFiles)
        store.newChat() // Both drafts have a nil server ID; they must still be isolated.
        resolver?.resume(returning: [URL(fileURLWithPath: "/not-read-in-the-new-chat")])
        await importing.value
        XCTAssertTrue(store.draftFiles.isEmpty)
        XCTAssertNil(store.error)
        XCTAssertFalse(store.isReadingFiles)
        XCTAssertTrue(store.canSend)
    }

    @MainActor func testFileReadFailurePreservesExistingDraftAndAttachments() async {
        let store = ChatStore(service: FakeService())
        let previous = DraftFile(name: "kept.txt", mimeType: "text/plain", data: Data("Keep".utf8))
        store.addFiles([previous])
        store.draft = "Keep my text"
        await store.importFiles([FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)])
        XCTAssertEqual(store.draftFiles, [previous])
        XCTAssertEqual(store.draft, "Keep my text")
        XCTAssertNotNil(store.error)
        XCTAssertTrue(store.canSend)
        XCTAssertFalse(store.isReadingFiles)
    }

    @MainActor func testQuickConversationStartsWithoutParentAndPreservesPreviousDrafts() async throws {
        let service = FakeService()
        let previous = ChatStore(service: service, conversations: service.history)
        previous.select("chat")
        await previous.loadSelectedConversation()
        previous.draft = "Keep this draft"
        let file = DraftFile(name: "note.txt", mimeType: "text/plain", data: Data("Hello".utf8))
        previous.addFiles([file])
        previous.modeID = "auto"
        let fresh = previous.makeNewConversationStore()
        XCTAssertEqual(fresh.modeID, "auto")
        XCTAssertNil(fresh.selectedConversationID)
        XCTAssertTrue(fresh.messages.isEmpty)
        XCTAssertTrue(fresh.draftFiles.isEmpty)
        fresh.setTemporary(true)
        fresh.draft = "Quick message"
        service.events = [ReplyEvent(conversationID: "quick", responseID: "answer", text: "Answer", isFinal: true)]
        fresh.send()
        fresh.inheritDrafts(from: previous)
        await fresh.waitForSend()
        XCTAssertNil(service.calls.first?.0)
        XCTAssertNil(service.calls.first?.1)
        XCTAssertEqual(service.calls.first?.2, "Quick message")
        XCTAssertEqual(previous.draft, "Keep this draft")
        fresh.select("chat")
        XCTAssertEqual(fresh.draft, "Keep this draft")
        XCTAssertEqual(fresh.draftFiles, [file])
    }

    @MainActor func testQuickConversationPreservesAnUnsentNewChatDraft() async throws {
        let service = FakeService()
        let previous = ChatStore(service: service)
        previous.draft = "Unsent new chat"
        let fresh = previous.makeNewConversationStore()
        fresh.draft = "Quick message"
        service.events = [ReplyEvent(conversationID: "quick", responseID: "answer", text: "Answer", isFinal: true)]
        service.loaded = try ChatThread(responses: [ChatMessage(id: "answer", role: .assistant, text: "Answer")])
        fresh.send()
        fresh.inheritDrafts(from: previous)
        await fresh.waitForSend()
        fresh.newChat()
        XCTAssertEqual(fresh.draft, "Unsent new chat")
    }

    @MainActor func testStreamingReasoningIsSeparateAndSurvivesTemporaryFinalEvent() async {
        let service = FakeService()
        let store = ChatStore(service: service)
        store.setTemporary(true)
        service.events = [
            ReplyEvent(conversationID: "private", responseID: "answer", text: "Checking ", isThinking: true),
            ReplyEvent(conversationID: "private", responseID: "answer", text: "sources", isThinking: true),
            ReplyEvent(conversationID: "private", responseID: "answer", text: "Answer", isFinal: true)
        ]
        store.draft = "Question"; store.send(); await store.waitForSend()
        XCTAssertEqual(store.messages.last?.text, "Answer")
        XCTAssertEqual(store.messages.last?.reasoning, "Checking sources")
    }

    @MainActor func testFilesUploadOnlyOnSendAndPrivateReplyUsesUploadedIDs() async {
        let service = FakeService()
        let store = ChatStore(service: service)
        store.setTemporary(true)
        let file = DraftFile(name: "note.txt", mimeType: "text/plain", data: Data("Hello".utf8))
        store.addFiles([file])
        XCTAssertTrue(service.uploads.isEmpty)
        XCTAssertTrue(store.canSend)
        service.events = [ReplyEvent(conversationID: "private", responseID: "answer", text: "Read", isFinal: true)]
        store.send()
        await store.waitForSend()
        XCTAssertEqual(service.uploads, ["note.txt"])
        XCTAssertEqual(service.replyFiles, [["uploaded-note.txt"]])
        XCTAssertEqual(service.calls.first?.4, true)
        XCTAssertTrue(store.draftFiles.isEmpty)
        XCTAssertTrue(store.conversations.isEmpty)
        XCTAssertFalse(store.needsReload)
    }

    @MainActor func testUploadFailureRestoresDraftWithoutSendingOrBlockingRetry() async {
        let service = FakeService()
        service.uploadError = URLError(.notConnectedToInternet)
        let store = ChatStore(service: service)
        let file = DraftFile(name: "note.txt", mimeType: "text/plain", data: Data("Hello".utf8))
        store.addFiles([file]); store.draft = "Read this"
        store.send()
        await store.waitForSend()
        XCTAssertTrue(service.calls.isEmpty)
        XCTAssertTrue(store.messages.isEmpty)
        XCTAssertEqual(store.draft, "Read this")
        XCTAssertEqual(store.draftFiles, [file])
        XCTAssertFalse(store.needsReload)
        XCTAssertTrue(store.canSend)
        XCTAssertNotNil(store.error)
    }

    @MainActor func testFileDraftsAreSeparateAndPrivateFilesAreClearedOnExit() {
        let store = ChatStore(service: FakeService())
        let file = DraftFile(name: "public.txt", mimeType: "text/plain", data: Data())
        store.addFiles([file])
        store.select("chat")
        XCTAssertTrue(store.draftFiles.isEmpty)
        store.select(nil)
        XCTAssertEqual(store.draftFiles, [file])
        store.setTemporary(true)
        XCTAssertEqual(store.draftFiles, [file])
        store.select("chat")
        store.select(nil)
        XCTAssertTrue(store.draftFiles.isEmpty)
    }

    @MainActor func testCancelledUploadCannotStartReplyEvenIfUploadIgnoresCancellation() async {
        let service = FakeService()
        let store = ChatStore(service: service)
        service.uploadHook = { store.stopSending() }
        let file = DraftFile(name: "note.txt", mimeType: "text/plain", data: Data())
        store.addFiles([file]); store.send()
        await store.waitForSend()
        XCTAssertTrue(service.calls.isEmpty)
        XCTAssertFalse(store.needsReload)
        XCTAssertEqual(store.draftFiles, [file])
    }

    @MainActor func testTemporaryConversationContinuesWithoutHistoryAndNeverAppearsInList() async throws {
        let service = FakeService()
        let store = ChatStore(service: service, conversations: service.history)
        store.setTemporary(true)
        let source = MessageSource(id: "source", title: "Source", url: URL(string: "https://example.com")!)
        service.events = [ReplyEvent(conversationID: "private", responseID: "answer-1", text: "One", isFinal: true, sources: [source])]
        store.draft = "Secret one"
        store.send()
        await store.waitForSend()
        XCTAssertEqual(store.title, L10n.text("Private conversation"))
        XCTAssertEqual(store.messages.last?.sources, [source])
        XCTAssertEqual(store.selectedLeafID, "answer-1")
        XCTAssertFalse(store.needsReload)
        service.events = [ReplyEvent(conversationID: "private", responseID: "answer-2", text: "Two", isFinal: true)]
        store.draft = "Secret two"
        store.send()
        await store.waitForSend()
        XCTAssertEqual(service.calls.count, 2)
        XCTAssertTrue(service.calls.allSatisfy { $0.4 })
        XCTAssertNil(service.calls[0].0)
        XCTAssertEqual(service.calls[1].0, "private")
        XCTAssertEqual(service.calls[1].1, "answer-1")
        XCTAssertEqual(store.messages.count, 4)
        XCTAssertEqual(store.messages.last?.id, "answer-2")
        XCTAssertEqual(service.threadCalls, 0)
        XCTAssertEqual(service.historyCalls, 0)
        service.history.append(ChatSummary(id: "private", title: "Must stay hidden"))
        await store.refreshHistory()
        XCTAssertEqual(store.conversations.map(\.id), ["chat"])
        let privateLink = await store.shareConversation(id: "private", responseID: "answer-2")
        XCTAssertNil(privateLink)
        await store.pinConversation(id: "private", pinned: true)
        await store.renameConversation(id: "private", title: "No")
        await store.deleteConversation(id: "private")
        XCTAssertTrue(service.mutations.isEmpty)
        let fresh = store.makeNewConversationStore()
        await fresh.refreshHistory()
        XCTAssertFalse(fresh.conversations.contains { $0.id == "private" })
    }

    @MainActor func testLeavingTemporaryChatDiscardsPrivateDraftAndRestoresNormalDraft() async {
        let service = FakeService()
        let store = ChatStore(service: service, conversations: service.history)
        store.select("chat")
        store.draft = "Normal draft"
        store.setTemporary(true)
        XCTAssertNil(store.selectedConversationID)
        XCTAssertTrue(store.draft.isEmpty)
        store.draft = "Private draft"
        store.select("chat")
        XCTAssertFalse(store.isTemporary)
        XCTAssertEqual(store.draft, "Normal draft")
        store.setTemporary(true)
        XCTAssertTrue(store.draft.isEmpty)
        store.draft = "Another private draft"
        store.newChat()
        XCTAssertTrue(store.isTemporary)
        XCTAssertTrue(store.draft.isEmpty)
        store.setTemporary(false)
        XCTAssertTrue(store.draft.isEmpty)
    }

    @MainActor func testTemporaryModePreservesUnsentNewDraftWithoutLeakingItBack() {
        let store = ChatStore(service: FakeService())
        store.draft = "Send this privately"
        store.setTemporary(true)
        XCTAssertEqual(store.draft, "Send this privately")
        store.setTemporary(false)
        XCTAssertTrue(store.draft.isEmpty)
    }

    @MainActor func testTemporaryInterruptedReplyRequiresFreshConversation() async {
        let service = FakeService()
        service.events = [ReplyEvent(conversationID: "private", responseID: "partial", text: "Part")]
        let store = ChatStore(service: service)
        store.setTemporary(true)
        store.draft = "Secret"
        store.send()
        await store.waitForSend()
        XCTAssertTrue(store.needsReload)
        XCTAssertEqual(store.recoveryText, "Secret")
        store.draft = "Another message"
        XCTAssertFalse(store.canSend)
        await store.loadSelectedConversation()
        XCTAssertTrue(store.needsReload)
        XCTAssertEqual(service.threadCalls, 0)
        store.newChat()
        XCTAssertTrue(store.isTemporary)
        XCTAssertNil(store.selectedConversationID)
        XCTAssertNil(store.recoveryText)
        XCTAssertTrue(store.messages.isEmpty)
        XCTAssertTrue(store.draft.isEmpty)
        store.draft = "Fresh"
        XCTAssertTrue(store.canSend)
    }

    @MainActor func testTemporaryModeCannotSwitchDuringSendAndShutdownClearsContent() async {
        let service = FakeService()
        var continuation: AsyncThrowingStream<ReplyEvent, Error>.Continuation?
        service.streamHook = { AsyncThrowingStream { continuation = $0 } }
        let store = ChatStore(service: service, conversations: service.history)
        store.setTemporary(true)
        store.draft = "Secret"
        store.send()
        while continuation == nil { await Task.yield() }
        store.setTemporary(false)
        store.select("chat")
        XCTAssertTrue(store.isTemporary)
        XCTAssertNil(store.selectedConversationID)
        store.shutdown()
        continuation?.finish()
        await store.waitForSend()
        XCTAssertTrue(store.messages.isEmpty)
        XCTAssertTrue(store.draft.isEmpty)
        XCTAssertNil(store.recoveryText)
    }

    @MainActor func testShareUsesCapturedPathAndKeepsSelection() async {
        let service = FakeService()
        let store = ChatStore(service: service, conversations: service.history)
        store.select("chat")
        let url = await store.shareConversation(id: "chat", responseID: "chosen-leaf")
        XCTAssertEqual(url?.absoluteString, "https://grok.com/share/public-fixture")
        XCTAssertEqual(service.mutations, ["share:chat:chosen-leaf"])
        XCTAssertEqual(service.threadCalls, 0)
        XCTAssertEqual(store.selectedConversationID, "chat")
        service.mutationError = URLError(.notConnectedToInternet)
        let failed = await store.shareConversation(id: "chat", responseID: "chosen-leaf")
        XCTAssertNil(failed)
        XCTAssertNotNil(store.error)
        XCTAssertTrue(store.updatingConversations.isEmpty)
    }

    @MainActor func testShareUnselectedChatLoadsItsOwnThreadAndKeepsDraft() async throws {
        let service = FakeService()
        let store = ChatStore(service: service, conversations: service.history + [ChatSummary(id: "other", title: "Other")])
        store.select("chat")
        await store.loadSelectedConversation()
        store.draft = "Keep this draft"
        service.loadHook = { id in
            XCTAssertEqual(id, "other")
            return try ChatThread(responses: [
                ChatMessage(id: "other-question", role: .user, text: "Other question"),
                ChatMessage(id: "other-answer", parentID: "other-question", role: .assistant, text: "Other answer")
            ])
        }
        let url = await store.shareConversation(id: "other")
        XCTAssertNotNil(url)
        XCTAssertEqual(service.mutations, ["share:other:other-answer"])
        XCTAssertEqual(store.selectedConversationID, "chat")
        XCTAssertEqual(store.selectedLeafID, "previous")
        XCTAssertEqual(store.messages.map(\.id), ["previous"])
        XCTAssertEqual(store.draft, "Keep this draft")
        XCTAssertTrue(store.updatingConversations.isEmpty)
    }

    @MainActor func testShareEmptyChatDoesNotPublish() async throws {
        let service = FakeService()
        service.loaded = try ChatThread(responses: [])
        let store = ChatStore(service: service, conversations: service.history)
        let url = await store.shareConversation(id: "chat")
        XCTAssertNil(url)
        XCTAssertTrue(service.mutations.isEmpty)
        XCTAssertNotNil(store.error)
        XCTAssertTrue(store.updatingConversations.isEmpty)
    }

    @MainActor func testShareDoesNotPublishAfterShutdownDuringThreadLoad() async throws {
        let service = FakeService()
        var loading: CheckedContinuation<ChatThread, Error>?
        service.loadHook = { _ in try await withCheckedThrowingContinuation { loading = $0 } }
        let store = ChatStore(service: service, conversations: service.history)
        let sharing = Task { await store.shareConversation(id: "chat") }
        while loading == nil { await Task.yield() }
        store.shutdown()
        loading?.resume(returning: service.loaded)
        let url = await sharing.value
        XCTAssertNil(url)
        XCTAssertTrue(service.mutations.isEmpty)
        XCTAssertTrue(store.updatingConversations.isEmpty)
    }

    @MainActor func testDeleteSelectedChatOutsideCurrentSearchResults() async {
        let service = FakeService()
        let store = ChatStore(service: service)
        store.select("chat")
        await store.deleteConversation(id: "chat")
        XCTAssertNil(store.selectedConversationID)
        XCTAssertEqual(service.mutations, ["delete:chat"])
    }

    @MainActor func testProfileAndConversationActions() async throws {
        let service = FakeService()
        let store = ChatStore(service: service, conversations: [
            ChatSummary(id: "newer", title: "Newer", modifiedAt: Date(timeIntervalSince1970: 2)),
            ChatSummary(id: "older", title: "Older", modifiedAt: Date(timeIntervalSince1970: 1))
        ])
        await store.loadProfile()
        XCTAssertEqual(store.accountName, "Test User")
        XCTAssertEqual(store.accountImageURL?.absoluteString, "https://assets.grok.com/avatar.jpg")
        await store.pinConversation(id: "older", pinned: true)
        XCTAssertEqual(store.conversations.map(\.id), ["older", "newer"])
        store.select("older")
        await store.loadSelectedConversation()
        await store.renameConversation(id: "older", title: "  Renamed  ")
        XCTAssertEqual(store.title, "Renamed")
        await store.pinConversation(id: "older", pinned: false)
        XCTAssertEqual(store.conversations.map(\.id), ["newer", "older"])
        store.draft = "Remove with chat"
        await store.deleteConversation(id: "older")
        XCTAssertNil(store.selectedConversationID)
        XCTAssertTrue(store.messages.isEmpty)
        XCTAssertTrue(store.draft.isEmpty)
        XCTAssertEqual(store.conversations.map(\.id), ["newer"])
        XCTAssertEqual(service.mutations, ["pin:older:true", "rename:older:Renamed", "pin:older:false", "delete:older"])
    }

    @MainActor func testFailedMutationPreservesChatAndSelection() async {
        let service = FakeService()
        let store = ChatStore(service: service, conversations: service.history)
        store.select("chat")
        await store.loadSelectedConversation()
        service.mutationError = URLError(.networkConnectionLost)
        await store.renameConversation(id: "chat", title: "New")
        await store.pinConversation(id: "chat", pinned: true)
        await store.deleteConversation(id: "chat")
        XCTAssertEqual(store.title, "Test")
        XCTAssertEqual(store.selectedConversationID, "chat")
        XCTAssertFalse(store.conversations[0].isPinned)
        XCTAssertFalse(store.messages.isEmpty)
        XCTAssertNotNil(store.error)
        XCTAssertTrue(store.updatingConversations.isEmpty)
    }

    @MainActor func testMutationBlocksSendAndIgnoresCompletionAfterShutdown() async {
        let service = FakeService()
        let store = ChatStore(service: service, conversations: service.history)
        await store.loadSelectedConversation()
        store.draft = "Do not send during update"
        service.mutationHook = {
            XCTAssertFalse(store.canSend)
            store.shutdown()
        }
        await store.renameConversation(id: "chat", title: "Late")
        XCTAssertEqual(store.conversations[0].title, "Test")
        XCTAssertTrue(store.updatingConversations.isEmpty)
    }

    @MainActor func testContinueUsesSelectedLeafAndReconcilesFinal() async throws {
        let service = FakeService()
        let store = ChatStore(service: service, conversations: service.history)
        store.select("chat")
        await store.loadSelectedConversation()
        service.loaded = try ChatThread(responses: [
            ChatMessage(id: "previous", role: .assistant, text: "Before"),
            ChatMessage(id: "user2", parentID: "previous", role: .user, text: "Hello"),
            ChatMessage(id: "answer", parentID: "user2", role: .assistant, text: "Final answer")
        ])
        service.events = [
            ReplyEvent(conversationID: "chat", responseID: "answer", text: "private thinking", isThinking: true),
            ReplyEvent(conversationID: "chat", responseID: "answer", text: "Final "),
            ReplyEvent(conversationID: "chat", responseID: "answer", text: "Final answer", isFinal: true)
        ]
        store.draft = " Hello "
        store.send()
        store.send() // No double send while the first task is starting.
        await store.waitForSend()
        XCTAssertEqual(service.calls.count, 1)
        XCTAssertEqual(service.calls.first?.0, "chat")
        XCTAssertEqual(service.calls.first?.1, "previous")
        XCTAssertEqual(service.calls.first?.2, "Hello")
        XCTAssertEqual(store.messages.last?.text, "Final answer")
        XCTAssertEqual(store.messages.last?.id, "answer")
        XCTAssertFalse(store.needsReload)
        XCTAssertFalse(store.isSending)
    }

    @MainActor func testNewChatAcquiresServerID() async throws {
        let service = FakeService()
        service.loaded = try ChatThread(responses: [ChatMessage(id: "answer", role: .assistant, text: "Hi")])
        service.events = [ReplyEvent(conversationID: "created", responseID: "answer", text: "Hi", isFinal: true)]
        service.history = [ChatSummary(id: "created", title: "New")]
        let store = ChatStore(service: service)
        store.draft = "Hi"
        store.send()
        await store.waitForSend()
        XCTAssertNil(service.calls.first?.0)
        XCTAssertNil(service.calls.first?.1)
        XCTAssertEqual(store.selectedConversationID, "created")
        XCTAssertEqual(store.selectedLeafID, "answer")
        XCTAssertEqual(store.conversations.first?.id, "created")
    }

    @MainActor func testUncertainSendBlocksRetryUntilReload() async {
        let service = FakeService()
        service.replyError = URLError(.networkConnectionLost)
        let store = ChatStore(service: service)
        store.select("chat")
        await store.loadSelectedConversation()
        store.draft = "Keep this text"
        store.send()
        await store.waitForSend()
        XCTAssertTrue(store.needsReload)
        XCTAssertEqual(store.recoveryText, "Keep this text")
        store.draft = "Try again"
        XCTAssertFalse(store.canSend)
        await store.loadSelectedConversation()
        XCTAssertTrue(store.canSend)
    }

    @MainActor func testEmptyStreamIsAnError() async {
        let store = ChatStore(service: FakeService())
        store.draft = "Hi"
        store.send()
        await store.waitForSend()
        XCTAssertNotNil(store.error)
        XCTAssertTrue(store.needsReload)
        XCTAssertFalse(store.isSending)
    }

    @MainActor func testStopCancelsAndRequiresReconciliation() async {
        let service = FakeService()
        var continuation: AsyncThrowingStream<ReplyEvent, Error>.Continuation?
        service.streamHook = { AsyncThrowingStream { continuation = $0 } }
        let store = ChatStore(service: service)
        store.draft = "Hi"
        store.send()
        while continuation == nil { await Task.yield() }
        store.stopSending()
        await store.waitForSend()
        XCTAssertFalse(store.isSending)
        XCTAssertTrue(store.needsReload)
        XCTAssertNotNil(store.error)
    }

    @MainActor func testDraftsAreSeparateForEachChat() async {
        let store = ChatStore(service: FakeService())
        store.draft = "New chat draft"
        store.select("one")
        store.draft = "First draft"
        store.select("two")
        XCTAssertEqual(store.draft, "")
        store.select("one")
        XCTAssertEqual(store.draft, "First draft")
        store.newChat()
        XCTAssertEqual(store.draft, "New chat draft")
    }

    @MainActor func testLateLoadCannotOverwriteAnotherChat() async throws {
        let service = FakeService()
        var first: CheckedContinuation<ChatThread, Error>?
        service.loadHook = { id in
            if id == "one" { return try await withCheckedThrowingContinuation { first = $0 } }
            return try ChatThread(responses: [ChatMessage(id: "two-answer", role: .assistant, text: "Two")])
        }
        let store = ChatStore(service: service)
        store.select("one")
        let oldTask = Task { await store.loadSelectedConversation() }
        while first == nil { await Task.yield() }
        store.select("two")
        await store.loadSelectedConversation()
        first?.resume(returning: try ChatThread(responses: [ChatMessage(id: "one-answer", role: .assistant, text: "One")]))
        await oldTask.value
        XCTAssertEqual(store.messages.last?.text, "Two")
        XCTAssertEqual(store.selectedConversationID, "two")
    }

    @MainActor func testSearchIgnoresLatePreviousQuery() async {
        let service = FakeService()
        var old: CheckedContinuation<[ChatSummary], Error>?
        service.historyHook = { query in
            if query == "old" { return try await withCheckedThrowingContinuation { old = $0 } }
            return [ChatSummary(id: "new", title: "New")]
        }
        let store = ChatStore(service: service)
        store.search = "old"
        let oldTask = Task { await store.refreshHistory() }
        while old == nil { await Task.yield() }
        store.search = "new"
        await store.refreshHistory()
        old?.resume(returning: [ChatSummary(id: "old", title: "Old")])
        await oldTask.value
        XCTAssertEqual(store.conversations.map(\.id), ["new"])
    }

    @MainActor func testUnauthorizedIsActionable() async {
        let service = FakeService()
        service.historyHook = { _ in throw GrokError.unauthorized }
        let store = ChatStore(service: service)
        await store.refreshHistory()
        XCTAssertEqual(store.error?.needsLogin, true)
        store.newChat()
        store.draft = "Hi"
        XCTAssertTrue(store.requiresLogin)
        XCTAssertFalse(store.canSend)
        let fresh = store.makeNewConversationStore()
        fresh.draft = "Quick message"
        XCTAssertTrue(fresh.requiresLogin)
        XCTAssertFalse(fresh.canSend)
    }

    @MainActor func testHistoryAppendsPagesAndStopsRepeatedCursor() async {
        let service = FakeService()
        var tokens: [String?] = []
        service.pageHook = { token, _ in
            tokens.append(token)
            if token == nil { return HistoryPage(items: [ChatSummary(id: "one", title: "One")], nextPageToken: "next") }
            return HistoryPage(items: [ChatSummary(id: "one", title: "One"), ChatSummary(id: "two", title: "Two")], nextPageToken: "next")
        }
        let store = ChatStore(service: service)
        await store.refreshHistory()
        XCTAssertTrue(store.hasMoreHistory)
        await store.refreshHistory(loadMore: true)
        XCTAssertEqual(store.conversations.map(\.id), ["one", "two"])
        XCTAssertFalse(store.hasMoreHistory)
        XCTAssertEqual(tokens.count, 2)
        XCTAssertNil(tokens[0])
        XCTAssertEqual(tokens[1], "next")
    }

    @MainActor func testBranchReplyUsesDisplayedParent() async throws {
        let service = FakeService()
        service.loaded = try ChatThread(responses: [
            ChatMessage(id: "user", role: .user, text: "Question"),
            ChatMessage(id: "one", parentID: "user", role: .assistant, text: "One"),
            ChatMessage(id: "two", parentID: "user", role: .assistant, text: "Two")
        ])
        service.replyError = URLError(.notConnectedToInternet)
        let store = ChatStore(service: service)
        store.select("chat")
        await store.loadSelectedConversation()
        store.selectBranch("one")
        store.draft = "Continue this branch"
        store.send()
        await store.waitForSend()
        XCTAssertEqual(service.calls.first?.1, "one")
    }

    @MainActor func testReconciliationCannotEnableSendWithoutAcknowledgedResponse() async {
        let service = FakeService()
        service.events = [ReplyEvent(conversationID: "chat", responseID: "not-yet-visible", text: "Answer", isFinal: true)]
        let store = ChatStore(service: service)
        store.select("chat")
        await store.loadSelectedConversation()
        store.draft = "Hi"
        store.send()
        await store.waitForSend()
        XCTAssertTrue(store.needsReload)
        XCTAssertNotNil(store.error)
        store.draft = "Next"
        XCTAssertFalse(store.canSend)
    }
}
