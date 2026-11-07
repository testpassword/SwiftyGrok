import AppKit
import SwiftUI
import GrokCore

/// Keep native text editing, but prefer Finder's file objects over their text names.
@MainActor struct ComposerTextEditor: NSViewRepresentable {
    @Binding var text: String
    let contextID: String
    let isEnabled: Bool
    var focusRequest: UUID? = nil
    let sendShortcut: MessageSendShortcut
    let onSend: () -> Void
    let onPasteFiles: ([URL]) -> Void
    var canAttachFiles: () -> Bool = { true }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        scroll.borderType = .noBorder

        let editor = FilePasteTextView()
        editor.isRichText = false
        editor.importsGraphics = false
        editor.allowsUndo = true
        editor.drawsBackground = false
        editor.font = .systemFont(ofSize: 15)
        editor.textColor = .labelColor
        editor.insertionPointColor = .labelColor
        editor.textContainerInset = NSSize(width: 0, height: 5)
        editor.textContainer?.lineFragmentPadding = 5
        editor.isVerticallyResizable = true
        editor.isHorizontallyResizable = false
        editor.autoresizingMask = [.width]
        editor.textContainer?.widthTracksTextView = true
        editor.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        editor.isAutomaticQuoteSubstitutionEnabled = false
        editor.isAutomaticDashSubstitutionEnabled = false
        editor.setAccessibilityLabel(L10n.text("Message Grok"))
        editor.delegate = context.coordinator
        editor.registerForDraggedTypes(editor.registeredDraggedTypes + [.fileURL])
        scroll.documentView = editor
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let editor = scroll.documentView as? FilePasteTextView else { return }
        context.coordinator.parent = self
        editor.sendShortcut = sendShortcut
        editor.onSend = onSend
        editor.onPasteFiles = onPasteFiles
        editor.canAttachFiles = canAttachFiles
        editor.isEditable = isEnabled
        if let focusRequest, context.coordinator.focusRequest != focusRequest {
            context.coordinator.focusRequest = focusRequest
            DispatchQueue.main.async { [weak editor] in
                guard let editor, let window = editor.window else { return }
                window.makeFirstResponder(editor)
            }
        }
        if editor.string != text || context.coordinator.contextID != contextID {
            // Undo must not bring text from another chat or a completed send back.
            editor.undoManager?.removeAllActions()
            editor.string = text
            context.coordinator.contextID = contextID
        }
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: ComposerTextEditor
        var contextID: String
        var focusRequest: UUID?

        init(_ parent: ComposerTextEditor) {
            self.parent = parent
            self.contextID = parent.contextID
        }

        func textDidChange(_ notification: Notification) {
            guard let editor = notification.object as? NSTextView else { return }
            parent.text = editor.string
        }
    }
}

@MainActor private final class FilePasteTextView: NSTextView {
    var sendShortcut: MessageSendShortcut = .commandEnter
    var onSend: (() -> Void)?
    var onPasteFiles: (([URL]) -> Void)?
    var canAttachFiles: () -> Bool = { true }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if window?.firstResponder === self, event.modifierFlags.contains(.command), handleReturn(event) { return true }
        return super.performKeyEquivalent(with: event)
    }

    override func keyDown(with event: NSEvent) {
        if !handleReturn(event) { super.keyDown(with: event) }
    }

    private func handleReturn(_ event: NSEvent) -> Bool {
        guard event.type == .keyDown, event.keyCode == 36 || event.keyCode == 76,
              !hasMarkedText() else { return false }
        let modifiers = event.modifierFlags.intersection([.command, .shift, .option, .control])
        guard modifiers.isEmpty || modifiers == .command else { return false }
        guard isEditable else { return true }
        let shouldSend = sendShortcut == .commandEnter ? modifiers == .command : modifiers.isEmpty
        if shouldSend {
            // Holding Return must neither send twice nor stop an active response.
            if !event.isARepeat { onSend?() }
        } else {
            insertNewline(nil)
        }
        return true
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        if !FileDropInput.urls(from: sender.draggingPasteboard).isEmpty { return canAttachFiles() ? .copy : [] }
        return super.draggingEntered(sender)
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        if !FileDropInput.urls(from: sender.draggingPasteboard).isEmpty { return canAttachFiles() ? .copy : [] }
        return super.draggingUpdated(sender)
    }

    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
        if !FileDropInput.urls(from: sender.draggingPasteboard).isEmpty { return canAttachFiles() }
        return super.prepareForDragOperation(sender)
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let urls = FileDropInput.urls(from: sender.draggingPasteboard)
        if !urls.isEmpty {
            guard canAttachFiles(), let onPasteFiles else { return false }
            onPasteFiles(urls)
            return true
        }
        return super.performDragOperation(sender)
    }

    override func paste(_ sender: Any?) {
        if !pasteFiles() { super.paste(sender) }
    }

    override func pasteAsPlainText(_ sender: Any?) {
        if !pasteFiles() { super.pasteAsPlainText(sender) }
    }

    private func pasteFiles() -> Bool {
        let objects = FileDropInput.urls(from: .general)
        guard !objects.isEmpty else { return false }
        guard isEditable, canAttachFiles(), let onPasteFiles else { return true }
        onPasteFiles(objects)
        return true
    }
}
