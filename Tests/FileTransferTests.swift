import Foundation
import XCTest
@testable import GrokCore

final class FileTransferTests: XCTestCase {
    func testFinderHandoffPreservesFileNamesAndKeepsPathsOutOfTheRequestURL() throws {
        let files = [URL(fileURLWithPath: "/fixture/Отчёт #1 & 50% +.md"), URL(fileURLWithPath: "/fixture/image.png")]
        XCTAssertEqual(try FinderAttachmentHandoff.decode(FinderAttachmentHandoff.encode(files)), files)
        let id = UUID()
        let request = FinderAttachmentHandoff.requestURL(id)
        XCTAssertEqual(FinderAttachmentHandoff.requestID(request), id)
        XCTAssertFalse(request.absoluteString.contains("fixture"))
    }

    func testFinderHandoffRejectsMalformedRequestsAndNonLocalFiles() throws {
        let id = UUID().uuidString
        for value in [
            "https://finder/attach?request=\(id)", "swiftygrok://other/attach?request=\(id)",
            "swiftygrok://finder/other?request=\(id)", "swiftygrok://finder/attach?request=invalid",
            "swiftygrok://finder/attach?request=\(id)&request=\(id)",
            "swiftygrok://user@finder/attach?request=\(id)",
            "swiftygrok://finder:123/attach?request=\(id)", "swiftygrok://finder/attach?request=\(id)#fragment"
        ] {
            XCTAssertNil(FinderAttachmentHandoff.requestID(URL(string: value)!), value)
        }
        for files in [[], [URL(string: "https://example.com/file.txt")!],
                      [URL(string: "file://remote/fixture/file.txt")!], [URL(string: "relative.txt")!]] as [[URL]] {
            XCTAssertThrowsError(try FinderAttachmentHandoff.encode(files))
            let data = try JSONEncoder().encode(files)
            XCTAssertThrowsError(try FinderAttachmentHandoff.decode(data))
        }
        XCTAssertThrowsError(try FinderAttachmentHandoff.decode(Data("not JSON".utf8)))
        XCTAssertThrowsError(try FinderAttachmentHandoff.decode(Data(repeating: 0, count: 1_048_577)))
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
    func testFinderHandoffCanOnlyBeConsumedOnce() throws {
        let files = [URL(fileURLWithPath: "/fixture/selected.md")]
        let request = try FinderAttachmentHandoff.prepare(files)
        defer { FinderAttachmentHandoff.discard(request) }
        XCTAssertEqual(FinderAttachmentHandoff.takeFiles(from: request), files)
        XCTAssertTrue(FinderAttachmentHandoff.takeFiles(from: request).isEmpty)
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
