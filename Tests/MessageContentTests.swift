import XCTest
import GrokClient
@testable import GrokCore

final class MessageContentTests: XCTestCase {
    func testHistoricalReasoningStepsAndTimingSurviveResponseDecoding() throws {
        let json = #"{"responseId":"a","sender":"assistant","message":"Final answer","thinkingTrace":"","steps":[{"text":["Plan","Check sources","Final answer"],"tags":["header","thinking","final"]}],"thinkingStartTime":"2026-11-06T00:00:00.000Z","thinkingEndTime":"2026-11-06T00:00:28.400Z"}"#
        let response = try JSONDecoder().decode(Response.self, from: Data(json.utf8))
        let content = GrokMessageContent(response.richContent)
        XCTAssertTrue(content.reasoning?.contains("Check sources") == true)
        XCTAssertFalse(content.reasoning?.contains("Final answer") == true)
        XCTAssertEqual(content.reasoningDuration ?? 0, 28.4, accuracy: 0.001)
        let restored = try JSONDecoder().decode(Response.self, from: JSONEncoder().encode(response))
        XCTAssertEqual(GrokMessageContent(restored.richContent).reasoning, content.reasoning)
    }

    func testCardsUseTheirOwnURLInsteadOfRepeatedCitationIndex() throws {
        let json = #"{"responseId":"a","sender":"assistant","message":"Text","webSearchResults":[{"url":"https://first.example/page","title":"First"}],"cardAttachmentsJson":["{\"id\":\"card\",\"url\":\"https://second.example/page\"}"]}"#
        let response = try JSONDecoder().decode(Response.self, from: Data(json.utf8))
        let content = GrokMessageContent(response.richContent)
        let card = #"<grok:render card_id="card" card_type="citation_card"><argument name="citation_id">0</argument></grok:render>"#
        let rendered = GrokMessageContent.markdown("Answer" + card, sources: content.sources)
        XCTAssertTrue(rendered.contains("https://second.example/page"))
        XCTAssertFalse(rendered.contains("first.example"))
        XCTAssertFalse(rendered.contains("grok:render"))
    }

    func testLiteralCardsInCodeArePreservedAndStreamingCardsAreHidden() {
        let card = #"<grok:render card_id="missing">value</grok:render>"#
        for fence in ["```", "~~~"] {
            let text = "\(fence)xml\n\(card)\n\(fence)\n\nAnswer \(card)"
            let result = GrokMessageContent.markdown(text, sources: [])
            XCTAssertEqual(result.components(separatedBy: card).count, 2)
        }
        XCTAssertEqual(GrokMessageContent.markdown("`\(card)`", sources: []), "`\(card)`")
        XCTAssertEqual(GrokMessageContent.markdown("Answer <grok:render card_id=\"unfinished", sources: []), "Answer ")
    }

    func testRichResponsesRetainMediaFilesReasoningAndErrors() throws {
        let json = #"{"responseId":"a","sender":"assistant","generatedImageUrls":["https://assets.grok.com/image.png"],"fileAttachments":["file"],"fileAttachmentsMetadata":[{"fileId":"file","fileName":"notes.pdf","url":"https://assets.grok.com/notes.pdf"}],"thinkingTrace":"Thought","streamErrors":[{"message":"Model unavailable"}]}"#
        let response = try JSONDecoder().decode(Response.self, from: Data(json.utf8))
        let content = GrokMessageContent(response.richContent)
        XCTAssertEqual(content.attachments.count, 2)
        XCTAssertEqual(content.attachments.first?.kind, .image)
        XCTAssertEqual(content.attachments.first?.isGenerated, true)
        XCTAssertEqual(content.attachments.last?.isGenerated, false)
        XCTAssertEqual(content.attachments.last?.name, "notes.pdf")
        XCTAssertEqual(content.reasoning, "Thought")
        XCTAssertEqual(content.failure, "Model unavailable")
        let roundTrip = try JSONDecoder().decode(Response.self, from: JSONEncoder().encode(response))
        XCTAssertEqual(GrokMessageContent(roundTrip.richContent).attachments, content.attachments)
    }

