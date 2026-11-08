import XCTest
@testable import GrokCore

@MainActor final class ProjectFixture: ProjectServing {
    var items = [GrokProject(id: "one", name: "Existing")]
    var loads = 0
    var creates = 0
    var failure: Error?
    var createHook: (() async -> Void)?
    var loadHook: (() async -> Void)?
    var receivedName: String?
    var receivedDescription: String?
    var mutations: [String] = []
    var mutationHook: (() async -> Void)?
    var conversationCalls: [(String, String?)] = []
    var conversationHook: ((String, String?) async throws -> HistoryPage)?

    func projectConversations(id: String, pageToken: String?) async throws -> HistoryPage {
        conversationCalls.append((id, pageToken))
        if let conversationHook { return try await conversationHook(id, pageToken) }
        return HistoryPage(items: [ChatSummary(id: "chat-\(id)", title: "Project chat")])
    }

    func projects() async throws -> [GrokProject] {
        loads += 1
        await loadHook?()
        if let failure { throw failure }
        return items
    }

    func createProject(name: String, description: String, icon: ProjectIcon) async throws -> GrokProject {
        creates += 1
        receivedName = name
        receivedDescription = description
        await createHook?()
        if let failure { throw failure }
        return GrokProject(id: "created", name: name, description: description, icon: icon.encodedValue)
    }

    func renameProject(id: String, name: String) async throws {
        mutations.append("rename:\(id):\(name)")
        await mutationHook?()
        if let failure { throw failure }
    }

    func deleteProject(id: String) async throws {
        mutations.append("delete:\(id)")
        await mutationHook?()
        if let failure { throw failure }
    }

    func addConversationToProject(conversationID: String, projectID: String) async throws {
        mutations.append("move:\(conversationID):\(projectID)")
        await mutationHook?()
        if let failure { throw failure }
    }

    func removeConversationFromProject(conversationID: String, projectID: String) async throws {
        mutations.append("remove:\(conversationID):\(projectID)")
        await mutationHook?()
        if let failure { throw failure }
    }
}

final class ProjectTests: XCTestCase {
    @MainActor func testRemoveFromProjectKeepsCacheOnFailureAndInvalidatesOnSuccess() async {
        let service = ProjectFixture()
        let store = ProjectStore(service: service)
        await store.load()
        await store.loadConversations(projectID: "one")
        service.failure = URLError(.notConnectedToInternet)
        let failed = await store.removeConversation(id: "chat-one", from: "one")
        XCTAssertFalse(failed)
        XCTAssertEqual(store.conversations["one"]?.count, 1)
        XCTAssertNotNil(store.actionError)
        service.failure = nil
        let removed = await store.removeConversation(id: "chat-one", from: "one")
        XCTAssertTrue(removed)
        XCTAssertNil(store.conversations["one"])
        XCTAssertEqual(store.conversationRevisions["one"], 1)
        XCTAssertEqual(store.items.count, 1)
        XCTAssertNil(store.actionError)
    }

    @MainActor func testProjectChatsAreIsolatedAndPaginatedWithoutDuplicates() async {
        let service = ProjectFixture()
        service.items.append(GrokProject(id: "two", name: "Other"))
        service.conversationHook = { id, token in
            let first = ChatSummary(id: "\(id)-first", title: "First")
            return token == nil ? HistoryPage(items: [first], nextPageToken: "next") :
                HistoryPage(items: [first, ChatSummary(id: "\(id)-second", title: "Second")], nextPageToken: "next")
        }
        let store = ProjectStore(service: service)
        await store.load()
        await store.loadConversations(projectID: "one")
        await store.loadConversations(projectID: "two")
        await store.loadConversations(projectID: "one", loadMore: true)
        XCTAssertEqual(store.conversations["one"]?.map(\.id), ["one-first", "one-second"])
        XCTAssertEqual(store.conversations["two"]?.map(\.id), ["two-first"])
        XCTAssertFalse(store.hasMoreConversations(in: "one"))
        XCTAssertTrue(store.hasMoreConversations(in: "two"))
        XCTAssertEqual(service.conversationCalls.last?.1, "next")
    }

