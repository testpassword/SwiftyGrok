import XCTest
import GrokClient
@testable import GrokCore

enum WeatherFixtures {
    static let card: [String: Any] = [
        "id": "example-weather", "city_or_country": "Example City", "timezone": "Europe/Paris", "temperature_scale": "celsius",
        "weather_data": [
            "current_weather": ["temperature": 12.5, "temperature_apparent": 11, "wind_speed": 9, "humidity": 0.81,
                                "condition_code": "Cloudy", "daylight": true, "as_of": "2026-01-02T12:00:00Z",
                                "metadata": ["units": "m", "attribution_url": "https://weather.example/source"]],
            "forecast_hourly": ["metadata": ["units": "m"], "hours": [
                ["temperature": 13, "forecast_start": "2026-01-02T13:00:00Z", "condition_code": "PartlyCloudy", "daylight": true],
                ["temperature": 8, "forecast_start": "2026-01-02T21:00:00Z", "condition_code": "Clear", "daylight": false]]],
            "forecast_daily": ["days": [["forecast_start": "2026-01-03T00:00:00Z", "temperature_min": 5, "temperature_max": 15, "condition_code": "Rain"]]]
        ]
    ]
}

final class WeatherCardTests: XCTestCase {
    func testMetricWeatherIncludesCurrentHourlyAndDailyValues() throws {
        let card = try XCTUnwrap(WeatherCard(WeatherFixtures.card))
        XCTAssertEqual(card.location, "Example City")
        XCTAssertEqual(card.current?.temperatureCelsius, 12.5)
        XCTAssertEqual(card.current?.feelsLikeCelsius, 11)
        XCTAssertEqual(card.current?.humidityPercent, 81)
        XCTAssertEqual(card.current?.windKilometersPerHour, 9)
        XCTAssertEqual(card.current?.condition, .cloudy)
        XCTAssertEqual(card.hours.count, 2)
        XCTAssertEqual(card.hours.last?.condition.symbol(isDaylight: false), "moon.stars.fill")
        XCTAssertEqual(card.days.first?.lowCelsius, 5)
        XCTAssertEqual(card.attributionURL?.host, "weather.example")
    }

    func testCamelCaseAndImperialInputNormalizeBeforeDisplay() throws {
        let card = try XCTUnwrap(WeatherCard([
            "id": "imperial", "cityOrCountry": "Example", "temperatureScale": "fahrenheit",
            "weatherData": ["currentWeather": ["temperature": 50, "temperatureApparent": 41, "windSpeed": 10, "metadata": ["units": "e"]]]
        ]))
        XCTAssertEqual(card.initialScale, .fahrenheit)
        XCTAssertEqual(card.current?.temperatureCelsius, 10)
        XCTAssertEqual(card.current?.feelsLikeCelsius, 5)
        XCTAssertEqual(try XCTUnwrap(card.current?.windKilometersPerHour), 16.09344, accuracy: 0.00001)
        XCTAssertEqual(WeatherCard.TemperatureScale.fahrenheit.temperature(fromCelsius: 10), 50)
    }

    func testInvalidValuesDoNotFabricateWeatherOrUnsafeLinks() throws {
        XCTAssertNil(WeatherCard(["id": "empty", "city_or_country": "Example", "weather_data": [:]]))
        let card = try XCTUnwrap(WeatherCard([
            "id": "invalid", "city_or_country": "Example",
            "weather_data": ["current_weather": ["temperature": 0, "humidity": -1, "wind_speed": -3,
                "metadata": ["attribution_url": "javascript:alert(1)"]],
                "forecast_hourly": ["hours": [["temperature": Double.infinity], ["condition_code": "Cloudy"]]]]
        ]))
        XCTAssertNil(card.current?.humidityPercent); XCTAssertNil(card.current?.windKilometersPerHour)
        XCTAssertNil(card.attributionURL); XCTAssertTrue(card.hours.isEmpty)
    }

    func testWeatherKeepsPositionAndOriginalTextAlongsidePlaces() {
        let chunks: [[String: Any]] = [
            ["text": ["text": "Before", "channel": "ASSISTANT"]],
            ["render_weather": WeatherFixtures.card],
            ["text": ["text": "Between", "channel": "ASSISTANT"]],
            ["render_places": ["id": "example-places", "locs": [PlaceFixtures.place]]],
            ["text": ["text": "After", "channel": "ASSISTANT"]]
        ]
        let blocks = ResponseCardContent(chunks: chunks).blocks(matching: "**Before**\nBetween\nAfter")
        XCTAssertEqual(blocks.count, 5)
        guard case .weather = blocks[1], case .gallery = blocks[3] else { return XCTFail("Card ordering") }
        let text = blocks.compactMap { if case .text(let text) = $0 { return text }; return nil }.joined()
        XCTAssertEqual(text, "**Before**\nBetween\nAfter")
    }

    func testHourlyForecastStartsAtSnapshotTimeAndMissingDaylightMeansNight() throws {
        let card = try XCTUnwrap(WeatherCard([
            "id": "hours", "city_or_country": "Example", "weather_data": [
                "current_weather": ["temperature": -0.3, "condition_code": "Clear", "as_of": "2026-01-02T12:29:00Z"],
                "forecast_hourly": ["hours": [
                    ["temperature": 8, "forecast_start": "2026-01-02T10:00:00Z"],
                    ["temperature": 2, "forecast_start": "2026-01-02T12:00:00Z"],
                    ["temperature": 1, "forecast_start": "2026-01-02T13:00:00Z"]]]
            ]
        ]))
        XCTAssertEqual(card.hours.map(\.temperatureCelsius), [2, 1])
        XCTAssertEqual(card.current?.isDaylight, false)
    }

    func testUpdatingWeatherCardDoesNotDuplicateIt() {
        let content = ResponseCardContent(chunks: [["render_weather": WeatherFixtures.card], ["renderWeather": WeatherFixtures.card]])
        XCTAssertEqual(content.blocks.count, 1)
        guard case .weather = content.blocks.first else { return XCTFail("Weather missing") }
    }

    func testRecognizedWeatherAndSportToolsRequestCardHistory() {
        for name in ["weather", "functions.weather", "sports", "functions.sports_standings"] {
            let metadata = ["steps": AnyCodable([["toolUsageCards": [["mcp": ["toolName": name]]]]])]
            XCTAssertTrue(ResponseCardContent.needsHistory(metadata))
        }
    }
}
