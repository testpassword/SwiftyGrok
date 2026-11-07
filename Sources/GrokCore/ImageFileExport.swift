#if os(macOS)
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Original image bytes, ready for a Finder file promise or Quick Look.
public struct ImageFileExport: Sendable {
    public let data: Data
    public let filename: String
    public let typeIdentifier: String

    public init(data: Data, name: String) throws {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let identifier = CGImageSourceGetType(source), let type = UTType(identifier as String),
              type.conforms(to: .image) else { throw URLError(.cannotDecodeContentData) }
        self.data = data
        typeIdentifier = type.identifier
        let base = ((name as NSString).lastPathComponent as NSString).deletingPathExtension
        let forbidden = CharacterSet.controlCharacters.union(CharacterSet(charactersIn: "/:\\"))
        var safe = String(base.unicodeScalars.filter { !forbidden.contains($0) }).trimmingCharacters(in: .whitespacesAndNewlines)
        while safe.utf8.count > 180 { safe.removeLast() }
        if safe.isEmpty || safe == "." || safe == ".." { safe = L10n.text("Image") }
        filename = safe + "." + (type.preferredFilenameExtension ?? "img")
    }

    public func write(to url: URL) throws {
        // Finder supplies the resolved destination, including conflict handling.
        // Never overwrite an existing file if a receiver supplies an occupied URL.
        try data.write(to: url, options: .withoutOverwriting)
    }
}
#endif
