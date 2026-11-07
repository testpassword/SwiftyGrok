import Foundation

public struct SessionCredentials: Codable, Equatable, Sendable {
    public let cookies: [String: String]
    public let userAgent: String

    public static let defaultUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15"

    public init(cookies: [String: String], userAgent: String = Self.defaultUserAgent) throws {
        // Only a cookie name/value pair can enter a request header. Reject CR/LF and separators.
        let names = CharacterSet(charactersIn: "()<>@,;:\\\"/[]?={} \t\r\n")
        guard !cookies.isEmpty, cookies.allSatisfy({ name, value in
            !name.isEmpty && name.unicodeScalars.allSatisfy { $0.isASCII && !names.contains($0) && $0.value > 31 && $0.value != 127 }
            && value.unicodeScalars.allSatisfy { $0.value >= 32 && $0.value != 127 && $0 != ";" && $0 != "\r" && $0 != "\n" }
        }), ["sso", "sso-rw"].contains(where: { !(cookies[$0] ?? "").isEmpty }),
        !userAgent.isEmpty, userAgent.unicodeScalars.allSatisfy({ $0 != "\r" && $0 != "\n" }) else {
            throw ClientFailure.invalidCookies
        }
        self.cookies = cookies
        self.userAgent = userAgent
    }

    public static func isGrokDomain(_ domain: String) -> Bool {
        let domain = domain.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
        return domain == "grok.com" || domain.hasSuffix(".grok.com")
    }

    public static func importing(_ text: String, userAgent: String = Self.defaultUserAgent) throws -> Self {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let data = trimmed.data(using: .utf8), trimmed.hasPrefix("{") || trimmed.hasPrefix("[") {
            if let dictionary = try? JSONDecoder().decode([String: String].self, from: data) {
                return try Self(cookies: dictionary, userAgent: userAgent)
            }
            struct Cookie: Decodable {
                let name: String
                let value: String
                let domain: String?
                let expirationDate: Double?
            }
            if let records = try? JSONDecoder().decode([Cookie].self, from: data) {
                var cookies: [String: String] = [:]
                for record in records where record.domain.map(isGrokDomain) ?? false {
                    guard record.expirationDate.map({ $0 <= 0 || $0 > Date().timeIntervalSince1970 }) ?? true else { continue }
                    cookies[record.name] = record.value
                }
                return try Self(cookies: cookies, userAgent: userAgent)
            }
            throw ClientFailure.invalidCookies
        }
        let header = trimmed.lowercased().hasPrefix("cookie:") ? String(trimmed.dropFirst(7)) : trimmed
        var cookies: [String: String] = [:]
        for pair in header.split(separator: ";") {
            let parts = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2 else { throw ClientFailure.invalidCookies }
            cookies[parts[0].trimmingCharacters(in: .whitespaces)] = parts[1].trimmingCharacters(in: .whitespaces)
        }
        return try Self(cookies: cookies, userAgent: userAgent)
    }
}
