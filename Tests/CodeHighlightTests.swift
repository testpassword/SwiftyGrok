import XCTest
@testable import GrokCore

final class CodeHighlightTests: XCTestCase {
    func testPythonStringsCommentsAndUnicodePreserveSource() {
        let source = "# return 'comment'\nasync def ответ():\n    return \"Привет \\\"if\\\"\" + str(42)\n"
        let segments = CodeHighlight.segments(source, language: "Python")
        XCTAssertEqual(segments.map(\.text).joined(), source)
        XCTAssertEqual(segments.first?.kind, .comment)
        XCTAssertTrue(segments.contains { $0.text == "async" && $0.kind == .keyword })
        XCTAssertTrue(segments.contains { $0.text == "ответ" && $0.kind == .function })
        XCTAssertTrue(segments.contains { $0.text == "42" && $0.kind == .number })
        XCTAssertTrue(segments.contains { $0.text.hasPrefix("\"Привет") && $0.kind == .string })
    }

    func testMultilineStringsAndCommentsProtectKeywords() {
        for (language, source) in [("python", "\"\"\"if\nreturn # comment\"\"\""), ("swift", "/* if\n return */"), ("js", "`hello ${returnValue}`")] {
            let segments = CodeHighlight.segments(source, language: language)
            XCTAssertEqual(segments.map(\.text).joined(), source)
            XCTAssertEqual(segments.count, 1)
            XCTAssertEqual(segments[0].kind, language == "swift" ? .comment : .string)
        }
    }

    func testJSONSQLUnknownAndPartialCode() {
        let json = CodeHighlight.segments(#"{"if":true,"count":1.5e-2}"#, language: "json")
        XCTAssertTrue(json.contains { $0.text == "true" && $0.kind == .keyword })
        XCTAssertTrue(json.contains { $0.text == "1.5e-2" && $0.kind == .number })
        XCTAssertTrue(CodeHighlight.segments("SELECT * -- FROM table", language: "sql").contains { $0.text == "SELECT" && $0.kind == .keyword })
        let source = "return 😀 \"unfinished"
        XCTAssertEqual(CodeHighlight.segments(source, language: "python").map(\.text).joined(), source)
        XCTAssertEqual(CodeHighlight.segments(source, language: "unknown").map(\.kind), [.plain])
    }
}
