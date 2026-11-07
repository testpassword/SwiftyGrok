import AppKit
import SwiftUI
import GrokCore

/// Native file promises let Finder choose a destination before any file is written.
@MainActor struct DraggableChatImage: NSViewRepresentable {
    let image: NSImage
    let file: ImageFileExport?
    let name: String
    let onOpen: () -> Void

    func makeNSView(context: Context) -> ImageDragView {
        let view = ImageDragView()
        view.imageScaling = .scaleProportionallyUpOrDown
        view.setAccessibilityRole(.button)
        return view
    }

    func updateNSView(_ view: ImageDragView, context: Context) {
        view.image = image
        view.file = file
        view.onOpen = onOpen
        view.setAccessibilityLabel(name.isEmpty ? L10n.text("Image") : name)
    }

    final class ImageDragView: NSImageView, NSDraggingSource {
        var file: ImageFileExport?
        var onOpen: (() -> Void)?
        private var startPoint: NSPoint?
        private var dragged = false

        override var acceptsFirstResponder: Bool { true }
        override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: NSView.noIntrinsicMetric) }
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

        override func mouseDown(with event: NSEvent) {
            startPoint = convert(event.locationInWindow, from: nil)
            dragged = false
        }

        override func mouseDragged(with event: NSEvent) {
            guard !dragged, let startPoint, let image, let file else { return }
            let point = convert(event.locationInWindow, from: nil)
            guard hypot(point.x - startPoint.x, point.y - startPoint.y) >= 4 else { return }
            dragged = true
            let delegate = ImageFilePromise(file: file)
            let provider = NSFilePromiseProvider(fileType: file.typeIdentifier, delegate: delegate)
            // The provider outlives the view if Finder writes after the drag ends.
            provider.userInfo = delegate
            let item = NSDraggingItem(pasteboardWriter: provider)
            item.setDraggingFrame(bounds, contents: image)
            beginDraggingSession(with: [item], event: event, source: self)
        }

        override func mouseUp(with event: NSEvent) {
            if !dragged, bounds.contains(convert(event.locationInWindow, from: nil)) { onOpen?() }
            startPoint = nil
        }

        override func keyDown(with event: NSEvent) {
            if event.keyCode == 36 || event.keyCode == 49 { onOpen?() }
            else { super.keyDown(with: event) }
        }

        override func accessibilityPerformPress() -> Bool { onOpen?(); return true }

        func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation { .copy }
    }
}

private final class ImageFilePromise: NSObject, NSFilePromiseProviderDelegate {
    let file: ImageFileExport
    private static let queue: OperationQueue = {
        let queue = OperationQueue()
        queue.qualityOfService = .userInitiated
        queue.maxConcurrentOperationCount = 2
        return queue
    }()

    init(file: ImageFileExport) { self.file = file }

    func filePromiseProvider(_ filePromiseProvider: NSFilePromiseProvider, fileNameForType fileType: String) -> String { file.filename }

    func filePromiseProvider(_ filePromiseProvider: NSFilePromiseProvider, writePromiseTo url: URL, completionHandler: @escaping (Error?) -> Void) {
        do { try file.write(to: url); completionHandler(nil) }
        catch { completionHandler(error) }
    }

    func operationQueue(for filePromiseProvider: NSFilePromiseProvider) -> OperationQueue { Self.queue }
}