    @MainActor func testProjectChatFailureKeepsPreviousPageAndCanRetry() async {
        let service = ProjectFixture()
        let store = ProjectStore(service: service)
        await store.load()
        await store.loadConversations(projectID: "one")
        service.conversationHook = { _, _ in throw URLError(.notConnectedToInternet) }
        await store.loadConversations(projectID: "one")
        XCTAssertEqual(store.conversations["one"]?.count, 1)
        XCTAssertNotNil(store.conversationErrors["one"])
        XCTAssertTrue(store.loadingConversations.isEmpty)
        service.conversationHook = { _, _ in HistoryPage(items: []) }
        await store.loadConversations(projectID: "one")
        XCTAssertEqual(store.conversations["one"], [])
        XCTAssertNil(store.conversationErrors["one"])
    }

    @MainActor func testDeletedProjectAndLogoutDiscardPendingChatLoads() async {
        for deleting in [false, true] {
            let service = ProjectFixture()
            let store = ProjectStore(service: service)
            await store.load()
            var release: CheckedContinuation<Void, Never>?
            service.conversationHook = { _, _ in
                await withCheckedContinuation { release = $0 }
                return HistoryPage(items: [ChatSummary(id: "late", title: "Late")])
            }
            let load = Task { await store.loadConversations(projectID: "one") }
            while release == nil { await Task.yield() }
            if deleting { _ = await store.delete(id: "one") } else { store.shutdown() }
            release?.resume()
            await load.value
            XCTAssertNil(store.conversations["one"])
            XCTAssertTrue(store.loadingConversations.isEmpty)
            XCTAssertNil(store.conversationErrors["one"])
        }
    }

    @MainActor func testMovingChatInvalidatesProjectCacheAndLateLoad() async {
        let service = ProjectFixture()
        let store = ProjectStore(service: service)
        await store.load()
        await store.loadConversations(projectID: "one")
        var release: CheckedContinuation<Void, Never>?
        service.conversationHook = { _, _ in
            await withCheckedContinuation { release = $0 }
            return HistoryPage(items: [])
        }
        let stale = Task { await store.loadConversations(projectID: "one") }
        while release == nil { await Task.yield() }
        let moved = await store.moveConversation(id: "added", to: "one")
        XCTAssertTrue(moved)
        XCTAssertEqual(store.conversationRevisions["one"], 1)
        release?.resume()
        await stale.value
        XCTAssertNil(store.conversations["one"])
    }

    @MainActor func testRenameKeepsProjectMetadataAndDeleteRequiresSuccess() async {
        let service = ProjectFixture()
        service.items = [GrokProject(id: "one", name: "Before", description: "Keep this", icon: "l:briefcase:blue")]
        let store = ProjectStore(service: service)
        await store.load()
        let blank = await store.rename(id: "one", name: " \n")
        XCTAssertFalse(blank)
        XCTAssertTrue(service.mutations.isEmpty)
        let renamed = await store.rename(id: "one", name: " After \n")
        XCTAssertTrue(renamed)
        XCTAssertEqual(store.items.first?.name, "After")
        XCTAssertEqual(store.items.first?.description, "Keep this")
        XCTAssertEqual(store.items.first?.icon, "l:briefcase:blue")
        service.failure = URLError(.notConnectedToInternet)
        let failed = await store.delete(id: "one")
        XCTAssertFalse(failed)
        XCTAssertEqual(store.items.count, 1)
        XCTAssertNotNil(store.actionError)
        service.failure = nil
        let deleted = await store.delete(id: "one")
        XCTAssertTrue(deleted)
        XCTAssertTrue(store.items.isEmpty)
        XCTAssertNil(store.actionError)
    }

    @MainActor func testMoveRejectsMissingProjectsAndSerializesMutations() async {
        let service = ProjectFixture()
        let store = ProjectStore(service: service)
        await store.load()
        let missing = await store.moveConversation(id: "chat", to: "missing")
        XCTAssertFalse(missing)
        XCTAssertTrue(service.mutations.isEmpty)
        var release: CheckedContinuation<Void, Never>?
        service.mutationHook = { await withCheckedContinuation { release = $0 } }
        let move = Task { await store.moveConversation(id: "chat", to: "one") }
        while release == nil { await Task.yield() }
        XCTAssertEqual(store.movingConversationID, "chat")
        let duplicate = await store.moveConversation(id: "chat", to: "one")
        let deleting = await store.delete(id: "one")
        XCTAssertFalse(duplicate)
        XCTAssertFalse(deleting)
        XCTAssertEqual(service.mutations, ["move:chat:one"])
        release?.resume()
        let moved = await move.value
        XCTAssertTrue(moved)
        XCTAssertFalse(store.isBusy)
        XCTAssertEqual(store.items.count, 1)
    }

