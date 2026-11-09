import Foundation
import XCTest
#if os(macOS)
import UniformTypeIdentifiers
#endif
@testable import GrokCore

final class FileTransferTests: XCTestCase {
    func testShareHandoffPreservesActualBytesAndKeepsNamesOutOfTheRequestURL() throws {
        let files = [SharedFile(name: "Отчёт #1 & 50% +.md", mimeType: "text/markdown", data: Data("Actual contents".utf8)),
                     SharedFile(name: "image.png", mimeType: "image/png", data: Data([0, 1, 2, 255]))]
        XCTAssertEqual(try ShareAttachmentHandoff.decode(ShareAttachmentHandoff.encode(files)), files)
        let id = UUID()
        let request = ShareAttachmentHandoff.requestURL(id)
        XCTAssertEqual(ShareAttachmentHandoff.requestID(request), id)
        XCTAssertFalse(request.absoluteString.contains("image"))
        XCTAssertFalse(request.absoluteString.contains("Actual"))
    }

    func testShareHandoffRejectsMalformedRequestsAndInvalidAttachments() throws {
        let id = UUID().uuidString
        for value in [
            "https://share/attach?request=\(id)", "swiftygrok://other/attach?request=\(id)",
            "swiftygrok://share/other?request=\(id)", "swiftygrok://share/attach?request=invalid",
            "swiftygrok://share/attach?request=\(id)&request=\(id)",
            "swiftygrok://user@share/attach?request=\(id)",
            "swiftygrok://share:123/attach?request=\(id)", "swiftygrok://share/attach?request=\(id)#fragment"
        ] {
            XCTAssertNil(ShareAttachmentHandoff.requestID(URL(string: value)!), value)
        }
        for name in ["", "..", "/private/file.txt", "../file.txt", "nul\0.txt"] {
            let files = [SharedFile(name: name, mimeType: "text/plain", data: Data())]
            XCTAssertThrowsError(try ShareAttachmentHandoff.encode(files))
            let data = try PropertyListEncoder().encode(files)
            XCTAssertThrowsError(try ShareAttachmentHandoff.decode(data))
        }
        XCTAssertThrowsError(try ShareAttachmentHandoff.encode([]))
        XCTAssertThrowsError(try ShareAttachmentHandoff.encode(Array(repeating: SharedFile(name: "file", mimeType: "text/plain", data: Data()), count: 101)))
        XCTAssertThrowsError(try ShareAttachmentHandoff.encode([SharedFile(name: "large", mimeType: "application/octet-stream", data: Data(repeating: 0, count: ShareAttachmentHandoff.maximumTotalSize + 1))]))
        XCTAssertThrowsError(try ShareAttachmentHandoff.decode(Data("not a property list".utf8)))
    }

    func testFileReaderChecksTheWholeBatchAndSkipsDirectoriesAndDuplicates() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = directory.appendingPathComponent("one.txt")
        let second = directory.appendingPathComponent("two.txt")
        try Data("1234".utf8).write(to: first)
        try Data("5678".utf8).write(to: second)
        let files = try DraftFileReader.read([directory, first, first, second], maximumBytes: 8)
        XCTAssertEqual(files.map(\.name), ["one.txt", "two.txt"])
        XCTAssertEqual(files.map(\.data), [Data("1234".utf8), Data("5678".utf8)])
        XCTAssertThrowsError(try DraftFileReader.read([first, second], maximumBytes: 7)) {
            guard case ClientFailure.filesTooLarge = $0 else { return XCTFail("Expected the total-size limit") }
        }
        XCTAssertThrowsError(try DraftFileReader.read([URL(string: "https://example.com/file.txt")!], maximumBytes: 8))
    }

    #if os(macOS)
    func testShareHandoffCanOnlyBeConsumedOnceAndCanBeDiscarded() throws {
        let files = [SharedFile(name: "selected.md", mimeType: "text/markdown", data: Data("Contents".utf8))]
        let request = try ShareAttachmentHandoff.prepare(files)
        defer { ShareAttachmentHandoff.discard(request) }
        XCTAssertEqual(ShareAttachmentHandoff.takeFiles(from: request), files)
        XCTAssertTrue(ShareAttachmentHandoff.takeFiles(from: request).isEmpty)
        let discarded = try ShareAttachmentHandoff.prepare(files)
        ShareAttachmentHandoff.discard(discarded)
        XCTAssertTrue(ShareAttachmentHandoff.takeFiles(from: discarded).isEmpty)
    }

    func testShareReaderLoadsActualFileURLContentsAndEnforcesSize() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).txt")
        let data = Data("File contents, not its name".utf8)
        try data.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let provider = NSItemProvider(item: url as NSURL, typeIdentifier: UTType.fileURL.identifier)
        let file = try await SharedFileReader.load(provider, maximumBytes: data.count)
        XCTAssertEqual(file.data, data)
        XCTAssertEqual(file.name, url.lastPathComponent)
        XCTAssertEqual(file.mimeType, "text/plain")
        do { _ = try await SharedFileReader.load(provider, maximumBytes: data.count - 1); XCTFail("Must reject oversized files") }
        catch {}
        let folder = NSItemProvider(item: url.deletingLastPathComponent() as NSURL, typeIdentifier: UTType.fileURL.identifier)
        do { _ = try await SharedFileReader.load(folder, maximumBytes: 100); XCTFail("Must reject directories") }
        catch {}
    }

    func testShareReaderPreservesFileRepresentationBeforeProviderDeletesIt() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let data = Data([0x89, 0x50, 0x4e, 0x47])
        try data.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let provider = NSItemProvider()
        provider.suggestedName = "photo"
        provider.registerFileRepresentation(forTypeIdentifier: UTType.png.identifier, fileOptions: [], visibility: .all) { completion in
            completion(url, false, nil)
            return nil
        }
        let file = try await SharedFileReader.load(provider, maximumBytes: data.count)
        try FileManager.default.removeItem(at: url)
        XCTAssertEqual(file.data, data)
        XCTAssertEqual(file.name, "photo.png")
        XCTAssertEqual(file.mimeType, "image/png")
    }

    func testImageExportPreservesOriginalBytesAndNeverOverwrites() throws {
        let data = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+/l9sAAAAASUVORK5CYII=")!
        let file = try ImageFileExport(data: data, name: "../../photo:original.jpg")
        XCTAssertEqual(file.typeIdentifier, "public.png")
        XCTAssertEqual(file.filename, "photooriginal.png")
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent(file.filename)
        try file.write(to: url)
        XCTAssertEqual(try Data(contentsOf: url), data)
        XCTAssertThrowsError(try file.write(to: url))
        XCTAssertEqual(try Data(contentsOf: url), data)
        let long = try ImageFileExport(data: data, name: String(repeating: "🌿", count: 100) + ".jpg")
        XCTAssertLessThan(long.filename.utf8.count, 255)
        XCTAssertThrowsError(try ImageFileExport(data: Data("not an image".utf8), name: "image.png"))
    }
    #endif
}
