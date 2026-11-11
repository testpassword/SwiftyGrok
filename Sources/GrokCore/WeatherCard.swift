import Foundation

public struct WeatherCard: Identifiable, Equatable, Sendable {
    public struct Conditions: Equatable, Sendable {
        public let date: Date?
        public let temperatureCelsius: Double
        public let feelsLikeCelsius: Double?
        public let windKilometersPerHour: Double?
        public let humidityPercent: Double?
        public let condition: WeatherCondition
        public let isDaylight: Bool

        init?(_ json: [String: Any], imperial: Bool) {
            guard let temperature = CardJSON.number(json, "temperature"), (-200...300).contains(temperature) else { return nil }
            func celsius(_ value: Double) -> Double { imperial ? (value - 32) * 5 / 9 : value }
            temperatureCelsius = celsius(temperature)
            feelsLikeCelsius = CardJSON.number(json, "temperature_apparent", "temperatureApparent").map(celsius)
            windKilometersPerHour = CardJSON.number(json, "wind_speed", "windSpeed").flatMap { $0 >= 0 ? (imperial ? $0 * 1.609344 : $0) : nil }
            humidityPercent = CardJSON.number(json, "humidity").flatMap { (0...1).contains($0) ? $0 * 100 : nil }
            date = CardJSON.string(json, "as_of", "asOf", "forecast_start", "forecastStart").flatMap(GrokDate.parse)
            condition = WeatherCondition(code: CardJSON.string(json, "condition_code", "conditionCode") ?? "")
            isDaylight = (json["daylight"] as? Bool) ?? false
        }
    }

    public struct Day: Equatable, Sendable {
        public let date: Date
        public let lowCelsius: Double
        public let highCelsius: Double
        public let condition: WeatherCondition

        init?(_ json: [String: Any], imperial: Bool) {
            guard let date = CardJSON.string(json, "forecast_start", "forecastStart").flatMap(GrokDate.parse),
                  let low = CardJSON.number(json, "temperature_min", "temperatureMin"),
                  let high = CardJSON.number(json, "temperature_max", "temperatureMax"),
                  (-200...300).contains(low), (-200...300).contains(high), low <= high else { return nil }
            self.date = date
            lowCelsius = imperial ? (low - 32) * 5 / 9 : low
            highCelsius = imperial ? (high - 32) * 5 / 9 : high
            condition = WeatherCondition(code: CardJSON.string(json, "condition_code", "conditionCode") ?? "")
        }
    }

    public enum TemperatureScale: String, CaseIterable, Sendable {
        case celsius, fahrenheit
        public var symbol: String { self == .celsius ? "°C" : "°F" }
        public func temperature(fromCelsius value: Double) -> Double { self == .celsius ? value : value * 9 / 5 + 32 }
    }

    public let id: String
    public let location: String
    public let timezone: String?
    public let initialScale: TemperatureScale
    public let current: Conditions?
    public let hours: [Conditions]
    public let days: [Day]
    public let attributionURL: URL?

    init?(_ json: [String: Any]) {
        guard let id = CardJSON.string(json, "id"),
              let location = CardJSON.string(json, "city_or_country", "cityOrCountry", "location_original", "locationOriginal") else { return nil }
        let data = CardJSON.object(json, "weather_data", "weatherData")
        let current = CardJSON.object(data, "current_weather", "currentWeather")
        let hourly = CardJSON.object(data, "forecast_hourly", "forecastHourly")
        let daily = CardJSON.object(data, "forecast_daily", "forecastDaily")
        func imperial(_ json: [String: Any]) -> Bool {
            let metadata = CardJSON.object(json, "metadata")
            return ["e", "imperial"].contains((CardJSON.string(metadata, "units") ?? "m").lowercased())
        }
        self.current = Conditions(current, imperial: imperial(current))
        let earliestHour = self.current?.date?.addingTimeInterval(-3600)
        hours = Array((hourly["hours"] as? [[String: Any]] ?? []).prefix(240)
            .compactMap { Conditions($0, imperial: imperial(hourly)) }
            .filter { hour in
                guard let date = hour.date else { return false }
                return earliestHour.map { date > $0 } ?? true
            }.prefix(96))
        days = (daily["days"] as? [[String: Any]] ?? []).prefix(14).compactMap { Day($0, imperial: imperial(daily)) }
        guard self.current != nil || !hours.isEmpty || !days.isEmpty else { return nil }
        self.id = id; self.location = location
        timezone = CardJSON.string(json, "timezone")
        let scale = (CardJSON.string(json, "temperature_scale", "temperatureScale") ?? "").lowercased()
        initialScale = (scale == "f" || scale.hasSuffix("fahrenheit")) ? .fahrenheit : .celsius
        let metadata = CardJSON.object(current.isEmpty ? (hourly.isEmpty ? daily : hourly) : current, "metadata")
        attributionURL = CardJSON.url(CardJSON.string(metadata, "attribution_url", "attributionUrl"))
    }
}

public enum WeatherCondition: Equatable, Sendable {
    case clear, partlyCloudy, cloudy, rain, drizzle, thunderstorm, snow, sleet, fog, windy, unknown

    init(code: String) {
        let code = code.lowercased().filter(\.isLetter)
        switch code {
        case "clear", "mostlyclear", "hot": self = .clear
        case "partlycloudy", "mostlysunny", "mostlycloudy": self = .partlyCloudy
        case "cloudy", "overcast": self = .cloudy
        case "drizzle": self = .drizzle
        case "rain", "heavyrain", "sunshowers", "scatteredshowers", "isolatedshowers": self = .rain
        case "thunderstorms", "thunderstorm", "strongstorms", "isolatedthunderstorms", "scatteredthunderstorms": self = .thunderstorm
        case "snow", "heavysnow", "flurries", "blowingsnow", "blizzard", "sunflurries": self = .snow
        case "sleet", "freezingrain", "freezingdrizzle", "hail", "wintrymix": self = .sleet
        case "foggy", "fog", "haze", "smoky", "blowingdust": self = .fog
        case "windy", "breezy", "hurricane", "tropicalstorm": self = .windy
        default: self = .unknown
        }
    }

    public var localizedName: String {
        switch self {
        case .clear: return L10n.text("Clear")
        case .partlyCloudy: return L10n.text("Partly cloudy")
        case .cloudy: return L10n.text("Cloudy")
        case .rain: return L10n.text("Rain")
        case .drizzle: return L10n.text("Drizzle")
        case .thunderstorm: return L10n.text("Thunderstorms")
        case .snow: return L10n.text("Snow")
        case .sleet: return L10n.text("Sleet")
        case .fog: return L10n.text("Fog")
        case .windy: return L10n.text("Windy")
        case .unknown: return L10n.text("Weather")
        }
    }

    public func symbol(isDaylight: Bool = true) -> String {
        switch self {
        case .clear: return isDaylight ? "sun.max.fill" : "moon.stars.fill"
        case .partlyCloudy: return isDaylight ? "cloud.sun.fill" : "cloud.moon.fill"
        case .cloudy, .unknown: return "cloud.fill"
        case .rain: return "cloud.rain.fill"
        case .drizzle: return "cloud.drizzle.fill"
        case .thunderstorm: return "cloud.bolt.rain.fill"
        case .snow: return "cloud.snow.fill"
        case .sleet: return "cloud.sleet.fill"
        case .fog: return "cloud.fog.fill"
        case .windy: return "wind"
        }
    }
}
