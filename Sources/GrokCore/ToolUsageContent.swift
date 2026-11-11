import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif

/// Presentation-only parsing. The original streamed response stays intact.
public enum ToolUsageContent {
    public enum Block: Equatable, Sendable {
        case text(String)
        case tool(ToolCall)
    }

    public struct ToolCall: Equatable, Sendable {
        public enum Kind: Equatable, Sendable { case webSearch, webPage, other }
        public let kind: Kind
        public let detail: String?
        public var title: String {
            L10n.text(kind == .webSearch ? "Web search" : kind == .webPage ? "Reading a webpage" : "Tool activity")
        }
        public var systemImage: String { kind == .webSearch ? "magnifyingglass" : kind == .webPage ? "globe" : "gearshape" }
    }

    private static let opening = "<xai:tool_usage_card"
    private static let closing = "</xai:tool_usage_card"

    public static func parse(_ text: String) -> [Block] {
        guard text.contains("<x") else { return text.isEmpty ? [] : [.text(text)] }
        var blocks: [Block] = []
        var prose = ""
        var cursor = text.startIndex
        func flush() {
            if !prose.isEmpty { blocks.append(.text(prose)); prose = "" }
        }
        while cursor < text.endIndex {
            // Markdown examples, including an unfinished fenced block, are literal.
            if (cursor == text.startIndex || text[text.index(before: cursor)] == "\n"),
               let end = fencedCodeEnd(in: text, from: cursor) {
                prose += text[cursor..<end]; cursor = end; continue
            }
            if text[cursor] == "`" {
                let end = inlineCodeEnd(in: text, from: cursor)
                prose += text[cursor..<end]; cursor = end; continue
            }
            if matches(opening, in: text, at: cursor) {
                flush()
                let card = cardEnd(in: text, from: cursor)
                if card.complete, let tool = decode(String(text[cursor..<card.end])) { blocks.append(.tool(tool)) }
                cursor = card.end
                continue
            }
            let tail = text[cursor...]
            if tail.hasPrefix("<xai:"), tail.count < opening.count, opening.hasPrefix(String(tail)) {
                // The next token can finish a service tag; don't flash it as text.
                break
            }
            prose.append(text[cursor]); cursor = text.index(after: cursor)
        }
        flush()
        return blocks
    }

    /// Copy and notification previews contain the answer, not tool metadata.
    public static func plainText(_ text: String) -> String {
        let fragments = parse(text).compactMap { if case .text(let value) = $0 { return value }; return nil }
        guard var result = fragments.first else { return "" }
        for fragment in fragments.dropFirst() {
            while result.last?.isNewline == true { result.removeLast() }
            let next = fragment.drop(while: \.isNewline)
            if !result.isEmpty && !next.isEmpty { result += "\n\n" }
            result += next
        }
        return result
    }

    private static func matches(_ tag: String, in text: String, at index: String.Index) -> Bool {
        guard text[index...].hasPrefix(tag) else { return false }
        let end = text.index(index, offsetBy: tag.count)
        return end == text.endIndex || text[end].isWhitespace || text[end] == ">" || text[end] == "/"
    }

    private static func tagEnd(in text: String, from start: String.Index) -> String.Index? {
        var cursor = start
        var quote: Character?
        while cursor < text.endIndex {
            let character = text[cursor]
            if let current = quote {
                if character == current { quote = nil }
            } else if character == "\"" || character == "'" { quote = character }
            else if character == ">" { return text.index(after: cursor) }
            cursor = text.index(after: cursor)
        }
        return nil
    }

