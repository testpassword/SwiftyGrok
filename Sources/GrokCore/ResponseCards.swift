import Foundation
import GrokClient

public enum ResponseContentBlock: Equatable, Sendable {
    case text(String)
    case gallery(PlaceGallery)
    case weather(WeatherCard)
    case standings(SportsStandingsCard)

    var cardID: String? {
        switch self {
        case .text: return nil
        case .gallery(let card): return "places-" + card.id
        case .weather(let card): return "weather-" + card.id
        case .standings(let card): return "sports-" + card.id
        }
    }
}

public struct ResponseCardContent: Equatable, Sendable {
    public let blocks: [ResponseContentBlock]
    public var galleries: [PlaceGallery] {
        blocks.compactMap { if case .gallery(let gallery) = $0 { return gallery }; return nil }
    }

    /// Only final answer text participates in positioning. Thinking and tool
    /// output must never be copied into the visible answer around a card.
    public init(chunks: [[String: Any]]) {
        var blocks: [ResponseContentBlock] = []
        var text = ""
        func flush() {
            if !text.isEmpty { blocks.append(.text(text)); text = "" }
        }
        for chunk in chunks {
            let content = CardJSON.object(chunk, "text")
            if let fragment = content["text"] as? String {
                let channel = (content["channel"] as? String ?? "").uppercased()
                if !["THINKING", "ANALYSIS", "SUMMARY", "HEADER"].contains(where: channel.contains) {
                    text += fragment
                }
            }
            func append(_ block: ResponseContentBlock) {
                flush()
                if let index = blocks.firstIndex(where: { $0.cardID == block.cardID }) {
                    blocks[index] = block
                } else { blocks.append(block) }
            }
            let placesCard = CardJSON.object(chunk, "render_places", "renderPlaces")
            if let id = CardJSON.string(placesCard, "id") {
                var seen = Set<String>()
                let places = (placesCard["locs"] as? [[String: Any]] ?? []).compactMap(PlaceCard.init).filter { seen.insert($0.id).inserted }
                if !places.isEmpty { append(.gallery(PlaceGallery(id: id, places: places))) }
            }
            if let weather = WeatherCard(CardJSON.object(chunk, "render_weather", "renderWeather")) {
                append(.weather(weather))
            }
            if let sports = SportsStandingsCard(CardJSON.object(chunk, "render_sports", "renderSports")) {
                append(.standings(sports))
            }
        }
        flush()
        self.blocks = blocks
    }

    public func blocks(matching original: String) -> [ResponseContentBlock] {
        guard blocks.contains(where: { $0.cardID != nil }) else { return [] }
        let text = blocks.compactMap { if case .text(let text) = $0 { return text }; return nil }.joined()
        if text == original { return blocks }
        // REST can add formatting or separators absent from chunk text. Anchor
        // each card to a neighbouring fragment, preserving every original character.
        var result: [ResponseContentBlock] = []
        var cursor = original.startIndex
        for (index, block) in blocks.enumerated() {
            guard block.cardID != nil else { continue }
            func fragment(_ block: ResponseContentBlock) -> String? {
                guard case .text(let value) = block else { return nil }
                let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                return trimmed.isEmpty ? nil : trimmed
            }
            let after = blocks.dropFirst(index + 1).compactMap(fragment).first
            let before = blocks.prefix(index).reversed().compactMap(fragment).first
            let remaining = cursor..<original.endIndex
            let boundary: String.Index
            if let after, let range = original.range(of: after, range: remaining) { boundary = range.lowerBound }
            else if let before, let range = original.range(of: before, range: remaining) { boundary = range.upperBound }
            else { boundary = original.endIndex }
            if cursor < boundary { result.append(.text(String(original[cursor..<boundary]))) }
            result.append(block)
            cursor = boundary
        }
        if cursor < original.endIndex { result.append(.text(String(original[cursor...]))) }
        return result
    }

    static func needsHistory(_ metadata: [String: AnyCodable]) -> Bool {
        let root = metadata.mapValues(CardJSON.unwrap)
        for step in root["steps"] as? [[String: Any]] ?? [] {
            for card in step["toolUsageCards"] as? [[String: Any]] ?? [] {
                let mcp = CardJSON.object(card, "mcp")
                let name = CardJSON.string(mcp, "toolName", "tool_name") ?? ""
                let tool = name.split(separator: ".").last.map(String.init) ?? name
                if ["places_search", "weather", "weather_forecast", "sports", "sports_standings"].contains(tool) ||
                    card["callPlacesApi"] != nil || card["callWeatherApi"] != nil || card["callSportsApi"] != nil { return true }
            }
        }
        return false
    }
}

enum CardJSON {
    static func unwrap(_ value: AnyCodable) -> Any {
        if let array = value.value as? [AnyCodable] { return array.map(unwrap) }
        if let object = value.value as? [String: AnyCodable] { return object.mapValues(unwrap) }
        return value.value
    }
    static func string(_ object: [String: Any], _ keys: String...) -> String? {
        keys.compactMap { object[$0] as? String }.first { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }
    static func object(_ object: [String: Any], _ keys: String...) -> [String: Any] {
        keys.compactMap { object[$0] as? [String: Any] }.first ?? [:]
    }
    static func number(_ object: [String: Any], _ keys: String...) -> Double? {
        for key in keys {
            let value = (object[key] as? NSNumber)?.doubleValue ?? (object[key] as? String).flatMap(Double.init)
            if let value, value.isFinite { return value }
        }
        return nil
    }
    static func url(_ text: String?) -> URL? {
        guard let url = GrokMessageContent.url(text), url.scheme?.lowercased() == "https" else { return nil }
        return url
    }
}
