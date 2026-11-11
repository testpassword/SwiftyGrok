import XCTest
import GrokClient
@testable import GrokCore

final class ToolUsageContentTests: XCTestCase {
    private func card(_ name: String = "web_search", arguments: String = #"[{"query":"Example search","num_results":"15"}]"#) -> String {
        "<xai:tool_usage_card><xai:tool_usage_card_id>fixture-call</xai:tool_usage_card_id>" +
        "<xai:tool_name>\(name)</xai:tool_name><xai:tool_args><![CDATA[\(arguments)]]></xai:tool_args></xai:tool_usage_card>"
    }

    private func tools(_ text: String) -> [ToolUsageContent.ToolCall] {
        ToolUsageContent.parse(text).compactMap { if case .tool(let tool) = $0 { return tool }; return nil }
    }

    func testSearchCardsReplaceXMLInOrderWithoutLosingSurroundingText() {
        let raw = "First paragraph" + card() + "Second paragraph" + card(arguments: #"{"query":"Another search"}"#) + "Answer"
        let blocks = ToolUsageContent.parse(raw)
        XCTAssertEqual(blocks.count, 5)
        XCTAssertEqual(blocks[0], .text("First paragraph"))
        XCTAssertEqual(blocks[2], .text("Second paragraph"))
        XCTAssertEqual(blocks[4], .text("Answer"))
        XCTAssertEqual(tools(raw).map(\.kind), [.webSearch, .webSearch])
        XCTAssertEqual(tools(raw).map(\.detail), ["Example search", "Another search"])
        XCTAssertEqual(ToolUsageContent.plainText(raw), "First paragraph\n\nSecond paragraph\n\nAnswer")
    }

    func testEveryStreamingPrefixHidesServiceDataUntilTheCardIsComplete() {
        let xml = card(arguments: #"[{"query":"A search with 🗺️ and русский текст"}]"#)
        for length in 0..<xml.count {
            let partial = "Thinking " + xml.prefix(length)
            let visible = ToolUsageContent.plainText(partial)
            XCTAssertTrue(tools(partial).isEmpty, "Unexpected card at prefix \(length)")
            XCTAssertFalse(visible.contains("xai:"), "Leaked tag at prefix \(length)")
            XCTAssertFalse(visible.contains("fixture-call"))
            XCTAssertFalse(visible.contains("CDATA"))
        }
        XCTAssertEqual(tools("Thinking " + xml).first?.detail, "A search with 🗺️ and русский текст")
    }

    func testCDATAContentsCannotCloseOrCreateAnotherServiceCard() {
        let detail = #"Find </xai:tool_usage_card> and <xai:tool_usage_card> in XML"#
        let xml = card(arguments: #"{"query":"Find </xai:tool_usage_card> and <xai:tool_usage_card> in XML"}"#)
        XCTAssertEqual(tools(xml).count, 1)
        XCTAssertEqual(tools(xml).first?.detail, detail)
        XCTAssertEqual(ToolUsageContent.plainText("Before" + xml + "After"), "Before\n\nAfter")
    }

    func testLiteralExamplesInMarkdownCodeStayIntact() {
        let xml = card()
        for (start, end) in [("```xml", "```"), ("~~~xml", "~~~~"), ("````xml", "`````"), ("   ```xml", "   ```")] {
            let literal = start + "\n" + xml + "\n" + end
            XCTAssertEqual(ToolUsageContent.plainText(literal), literal)
            XCTAssertTrue(tools(literal).isEmpty)
            XCTAssertEqual(tools(literal + "\n" + xml).count, 1)
        }
        for literal in ["`\(xml)`", "``sample ` \(xml)``", "```xml\n\(xml)", "    \(xml)", "\t\(xml)"] {
            XCTAssertEqual(ToolUsageContent.plainText(literal), literal)
            XCTAssertTrue(tools(literal).isEmpty)
        }
    }

    func testNormalXMLMathAndMarkdownAreNotTreatedAsToolCalls() {
        for text in ["a < b and c > d", "f(x) <x", "An angle <", "<example>XML</example>", "<xai:example>Literal</xai:example>", "# Header\n\n- **One**\n- `Two`"] {
            XCTAssertEqual(ToolUsageContent.parse(text), [.text(text)])
            XCTAssertEqual(ToolUsageContent.plainText(text), text)
        }
        XCTAssertEqual(ToolUsageContent.parse(""), [])
    }

    func testMalformedAndInterruptedCardsRecoverBeforeFollowingTextOrCards() {
        let malformed = "<xai:tool_usage_card><xai:tool_name>web_search</xai:wrong></xai:tool_usage_card>"
        XCTAssertEqual(ToolUsageContent.plainText("Before" + malformed + "After"), "Before\n\nAfter")
        XCTAssertTrue(tools(malformed).isEmpty)
        let interrupted = "<xai:tool_usage_card><xai:tool_name>web_search</xai:tool_name>"
        XCTAssertEqual(tools(interrupted + card()).first?.detail, "Example search")
        XCTAssertEqual(ToolUsageContent.plainText("Before<xai:tool_usage_card/>After"), "Before\n\nAfter")
    }

    func testWebpageAndUnknownToolsExposeOnlyReadableDetails() {
        let page = tools(card("browse_page", arguments: #"{"url":"https://example.com/article","instructions":"Internal instructions"}"#)).first
        XCTAssertEqual(page?.kind, .webPage)
        XCTAssertEqual(page?.detail, "https://example.com/article")
        let unknown = tools(card("fixture_tool", arguments: #"{"query":"Readable query","internal_id":"never-display-this"}"#)).first
        XCTAssertEqual(unknown?.kind, .other)
        XCTAssertEqual(unknown?.detail, "Readable query")
        XCTAssertNil(tools(card(arguments: "not JSON")).first?.detail)
        XCTAssertEqual(tools(card(arguments: #"[{"query":"One"},{"query":"Two"}]"#)).first?.detail, "One\nTwo")
    }

    func testCopyMarkdownRemovesToolMetadataAndStillResolvesCitations() {
        let source = MessageSource(id: "source", title: "Example", url: URL(string: "https://example.com/article")!)
        let citation = #"<grok:render card_id="source" card_type="citation_card"></grok:render>"#
        let raw = "Before\n\n" + card() + "\n\nAnswer " + citation
        let message = ChatMessage(id: "fixture", role: .assistant, text: raw, sources: [source], reasoning: card())
        XCTAssertEqual(message.text, raw)
        XCTAssertEqual(message.reasoning, card())
        XCTAssertFalse(message.displayMarkdown.contains("xai:"))
        XCTAssertFalse(message.displayMarkdown.contains("num_results"))
        XCTAssertFalse(message.displayMarkdown.contains("fixture-call"))
        XCTAssertTrue(message.displayMarkdown.contains("Before\n\nAnswer"))
        XCTAssertTrue(message.displayMarkdown.contains("https://example.com/article"))
        XCTAssertEqual(GrokMessageContent.markdown("```xml\n" + card() + "\n```", sources: []), "```xml\n" + card() + "\n```")
    }

    func testQuotedTagAttributesAndSplitCDATAAreSupported() {
        let xml = #"<xai:tool_usage_card label="a>b"><xai:tool_name>web_search</xai:tool_name><xai:tool_args><![CDATA[{"query":]]><![CDATA["Example"}]]></xai:tool_args></xai:tool_usage_card>"#
        XCTAssertEqual(tools(xml).first?.detail, "Example")
    }

    func testReasoningHeadersSeparateParagraphsWithoutSplittingTextTokens() {
        let metadata: [String: AnyCodable] = ["steps": AnyCodable([
            ["text": ["A plan", "Checking ", "sources", "A summary", "Not reasoning"],
             "tags": ["header", "thinking", "thinking", "summary", "final"]]
        ])]
        XCTAssertEqual(GrokMessageContent(metadata).reasoning, "A plan\n\nChecking sources\n\nA summary")
    }
}
