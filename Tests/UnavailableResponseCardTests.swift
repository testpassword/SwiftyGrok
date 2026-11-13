import XCTest
import GrokClient
@testable import GrokCore

final class UnavailableResponseCardTests: XCTestCase {
    private func marker(_ id: String, kind: String = "render_chart") -> String {
        "<grok:render card_id=\"\(id)\" type=\"\(kind)\"><argument name=\"symbol\">TEST</argument></grok:render>"
    }
    private func unavailable(_ blocks: [ResponseContentBlock]) -> [UnavailableResponseCard] {
        blocks.compactMap { if case .unavailable(let card) = $0 { return card }; return nil }
    }
    private func text(_ blocks: [ResponseContentBlock]) -> String {
        blocks.compactMap { if case .text(let value) = $0 { return value }; return nil }.joined()
    }

    func testUnknownInlineCardKeepsPositionAndExposesPayload() throws {
        let raw: [String: Any] = ["id": "chart", "type": "render_chart", "points": [1, 2, 3]]
        let json = String(decoding: try JSONSerialization.data(withJSONObject: raw), as: UTF8.self)
        let original = "Before\n" + marker("chart") + "\nAfter"
        let blocks = GrokMessageContent(["cardAttachmentsJson": AnyCodable([json])]).contentBlocks(in: original)
        let card = try XCTUnwrap(unavailable(blocks).first)
        XCTAssertEqual(blocks.count, 3)
        XCTAssertEqual(card.kind, "render_chart")
        XCTAssertEqual(card.reason, .unsupported)
        XCTAssertTrue(card.rawData.contains("points"))
        XCTAssertTrue(card.rawData.contains("grok:render"))
        XCTAssertEqual(text(blocks), original)
        XCTAssertEqual(blocks.last, .text("\nAfter"))
    }

    func testMissingPayloadAndRepeatedReferencesShowOnePlaceholder() throws {
        let original = "Before" + marker("missing") + "Between" + marker("missing") + "After"
        let blocks = GrokMessageContent([:]).contentBlocks(in: original)
        XCTAssertEqual(unavailable(blocks).count, 1)
        let card = try XCTUnwrap(unavailable(blocks).first)
        XCTAssertEqual(card.reason, .missingData)
        XCTAssertEqual(card.rawData, marker("missing"))
        XCTAssertEqual(text(blocks), original)
    }

    func testMalformedKnownCardShowsInvalidDataInsteadOfDisappearing() throws {
        let content = GrokMessageContent(["cardAttachmentsJson": AnyCodable([
            ["id": "image", "type": "render_searched_image", "image": ["original": "file:///secret"]]
        ])])
        let blocks = content.contentBlocks(in: marker("image", kind: "render_searched_image"))
        XCTAssertEqual(try XCTUnwrap(unavailable(blocks).first).reason, .invalidData)
    }

    func testLiteralCodeAndToolUsageDoNotCreatePlaceholders() {
        let content = GrokMessageContent([:])
        for example in ["```xml\n\(marker("example"))\n```", "~~~xml\n\(marker("example"))\n~~~", "`\(marker("example"))`",
                        "<xai:tool_usage_card>private tool metadata</xai:tool_usage_card>"] {
            XCTAssertTrue(content.contentBlocks(in: example).isEmpty)
        }
        let original = "```xml\n\(marker("literal"))\n```\n" + marker("real")
        let blocks = content.contentBlocks(in: original)
        XCTAssertEqual(unavailable(blocks).map(\.id), ["real"])
        XCTAssertEqual(text(blocks), original)
    }

    func testWorkingImagesAndCitationsAreNotDuplicatedByFallbacks() {
        let content = GrokMessageContent(SearchedImageFixtures.metadata)
        let blocks = content.contentBlocks(in: SearchedImageFixtures.text)
        XCTAssertTrue(unavailable(blocks).isEmpty)
        XCTAssertEqual(SearchedImageFixtures.galleries(blocks).count, 1)
        let citation = "<grok:render card_id=\"citation\" card_type=\"citation_card\"><argument name=\"citation_id\">0</argument></grok:render>"
        let source = MessageSource(id: "citation", title: "Example", url: URL(string: "https://example.com")!)
        XCTAssertTrue(unavailable(UnavailableResponseCard.inserting(in: [.text(citation)], sources: [source])).isEmpty)
    }

    func testUnknownCardWithURLStillHasPlaceholderInsteadOfOnlyBecomingALink() {
        let content = GrokMessageContent(["cardAttachmentsJson": AnyCodable([
            ["id": "widget", "type": "render_finance", "url": "https://example.com/finance"]
        ])])
        XCTAssertEqual(unavailable(content.contentBlocks(in: marker("widget", kind: "render_finance"))).count, 1)
    }

