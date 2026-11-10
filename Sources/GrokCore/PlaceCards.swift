import Foundation
import GrokClient

public struct PlacePhoto: Equatable, Sendable {
    public struct Author: Equatable, Sendable {
        public let name: String
        public let url: URL?
    }
    public let url: URL
    public let authors: [Author]
}

public struct PlaceCard: Identifiable, Equatable, Sendable {
    public let id: String
    public let name: String
    public let address: String?
    public let latitude: Double?
    public let longitude: Double?
    public let rating: Double?
    public let reviewCount: Int?
    public let isOpen: Bool?
    public let hours: [String]
    public let phone: String?
    public let website: URL?
    public let mapsURL: URL?
    public let photos: [PlacePhoto]

    init?(_ json: [String: Any]) {
        guard let id = PlaceJSON.string(json, "id"),
              let name = PlaceJSON.string(json, "name")
                ?? PlaceJSON.string(PlaceJSON.object(json, "display_name", "displayName"), "text") else { return nil }
        self.id = id; self.name = name
        address = PlaceJSON.string(json, "formatted_address", "formattedAddress", "address")
        let coordinates = PlaceJSON.object(json, "coordinates", "location")
        let lat = PlaceJSON.number(coordinates, "latitude"), lon = PlaceJSON.number(coordinates, "longitude")
        if let lat, let lon, (-90...90).contains(lat), (-180...180).contains(lon) {
            latitude = lat; longitude = lon
        } else { latitude = nil; longitude = nil }
        rating = PlaceJSON.number(json, "rating").flatMap { (0...5).contains($0) ? $0 : nil }
        reviewCount = PlaceJSON.number(json, "user_ratings_total", "userRatingsTotal", "ratingCount").flatMap {
            $0 >= 0 && $0 < Double(Int.max) ? Int($0) : nil
        }
        let opening = PlaceJSON.object(json, "opening_hours", "openingHours")
        isOpen = (opening["open_now"] ?? opening["openNow"]) as? Bool
        hours = ((opening["weekday_descriptions"] ?? opening["weekdayDescriptions"]) as? [String] ?? []).filter { !$0.isEmpty }
        phone = PlaceJSON.string(json, "formatted_phone_number", "formattedPhoneNumber", "phone")
        website = PlaceJSON.url(PlaceJSON.string(json, "website_uri", "websiteUri", "websiteUrl"))
        mapsURL = PlaceJSON.url(PlaceJSON.string(json, "google_maps_uri", "googleMapsUri", "mapsUrl"))
        photos = (json["photos"] as? [[String: Any]] ?? []).compactMap { photo in
            guard let url = PlaceJSON.url(PlaceJSON.string(photo, "photo_uri", "photoUri", "url")) else { return nil }
            let authors = ((photo["author_attributions"] ?? photo["authorAttributions"] ?? photo["authors"]) as? [[String: Any]] ?? []).compactMap { author -> PlacePhoto.Author? in
                guard let name = PlaceJSON.string(author, "display_name", "displayName", "name") else { return nil }
                return PlacePhoto.Author(name: name, url: PlaceJSON.url(PlaceJSON.string(author, "uri", "profileUrl")))
            }
            return PlacePhoto(url: url, authors: authors)
        }
    }
}

public struct PlaceGallery: Identifiable, Equatable, Sendable {
    public let id: String
    public let places: [PlaceCard]
}

public enum PlaceMessageBlock: Equatable, Sendable {
    case text(String)
    case gallery(PlaceGallery)
}

public struct PlaceResponseContent: Equatable, Sendable {
    public let blocks: [PlaceMessageBlock]
    public var galleries: [PlaceGallery] {
        blocks.compactMap { if case .gallery(let gallery) = $0 { return gallery }; return nil }
    }

    /// Only final answer text participates in positioning. Thinking and tool
    /// output must never be copied into the visible answer around a card.
    public init(chunks: [[String: Any]]) {
        var blocks: [PlaceMessageBlock] = []
        var text = ""
        func flush() {
            if !text.isEmpty { blocks.append(.text(text)); text = "" }
        }
        for chunk in chunks {
            let content = PlaceJSON.object(chunk, "text")
            if let fragment = content["text"] as? String {
                let channel = (content["channel"] as? String ?? "").uppercased()
                if !["THINKING", "ANALYSIS", "SUMMARY", "HEADER"].contains(where: channel.contains) {
                    text += fragment
                }
            }
            let card = PlaceJSON.object(chunk, "render_places", "renderPlaces")
            guard let id = PlaceJSON.string(card, "id") else { continue }
            var seen = Set<String>()
            let places = (card["locs"] as? [[String: Any]] ?? []).compactMap(PlaceCard.init).filter { seen.insert($0.id).inserted }
            guard !places.isEmpty else { continue }
            flush()
            let gallery = PlaceMessageBlock.gallery(PlaceGallery(id: id, places: places))
            if let index = blocks.firstIndex(where: { if case .gallery(let old) = $0 { return old.id == id }; return false }) {
                blocks[index] = gallery
            } else { blocks.append(gallery) }
        }
        flush()
        self.blocks = blocks
    }

    public func blocks(matching original: String) -> [PlaceMessageBlock] {
        guard !galleries.isEmpty else { return [] }
        let text = blocks.compactMap { if case .text(let text) = $0 { return text }; return nil }.joined()
        if text == original { return blocks }
        // REST can add formatting or separators absent from chunk text. Anchor
        // each gallery to a neighbouring fragment, preserving every original character.
        var result: [PlaceMessageBlock] = []
        var cursor = original.startIndex
        for (index, block) in blocks.enumerated() {
            guard case .gallery(let gallery) = block else { continue }
            func fragment(_ block: PlaceMessageBlock) -> String? {
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
            result.append(.gallery(gallery))
            cursor = boundary
        }
        if cursor < original.endIndex { result.append(.text(String(original[cursor...]))) }
        return result
    }

    static func needsHistory(_ metadata: [String: AnyCodable]) -> Bool {
        let root = metadata.mapValues(PlaceJSON.unwrap)
        for step in root["steps"] as? [[String: Any]] ?? [] {
            for card in step["toolUsageCards"] as? [[String: Any]] ?? [] {
                let mcp = PlaceJSON.object(card, "mcp")
                let name = PlaceJSON.string(mcp, "toolName", "tool_name") ?? ""
                if name == "places_search" || name.hasSuffix(".places_search") || card["callPlacesApi"] != nil { return true }
            }
        }
        return false
    }
}

enum PlaceJSON {
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
