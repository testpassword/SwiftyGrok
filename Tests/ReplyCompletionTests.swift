import XCTest
@testable import GrokCore

final class ReplyCompletionTests: XCTestCase {
    func testPreviewRemovesMarkdownAndGrokCards() {
        let text = """
        # **Готово**

        Смотри [пример](https://example.com).
        <grok:render card_id="source" card_type="citation_card"><argument name="citation_id">0</argument></grok:render>

        ```swift
        let count = 2
        ```
        """
        let completion = ReplyCompletion(requestID: "request", conversationID: "chat", responseID: "answer", isTemporary: false, text: text)
        XCTAssertEqual(completion.preview, "Готово Смотри пример. let count = 2")
    }

    func testPreviewLimitsWholeUnicodeCharacters() {
        let emoji = "👩🏽‍💻"
        let completion = ReplyCompletion(requestID: "request", conversationID: "chat", responseID: "answer", isTemporary: false,
                                         text: String(repeating: emoji, count: 210))
        XCTAssertEqual(completion.preview, String(repeating: emoji, count: 199) + "…")
        XCTAssertEqual(completion.preview.count, 200)
    }
}
