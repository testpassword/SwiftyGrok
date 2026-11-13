import Foundation
import GrokClient

public struct MessageSource: Identifiable, Equatable, Sendable {
    public let id: String
    public let title: String
    public let url: URL
    public let citationID: String?
    public init(id: String, title: String, url: URL, citationID: String? = nil) {
        self.id = id; self.title = title; self.url = url; self.citationID = citationID
    }
}

public struct MessageAttachment: Identifiable, Equatable, Sendable {
    public enum Kind: String, Sendable { case image, file, video, audio }
    public let id: String
    public let name: String
    public let url: URL?
    public let kind: Kind
    public let isGenerated: Bool
    public init(id: String, name: String, url: URL?, kind: Kind, isGenerated: Bool = false) {
        self.id = id; self.name = name; self.url = url; self.kind = kind; self.isGenerated = isGenerated
    }
}

public struct GrokMessageContent {
    public let sources: [MessageSource]
    public let attachments: [MessageAttachment]
    public let reasoning: String?
    public let reasoningDuration: TimeInterval?
    public let failure: String?
    private let searchedImages: [String: SearchedImage]
    private let renderCards: [String: [String: Any]]
    private let outputChunks: [[String: Any]]

    public init(_ metadata: [String: AnyCodable]) {
        let json = metadata.mapValues { Self.unwrap($0) }
        searchedImages = SearchedImageContent.images(json["cardAttachmentsJson"])
        var renderCards: [String: [String: Any]] = [:]
        for value in json["cardAttachmentsJson"] as? [Any] ?? [] {
            let card: [String: Any]?
            if let string = value as? String, let data = string.data(using: .utf8) {
                card = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            } else { card = value as? [String: Any] }
            if let card, let id = CardJSON.string(card, "id", "cardId") { renderCards[id] = card }
        }
        self.renderCards = renderCards
        outputChunks = json["outputChunks"] as? [[String: Any]] ?? []
        var sources: [MessageSource] = []
        for key in ["webSearchResults", "citedWebSearchResults"] {
            for (index, item) in Self.array(json[key]).enumerated() {
                guard let item = item as? [String: Any], let url = Self.url(Self.string(item, ["url", "link"])) else { continue }
                let id = Self.string(item, ["citationId", "citation_id", "id"]) ?? String(index)
                sources.append(MessageSource(id: "search-\(id)", title: Self.string(item, ["title", "name"]) ?? url.host ?? L10n.text("Source"),
                                             url: url, citationID: id))
            }
        }
        for value in Self.array(json["cardAttachmentsJson"]) {
            let card: [String: Any]?
            if let value = value as? String, let data = value.data(using: .utf8) {
                card = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            } else { card = value as? [String: Any] }
            guard let card, let id = Self.string(card, ["id", "cardId"]), let url = Self.url(Self.string(card, ["url"])) else { continue }
            let title = Self.string(card, ["title", "name"]) ?? sources.first { $0.url == url }?.title ?? url.host ?? L10n.text("Source")
            sources.append(MessageSource(id: id, title: title, url: url))
        }
        for value in Self.array(json["xposts"]) {
            guard let post = value as? [String: Any], let id = Self.string(post, ["postId", "id"]) else { continue }
            if let url = Self.url("https://x.com/i/status/\(id)") {
                sources.append(MessageSource(id: "post-\(id)", title: Self.string(post, ["name", "username"]) ?? L10n.text("Post on X"), url: url))
            }
        }
        var sourceIDs = Set<String>()
        self.sources = sources.filter { sourceIDs.insert($0.id).inserted }

        var attachments: [MessageAttachment] = []
        let fileMetadata = Self.array(json["fileAttachmentsMetadata"]).compactMap { $0 as? [String: Any] }
        for key in ["generatedImageUrls", "imageAttachments", "fileAttachments", "fileAttachmentsMetadata", "fileUris"] {
            // Metadata is the detailed representation of fileAttachments, not an extra attachment.
            if key == "fileAttachments" && !fileMetadata.isEmpty { continue }
            for (index, item) in Self.array(json[key]).enumerated() {
                let raw = item as? String
                let record = (item as? [String: Any]) ?? fileMetadata.first {
                    Self.string($0, ["fileId", "id"]) == raw
                } ?? [:]
                let id = Self.string(record, ["fileId", "id", "fileUri"]) ?? raw ?? "\(key)-\(index)"
                let directURL = Self.string(record, ["url", "fileUrl", "downloadUrl", "uri", "imageUrl"]) ?? raw
                let relativeURI = Self.string(record, ["fileUri"])
                    ?? (raw?.hasPrefix("users/") == true || raw?.hasPrefix("/users/") == true ? raw : nil)
                let url = Self.url(directURL) ?? Self.assetURL(relativeURI)
                let name = Self.string(record, ["fileName", "filename", "name", "title"]) ?? url?.lastPathComponent
                let contentType = Self.string(record, ["fileMimeType", "mimeType", "contentType"]) ?? ""
                let ext = (name as NSString?)?.pathExtension.lowercased() ?? url?.pathExtension.lowercased() ?? ""
                let kind: MessageAttachment.Kind = key.contains("Image") || key == "imageAttachments" || contentType.hasPrefix("image/") || ["png", "jpg", "jpeg", "webp", "gif", "heic"].contains(ext) ? .image :
                    (contentType.hasPrefix("video/") || ["mp4", "mov", "webm"].contains(ext) ? .video :
                        (contentType.hasPrefix("audio/") || ["mp3", "m4a", "wav"].contains(ext) ? .audio : .file))
                attachments.append(MessageAttachment(id: id, name: name?.isEmpty == false ? name! : (kind == .image ? L10n.text("Image") : L10n.text("File")), url: url, kind: kind,
                                                     isGenerated: key == "generatedImageUrls" || Self.isGeneratedAsset(url)))
            }
        }
        var attachmentIDs = Set<String>()
        self.attachments = attachments.filter { attachmentIDs.insert($0.url?.absoluteString ?? $0.id).inserted }
        let trace = Self.string(json, ["thinkingTrace", "reasoningTrace"])?.trimmingCharacters(in: .whitespacesAndNewlines)
        reasoning = trace?.isEmpty == false ? trace : Self.reasoningSteps(json)
        if let start = Self.timestamp(json["thinkingStartTime"]), let end = Self.timestamp(json["thinkingEndTime"]), end >= start {
            reasoningDuration = end - start
        } else { reasoningDuration = nil }
        let errors = Self.array(json["streamErrors"]).compactMap { value -> String? in
            if let value = value as? String { return value }
            return (value as? [String: Any]).flatMap { Self.string($0, ["message", "error", "description"]) }
        }
        failure = errors.isEmpty ? nil : errors.joined(separator: "\n")
    }

