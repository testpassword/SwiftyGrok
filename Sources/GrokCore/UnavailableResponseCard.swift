import Foundation

public struct UnavailableResponseCard: Identifiable, Equatable, Sendable {
    public enum Reason: Equatable, Sendable { case unsupported, invalidData, missingData }
    public let id: String
    public let kind: String
    public let rawData: String
    public let reason: Reason

    var cardID: String {
        let prefix: String
        switch kind {
        case "render_places", "renderPlaces": prefix = "places"
        case "render_weather", "renderWeather": prefix = "weather"
        case "render_sports", "renderSports": prefix = "sports"
        case "render_searched_image", "renderSearchedImage": prefix = "images"
        default: prefix = kind
        }
        return prefix + "-" + id
    }

    static func raw(_ value: Any) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys, .fragmentsAllowed]) else { return String(describing: value) }
        return String(decoding: data, as: UTF8.self)
    }

    /// A marker is visible content even when its payload is absent. Only render
    /// directives participate; tool calls and reasoning metadata never do.
    public static func inserting(in blocks: [ResponseContentBlock], sources: [MessageSource],
                                 cards: [String: [String: Any]] = [:], includeIncomplete: Bool = true) -> [ResponseContentBlock] {
        var displayed = Set(blocks.flatMap(\.renderedCardIDs))
        var result: [ResponseContentBlock] = []
        for block in blocks {
            guard case .text(let text) = block else { result.append(block); continue }
            var cursor = text.startIndex
            for reference in RenderCardReference.references(in: text, includeIncomplete: includeIncomplete) {
                if let id = reference.id, displayed.contains(id) { continue }
                if reference.isCitation || reference.kind == "grok:render" {
                    let source = reference.id.flatMap { id in sources.first { $0.id == id } }
                        ?? (reference.id == nil ? sources.first { $0.citationID != nil && $0.citationID == reference.citationID } : nil)
                    if source != nil { continue }
                }
                let id = reference.id ?? "inline-\(result.count)-\(text.distance(from: text.startIndex, to: reference.range.lowerBound))"
                let payload = reference.id.flatMap { cards[$0] }
                let kind = payload.flatMap { CardJSON.string($0, "type", "cardType") } ?? reference.kind
                let invalid = ["render_searched_image", "renderSearchedImage", "render_weather", "renderWeather", "render_places", "renderPlaces", "render_sports", "renderSports"].contains(kind)
                let raw = payload.map { Self.raw(["reference": reference.markup, "card": $0]) } ?? reference.markup
                result.append(.text(String(text[cursor..<reference.range.upperBound])))
                result.append(.unavailable(Self(id: id, kind: kind, rawData: raw,
                    reason: payload == nil ? .missingData : invalid ? .invalidData : .unsupported)))
                cursor = reference.range.upperBound
                displayed.insert(id)
            }
            if cursor < text.endIndex { result.append(.text(String(text[cursor...]))) }
        }
        return result
    }
}

extension ResponseContentBlock {
    var renderedCardIDs: [String] {
        switch self {
        case .text: return []
        case .gallery(let card): return [card.id]
        case .images(let card): return card.images.map(\.id)
        case .weather(let card): return [card.id]
        case .standings(let card): return [card.id]
        case .unavailable(let card): return [card.id]
        }
    }
}

struct RenderCardReference {
    let range: Range<String.Index>
    let markup: String
    let id: String?
    let kind: String
    let citationID: String?
    let isCitation: Bool

    static func references(in text: String, includeIncomplete: Bool) -> [Self] {
        let pattern = #"(?s)(`+).*?\1|<grok:render\b[^>]*>.*?</grok:render\s*>"# + (includeIncomplete ? #"|<grok:render\b.*\z"# : "")
        let regex = try! NSRegularExpression(pattern: pattern)
        func capture(_ pattern: String, in value: String) -> String? {
            guard let regex = try? NSRegularExpression(pattern: pattern),
                  let match = regex.firstMatch(in: value, range: NSRange(value.startIndex..., in: value)),
                  let range = Range(match.range(at: 1), in: value) else { return nil }
            return String(value[range])
        }
        var result: [Self] = []
        func scan(_ range: Range<String.Index>) {
            for match in regex.matches(in: text, range: NSRange(range, in: text)) {
                guard let range = Range(match.range, in: text), text[range].hasPrefix("<grok:render") else { continue }
                let markup = String(text[range])
                let header = markup.firstIndex(of: ">").map { String(markup.prefix(through: $0)) } ?? markup
                let type = capture(#"\btype\s*=\s*["']([^"']+)["']"#, in: header)
                let cardType = capture(#"\bcard_type\s*=\s*["']([^"']+)["']"#, in: header)
                result.append(Self(range: range, markup: markup,
                    id: capture(#"\bcard_id\s*=\s*["']([^"']+)["']"#, in: header),
                    kind: type ?? cardType ?? "grok:render",
                    citationID: capture(#"name\s*=\s*["']citation_id["']\s*>([^<]+)<"#, in: markup),
                    isCitation: cardType == "citation_card" || type == "render_inline_citation" || type == "renderInlineCitation"))
            }
        }
        var fence: (Character, Int)?
        var cursor = text.startIndex
        var proseStart = cursor
        let lines = text.components(separatedBy: "\n")
        for (index, line) in lines.enumerated() {
            let end = text.index(cursor, offsetBy: (line + (index < lines.count - 1 ? "\n" : "")).count)
            let trimmed = line.drop(while: { $0 == " " })
            let marker = trimmed.first
            let count = marker.map { character in trimmed.prefix(while: { $0 == character }).count } ?? 0
            if let current = fence {
                if marker == current.0 && count >= current.1 && trimmed.dropFirst(count).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    fence = nil; proseStart = end
                }
            } else if (marker == "`" || marker == "~") && count >= 3 {
                scan(proseStart..<cursor)
                fence = (marker!, count)
            }
            cursor = end
        }
        if fence == nil { scan(proseStart..<text.endIndex) }
        return result
    }
}