    func testUnknownGatewayWidgetPreservesOrderRawDataAndUpdates() throws {
        let chunks: [[String: Any]] = [
            ["text": ["text": "Before", "channel": "ASSISTANT"]],
            ["render_chart": ["id": "chart", "value": 1]],
            ["render_chart": ["id": "chart", "value": 2]],
            ["text": ["text": "After", "channel": "ASSISTANT"]]
        ]
        let blocks = ResponseCardContent(chunks: chunks).blocks(matching: "BeforeAfter")
        XCTAssertEqual(blocks.count, 3)
        let card = try XCTUnwrap(unavailable(blocks).first)
        XCTAssertEqual(card.reason, .unsupported)
        XCTAssertTrue(card.rawData.contains("2"))
        XCTAssertEqual(text(blocks), "BeforeAfter")
    }

    func testInvalidKnownGatewayWidgetIsReplacedWhenValidDataArrives() {
        let invalid: [String: Any] = ["id": WeatherFixtures.card["id"]!, "weather_data": [:]]
        let failed = ResponseCardContent(chunks: [["render_weather": invalid]])
        XCTAssertEqual(unavailable(failed.blocks).first?.reason, .invalidData)
        let complete = ResponseCardContent(chunks: [["render_weather": invalid], ["render_weather": WeatherFixtures.card]])
        XCTAssertTrue(unavailable(complete.blocks).isEmpty)
        XCTAssertEqual(complete.blocks.count, 1)
        guard case .weather = complete.blocks[0] else { return XCTFail("Valid card did not replace placeholder") }
    }

    func testRenderChunksInThinkingAndOrdinaryToolEventsAreNotDisplayed() {
        let content = ResponseCardContent(chunks: [
            ["channel": "ASSISTANT_THINKING", "render_chart": ["id": "hidden"]],
            ["tool_usage": ["name": "web_search", "arguments": "private"]]
        ])
        XCTAssertTrue(content.blocks.isEmpty)
    }

    func testRESTOutputChunksSurviveResponseDecodingAndProducePlaceholder() throws {
        let json = #"{"responseId":"answer","sender":"assistant","message":"BeforeAfter","outputChunks":[{"text":{"text":"Before","channel":"ASSISTANT"}},{"render_new_widget":{"id":"new","data":[1,2]}},{"text":{"text":"After","channel":"ASSISTANT"}}]}"#
        let response = try JSONDecoder().decode(Response.self, from: Data(json.utf8))
        let roundTrip = try JSONDecoder().decode(Response.self, from: JSONEncoder().encode(response))
        let blocks = GrokMessageContent(roundTrip.richContent).contentBlocks(in: roundTrip.message)
        XCTAssertEqual(unavailable(blocks).map(\.kind), ["render_new_widget"])
        XCTAssertEqual(blocks.last, .text("After"))
        XCTAssertEqual(text(blocks), roundTrip.message)
    }

    func testIncompleteFinalMarkupGetsPlaceholderButStreamingWaitsForCompletion() {
        let original = "Before <grok:render card_id=\"partial"
        let streaming = UnavailableResponseCard.inserting(in: [.text(original)], sources: [], includeIncomplete: false)
        XCTAssertTrue(unavailable(streaming).isEmpty)
        let final = GrokMessageContent([:]).contentBlocks(in: original)
        XCTAssertEqual(unavailable(final).count, 1)
        XCTAssertEqual(text(final), original)
    }

    func testNonLatinTextAndCRLFKeepAllCharactersAroundFallback() {
        let original = "До 👩‍💻\r\n" + marker("chart") + "\r\nПосле"
        let blocks = GrokMessageContent([:]).contentBlocks(in: original)
        XCTAssertEqual(unavailable(blocks).count, 1)
        XCTAssertEqual(text(blocks), original)
    }

    func testImageDeliveredInBothChunksAndInlineMetadataIsRenderedOnce() {
        let card = SearchedImageFixtures.card("one")
        let original = SearchedImageFixtures.marker("one")
        let content = GrokMessageContent([
            "cardAttachmentsJson": AnyCodable([card]),
            "outputChunks": AnyCodable([["text": ["text": original]], ["render_searched_image": card]])
        ])
        let blocks = content.contentBlocks(in: original)
        XCTAssertEqual(SearchedImageFixtures.galleries(blocks).count, 1)
        XCTAssertTrue(unavailable(blocks).isEmpty)
    }
}
