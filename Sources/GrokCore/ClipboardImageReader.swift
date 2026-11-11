#if os(macOS)
import AppKit
import ImageIO
import UniformTypeIdentifiers

public enum ClipboardImageReader {
    private static let types: [NSPasteboard.PasteboardType] = [
        .png, .tiff, .init(UTType.jpeg.identifier), .init(UTType.heic.identifier)
    ]

    /// Inspect formats without reading the user's image during menu validation.
    @MainActor public static func containsImages(on pasteboard: NSPasteboard) -> Bool {
        pasteboard.availableType(from: types) != nil
    }

    /// Snapshot each clipboard item once, before asynchronous draft importing.
    /// Multiple representations of one screenshot must not add duplicate files.
    @MainActor public static func imageData(from pasteboard: NSPasteboard) -> [Data] {
        if let items = pasteboard.pasteboardItems, !items.isEmpty {
            return items.compactMap { item in
                guard item.availableType(from: types) != nil else { return nil }
                return types.lazy.compactMap { item.data(forType: $0) }.first { !$0.isEmpty } ?? Data()
            }
        }
        guard containsImages(on: pasteboard) else { return [] }
        return [types.lazy.compactMap { pasteboard.data(forType: $0) }.first { !$0.isEmpty } ?? Data()]
    }

    /// ImageIO conversion can run off the main thread and needs no temporary file.
    public static func read(_ images: [Data], maximumBytes: Int = DraftFile.maximumTotalSize) throws -> [DraftFile] {
        var remaining = maximumBytes
        return try images.map { data in
            guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { throw URLError(.cannotDecodeContentData) }
            let isPNG = (CGImageSourceGetType(source) as String?) == UTType.png.identifier
            if isPNG, data.count > remaining { throw ClientFailure.filesTooLarge }
            guard let image = CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCache: false] as CFDictionary) else {
                throw URLError(.cannotDecodeContentData)
            }
            let png: Data
            if isPNG { png = data }
            else {
                let encoded = NSMutableData()
                guard let destination = CGImageDestinationCreateWithData(encoded, UTType.png.identifier as CFString, 1, nil) else {
                    throw URLError(.cannotDecodeContentData)
                }
                CGImageDestinationAddImage(destination, image, nil)
                guard CGImageDestinationFinalize(destination) else { throw URLError(.cannotDecodeContentData) }
                png = encoded as Data
            }
            guard png.count <= remaining else { throw ClientFailure.filesTooLarge }
            remaining -= png.count
            return DraftFile(name: "Image-\(UUID().uuidString.prefix(8)).png", mimeType: "image/png", data: png)
        }
    }
}
#endif
