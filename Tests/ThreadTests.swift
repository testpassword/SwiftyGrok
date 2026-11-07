import XCTest
@testable import GrokCore

final class ThreadTests: XCTestCase {
    func testUnorderedResponsesProjectOneBranch() throws {
        let responses = [
            ChatMessage(id: "new", parentID: "u", role: .assistant, text: "Latest", createdAt: Date(timeIntervalSince1970: 3)),
            ChatMessage(id: "u", role: .user, text: "Hi", createdAt: Date(timeIntervalSince1970: 1)),
            ChatMessage(id: "old", parentID: "u", role: .assistant, text: "Older", createdAt: Date(timeIntervalSince1970: 2))
        ]
        let thread = try ChatThread(responses: responses)
        XCTAssertEqual(try thread.path().map(\.id), ["u", "new"])
        XCTAssertEqual(try thread.path(to: "old").map(\.id), ["u", "old"])
        XCTAssertEqual(thread.branches.count, 2)
    }

    func testRejectsDuplicateIDsCyclesAndMissingParents() throws {
        let user = ChatMessage(id: "a", role: .user, text: "Hi")
        XCTAssertThrowsError(try ChatThread(responses: [user, user]))
        XCTAssertThrowsError(try ChatThread(responses: [ChatMessage(id: "loop", parentID: "loop", role: .user, text: "Loop")]))
        let missing = try ChatThread(responses: [ChatMessage(id: "leaf", parentID: "missing", role: .assistant, text: "Hi")])
        XCTAssertThrowsError(try missing.path())
        let cycleWithLeaf = try ChatThread(responses: [
            ChatMessage(id: "a", parentID: "b", role: .user, text: "A"),
            ChatMessage(id: "b", parentID: "a", role: .assistant, text: "B"),
            ChatMessage(id: "c", parentID: "b", role: .user, text: "C")
        ])
        XCTAssertThrowsError(try cycleWithLeaf.path())
    }

    func testEmptyThreadAndFractionalDates() throws {
        XCTAssertTrue(try ChatThread(responses: []).path().isEmpty)
        XCTAssertNotNil(GrokDate.parse("2026-11-06T10:20:30.123Z"))
        XCTAssertNotNil(GrokDate.parse("2026-11-06T10:20:30Z"))
    }
}
