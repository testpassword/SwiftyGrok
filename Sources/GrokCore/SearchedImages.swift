import Foundation

public struct SearchedImage: Identifiable, Equatable, Sendable {
    public let id: String
    public let title: String
    public let url: URL
    public let thumbnailURL: URL?
    public let source: String?
    public let sourceURL: URL?

    init?(_ card: [String: Any]) {
        guard card["type"] as? String == "render_searched_image",
              let id = CardJSON.string(card, "id", "cardId") else { return nil }
        let image = CardJSON.object(card, "image")
        let thumbnail = CardJSON.url(CardJSON.string(image, "thumbnail"))
        guard let url = CardJSON.url(CardJSON.string(image, "original")) ?? thumbnail else { return nil }
        self.id = id
        self.url = url
        thumbnailURL = thumbnail
        title = CardJSON.string(image, "title") ?? L10n.text("Image")
        source = CardJSON.string(image, "source")
        sourceURL = GrokMessageContent.url(CardJSON.string(image, "link"))
    }
}

public struct SearchedImageGallery: Identifiable, Equatable, Sendable {
    public var id: String { images[0].id }
    public let images: [SearchedImage]
}

enum SearchedImageContent {
    static func images(_ cards: Any?) -> [String: SearchedImage] {
        var result: [String: SearchedImage] = [:]
        for value in cards as? [Any] ?? [] {
            let card: [String: Any]?
            if let string = value as? String, let data = string.data(using: .utf8) {
                card = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            } else { card = value as? [String: Any] }
            if let card, let image = SearchedImage(card) { result[image.id] = image }
        }
        return result
    }

    /// Keep the original text, including citation and image markers, intact.
    /// Markdown hides the image markers; adjacent markers become one gallery.
    static func inserting(in blocks: [ResponseContentBlock], images: [String: SearchedImage]) -> [ResponseContentBlock] {
        guard !images.isEmpty else { return blocks }
        var result: [ResponseContentBlock] = []
        func appendText(_ text: String) {
            guard !text.isEmpty else { return }
            if case .text(let previous) = result.last { result[result.count - 1] = .text(previous + text) }
            else { result.append(.text(text)) }
        }
        func appendProse(_ text: String) {
            let pattern = #"(?s)(`+).*?\1|<grok:render\b[^>]*>.*?</grok:render\s*>"#
            let regex = try! NSRegularExpression(pattern: pattern)
            let idRegex = try! NSRegularExpression(pattern: #"\bcard_id\s*=\s*["']([^"']+)["']"#)
            var cursor = text.startIndex
            var groupEnd: String.Index?
            var group: [SearchedImage] = []
            func flush() {
                guard let end = groupEnd else { return }
                appendText(String(text[cursor..<end]))
                result.append(.images(SearchedImageGallery(images: group)))
                cursor = end; groupEnd = nil; group = []
            }
            for match in regex.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
                guard let range = Range(match.range, in: text), text[range].hasPrefix("<grok:render"),
                      let idMatch = idRegex.firstMatch(in: text, range: match.range),
                      let idRange = Range(idMatch.range(at: 1), in: text), let image = images[String(text[idRange])] else { continue }
                if let end = groupEnd, !text[end..<range.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { flush() }
                if !group.contains(where: { $0.id == image.id }) { group.append(image) }
                groupEnd = range.upperBound
            }
            flush()
            appendText(String(text[cursor...]))
        }
        for block in blocks {
            guard case .text(let text) = block else { result.append(block); continue }
            var prose = ""
            var fence: (Character, Int)?
            let lines = text.components(separatedBy: "\n")
            for (index, line) in lines.enumerated() {
                let fragment = line + (index < lines.count - 1 ? "\n" : "")
                let trimmed = line.drop(while: { $0 == " " })
                let marker = trimmed.first
                let count = marker.map { character in trimmed.prefix(while: { $0 == character }).count } ?? 0
                if let current = fence {
                    appendText(fragment)
                    if marker == current.0 && count >= current.1 && trimmed.dropFirst(count).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { fence = nil }
                } else if (marker == "`" || marker == "~") && count >= 3 {
                    appendProse(prose); prose = ""
                    fence = (marker!, count)
                    appendText(fragment)
                } else { prose += fragment }
            }
            appendProse(prose)
        }
        return result
    }
}