    private static func cardEnd(in text: String, from start: String.Index) -> (end: String.Index, complete: Bool) {
        guard let openingEnd = tagEnd(in: text, from: start) else { return (text.endIndex, false) }
        if text[start..<openingEnd].hasSuffix("/>") { return (openingEnd, true) }
        var cursor = openingEnd
        while let next = text.range(of: "<", range: cursor..<text.endIndex)?.lowerBound {
            if text[next...].hasPrefix("<![CDATA[") {
                guard let end = text.range(of: "]]>", range: next..<text.endIndex)?.upperBound else { return (text.endIndex, false) }
                cursor = end
            } else if text[next...].hasPrefix("<!--") {
                guard let end = text.range(of: "-->", range: next..<text.endIndex)?.upperBound else { return (text.endIndex, false) }
                cursor = end
            } else if matches(closing, in: text, at: next) {
                guard let end = tagEnd(in: text, from: next) else { return (text.endIndex, false) }
                return (end, true)
            } else if matches(opening, in: text, at: next) {
                // Recover from a malformed previous card without swallowing the next one.
                return (next, false)
            } else {
                guard let end = tagEnd(in: text, from: next) else { return (text.endIndex, false) }
                cursor = end
            }
        }
        return (text.endIndex, false)
    }

    private static func decode(_ xml: String) -> ToolCall? {
        guard xml.utf8.count <= 262_144 else { return nil }
        let delegate = ToolCardXML()
        let wrapped = "<root xmlns:xai=\"urn:swiftygrok:tool-card\">" + xml + "</root>"
        let parser = XMLParser(data: Data(wrapped.utf8))
        parser.shouldResolveExternalEntities = false
        parser.delegate = delegate
        guard parser.parse() else { return nil }
        let name = delegate.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return nil }
        let kind: ToolCall.Kind = name == "web_search" ? .webSearch : name == "browse_page" ? .webPage : .other
        let arguments = delegate.arguments.data(using: .utf8).flatMap { try? JSONSerialization.jsonObject(with: $0) }
        let records = (arguments as? [[String: Any]]) ?? (arguments as? [String: Any]).map { [$0] } ?? []
        let keys = kind == .webPage ? ["url", "query"] : ["query", "url"]
        let details = records.compactMap { record in
            keys.compactMap { record[$0] as? String }.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.first { !$0.isEmpty }
        }
        return ToolCall(kind: kind, detail: details.isEmpty ? nil : details.joined(separator: "\n"))
    }

    private static func fencedCodeEnd(in text: String, from start: String.Index) -> String.Index? {
        let lineEnd = text.range(of: "\n", range: start..<text.endIndex)?.upperBound ?? text.endIndex
        let line = text[start..<lineEnd]
        let spaces = line.prefix { $0 == " " }.count
        if spaces >= 4 || line.first == "\t" { return lineEnd }
        let trimmed = line.dropFirst(spaces)
        guard let marker = trimmed.first, marker == "`" || marker == "~" else { return nil }
        let count = trimmed.prefix { $0 == marker }.count
        guard count >= 3 else { return nil }
        var cursor = lineEnd
        while cursor < text.endIndex {
            let end = text.range(of: "\n", range: cursor..<text.endIndex)?.upperBound ?? text.endIndex
            let candidate = text[cursor..<end]
            let indent = candidate.prefix { $0 == " " }.count
            let body = candidate.dropFirst(indent)
            let length = body.prefix { $0 == marker }.count
            if indent <= 3, length >= count, body.dropFirst(length).allSatisfy(\.isWhitespace) { return end }
            cursor = end
        }
        return text.endIndex
    }

    private static func inlineCodeEnd(in text: String, from start: String.Index) -> String.Index {
        let count = text[start...].prefix { $0 == "`" }.count
        var cursor = text.index(start, offsetBy: count)
        while let next = text.range(of: "`", range: cursor..<text.endIndex)?.lowerBound {
            let length = text[next...].prefix { $0 == "`" }.count
            cursor = text.index(next, offsetBy: length)
            if length == count { return cursor }
        }
        return text.endIndex
    }
}

private final class ToolCardXML: NSObject, XMLParserDelegate {
    var name = ""
    var arguments = ""
    private var elements: [String] = []

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String: String]) {
        elements.append(elementName)
    }
    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        elements.removeLast()
    }
    func parser(_ parser: XMLParser, foundCharacters string: String) { append(string) }
    func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) { append(String(decoding: CDATABlock, as: UTF8.self)) }
    private func append(_ text: String) {
        if elements.last == "xai:tool_name" { name += text }
        if elements.last == "xai:tool_args" { arguments += text }
    }
}
