import Foundation

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
        guard let id = CardJSON.string(json, "id"),
              let name = CardJSON.string(json, "name")
                ?? CardJSON.string(CardJSON.object(json, "display_name", "displayName"), "text") else { return nil }
        self.id = id; self.name = name
        address = CardJSON.string(json, "formatted_address", "formattedAddress", "address")
        let coordinates = CardJSON.object(json, "coordinates", "location")
        let lat = CardJSON.number(coordinates, "latitude"), lon = CardJSON.number(coordinates, "longitude")
        if let lat, let lon, (-90...90).contains(lat), (-180...180).contains(lon) {
            latitude = lat; longitude = lon
        } else { latitude = nil; longitude = nil }
        rating = CardJSON.number(json, "rating").flatMap { (0...5).contains($0) ? $0 : nil }
        reviewCount = CardJSON.number(json, "user_ratings_total", "userRatingsTotal", "ratingCount").flatMap {
            $0 >= 0 && $0 < Double(Int.max) ? Int($0) : nil
        }
        let opening = CardJSON.object(json, "opening_hours", "openingHours")
        isOpen = (opening["open_now"] ?? opening["openNow"]) as? Bool
        hours = ((opening["weekday_descriptions"] ?? opening["weekdayDescriptions"]) as? [String] ?? []).filter { !$0.isEmpty }
        phone = CardJSON.string(json, "formatted_phone_number", "formattedPhoneNumber", "phone")
        website = CardJSON.url(CardJSON.string(json, "website_uri", "websiteUri", "websiteUrl"))
        mapsURL = CardJSON.url(CardJSON.string(json, "google_maps_uri", "googleMapsUri", "mapsUrl"))
        photos = (json["photos"] as? [[String: Any]] ?? []).compactMap { photo in
            guard let url = CardJSON.url(CardJSON.string(photo, "photo_uri", "photoUri", "url")) else { return nil }
            let authors = ((photo["author_attributions"] ?? photo["authorAttributions"] ?? photo["authors"]) as? [[String: Any]] ?? []).compactMap { author -> PlacePhoto.Author? in
                guard let name = CardJSON.string(author, "display_name", "displayName", "name") else { return nil }
                return PlacePhoto.Author(name: name, url: CardJSON.url(CardJSON.string(author, "uri", "profileUrl")))
            }
            return PlacePhoto(url: url, authors: authors)
        }
    }
}

public struct PlaceGallery: Identifiable, Equatable, Sendable {
    public let id: String
    public let places: [PlaceCard]
}
