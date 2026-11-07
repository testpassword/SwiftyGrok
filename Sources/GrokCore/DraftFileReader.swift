import Foundation
#if canImport(UniformTypeIdentifiers)
import UniformTypeIdentifiers
#endif

enum DraftFileReader {
    static func read(_ urls: [URL], maximumBytes: Int) throws -> [DraftFile] {
        var files: [DraftFile] = []
        var remaining = maximumBytes
        var seen = Set<URL>()
        for url in urls where seen.insert(url.standardizedFileURL).inserted {
            guard url.isFileURL else { throw URLError(.unsupportedURL) }
            #if os(macOS)
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            #endif
            let values = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
            guard values.isRegularFile == true else { continue }
            guard (values.fileSize ?? 0) <= remaining else { throw ClientFailure.filesTooLarge }
            let data = try Data(contentsOf: url)
            guard data.count <= remaining else { throw ClientFailure.filesTooLarge }
            remaining -= data.count
            #if canImport(UniformTypeIdentifiers)
            let mime = try url.resourceValues(forKeys: [.contentTypeKey]).contentType?.preferredMIMEType
            #else
            let mime: String? = nil
            #endif
            files.append(DraftFile(name: url.lastPathComponent, mimeType: mime ?? "application/octet-stream", data: data))
        }
        return files
    }
}