    @MainActor func testLogoutDiscardsLateMutationSuccessAndFailure() async {
        for fails in [false, true] {
            let service = ProjectFixture()
            let store = ProjectStore(service: service)
            await store.load()
            if fails { service.failure = URLError(.notConnectedToInternet) }
            var release: CheckedContinuation<Void, Never>?
            service.mutationHook = { await withCheckedContinuation { release = $0 } }
            let rename = Task { await store.rename(id: "one", name: "After") }
            while release == nil { await Task.yield() }
            store.shutdown()
            release?.resume()
            let renamed = await rename.value
            XCTAssertFalse(renamed)
            XCTAssertTrue(store.items.isEmpty)
            XCTAssertNil(store.actionError)
            XCTAssertFalse(store.isBusy)
        }
    }

    @MainActor func testConfirmedCreationUpdatesLoadedListAndTrimsInput() async {
        let service = ProjectFixture()
        service.items += service.items
        let store = ProjectStore(service: service)
        await store.load(ifNeeded: true)
        await store.load(ifNeeded: true)
        XCTAssertEqual(service.loads, 1)
        XCTAssertEqual(store.items.count, 1)
        let created = await store.create(name: " Study \n", description: " Notes \n", icon: .education)
        XCTAssertTrue(created)
        XCTAssertEqual(service.receivedName, "Study")
        XCTAssertEqual(service.receivedDescription, "Notes")
        XCTAssertEqual(store.items.map(\.id), ["created", "one"])
    }

    @MainActor func testFailuresKeepPreviousProjectsAndEmptyNameNeverPosts() async {
        let service = ProjectFixture()
        let store = ProjectStore(service: service)
        await store.load()
        let blank = await store.create(name: " \n", description: "", icon: .book)
        XCTAssertFalse(blank)
        XCTAssertEqual(service.creates, 0)
        service.failure = URLError(.notConnectedToInternet)
        let failed = await store.create(name: "Study", description: "", icon: .book)
        XCTAssertFalse(failed)
        XCTAssertNotNil(store.createError)
        await store.load()
        XCTAssertNotNil(store.loadError)
        XCTAssertEqual(store.items.map(\.id), ["one"])
    }

    @MainActor func testConcurrentCreationDoesNotSendDuplicateRequest() async {
        let service = ProjectFixture()
        var release: CheckedContinuation<Void, Never>?
        service.createHook = { await withCheckedContinuation { release = $0 } }
        let store = ProjectStore(service: service)
        let task = Task { await store.create(name: "First", description: "", icon: .book) }
        while release == nil { await Task.yield() }
        let second = await store.create(name: "Second", description: "", icon: .book)
        XCTAssertFalse(second)
        XCTAssertEqual(service.creates, 1)
        release?.resume()
        let first = await task.value
        XCTAssertTrue(first)
        XCTAssertEqual(store.items.map(\.name), ["First"])
    }

    @MainActor func testLogoutDiscardsLateCreationAndLoadResults() async {
        for creating in [true, false] {
            let service = ProjectFixture()
            var release: CheckedContinuation<Void, Never>?
            let wait: () async -> Void = { await withCheckedContinuation { release = $0 } }
            if creating { service.createHook = wait } else { service.loadHook = wait }
            let store = ProjectStore(service: service)
            let task = Task {
                if creating { _ = await store.create(name: "Study", description: "", icon: .book) }
                else { await store.load() }
            }
            while release == nil { await Task.yield() }
            store.shutdown()
            release?.resume()
            await task.value
            XCTAssertTrue(store.items.isEmpty)
            XCTAssertNil(store.createError)
            XCTAssertNil(store.loadError)
            XCTAssertFalse(store.isCreating)
            XCTAssertFalse(store.isLoading)
        }
    }
}
