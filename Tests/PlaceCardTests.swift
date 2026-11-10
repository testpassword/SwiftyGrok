import XCTest
import Foundation
import GrokClient
@testable import GrokCore
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

enum PlaceFixtures {
    static let place: [String: Any] = [
        "id": "example-garden", "display_name": ["text": "Example Garden"],
        "formatted_address": "Example Street", "coordinates": ["latitude": 48.1, "longitude": 11.5],
        "rating": 4.8, "user_ratings_total": 12,
        "opening_hours": ["open_now": true, "weekday_descriptions": ["Monday: 09:00–18:00"]],
        "photos": [["photo_uri": "https://images.example/garden.jpg", "author_attributions": [["display_name": "Photo credit", "uri": "https://images.example/author"]]]],
        "google_maps_uri": "https://maps.example/garden"
    ]
    static let chunks: [[String: Any]] = [
        ["text": ["text": "Private thinking", "channel": "ASSISTANT_THINKING"]],
        ["text": ["text": "Before\n\n", "channel": "ASSISTANT"]],
        ["render_places": ["id": "parks", "locs": [place]]],
        ["text": ["text": "\n\nAfter", "channel": "ASSISTANT"]]
    ]
}

@MainActor final class StubPlaceHistory: PlaceHistoryLoading {
    var calls: [[String]] = []
    var failure: Error?
    func load(conversationID: String, responseIDs: [String]) async throws -> [String: PlaceResponseContent] {
        calls.append(responseIDs)
        if let failure { throw failure }
        return Dictionary(uniqueKeysWithValues: responseIDs.map { ($0, PlaceResponseContent(chunks: PlaceFixtures.chunks)) })
    }
}

final class PlaceCardTests: XCTestCase {
    func testPlacesKeepPositionAndExcludeThinking() throws {
        let content = PlaceResponseContent(chunks: PlaceFixtures.chunks)
        XCTAssertEqual(content.blocks.count, 3)
        XCTAssertEqual(content.blocks.first, .text("Before\n\n"))
        XCTAssertEqual(content.blocks.last, .text("\n\nAfter"))
        XCTAssertEqual(content.blocks(matching: "Before\n\n\n\nAfter"), content.blocks)
        let place = try XCTUnwrap(content.galleries.first?.places.first)
        XCTAssertEqual(place.name, "Example Garden")
        XCTAssertEqual(place.latitude, 48.1)
        XCTAssertEqual(place.reviewCount, 12)
        XCTAssertEqual(place.isOpen, true)
        XCTAssertEqual(place.photos.first?.authors.first?.name, "Photo credit")
    }

    func testUnknownTextShapeCannotTruncateOriginalAnswer() {
        let content = PlaceResponseContent(chunks: PlaceFixtures.chunks)
        XCTAssertEqual(content.blocks(matching: "A complete different answer").first, .text("A complete different answer"))
        XCTAssertEqual(content.blocks(matching: "A complete different answer").count, 2)
    }

    func testFormattingDifferencesKeepGalleryBeforeFollowingParagraph() {
        let original = "**Before**\n\n\n\nAfter"
        let blocks = PlaceResponseContent(chunks: PlaceFixtures.chunks).blocks(matching: original)
        XCTAssertEqual(blocks.count, 3)
        XCTAssertEqual(blocks.first, .text("**Before**\n\n\n\n"))
        XCTAssertEqual(blocks.last, .text("After"))
        let restored = blocks.compactMap { if case .text(let text) = $0 { return text }; return nil }.joined()
        XCTAssertEqual(restored, original)
    }

    func testInvalidCoordinatesURLsAndRatingsAreRejectedWithoutDroppingPlace() throws {
        var json = PlaceFixtures.place
        json["coordinates"] = ["latitude": 1000, "longitude": 20]
        json["rating"] = 9; json["user_ratings_total"] = -1
        json["google_maps_uri"] = "javascript:alert(1)"
        json["photos"] = [["photo_uri": "https://user:secret@example.com/image"], ["photo_uri": "file:///fixture"]]
        let place = try XCTUnwrap(PlaceCard(json))
        XCTAssertNil(place.latitude); XCTAssertNil(place.longitude); XCTAssertNil(place.rating)
        XCTAssertNil(place.reviewCount); XCTAssertNil(place.mapsURL); XCTAssertTrue(place.photos.isEmpty)
        XCTAssertNil(PlaceCard(["id": "no-name"]))
    }

    func testUpdatedGalleryAndDuplicatePlacesDoNotCreateDuplicateCards() {
        let content = PlaceResponseContent(chunks: [
            ["render_places": ["id": "same", "locs": [PlaceFixtures.place, PlaceFixtures.place]]],
            ["render_places": ["id": "same", "locs": [PlaceFixtures.place]]]
        ])
        XCTAssertEqual(content.galleries.count, 1)
        XCTAssertEqual(content.galleries.first?.places.count, 1)
    }

    func testOnlyPlaceToolsRequestSupplementalHistory() {
        func metadata(_ name: String) -> [String: AnyCodable] {
            ["steps": AnyCodable([["toolUsageCards": [["mcp": ["toolName": name]]]]])]
        }
        XCTAssertTrue(PlaceResponseContent.needsHistory(metadata("places_search")))
        XCTAssertTrue(PlaceResponseContent.needsHistory(metadata("functions.places_search")))
        XCTAssertFalse(PlaceResponseContent.needsHistory(metadata("web_search")))
        XCTAssertFalse(PlaceResponseContent.needsHistory([:]))
    }

