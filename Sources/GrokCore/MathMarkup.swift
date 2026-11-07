import Foundation

public struct MathExpression: Codable, Hashable, Sendable {
    public let latex: String
    public let display: Bool
    public let original: String

    public init(latex: String, display: Bool, original: String? = nil) {
        self.latex = latex
        self.display = display
        self.original = original ?? latex
    }
}

public enum MathExpressionAttribute: AttributedStringKey {
    public typealias Value = MathExpression
    public static let name = "app.swiftygrok.math"
}

/// Protect LaTeX before Markdown consumes its backslashes and underscores.
/// Fenced and inline code, escaped dollars and ordinary currency stay literal.
public struct MathMarkup {
    public let markdown: String
    public let expressions: [String: MathExpression]

    public init(_ source: String) {
        var prefix = "GROKMATHPLACEHOLDER"
        while source.contains(prefix) { prefix += "X" }
        var output = "", expressions: [String: MathExpression] = [:]
        var index = source.startIndex
        var fence: (Character, Int)?
        var lineStart = true
        while index < source.endIndex {
            let character = source[index]
            if lineStart {
                let end = source[index...].firstIndex(of: "\n") ?? source.endIndex
                let line = source[index..<end]
                let trimmed = line.drop(while: { $0 == " " || $0 == "\t" })
                let indentation = line.count - trimmed.count
                if let marker = trimmed.first, marker == "`" || marker == "~", indentation <= 3 {
                    let count = trimmed.prefix(while: { $0 == marker }).count
                    if count >= 3 {
                        if let active = fence {
                            if active.0 == marker, count >= active.1 { fence = nil }
                        } else { fence = (marker, count) }
                        output += line
                        index = end
                        lineStart = false
                        continue
                    }
                }
                if fence != nil {
                    output += line; index = end; lineStart = false; continue
                }
            }
            if character == "`" {
                let count = source[index...].prefix(while: { $0 == "`" }).count
                let delimiter = String(repeating: "`", count: count)
                let start = source.index(index, offsetBy: count)
                if let end = source.range(of: delimiter, range: start..<source.endIndex)?.upperBound {
                    output += source[index..<end]; index = end; lineStart = false; continue
                }
            }
            if character == "\\", source[index...].hasPrefix("\\\\") || source[index...].hasPrefix("\\$") {
                let end = source.index(index, offsetBy: 2, limitedBy: source.endIndex) ?? source.endIndex
                output += source[index..<end]; index = end; lineStart = false; continue
            }
            let delimiters: [(String, String, Bool)] = [("\\[", "\\]", true), ("\\(", "\\)", false), ("$$", "$$", true), ("$", "$", false)]
            var consumed = false
            for (open, close, display) in delimiters where source[index...].hasPrefix(open) {
                let start = source.index(index, offsetBy: open.count)
                var search = start
                while let range = source.range(of: close, range: search..<source.endIndex) {
                    if range.lowerBound > start, source[source.index(before: range.lowerBound)] == "\\" {
                        search = range.upperBound; continue
                    }
                    let value = String(source[start..<range.lowerBound])
                    if !display && value.contains("\n") { break }
                    guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { break }
                    if open == "$", value.first?.isWhitespace == true || value.last?.isWhitespace == true { break }
                    if open == "$", range.upperBound < source.endIndex, source[range.upperBound].isNumber { break }
                    let token = "\(prefix)\(expressions.count)END"
                    expressions[token] = MathExpression(latex: value.trimmingCharacters(in: .whitespacesAndNewlines), display: display,
                                                        original: String(source[index..<range.upperBound]))
                    output += token; index = range.upperBound; consumed = true; lineStart = false
                    break
                }
                break
            }
            if consumed { continue }
            output.append(character)
            index = source.index(after: index)
            lineStart = character == "\n"
        }
        markdown = output
        self.expressions = expressions
    }

    public func restore(_ source: AttributedString, literal: Bool = false) -> AttributedString {
        var result = source
        for (token, expression) in expressions {
            while let range = result.range(of: token) {
                let attributes = result[range].runs.first?.attributes ?? AttributeContainer()
                var replacement = AttributedString(expression.original, attributes: attributes)
                if !literal {
                    replacement = AttributedString(expression.latex, attributes: attributes)
                    replacement[MathExpressionAttribute.self] = expression
                }
                result.replaceSubrange(range, with: replacement)
            }
        }
        return result
    }
}
