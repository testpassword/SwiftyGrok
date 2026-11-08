import Foundation
#if os(macOS)
import AppKit
#endif

/// The extension passes a one-time request, without opening files in its sandbox.
/// File paths stay off the URL and the user's general pasteboard.
public enum FinderAttachmentHandoff {
    private static let type = "app.swiftygrok.finder-attachments"
    private static let maximumRequestBytes = 1_048_576

    static func requestURL(_ id: UUID) -> URL {
        URL(string: "swiftygrok://finder/attach?request=\(id.uuidString)")!
    }

    static func requestID(_ url: URL) -> UUID? {
        guard let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              parts.scheme == "swiftygrok", parts.host == "finder", parts.path == "/attach",
              parts.user == nil, parts.password == nil, parts.port == nil, parts.fragment == nil,
              let query = parts.queryItems, query.count == 1, query[0].name == "request",
              let value = query[0].value else { return nil }
        return UUID(uuidString: value)
    }

    static func encode(_ files: [URL]) throws -> Data {
        guard !files.isEmpty, files.allSatisfy(isLocalFile) else { throw URLError(.badURL) }
        let data = try JSONEncoder().encode(files)
        guard data.count <= maximumRequestBytes else { throw URLError(.dataLengthExceedsMaximum) }
        return data
    }

    static func decode(_ data: Data) throws -> [URL] {
        guard data.count <= maximumRequestBytes else { throw URLError(.dataLengthExceedsMaximum) }
        let files = try JSONDecoder().decode([URL].self, from: data)
        guard !files.isEmpty, files.allSatisfy(isLocalFile) else { throw URLError(.badURL) }
        return files
    }

    private static func isLocalFile(_ url: URL) -> Bool {
        url.isFileURL && (url.host == nil || url.host == "" || url.host == "localhost") &&
            url.path.hasPrefix("/") && url.query == nil && url.fragment == nil
    }

    #if os(macOS)
    public static func prepare(_ files: [URL]) throws -> URL {
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

    public static func takeFiles(from request: URL) -> [URL] {
        guard let id = requestID(request) else { return [] }
        let board = pasteboard(id)
        defer { board.clearContents(); board.releaseGlobally() }
        guard let data = board.data(forType: NSPasteboard.PasteboardType(type)),
              let files = try? decode(data) else {
            NSLog("SwiftyGrok Finder handoff failed: missing or invalid attachment request")
            return []
        }
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
