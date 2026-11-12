import Foundation

public enum CreditsUsageError: Error { case invalidResponse }

/// The account endpoint and CLI proxy return the same shared-allowance payload.
public enum CreditsUsageParser {
    private struct Cent: Decodable {
        let val: Int64
        enum CodingKeys: String, CodingKey { case val }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            if !container.contains(.val) {
                val = 0
            } else if let number = try? container.decode(Int64.self, forKey: .val) {
                val = number
            } else {
                let string = try container.decode(String.self, forKey: .val)
                guard let number = Int64(string) else { throw CreditsUsageError.invalidResponse }
                val = number
            }
        }
    }
    private struct Period: Decodable { let type: String?; let end: String? }
    private struct Product: Decodable { let product: String; let usagePercent: Double? }
    private struct Config: Decodable {
        let creditUsagePercent: Double?
        let currentPeriod: Period?
        let billingPeriodEnd: String?
        let prepaidBalance: Cent?
        let monthlyLimit: Cent?
        let used: Cent?
        let productUsage: [Product]?
    }
    private struct Response: Decodable { let config: Config }

    public static func parse(_ data: Data, product: UsageProduct, now: Date = Date()) throws -> UsageSnapshot {
        let config = try JSONDecoder().decode(Response.self, from: data).config
        var percent = config.creditUsagePercent
        if percent == nil, config.currentPeriod?.type != "USAGE_PERIOD_TYPE_WEEKLY",
           let budget = config.monthlyLimit?.val, budget > 0,
           let used = config.used?.val, used >= 0 { percent = Double(used) / Double(budget) * 100 }
        if let percent, !percent.isFinite || !(0...100).contains(percent) { throw CreditsUsageError.invalidResponse }
        let reset = date(config.currentPeriod?.end ?? config.billingPeriodEnd)
        let period = config.currentPeriod?.type == "USAGE_PERIOD_TYPE_WEEKLY" ? "Weekly pool"
            : config.currentPeriod?.type == "USAGE_PERIOD_TYPE_MONTHLY" || config.monthlyLimit != nil ? "Monthly pool" : "Shared pool"
        guard percent != nil || reset != nil || config.prepaidBalance != nil else { throw CreditsUsageError.invalidResponse }
        let products = (config.productUsage ?? []).compactMap { item -> ProductUsage? in
            guard let value = item.usagePercent, value.isFinite, (0...100).contains(value), value > 0 else { return nil }
            return ProductUsage(id: item.product, percent: value)
        }
        // Shares describe the same allowance, not additional independent limits.
        let validProducts = percent.map { abs(products.reduce(0) { $0 + $1.percent } - $0) <= 1 } == true
        return UsageSnapshot(product: product, status: .available, fetchedAt: now,
                             windows: [.init(id: "credits", usedPercent: percent, resetAt: reset, period: period)],
                             prepaidCents: config.prepaidBalance?.val, products: validProducts ? products : [])
    }

    private static func date(_ value: String?) -> Date? {
        guard let value else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: value) ?? ISO8601DateFormatter().date(from: value)
    }
}
