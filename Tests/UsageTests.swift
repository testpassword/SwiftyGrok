import XCTest
import Foundation
import GrokUsage

final class UsageTests: XCTestCase {
    func testAccountCreditsAcceptStringCentsAndPreserveProductShares() throws {
        let data = Data(#"{"config":{"creditUsagePercent":29,"currentPeriod":{"type":"USAGE_PERIOD_TYPE_WEEKLY","end":"2026-11-17T18:06:28.580Z"},"prepaidBalance":{"val":"9007199254740993"},"productUsage":[{"product":"PRODUCT_GROK_BUILD","usagePercent":15},{"product":"PRODUCT_GROK_CHAT","usagePercent":11},{"product":"PRODUCT_GROK_IMAGINE","usagePercent":3}]}}"#.utf8)
        let snapshot = try CreditsUsageParser.parse(data, product: .chat)
        XCTAssertEqual(snapshot.product, .chat)
        XCTAssertEqual(snapshot.windows.first?.usedPercent, 29)
        XCTAssertEqual(snapshot.windows.first?.remainingPercent, 71)
        XCTAssertEqual(snapshot.prepaidCents, 9_007_199_254_740_993)
        XCTAssertEqual(snapshot.products.map(\.id), ["PRODUCT_GROK_BUILD", "PRODUCT_GROK_CHAT", "PRODUCT_GROK_IMAGINE"])
        XCTAssertEqual(snapshot.products.map(\.percent), [15, 11, 3])
        XCTAssertNotNil(snapshot.windows.first?.resetAt)
    }

    func testInvalidCreditBalanceIsNotReportedAsZero() {
        for value in [#""invalid""#, #""9223372036854775808""#, "null", "true"] {
            let data = Data("{\"config\":{\"creditUsagePercent\":29,\"prepaidBalance\":{\"val\":\(value)}}}".utf8)
            XCTAssertThrowsError(try CreditsUsageParser.parse(data, product: .chat))
        }
    }

    func testSharedPercentageAndProductsDescribeOnePool() throws {
        let data = Data(#"{"config":{"creditUsagePercent":24,"currentPeriod":{"type":"USAGE_PERIOD_TYPE_WEEKLY","end":"2033-05-18T03:33:20Z"},"prepaidBalance":{"val":2400},"productUsage":[{"product":"GrokChat","usagePercent":4},{"product":"GrokBuild","usagePercent":20}]}}"#.utf8)
        let snapshot = try BuildUsageParser.parse(data)
        XCTAssertEqual(snapshot.windows.first?.remainingPercent, 76)
        XCTAssertEqual(snapshot.windows.first?.period, "Weekly pool")
        XCTAssertEqual(snapshot.prepaidCents, 2400)
        XCTAssertEqual(snapshot.products.count, 2)
        XCTAssertEqual(snapshot.products.reduce(0) { $0 + $1.percent }, 24)
    }

    func testMissingPercentageAndBalanceRemainUnknown() throws {
        let snapshot = try BuildUsageParser.parse(Data(#"{"config":{"currentPeriod":{"type":"USAGE_PERIOD_TYPE_WEEKLY","end":"2033-05-18T03:33:20Z"}}}"#.utf8))
        XCTAssertNil(snapshot.windows.first?.usedPercent)
        XCTAssertNil(snapshot.windows.first?.remainingPercent)
        XCTAssertNil(snapshot.prepaidCents)
        let mixedLegacy = try BuildUsageParser.parse(Data(#"{"config":{"currentPeriod":{"type":"USAGE_PERIOD_TYPE_WEEKLY","end":"2033-05-18T03:33:20Z"},"monthlyLimit":{"val":10000},"used":{"val":2500}}}"#.utf8))
        XCTAssertNil(mixedLegacy.windows.first?.remainingPercent)
        let explicitZero = try BuildUsageParser.parse(Data(#"{"config":{"creditUsagePercent":0,"prepaidBalance":{}}}"#.utf8))
        XCTAssertEqual(explicitZero.windows.first?.remainingPercent, 100)
        XCTAssertEqual(explicitZero.prepaidCents, 0)
    }

    func testMalformedAndInconsistentBillingIsNotDisplayedAsValidUsage() throws {
        XCTAssertThrowsError(try BuildUsageParser.parse(Data(#"{"config":{}}"#.utf8)))
        XCTAssertThrowsError(try BuildUsageParser.parse(Data(#"{"config":{"creditUsagePercent":101}}"#.utf8)))
        let snapshot = try BuildUsageParser.parse(Data(#"{"config":{"creditUsagePercent":24,"productUsage":[{"product":"GrokBuild","usagePercent":80}]}}"#.utf8))
        XCTAssertTrue(snapshot.products.isEmpty)
    }

    func testLegacyMonthlyBudgetRetainsMonthlyMeaning() throws {
        let snapshot = try BuildUsageParser.parse(Data(#"{"config":{"monthlyLimit":{"val":10000},"used":{"val":2500}}}"#.utf8))
        XCTAssertEqual(snapshot.windows.first?.remainingPercent, 75)
        XCTAssertEqual(snapshot.windows.first?.period, "Monthly pool")
    }

    func testOnlyUsableFirstPartyCLISessionsAreSelected() throws {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let data = Data(#"{"xai::api_key":{"key":"xai-fixture"},"https://enterprise.example.com::one":{"key":"enterprise-fixture"},"https://auth.x.ai::expired":{"key":"expired-fixture","expires_at":"2020-01-01T00:00:00.123Z"},"https://auth.x.ai::one":{"key":"fixture-one","expires_at":"2040-01-01T00:00:00Z"},"https://auth.x.ai::two":{"key":"fixture-two","expires_at":"2040-01-01T00:00:00.123Z"}}"#.utf8)
        let accounts = try BuildAuthReader.accounts(from: data, now: now)
        XCTAssertEqual(accounts.map(\.id), ["https://auth.x.ai::one", "https://auth.x.ai::two"])
        // The host must ask for a selection instead of picking the first of two accounts.
        XCTAssertEqual(accounts.count, 2)
    }

    func testSnapshotCacheContainsDisplayDataWithoutRawPayloadOrSecrets() throws {
        let snapshot = try BuildUsageParser.parse(Data(#"{"config":{"creditUsagePercent":24,"access_token":"never-store-this-fixture","accountId":"private-account-fixture"},"rawSecret":"private-response-fixture"}"#.utf8))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = UsageSnapshotStore.fileURL(applicationSupport: directory)
        try UsageSnapshotStore.write(UsageSnapshots(build: snapshot), to: url)
        let json = String(decoding: try Data(contentsOf: url), as: UTF8.self)
        XCTAssertFalse(json.contains("never-store-this-fixture"))
        XCTAssertFalse(json.contains("private-account-fixture"))
        XCTAssertFalse(json.contains("private-response-fixture"))
        XCTAssertEqual(UsageSnapshotStore.read(from: url)?.build.windows.first?.usedPercent, 24)
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
    }

    func testExpiredAndUnknownLimitsAreNotPresentedAsFreshOrFull() {
        let now = Date()
        let expired = UsageWindow(id: "fast", remaining: 10, resetAt: now.addingTimeInterval(-1))
        XCTAssertTrue(expired.hasReset(at: now))
        XCTAssertTrue(UsageSnapshot(product: .chat, status: .available, fetchedAt: now, windows: [expired]).isStale(at: now))
        XCTAssertNil(UsageWindow(id: "expert", remaining: 20).remainingPercent)
        XCTAssertNil(UsageWindow(id: "unknown").remainingPercent)
        XCTAssertTrue(UsageSnapshot(product: .chat, status: .unavailable, fetchedAt: now).isStale(at: now))
    }
}
