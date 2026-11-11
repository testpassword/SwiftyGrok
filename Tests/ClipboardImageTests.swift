#if os(macOS)
import AppKit
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import GrokCore

enum ClipboardImageFixtures {
    @MainActor static func data(_ format: NSBitmapImageRep.FileType = .png) throws -> Data {
        let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 12, pixelsHigh: 8,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 32))
        bitmap.size = NSSize(width: 6, height: 4)
        for x in 0..<12 {
            for y in 0..<8 { bitmap.setColor(NSColor(deviceRed: 1, green: 0.2, blue: 0.1, alpha: 0.5), atX: x, y: y) }
        }
        return try XCTUnwrap(bitmap.representation(using: format, properties: [:]))
    }
}

final class ClipboardImageTests: XCTestCase {
    @MainActor func testScreenshotWithPNGAndTIFFRepresentationsAttachesOnceAndKeepsPNGBytes() throws {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let png = try ClipboardImageFixtures.data()
        let item = NSPasteboardItem()
        item.setData(png, forType: .png)
        item.setData(try ClipboardImageFixtures.data(.tiff), forType: .tiff)
        XCTAssertTrue(pasteboard.writeObjects([item]))
        XCTAssertTrue(ClipboardImageReader.containsImages(on: pasteboard))
        let captured = ClipboardImageReader.imageData(from: pasteboard)
        XCTAssertEqual(captured, [png])
        let files = try ClipboardImageReader.read(captured)
        XCTAssertEqual(files.count, 1)
        XCTAssertEqual(files.first?.data, png)
        XCTAssertEqual(files.first?.mimeType, "image/png")
        XCTAssertTrue(files.first?.name.hasSuffix(".png") == true)
    }

    @MainActor func testTIFFScreenshotConvertsToPNGWithoutLosingRetinaPixelsOrTransparency() throws {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        pasteboard.setData(try ClipboardImageFixtures.data(.tiff), forType: .tiff)
        let file = try XCTUnwrap(ClipboardImageReader.read(ClipboardImageReader.imageData(from: pasteboard)).first)
        let source = try XCTUnwrap(CGImageSourceCreateWithData(file.data as CFData, nil))
        XCTAssertEqual(CGImageSourceGetType(source) as String?, UTType.png.identifier)
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        XCTAssertEqual(image.width, 12)
        XCTAssertEqual(image.height, 8)
        let decoded = NSBitmapImageRep(cgImage: image)
        XCTAssertEqual(try XCTUnwrap(decoded.colorAt(x: 0, y: 0)).alphaComponent, 0.5, accuracy: 0.02)
    }

    @MainActor func testPlainTextRemainsAvailableForNativePasting() {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        pasteboard.setString("A plain message", forType: .string)
        XCTAssertFalse(ClipboardImageReader.containsImages(on: pasteboard))
        XCTAssertTrue(ClipboardImageReader.imageData(from: pasteboard).isEmpty)
        XCTAssertEqual(pasteboard.string(forType: .string), "A plain message")
    }

    @MainActor func testEachImageItemIsReadOnceAndCaptureSurvivesClipboardReplacement() throws {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let first = NSPasteboardItem(), second = NSPasteboardItem(), text = NSPasteboardItem()
        first.setData(try ClipboardImageFixtures.data(), forType: .png)
        second.setData(try ClipboardImageFixtures.data(.tiff), forType: .tiff)
        text.setString("Not an image", forType: .string)
        XCTAssertTrue(pasteboard.writeObjects([first, text, second]))
        let captured = ClipboardImageReader.imageData(from: pasteboard)
        pasteboard.clearContents()
        pasteboard.setString("New clipboard contents", forType: .string)
        let files = try ClipboardImageReader.read(captured)
        XCTAssertEqual(files.count, 2)
        XCTAssertNotEqual(files[0].name, files[1].name)
        XCTAssertEqual(pasteboard.string(forType: .string), "New clipboard contents")
    }

    @MainActor func testInvalidImageAndWholeBatchSizeLimitAreReported() throws {
        XCTAssertThrowsError(try ClipboardImageReader.read([Data("not an image".utf8)]))
        let png = try ClipboardImageFixtures.data()
        XCTAssertEqual(try ClipboardImageReader.read([png], maximumBytes: png.count).count, 1)
        XCTAssertThrowsError(try ClipboardImageReader.read([png, png], maximumBytes: png.count * 2 - 1)) {
            XCTAssertEqual($0 as? ClientFailure, .filesTooLarge)
        }
        XCTAssertThrowsError(try ClipboardImageReader.read([png], maximumBytes: 0)) {
            XCTAssertEqual($0 as? ClientFailure, .filesTooLarge)
        }
    }
}
#endif
