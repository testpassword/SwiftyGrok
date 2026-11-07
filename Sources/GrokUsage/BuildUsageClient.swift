import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public enum BuildUsageError: Error { case loginRequired, ambiguousAccount, invalidResponse }

public struct BuildAccount: Sendable, Identifiable {
    public let id: String
    public let label: String
    fileprivate let token: String
    fileprivate let userID: String?
}

public enum BuildAuthReader {
    /// Read only the official first-party OAuth scope. Never use API keys or
    /// unrelated enterprise/provider entries from the CLI credential store.
    public static func accounts(from data: Data, now: Date = Date()) throws -> [BuildAccount] {
        guard data.count <= 1_048_576, let values = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw BuildUsageError.loginRequired
        }
        return values.keys.sorted().compactMap { scope in
            guard scope.hasPrefix("https://auth.x.ai::"), let value = values[scope] as? [String: Any],
                  let token = value["key"] as? String, !token.isEmpty, !token.hasPrefix("xai-"),
                  token.unicodeScalars.allSatisfy({ $0.value > 32 && $0.value < 127 }) else { return nil }
            guard value["auth_mode"] as? String != "api_key" else { return nil }
            if let expiry = value["expires_at"] as? Double, expiry <= now.timeIntervalSince1970 { return nil }
            if let expiry = value["expires_at"] as? String {
                guard let date = expirationDate(expiry), date > now else { return nil }
            }
            let email = value["email"] as? String
            return BuildAccount(id: scope, label: email?.isEmpty == false ? email! : UsageText.text("Grok Build account"),
                                token: token, userID: value["user_id"] as? String)
        }
    }

    private static func expirationDate(_ value: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: value) ?? ISO8601DateFormatter().date(from: value)
    }
}

public enum BuildUsageParser {
    private struct Cent: Decodable { let val: Int64; enum CodingKeys: String, CodingKey { case val }
        init(from decoder: Decoder) throws { val = try decoder.container(keyedBy: CodingKeys.self).decodeIfPresent(Int64.self, forKey: .val) ?? 0 }
    }
    private struct Period: Decodable { let type: String?; let start: String?; let end: String? }
    private struct Product: Decodable { let product: String; let usagePercent: Double? }
    private struct Config: Decodable {
        let creditUsagePercent: Double?
        let currentPeriod: Period?
        let billingPeriodStart: String?
        let billingPeriodEnd: String?
        let prepaidBalance: Cent?
        let monthlyLimit: Cent?
        let used: Cent?
        let productUsage: [Product]?
    }
    private struct Response: Decodable { let config: Config }

    public static func parse(_ data: Data, now: Date = Date()) throws -> UsageSnapshot {
        let config = try JSONDecoder().decode(Response.self, from: data).config
        var percent = config.creditUsagePercent
        if percent == nil, config.currentPeriod?.type != "USAGE_PERIOD_TYPE_WEEKLY",
           let budget = config.monthlyLimit?.val, budget > 0,
           let used = config.used?.val, used >= 0 { percent = Double(used) / Double(budget) * 100 }
        if let percent, !percent.isFinite || !(0...100).contains(percent) { throw BuildUsageError.invalidResponse }
        let reset = date(config.currentPeriod?.end ?? config.billingPeriodEnd)
        let period = config.currentPeriod?.type == "USAGE_PERIOD_TYPE_WEEKLY" ? "Weekly pool"
            : config.currentPeriod?.type == "USAGE_PERIOD_TYPE_MONTHLY" || config.monthlyLimit != nil ? "Monthly pool" : "Shared pool"
        guard percent != nil || reset != nil || config.prepaidBalance != nil else { throw BuildUsageError.invalidResponse }
        let products = (config.productUsage ?? []).compactMap { item -> ProductUsage? in
            guard let value = item.usagePercent, value.isFinite, (0...100).contains(value), value > 0 else { return nil }
            return ProductUsage(id: item.product, percent: value)
        }
        // Shares describe the same allowance, not additional independent limits.
        let validProducts = percent.map { abs(products.reduce(0) { $0 + $1.percent } - $0) <= 1 } == true
        return UsageSnapshot(product: .build, status: .available, fetchedAt: now,
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

/// No redirects, shared cookies, disk cache, raw response logging or credential persistence.
public final class BuildUsageClient: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    public override init() { super.init() }

    public func fetch(account: BuildAccount) async throws -> UsageSnapshot {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil; configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = 20; configuration.timeoutIntervalForResource = 25
        let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: URL(string: "https://cli-chat-proxy.grok.com/v1/billing?format=credits")!)
        request.setValue("Bearer \(account.token)", forHTTPHeaderField: "Authorization")
        request.setValue("xai-grok-cli", forHTTPHeaderField: "X-XAI-Token-Auth")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("cli", forHTTPHeaderField: "x-grok-client-mode")
        if let id = account.userID, !id.contains("\r"), !id.contains("\n") { request.setValue(id, forHTTPHeaderField: "x-userid") }
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw BuildUsageError.invalidResponse }
        if http.statusCode == 401 { throw BuildUsageError.loginRequired }
        guard http.statusCode == 200, data.count <= 1_048_576 else { throw BuildUsageError.invalidResponse }
        return try BuildUsageParser.parse(data)
    }

    public func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                           newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
