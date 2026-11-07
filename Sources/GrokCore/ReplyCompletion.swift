import Foundation

/// A single completed answer, without the question or reasoning trace.
public struct ReplyCompletion: Equatable, Sendable {
    public let requestID: String
    public let conversationID: String
    public let responseID: String
    public let isTemporary: Bool
    public let preview: String

    init(requestID: String, conversationID: String, responseID: String, isTemporary: Bool, text: String) {
        self.requestID = requestID
        self.conversationID = conversationID
        self.responseID = responseID
        self.isTemporary = isTemporary
        self.preview = Self.makePreview(text)
    }

    private static func makePreview(_ text: String) -> String {
        // Bound parsing work and retain whole Unicode characters in the preview.
        let markdown = GrokMessageContent.markdown(String(text.prefix(8192)), sources: [])
        var plain = markdown
            .replacingOccurrences(of: #"(?m)^\s{0,3}(?:`{3,}|~{3,})[^\r\n]*$"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"(?m)^\s{0,3}(?:#{1,6}\s+|>\s*|[-+*]\s+|\d+[.)]\s+)"#, with: "", options: .regularExpression)
        #if os(macOS)
        if let parsed = try? AttributedString(markdown: markdown, options: .init(interpretedSyntax: .full)) {
            var blocks: [String] = []
            for (_, range) in parsed.runs[\.presentationIntent] {
                blocks.append(String(parsed[range].characters))
            }
            plain = blocks.joined(separator: " ")
        }
        #else
        plain = plain
            .replacingOccurrences(of: #"!?\[([^\]]*)\]\([^)]+\)"#, with: "$1", options: .regularExpression)
            .replacingOccurrences(of: #"(\*\*|__|~~|`)(.*?)\1"#, with: "$2", options: .regularExpression)
        #endif
        plain = plain.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return plain.count > 200 ? String(plain.prefix(199)) + "…" : plain
    }
}