    @MainActor func testGatewayLoadsBothBranchesWithoutGenerationAndClosesConnection() async throws {
        let socket = FakePlaceSocket()
        var request: URLRequest?
        let loader = GatewayPlaceHistory(credentials: try SessionCredentials(cookies: ["sso": "fixture", "x-userid": "fixture-user"]), timeout: 1) {
            request = $0; return socket
        }
        let result = try await loader.load(conversationID: "chat", responseIDs: ["branch-one", "branch-two"])
        XCTAssertEqual(Set(result.keys), ["branch-one", "branch-two"])
        XCTAssertEqual(result["branch-two"]?.galleries.first?.places.count, 1)
        XCTAssertEqual(request?.url?.host, "grok.com")
        XCTAssertEqual(URLComponents(url: request!.url!, resolvingAgainstBaseURL: false)?.queryItems?.first?.value, "fixture-user")
        XCTAssertTrue(request?.value(forHTTPHeaderField: "Cookie")?.contains("sso=fixture") == true)
        XCTAssertTrue(socket.closed)
        XCTAssertEqual(socket.events.map { $0["type"] as! String }, ["session.create", "conversation.history.load", "conversation.history.load"])
        let session = socket.events[0]["session"] as! [String: Any]
        let grok = session["x_grok"] as! [String: Any]
        XCTAssertEqual(grok["load_existing"] as? Bool, true)
        XCTAssertEqual(grok["use_chunk"] as? Bool, true)
        XCTAssertEqual(grok["needs_history"] as? Bool, false)
    }

    @MainActor func testGatewayReconnectsOnlyWhenRequestedByServer() async throws {
        let moved = FakePlaceSocket(); moved.moved = true
        let ready = FakePlaceSocket(); var count = 0
        let loader = GatewayPlaceHistory(credentials: try SessionCredentials(cookies: ["sso": "fixture"]), timeout: 1) { _ in
            count += 1; return count == 1 ? moved : ready
        }
        let result = try await loader.load(conversationID: "chat", responseIDs: ["answer"])
        XCTAssertEqual(count, 2); XCTAssertTrue(moved.closed); XCTAssertTrue(ready.closed)
        XCTAssertEqual(result.count, 1)
    }

    @MainActor func testMissingChunksCannotBeCachedAsSuccessfulEmptyGallery() async throws {
        let socket = FakePlaceSocket(); socket.omitChunks = true
        let loader = GatewayPlaceHistory(credentials: try SessionCredentials(cookies: ["sso": "fixture"]), timeout: 1) { _ in socket }
        do { _ = try await loader.load(conversationID: "chat", responseIDs: ["answer"]); XCTFail("Missing structured history accepted") }
        catch { XCTAssertTrue(socket.closed) }
    }

    @MainActor func testCancellationClosesSocketInsteadOfWaitingForTimeout() async throws {
        let socket = FakePlaceSocket(); socket.stall = true
        let loader = GatewayPlaceHistory(credentials: try SessionCredentials(cookies: ["sso": "fixture"]), timeout: 5) { _ in socket }
        let task = Task { try await loader.load(conversationID: "chat", responseIDs: ["answer"]) }
        while socket.waiter == nil { await Task.yield() }
        task.cancel()
        do { _ = try await task.value; XCTFail("Cancellation ignored") } catch { XCTAssertTrue(socket.closed) }
    }

    @MainActor func testDeadlineClosesUnresponsiveSocket() async throws {
        let socket = FakePlaceSocket(); socket.stall = true
        let loader = GatewayPlaceHistory(credentials: try SessionCredentials(cookies: ["sso": "fixture"]), timeout: 0.03) { _ in socket }
        do { _ = try await loader.load(conversationID: "chat", responseIDs: ["answer"]); XCTFail("Unresponsive history accepted") }
        catch { XCTAssertTrue(socket.closed) }
    }
}

@MainActor private final class FakePlaceSocket: PlaceHistorySocket {
    var moved = false, omitChunks = false, stall = false, closed = false
    var events: [[String: Any]] = []
    var queue: [Data] = []
    var waiter: CheckedContinuation<Data, Error>?
    func send(_ data: Data) async throws {
        let envelope = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        let event = envelope["event"] as! [String: Any]
        let chat = envelope["session_id"] as! String
        events.append(event)
        func enqueue(_ event: [String: Any]) throws {
            queue.append(try JSONSerialization.data(withJSONObject: ["session_id": chat, "event": event]))
        }
        switch event["type"] as? String {
        case "session.create":
            if stall { return }
            if moved { try enqueue(["type": "session.moved"]); return }
            try enqueue(["type": "session.created"])
            try enqueue(["type": "conversation.attached", "conversation": ["id": chat]])
        case "conversation.history.load":
            let load = event["load_id"] as! String, leaf = event["leaf_id"] as! String
            try enqueue(["type": "conversation.history.item", "load_id": load,
                         "item": ["id": leaf, "x_grok": omitChunks ? [:] : ["output_chunks": PlaceFixtures.chunks]]])
            try enqueue(["type": "conversation.history.done", "load_id": load])
        default: XCTFail("Unexpected mutating gateway event")
        }
    }
    func receive() async throws -> Data {
        if !queue.isEmpty { return queue.removeFirst() }
        return try await withCheckedThrowingContinuation { waiter = $0 }
    }
    func close() {
        closed = true
        let pending = waiter; waiter = nil
        pending?.resume(throwing: CancellationError())
    }
}