    public func contentBlocks(in text: String, merging blocks: [ResponseContentBlock] = []) -> [ResponseContentBlock] {
        let chunks = blocks.isEmpty ? ResponseCardContent(chunks: outputChunks).blocks(matching: text) : blocks
        let existing = Set(chunks.flatMap { block -> [String] in
            if case .unavailable = block { return [] }
            return block.renderedCardIDs
        })
        let images = SearchedImageContent.inserting(in: chunks.isEmpty ? [.text(text)] : chunks, images: searchedImages.filter { !existing.contains($0.key) })
        let rendered = Set(images.flatMap { block -> [String] in
            if case .unavailable = block { return [] }
            return block.renderedCardIDs
        })
        let unique = images.filter { block in
            if case .unavailable(let card) = block { return !rendered.contains(card.id) }
            return true
        }
        let result = UnavailableResponseCard.inserting(in: unique, sources: sources, cards: renderCards)
        return result.contains(where: { $0.cardID != nil }) ? result : []
    }

    public static func url(_ value: String?) -> URL? {
        guard let value, let url = URL(string: value), ["https", "http"].contains(url.scheme?.lowercased() ?? ""),
              url.host != nil, url.user == nil, url.password == nil else { return nil }
        return url
    }

    private static func timestamp(_ value: Any?) -> TimeInterval? {
        if let string = value as? String, let date = GrokDate.parse(string) { return date.timeIntervalSince1970 }
        let number = (value as? NSNumber)?.doubleValue ?? (value as? String).flatMap(Double.init)
        guard let number, number.isFinite else { return nil }
        return number > 100_000_000_000 ? number / 1000 : number
    }

