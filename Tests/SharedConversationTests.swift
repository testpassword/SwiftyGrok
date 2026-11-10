import XCTest
import GrokClient
@testable import GrokCore

@MainActor private final class SharedService: SharedConversationServing {
    var page = SharedConversationPage(items: [])
    var pages: [String?] = []
    var revoked: [String] = []
    var loadHook: ((String?) async throws -> SharedConversationPage)?
    var revokeHook: ((String) async throws -> Void)?
    func sharedConversations(pageToken: String?) async throws -> SharedConversationPage {
        pages.append(pageToken)
        if let loadHook { return try await loadHook(pageToken) }
        return page
    }
    func revokeSharedConversation(id: String) async throws {
        revoked.append(id)
        try await revokeHook?(id)
    }
}

final class SharedConversationTests: XCTestCase {
    private let one = SharedConversation(id: "management-one", conversationID: "original-chat", title: "First",
        url: URL(string: "https://grok.com/share/public-one"), views: 3)
    private let two = SharedConversation(id: "management-two", title: "Second", views: 0)

    @MainActor func testPagesDeduplicateLinksAndStopRepeatedCursor() async {
        let service = SharedService()
        let store = SharedConversationStore(service: service)
        service.page = SharedConversationPage(items: [one], nextPageToken: "next")
        await store.load()
        XCTAssertTrue(store.hasMore)
        service.page = SharedConversationPage(items: [one, two], nextPageToken: "next")
        await store.load(more: true)
        XCTAssertEqual(store.items.map(\.id), [one.id, two.id])
        XCTAssertEqual(service.pages, [nil, "next"])
        XCTAssertFalse(store.hasMore)
        await store.load(more: true)
        XCTAssertEqual(service.pages.count, 2)
        service.page = SharedConversationPage(items: [two])
        await store.load()
        XCTAssertEqual(store.items.map(\.id), [two.id])
    }

    @MainActor func testSuccessfulRevokeUsesManagementIDAndRemovesOnlyThatLink() async {
        let service = SharedService()
        service.page = SharedConversationPage(items: [one, two])
        let store = SharedConversationStore(service: service)
        await store.load()
        await store.revoke(one)
        XCTAssertEqual(service.revoked, ["management-one"])
        XCTAssertEqual(store.items.map(\.id), [two.id])
        await store.revoke(one)
        XCTAssertEqual(service.revoked.count, 1)
        XCTAssertFalse(store.isBusy)
    }

    @MainActor func testFailedRevokeKeepsLinkAndStats() async {
        let service = SharedService()
        service.page = SharedConversationPage(items: [one])
        service.revokeHook = { _ in throw URLError(.notConnectedToInternet) }
        let store = SharedConversationStore(service: service)
        await store.load()
        await store.revoke(one)
        XCTAssertEqual(store.items, [one])
        XCTAssertNotNil(store.error)
        XCTAssertFalse(store.isBusy)
    }

    @MainActor func testDuplicateDeleteAndRefreshCannotRacePendingRevoke() async {
        let service = SharedService()
        service.page = SharedConversationPage(items: [one])
        var result: CheckedContinuation<Void, Error>?
        service.revokeHook = { _ in try await withCheckedThrowingContinuation { result = $0 } }
        let store = SharedConversationStore(service: service)
        await store.load()
        let item = one
        let task = Task { await store.revoke(item) }
        while result == nil { await Task.yield() }
        await store.revoke(one)
        await store.load()
        XCTAssertEqual(service.revoked, [one.id])
        XCTAssertEqual(service.pages.count, 1)
        result?.resume(returning: ())
        await task.value
        XCTAssertTrue(store.items.isEmpty)
    }

    @MainActor func testClosedStoreRejectsLateResponseAndFurtherRequests() async {
        let service = SharedService()
        var result: CheckedContinuation<SharedConversationPage, Error>?
        service.loadHook = { _ in try await withCheckedThrowingContinuation { result = $0 } }
        let store = SharedConversationStore(service: service)
        let task = Task { await store.load() }
        while result == nil { await Task.yield() }
        store.shutdown()
        result?.resume(returning: SharedConversationPage(items: [one]))
        await task.value
        await store.load()
        await store.revoke(one)
        XCTAssertTrue(store.items.isEmpty)
        XCTAssertEqual(service.pages.count, 1)
        XCTAssertTrue(service.revoked.isEmpty)
    }

    @MainActor func testExpiredSessionPreservesListButBlocksFurtherChanges() async {
        let service = SharedService()
        service.page = SharedConversationPage(items: [one])
        let store = SharedConversationStore(service: service)
        await store.load()
        service.revokeHook = { _ in throw GrokError.unauthorized }
        await store.revoke(one)
        XCTAssertTrue(store.requiresLogin)
        XCTAssertEqual(store.items, [one])
        await store.revoke(one)
        await store.load()
        XCTAssertEqual(service.revoked.count, 1)
        XCTAssertEqual(service.pages.count, 1)
    }

    @MainActor func testConcurrentNetworkFailureDoesNotClearExpiredSession() async {
        let service = SharedService()
        service.page = SharedConversationPage(items: [one, two])
        var results: [String: CheckedContinuation<Void, Error>] = [:]
        service.revokeHook = { id in try await withCheckedThrowingContinuation { results[id] = $0 } }
        let store = SharedConversationStore(service: service)
        await store.load()
        let first = one, second = two
        let firstTask = Task { await store.revoke(first) }
        let secondTask = Task { await store.revoke(second) }
        while results.count < 2 { await Task.yield() }
        results[first.id]?.resume(throwing: GrokError.unauthorized)
        await firstTask.value
        results[second.id]?.resume(throwing: URLError(.notConnectedToInternet))
        await secondTask.value
        XCTAssertTrue(store.requiresLogin)
        XCTAssertEqual(store.items, [one, two])
        XCTAssertFalse(store.isBusy)
    }
}
