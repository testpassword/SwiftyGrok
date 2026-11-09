import Foundation
#if os(macOS)
import AppKit
#endif

public struct SharedFile: Codable, Equatable, Sendable {
    public let name: String
    public let mimeType: String
    public let data: Data

    public init(name: String, mimeType: String, data: Data) {
        self.name = name
        self.mimeType = mimeType
        self.data = data
    }
}

/// Transfer file bytes before the provider's temporary URLs expire. The request
/// URL contains only a nonce; neither file paths nor the general clipboard are used.
public enum ShareAttachmentHandoff {
    public static let maximumTotalSize = 50 * 1024 * 1024
    public static let maximumFileCount = 100
    private static let maximumRequestBytes = maximumTotalSize + 1_048_576
    private static let type = "app.swiftygrok.shared-attachments"

    static func requestURL(_ id: UUID) -> URL {
        URL(string: "swiftygrok://share/attach?request=\(id.uuidString)")!
    }

    static func requestID(_ url: URL) -> UUID? {
        guard let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              parts.scheme == "swiftygrok", parts.host == "share", parts.path == "/attach",
              parts.user == nil, parts.password == nil, parts.port == nil, parts.fragment == nil,
              let query = parts.queryItems, query.count == 1, query[0].name == "request",
              let value = query[0].value else { return nil }
        return UUID(uuidString: value)
    }

    private static func validate(_ files: [SharedFile]) throws {
        guard !files.isEmpty, files.count <= maximumFileCount else { throw URLError(.badURL) }
        var remaining = maximumTotalSize
        for file in files {
            guard !file.name.isEmpty, file.name != ".", file.name != "..",
                  !file.name.contains("/"), !file.name.contains("\\"), !file.name.contains("\0"),
                  file.name.utf8.count <= 512, !file.mimeType.isEmpty, file.mimeType.utf8.count <= 256 else {
                throw URLError(.badURL)
            }
            guard file.data.count <= remaining else { throw URLError(.dataLengthExceedsMaximum) }
            remaining -= file.data.count
        }
    }

    static func encode(_ files: [SharedFile]) throws -> Data {
        try validate(files)
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        let data = try encoder.encode(files)
        guard data.count <= maximumRequestBytes else { throw URLError(.dataLengthExceedsMaximum) }
        return data
    }

    static func decode(_ data: Data) throws -> [SharedFile] {
        guard data.count <= maximumRequestBytes else { throw URLError(.dataLengthExceedsMaximum) }
        let files = try PropertyListDecoder().decode([SharedFile].self, from: data)
        try validate(files)
        return files
    }

    #if os(macOS)
    public static func prepare(_ files: [SharedFile]) throws -> URL {
        let data = try encode(files)
        let id = UUID()
        let board = pasteboard(id)
        board.prepareForNewContents(with: .currentHostOnly)
        guard board.setData(data, forType: NSPasteboard.PasteboardType(type)) else {
            board.releaseGlobally()
            throw URLError(.cannotCreateFile)
        }
        return requestURL(id)
    }

    public static func takeFiles(from request: URL) -> [SharedFile] {
        guard let id = requestID(request) else { return [] }
        let board = pasteboard(id)
        defer { board.clearContents(); board.releaseGlobally() }
        guard let data = board.data(forType: NSPasteboard.PasteboardType(type)),
              let files = try? decode(data) else { return [] }
        return files
    }

    public static func discard(_ request: URL) {
        guard let id = requestID(request) else { return }
        let board = pasteboard(id)
        board.clearContents()
        board.releaseGlobally()
    }

    private static func pasteboard(_ id: UUID) -> NSPasteboard {
        NSPasteboard(name: NSPasteboard.Name("\(type).\(id.uuidString)"))
    }
    #endif
}