    private static func reasoningSteps(_ json: [String: Any]) -> String? {
        var fragments: [String] = []
        for item in array(json["traceSteps"]) {
            guard let step = item as? [String: Any], let type = step["type"] as? String,
                  ["thinking", "summarized_thinking", "summary", "header"].contains(type), let text = step["text"] as? String else { continue }
            fragments.append(text)
        }
        if fragments.isEmpty {
            for item in array(json["steps"]) {
                guard let step = item as? [String: Any] else { continue }
                let texts = step["text"] as? [String] ?? (step["text"] as? String).map { [$0] } ?? []
                let tags = step["tags"] as? [String] ?? (step["tags"] as? String).map { [$0] } ?? []
                var section = ""
                var previousTag: String?
                for (index, text) in texts.enumerated() where index < tags.count {
                    let tag = tags[index]
                    if ["thinking", "summary", "header"].contains(tag) {
                        if let previousTag, previousTag != tag, !section.isEmpty { section += "\n\n" }
                        section += text
                        previousTag = tag
                    }
                }
                if !section.isEmpty { fragments.append(section) }
            }
        }
        let result = fragments.joined(separator: "\n\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return result.isEmpty ? nil : result
    }

    private static func assetURL(_ value: String?) -> URL? {
        guard let value, !value.isEmpty else { return nil }
        if URL(string: value)?.scheme != nil { return url(value) }
        return url("https://assets.grok.com/" + value.trimmingCharacters(in: CharacterSet(charactersIn: "/")))
    }

    public static func resolvedAttachment(id: String, metadata: [String: AnyCodable]) -> MessageAttachment? {
        let root = metadata.mapValues(unwrap)
        let value = (root["asset"] ?? root["data"] ?? root["result"]) as? [String: Any] ?? root
        guard let url = assetURL(string(value, ["key", "fileUri", "url", "downloadUrl"])) else { return nil }
        let name = string(value, ["name", "fileName", "filename"]) ?? url.lastPathComponent
        let mime = string(value, ["mimeType", "fileMimeType", "contentType"]) ?? ""
        let ext = (name as NSString).pathExtension.lowercased()
        let kind: MessageAttachment.Kind = mime.hasPrefix("image/") || ["png", "jpg", "jpeg", "webp", "gif", "heic", "heif"].contains(ext) ? .image :
            (mime.hasPrefix("video/") || ["mp4", "mov", "webm"].contains(ext) ? .video :
                (mime.hasPrefix("audio/") || ["mp3", "m4a", "wav"].contains(ext) ? .audio : .file))
        return MessageAttachment(id: id, name: name, url: url, kind: kind, isGenerated: isGeneratedAsset(url))
    }

    private static func isGeneratedAsset(_ url: URL?) -> Bool {
        url?.host?.lowercased() == "assets.grok.com" && url?.pathComponents.contains("generated") == true
    }

    /// Convert Grok's display cards to links while preserving literal examples in code.
    public static func markdown(_ text: String, sources: [MessageSource]) -> String {
        let text = ToolUsageContent.plainText(text)
        var result = ""
        var prose = ""
        var fence: (Character, Int)?
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let string = String(line)
            let trimmed = string.drop(while: { $0 == " " })
            let marker = trimmed.first
            let count = marker.map { character in trimmed.prefix(while: { $0 == character }).count } ?? 0
            if let current = fence {
                result += string + "\n"
                if marker == current.0 && count >= current.1 && trimmed.dropFirst(count).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { fence = nil }
            } else if (marker == "`" || marker == "~") && count >= 3 {
                result += replaceCards(prose, sources: sources); prose = ""
                fence = (marker!, count)
                result += string + "\n"
            } else { prose += string + "\n" }
        }
        result += replaceCards(prose, sources: sources)
        if result.hasSuffix("\n") { result.removeLast() }
        return result
    }

    private static func replaceCards(_ text: String, sources: [MessageSource]) -> String {
        let pattern = #"(?s)(`+).*?\1|<grok:render\b[^>]*>.*?</grok:render\s*>|<grok:render\b.*\z"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return text }
        var result = text
        for match in regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).reversed() {
            guard let range = Range(match.range, in: text) else { continue }
            let card = String(text[range])
            if card.hasPrefix("`") { continue }
            let cardID = capture(#"card_id\s*=\s*["']([^"']+)["']"#, in: card)
            let citationID = capture(#"name\s*=\s*["']citation_id["']\s*>([^<]+)<"#, in: card)
            let source = cardID.flatMap { id in sources.first { $0.id == id } }
                ?? (cardID == nil ? sources.first { $0.citationID != nil && $0.citationID == citationID } : nil)
            let replacement = source.map { " [↗ \(($0.url.host ?? $0.title).replacingOccurrences(of: "www.", with: ""))](<\($0.url.absoluteString)>) " } ?? ""
            if let current = Range(match.range, in: result) { result.replaceSubrange(current, with: replacement) }
        }
        return result
    }

    private static func capture(_ pattern: String, in text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern), let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range(at: 1), in: text) else { return nil }
        return String(text[range])
    }
    private static func string(_ value: [String: Any], _ keys: [String]) -> String? {
        keys.compactMap { value[$0] as? String }.first { !$0.isEmpty }
    }
    private static func array(_ value: Any?) -> [Any] { value as? [Any] ?? [] }
    private static func unwrap(_ value: AnyCodable) -> Any {
        if let array = value.value as? [AnyCodable] { return array.map(unwrap) }
        if let dict = value.value as? [String: AnyCodable] { return dict.mapValues(unwrap) }
        return value.value
    }
}