    func testMediaCredentialsStayOnTrustedHTTPSHostsAndAreRemovedOnRedirect() throws {
        let loader = MessageMediaLoader(credentials: try SessionCredentials(cookies: ["sso": "fixture"]))
        for address in ["https://assets.grok.com/a.png", "https://grok.com/a.png"] {
            XCTAssertEqual(try loader.request(for: URL(string: address)!).value(forHTTPHeaderField: "Cookie"), "sso=fixture")
        }
        for address in ["https://grok.com.evil.test/a.png", "https://example.com/a.png", "http://assets.grok.com/a.png"] {
            XCTAssertNil(try loader.request(for: URL(string: address)!).value(forHTTPHeaderField: "Cookie"))
        }
        var redirect = try loader.request(for: URL(string: "https://assets.grok.com/a.png")!)
        redirect.url = URL(string: "https://example.com/a.png")!
        XCTAssertNil(MessageMediaLoader.redirect(redirect, from: URL(string: "https://assets.grok.com/a.png")).value(forHTTPHeaderField: "Cookie"))
        XCTAssertThrowsError(try loader.request(for: URL(string: "file:///tmp/secret")!))
        XCTAssertNil(GrokMessageContent.url("javascript:alert(1)"))
    }

    func testGrokFileURIsRenderImagesWithoutDuplicateIDCards() throws {
        let json = #"{"responseId":"a","sender":"assistant","fileAttachments":["ghost-id"],"fileAttachmentsMetadata":[{"fileName":"photo.heic","fileMimeType":"image/heic","fileUri":"users/user/asset/content"}]}"#
        let response = try JSONDecoder().decode(Response.self, from: Data(json.utf8))
        let attachments = GrokMessageContent(response.richContent).attachments
        XCTAssertEqual(attachments.count, 1)
        XCTAssertEqual(attachments[0].kind, .image)
        XCTAssertFalse(attachments[0].isGenerated)
        XCTAssertEqual(attachments[0].name, "photo.heic")
        XCTAssertEqual(attachments[0].url?.absoluteString, "https://assets.grok.com/users/user/asset/content")
        let generated = GrokMessageContent.resolvedAttachment(id: "generated", metadata: [
            "key": AnyCodable("users/user/generated/image.jpg"), "mimeType": AnyCodable("image/jpeg")
        ])
        XCTAssertEqual(generated?.isGenerated, true)
    }

    #if os(macOS)
    func testMarkdownKeepsBlockStructureInlineStylesAndImages() throws {
        let document = MarkdownDocument("""
        ### Heading

        Paragraph **bold** and `code`.

        - One
          - Nested
        - Two

        | A | B |
        |---|---|
        | X | Y |

        > Quoted

        ![Picture](https://example.com/image.png)

        ```json
        {"ok": true}
        ```
        """)
        XCTAssertEqual(document.blocks[0].kind, .header(level: 3))
        XCTAssertEqual(String(document.blocks[0].text.characters), "Heading")
        XCTAssertTrue(document.blocks[1].text.runs.contains { $0.inlinePresentationIntent?.contains(.stronglyEmphasized) == true })
        let list = document.blocks[2]
        XCTAssertEqual(list.kind, .unorderedList)
        XCTAssertEqual(list.children.count, 2)
        XCTAssertEqual(list.children[0].children.last?.kind, .unorderedList)
        let table = document.blocks[3]
        XCTAssertEqual(table.children.count, 2)
        XCTAssertEqual(table.children.first?.kind, .tableHeaderRow)
        XCTAssertEqual(String(table.children[1].children[1].text.characters), "Y")
        XCTAssertEqual(document.blocks[4].kind, .blockQuote)
        XCTAssertNotNil(document.blocks[5].text.runs.first?.imageURL)
        XCTAssertEqual(document.blocks[6].kind, .codeBlock(languageHint: "json"))
        XCTAssertTrue(String(document.blocks[6].text.characters).contains("{\"ok\": true}"))
    }
    #endif
}
