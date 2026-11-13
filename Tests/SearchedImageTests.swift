import XCTest
import GrokClient
@testable import GrokCore

enum SearchedImageFixtures {
    static func card(_ id: String, original: String = "https://images.example/photo.jpg") -> [String: Any] {
        ["id": id, "type": "render_searched_image", "cardType": "image_card", "image": [
            "title": "Example photo", "source": "Example", "original": original,
            "thumbnail": "https://thumbnails.example/photo.jpg", "link": "https://example.com/source"]]
    }
    static func marker(_ id: String) -> String {
        "<grok:render card_id=\"\(id)\" card_type=\"image_card\" type=\"render_searched_image\"><argument name=\"image_id\">\(id)</argument></grok:render>"
    }
    static var text: String { "Before\n\n" + marker("one") + "\n\n" + marker("two") + "\n\nAfter" }
    static var metadata: [String: AnyCodable] {
        ["cardAttachmentsJson": AnyCodable([card("one"), card("two")])]
    }
    static func galleries(_ blocks: [ResponseContentBlock]) -> [SearchedImageGallery] {
        blocks.compactMap { if case .images(let gallery) = $0 { return gallery }; return nil }
    }
    static func text(_ blocks: [ResponseContentBlock]) -> String {
        blocks.compactMap { if case .text(let text) = $0 { return text }; return nil }.joined()
    }
}

final class SearchedImageTests: XCTestCase {
    func testRESTCardStringsGroupAdjacentPhotosWithoutLosingTextOrSources() throws {
        let cardStrings = try [SearchedImageFixtures.card("one"), SearchedImageFixtures.card("two")].map {
            String(decoding: try JSONSerialization.data(withJSONObject: $0), as: UTF8.self)
        }
        let json: [String: Any] = ["responseId": "answer", "sender": "assistant", "message": SearchedImageFixtures.text,
            "cardAttachmentsJson": cardStrings + [#"{"id":"citation","url":"https://example.com/citation"}"#]]
        let response = try JSONDecoder().decode(Response.self, from: JSONSerialization.data(withJSONObject: json))
        let content = GrokMessageContent(response.richContent)
        let blocks = content.contentBlocks(in: response.message)
        let gallery = try XCTUnwrap(SearchedImageFixtures.galleries(blocks).first)
        XCTAssertEqual(blocks.count, 3)
        XCTAssertEqual(gallery.images.map(\.id), ["one", "two"])
        XCTAssertEqual(gallery.images.first?.source, "Example")
        XCTAssertEqual(gallery.images.first?.thumbnailURL?.host, "thumbnails.example")
        XCTAssertEqual(SearchedImageFixtures.text(blocks), response.message)
        XCTAssertEqual(blocks.last, .text("\n\nAfter"))
        XCTAssertEqual(content.sources.map(\.id), ["citation"])
        XCTAssertTrue(content.attachments.isEmpty)
    }

    func testTextBetweenImagesProducesSeparateGalleriesInTheRightOrder() {
        let text = SearchedImageFixtures.marker("two") + "\nA paragraph\n" + SearchedImageFixtures.marker("one")
        let blocks = GrokMessageContent(SearchedImageFixtures.metadata).contentBlocks(in: text)
        XCTAssertEqual(SearchedImageFixtures.galleries(blocks).map { $0.images.map(\.id) }, [["two"], ["one"]])
        XCTAssertEqual(SearchedImageFixtures.text(blocks), text)
    }

    func testLiteralExamplesInCodeAndUnreferencedCardsDoNotCreateGalleries() {
        let content = GrokMessageContent(SearchedImageFixtures.metadata)
        let marker = SearchedImageFixtures.marker("one")
        for text in ["```xml\n\(marker)\n```", "~~~xml\n\(marker)\n~~~", "`\(marker)`", "Answer without image references"] {
            XCTAssertTrue(content.contentBlocks(in: text).isEmpty)
        }
        let text = "```xml\n\(marker)\n```\nOutside\n" + SearchedImageFixtures.marker("two")
        let blocks = content.contentBlocks(in: text)
        XCTAssertEqual(SearchedImageFixtures.galleries(blocks).first?.images.map(\.id), ["two"])
        XCTAssertEqual(SearchedImageFixtures.text(blocks), text)
    }

    func testInvalidOriginalFallsBackToThumbnailAndUnsafeSourcesAreRejected() throws {
        var card = SearchedImageFixtures.card("one", original: "file:///private/secret")
        var image = card["image"] as! [String: Any]
        image["link"] = "javascript:alert(1)"; card["image"] = image
        let content = GrokMessageContent(["cardAttachmentsJson": AnyCodable([card])])
        let gallery = try XCTUnwrap(SearchedImageFixtures.galleries(content.contentBlocks(in: SearchedImageFixtures.marker("one"))).first)
        XCTAssertEqual(gallery.images.first?.url.host, "thumbnails.example")
        XCTAssertNil(gallery.images.first?.sourceURL)
        image["thumbnail"] = "https://user:secret@example.com/image"; card["image"] = image
        let invalid = GrokMessageContent(["cardAttachmentsJson": AnyCodable([card, "not-json", ["id": "missing-image"]])])
        let blocks = invalid.contentBlocks(in: SearchedImageFixtures.marker("one"))
        XCTAssertTrue(SearchedImageFixtures.galleries(blocks).isEmpty)
        guard case .unavailable(let card) = blocks.last else { return XCTFail("Invalid image disappeared") }
        XCTAssertEqual(card.reason, .invalidData)
    }

    func testDuplicateMetadataUpdatesImageWithoutDuplicatingGalleryEntries() throws {
        let updated = SearchedImageFixtures.card("one", original: "https://images.example/updated.jpg")
        let content = GrokMessageContent(["cardAttachmentsJson": AnyCodable([SearchedImageFixtures.card("one"), updated])])
        let text = SearchedImageFixtures.marker("one") + "\n\n" + SearchedImageFixtures.marker("one")
        let gallery = try XCTUnwrap(SearchedImageFixtures.galleries(content.contentBlocks(in: text)).first)
        XCTAssertEqual(gallery.images.count, 1)
        XCTAssertEqual(gallery.images.first?.url.lastPathComponent, "updated.jpg")
    }

    func testImageGalleriesCanCoexistWithGatewayCardsWithoutMovingText() throws {
        let weather = try XCTUnwrap(WeatherCard(WeatherFixtures.card))
        let original: [ResponseContentBlock] = [.text("Before" + SearchedImageFixtures.marker("one")), .weather(weather),
            .text("After" + SearchedImageFixtures.marker("two"))]
        let text = SearchedImageFixtures.text(original)
        let blocks = GrokMessageContent(SearchedImageFixtures.metadata).contentBlocks(in: text, merging: original)
        XCTAssertEqual(blocks.count, 5)
        guard case .images = blocks[1], case .weather = blocks[2], case .images = blocks[4] else { return XCTFail("Cards changed position") }
        XCTAssertEqual(SearchedImageFixtures.text(blocks), text)
    }
}
