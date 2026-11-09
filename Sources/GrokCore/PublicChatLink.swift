import Foundation
#if os(macOS)
import AppKit
import UniformTypeIdentifiers
#endif

/// Only Grok's public share routes are accepted. The token is never interpreted
/// as a URL or an arbitrary API path.
public struct PublicChatLink: Equatable, Sendable {
    public let id: String

    public init?(url: URL) {
        guard let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              parts.scheme?.lowercased() == "https",
              ["grok.com", "www.grok.com"].contains(parts.host?.lowercased() ?? ""),
              parts.user == nil, parts.password == nil, parts.port == nil,
              parts.path.hasPrefix("/share/") else { return nil }
        let token = String(parts.path.dropFirst("/share/".count))
        guard Self.validToken(token) else { return nil }
        id = token
    }

    public init?(handoffURL url: URL) {
        guard let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              parts.scheme == "swiftygrok", parts.host == "public-chat",
              parts.user == nil, parts.password == nil, parts.port == nil,
              parts.query == nil, parts.fragment == nil, parts.path.hasPrefix("/") else { return nil }
        let token = String(parts.path.dropFirst())
        guard Self.validToken(token) else { return nil }
        id = token
    }

    private static func validToken(_ token: String) -> Bool {
        !token.isEmpty && token.utf8.count <= 2048 && token.utf8.allSatisfy {
            (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || $0 == 45 || $0 == 95
        }
    }

    public var url: URL { URL(string: "https://grok.com/share/\(id)")! }
    public var handoffURL: URL { URL(string: "swiftygrok://public-chat/\(id)")! }

    #if os(macOS)
    public static func load(from provider: NSItemProvider) async throws -> PublicChatLink {
        try await withCheckedThrowingContinuation { continuation in
            provider.loadItem(forTypeIdentifier: UTType.url.identifier, options: nil) { item, error in
                if let error { continuation.resume(throwing: error); return }
                let url = (item as? URL)
                    ?? (item as? Data).flatMap { $0.count <= 8192 ? URL(dataRepresentation: $0, relativeTo: nil) : nil }
                    ?? (item as? String).flatMap { $0.utf8.count <= 8192 ? URL(string: $0.trimmingCharacters(in: .whitespacesAndNewlines)) : nil }
                guard let url, let link = PublicChatLink(url: url) else {
                    continuation.resume(throwing: URLError(.unsupportedURL)); return
                }
                continuation.resume(returning: link)
            }
        }
    }
    #endif
}
