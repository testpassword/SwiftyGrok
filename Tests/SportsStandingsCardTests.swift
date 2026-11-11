import XCTest
import GrokClient
@testable import GrokCore

enum SportsFixtures {
    static let table = """
    | Team | GP | W | L | OTL | PTS |
    | --- | ---: | ---: | ---: | ---: | ---: |
    | Example Bears | 18 | 13 | 4 | 1 | 27 |
    | Example Stars | 17 | 11 | 3 | 3 | 25 |
    """
    static let card: [String: Any] = [
        "id": "example-standings", "sport": "nhl",
        "standings": ["standings": [["scope": "Example Division", "table": table,
                                     "teams": [["name": "Example Bears", "abbreviation": "EXB"]]]]]
    ]
}

final class SportsStandingsCardTests: XCTestCase {
    func testNHLTableCombinesRecordAndKeepsGamesAndOvertimeLosses() throws {
        let card = try XCTUnwrap(SportsStandingsCard(SportsFixtures.card))
        XCTAssertEqual(card.league, "NHL")
        let table = try XCTUnwrap(card.tables.first)
        XCTAssertEqual(table.title, "Example Division")
        XCTAssertEqual(table.columns, ["W-L", "GP", "OTL"])
        XCTAssertEqual(table.rows.map(\.rank), [1, 2])
        XCTAssertEqual(table.rows.first?.team, "Example Bears")
        XCTAssertEqual(table.rows.first?.values, ["13–4", "18", "1"])
    }

    func testAllDivisionsArePreservedAndMalformedRowsIgnored() throws {
        let card = try XCTUnwrap(SportsStandingsCard([
            "id": "multiple", "sport": "nhl", "standings": ["standings": [
                ["scope": "Broken", "table": "not a table"],
                ["scope": "One", "table": SportsFixtures.table + "\n| missing cells |"],
                ["scope": "Two", "table": SportsFixtures.table]]]
        ]))
        XCTAssertEqual(card.tables.map(\.title), ["One", "Two"])
        XCTAssertEqual(card.tables.first?.rows.count, 2)
        XCTAssertEqual(card.tables.first?.id, 1)
        XCTAssertNil(SportsStandingsCard(["id": "empty", "sport": "nhl", "standings": [:]]))
    }

    func testNonZeroTiesAndOtherLeaguesDoNotLoseRecordData() throws {
        let card = try XCTUnwrap(SportsStandingsCard([
            "id": "ties", "sport": "example", "standings": ["standings": [["table": "| Club | W | L | T | GP |\n| --- | --- | --- | --- | --- |\n| Example | 2 | 1 | 1 | 4 |"]]]
        ]))
        XCTAssertEqual(card.tables.first?.columns, ["W-L-T", "GP"])
        XCTAssertEqual(card.tables.first?.rows.first?.values, ["2–1–1", "4"])
    }

    func testEscapedPipeInTeamNameCannotShiftStatistics() throws {
        let card = try XCTUnwrap(SportsStandingsCard([
            "id": "escaped", "sport": "nhl", "standings": ["standings": [["table": "| Team | W | L |\n| --- | --- | --- |\n| A \\| B | 2 | 1 |"]]]
        ]))
        XCTAssertEqual(card.tables.first?.rows.first?.team, "A | B")
        XCTAssertEqual(card.tables.first?.rows.first?.values, ["2–1"])
    }

    func testWeatherAndStandingsKeepOrderWithoutDuplicatingCardsOrAnswerText() {
        let chunks: [[String: Any]] = [
            ["text": ["text": "Weather", "channel": "ASSISTANT"]],
            ["render_weather": WeatherFixtures.card],
            ["text": ["text": "Standings", "channel": "ASSISTANT"]],
            ["render_sports": SportsFixtures.card], ["renderSports": SportsFixtures.card],
            ["text": ["text": "After", "channel": "ASSISTANT"]]
        ]
        let blocks = ResponseCardContent(chunks: chunks).blocks(matching: "Weather\nStandings\nAfter")
        XCTAssertEqual(blocks.count, 5)
        guard case .weather = blocks[1], case .standings = blocks[3] else { return XCTFail("Card order") }
        XCTAssertEqual(blocks.compactMap { if case .text(let text) = $0 { return text }; return nil }.joined(), "Weather\nStandings\nAfter")
    }

    func testTypedWeatherAndSportToolsRequestSupplementalHistory() {
        for tool in ["callWeatherApi", "callSportsApi"] {
            XCTAssertTrue(ResponseCardContent.needsHistory(["steps": AnyCodable([["toolUsageCards": [[tool: ["query": "Example"]]]]])]))
        }
    }
}
