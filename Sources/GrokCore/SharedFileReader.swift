#if os(macOS)
import Foundation
import UniformTypeIdentifiers

/// Read provider-owned files before their temporary representations disappear.
public enum SharedFileReader {
    public static func load(_ provider: NSItemProvider, maximumBytes: Int) async throws -> SharedFile {
        let suggestedName = provider.suggestedName
        if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            return try await withCheckedThrowingContinuation { continuation in
                provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, error in
                    do {
                        if let error { throw error }
                        let url: URL?
                        if let value = item as? URL { url = value }
                        else if let data = item as? Data { url = URL(dataRepresentation: data, relativeTo: nil) }
                        else if let value = item as? String { url = URL(string: value) }
                        else { url = nil }
                        guard let url else {
                            throw failure("Could not read the shared file. Please try again.")
                        }
                        continuation.resume(returning: try read(url, suggestedName: suggestedName,
                                                                typeIdentifier: nil, maximumBytes: maximumBytes))
                    } catch { continuation.resume(throwing: error) }
                }
            }
        }
        guard let identifier = provider.registeredTypeIdentifiers.first(where: {
            guard let type = UTType($0) else { return false }
            return type.conforms(to: .data) && !type.conforms(to: .url) && !type.conforms(to: .directory)
        }) else { throw failure("Choose files or photos to add to SwiftyGrok.") }
        return try await withCheckedThrowingContinuation { continuation in
            provider.loadFileRepresentation(forTypeIdentifier: identifier) { url, error in
                do {
                    if let error { throw error }
                    guard let url else { throw failure("Could not read the shared file. Please try again.") }
                    // The temporary file is deleted as soon as this callback returns.
                    continuation.resume(returning: try read(url, suggestedName: suggestedName,
                                                            typeIdentifier: identifier, maximumBytes: maximumBytes))
                } catch { continuation.resume(throwing: error) }
            }
        }
    }

    private static func read(_ url: URL, suggestedName: String?, typeIdentifier: String?, maximumBytes: Int) throws -> SharedFile {
        guard url.isFileURL, url.host == nil || url.host == "" || url.host == "localhost" else {
            throw failure("Could not read the shared file. Please try again.")
        }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        var result: Result<SharedFile, Error>?
        var coordinationError: NSError?
        NSFileCoordinator().coordinate(readingItemAt: url, options: [], error: &coordinationError) { file in
            result = Result {
                let values = try file.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey, .contentTypeKey])
                guard values.isRegularFile == true else { throw failure("Choose files or photos to add to SwiftyGrok.") }
                guard (values.fileSize ?? 0) <= maximumBytes else { throw failure("Shared files must not exceed 50 MB in total.") }
                let handle = try FileHandle(forReadingFrom: file)
                defer { try? handle.close() }
                var data = Data()
                while let chunk = try handle.read(upToCount: min(1_048_576, maximumBytes - data.count + 1)), !chunk.isEmpty {
                    data.append(chunk)
                    guard data.count <= maximumBytes else { throw failure("Shared files must not exceed 50 MB in total.") }
                }
                let type = typeIdentifier.flatMap(UTType.init) ?? values.contentType
                var name = ((suggestedName?.isEmpty == false ? suggestedName! : file.lastPathComponent) as NSString).lastPathComponent
                if (name as NSString).pathExtension.isEmpty, let ext = type?.preferredFilenameExtension { name += ".\(ext)" }
                return SharedFile(name: name, mimeType: type?.preferredMIMEType ?? "application/octet-stream", data: data)
            }
        }
        if let coordinationError { throw coordinationError }
        guard let result else { throw failure("Could not read the shared file. Please try again.") }
        return try result.get()
    }

    private final class Resources {}

    private static func failure(_ key: String) -> NSError {
        #if SWIFT_PACKAGE
        let bundle = Bundle.module
        #else
        let bundle = Bundle(for: Resources.self)
        #endif
        return NSError(domain: "app.swiftygrok.share", code: 1,
                       userInfo: [NSLocalizedDescriptionKey: NSLocalizedString(key, bundle: bundle, comment: "Share error")])
    }
}
#endif
