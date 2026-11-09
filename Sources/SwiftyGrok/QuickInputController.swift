import AppKit
import Carbon.HIToolbox
import SwiftUI
import Observation
import GrokCore

@MainActor @Observable final class QuickInputController: NSObject, NSWindowDelegate {
    private(set) var shortcutError: String?
    private(set) var focusRequest = UUID()
    @ObservationIgnored private weak var app: AppModel?
    @ObservationIgnored private var showMain: (() -> Void)?
    @ObservationIgnored private var panel: QuickInputPanel?
    @ObservationIgnored private var draftStore: ChatStore?
    @ObservationIgnored private var hotKey: EventHotKeyRef?
    @ObservationIgnored private var handler: EventHandlerRef?
    @ObservationIgnored private var observingSettings = false
    fileprivate static let panelWidth: CGFloat = 510
    private static let positionKey = "quickInput.topLeftPosition"

    func configure(app: AppModel, showMain: @escaping () -> Void) {
        self.app = app
        self.showMain = showMain
        if !observingSettings {
            NotificationCenter.default.addObserver(self, selector: #selector(quickInputSettingDidChange(_:)),
                                                  name: BehaviorSettings.quickInputEnabledDidChange, object: BehaviorSettings.shared)
            observingSettings = true
        }
        updateShortcutRegistration()
    }

    @objc private func quickInputSettingDidChange(_ notification: Notification) { updateShortcutRegistration() }

    private func updateShortcutRegistration() {
        guard BehaviorSettings.shared.quickInputEnabled else {
            hide()
            if let hotKey { UnregisterEventHotKey(hotKey); self.hotKey = nil }
            shortcutError = nil
            return
        }
        if handler == nil {
            var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
            let status = InstallEventHandler(GetApplicationEventTarget(), { _, event, data in
                guard let event, let data else { return OSStatus(eventNotHandledErr) }
                var id = EventHotKeyID()
                guard GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil,
                                        MemoryLayout<EventHotKeyID>.size, nil, &id) == noErr,
                      id.signature == 0x47724B4D, id.id == 1 else { return OSStatus(eventNotHandledErr) }
                let controller = Unmanaged<QuickInputController>.fromOpaque(data).takeUnretainedValue()
                Task { @MainActor [weak controller] in controller?.handleShortcut() }
                return noErr
            }, 1, &eventType, Unmanaged.passUnretained(self).toOpaque(), &handler)
            guard status == noErr else { shortcutError = L10n.format("Could not enable quick input (%@).", String(status)); return }
        }
        guard hotKey == nil else { return }
        let registration = RegisterEventHotKey(UInt32(kVK_Space), UInt32(optionKey), EventHotKeyID(signature: 0x47724B4D, id: 1),
                                               GetApplicationEventTarget(), 0, &hotKey)
        shortcutError = registration == noErr ? nil
            : L10n.format("⌥Space is unavailable (%@).", String(registration))
    }

    private func handleShortcut() {
        guard BehaviorSettings.shared.quickInputEnabled else { return }
        if panel?.isVisible == true { hide(); return }
        // Only present the panel when the main window isn't focused.
        guard !NSApp.isActive || NSApp.keyWindow?.identifier?.rawValue != "main" else { return }
        show()
    }

    func show() {
        guard BehaviorSettings.shared.quickInputEnabled else { return }
        guard NSApp.modalWindow == nil else { openMain(); return }
        guard let mainStore = app?.store, !mainStore.requiresLogin else { openMain(); return }
        if draftStore == nil { draftStore = mainStore.makeNewConversationStore() }
        guard let draftStore else { return }
        if panel == nil {
            let panel = QuickInputPanel(contentRect: NSRect(x: 0, y: 0, width: Self.panelWidth, height: 140),
                                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            panel.identifier = NSUserInterfaceItemIdentifier("quick-input")
            panel.title = L10n.text("Grok Quick Input")
            panel.level = .floating
            panel.isFloatingPanel = true
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.hasShadow = false
            panel.hidesOnDeactivate = false
            panel.isMovableByWindowBackground = true
            panel.delegate = self
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
            panel.onCancel = { [weak self] in self?.hide() }
            panel.contentView = NSHostingView(rootView: QuickInputView(store: draftStore, controller: self))
            self.panel = panel
        }
        guard let panel else { return }
        restorePosition(of: panel)
        focusRequest = UUID()
        panel.makeKeyAndOrderFront(nil)
    }

    func hide() {
        if let draftStore { VoiceDictation.shared.cancel(in: draftStore) }
        panel?.orderOut(nil)
    }

    var attachmentStore: ChatStore? { panel?.isVisible == true ? draftStore : nil }

    func windowDidMove(_ notification: Notification) {
        guard let moved = notification.object as? QuickInputPanel, moved === panel else { return }
        UserDefaults.standard.set([Double(moved.frame.minX), Double(moved.frame.maxY)], forKey: Self.positionKey)
    }

    private func restorePosition(of panel: QuickInputPanel) {
        let fallback = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main
        var frame = panel.frame
        var screen = fallback
        if let saved = UserDefaults.standard.array(forKey: Self.positionKey) as? [Double],
           saved.count == 2, saved.allSatisfy(\.isFinite) {
            frame.origin = NSPoint(x: saved[0], y: saved[1] - frame.height)
            // Select the screen with the largest intersection. Fall back to the
            // current screen if the saved monitor is no longer connected.
            let overlaps = NSScreen.screens.map { candidate -> (NSScreen, CGFloat) in
                let overlap = candidate.visibleFrame.intersection(frame)
                return (candidate, overlap.isNull ? 0 : overlap.width * overlap.height)
            }
            if let best = overlaps.max(by: { $0.1 < $1.1 }), best.1 > 0 { screen = best.0 }
        } else if let visible = fallback?.visibleFrame {
            frame.origin = NSPoint(x: visible.midX - frame.width / 2, y: visible.midY + 70)
        }
        if let visible = screen?.visibleFrame { frame = clamped(frame, to: visible) }
        panel.setFrameOrigin(frame.origin)
    }

    private func clamped(_ frame: NSRect, to visible: NSRect) -> NSRect {
        var result = frame
        result.origin.x = min(max(result.minX, visible.minX), max(visible.minX, visible.maxX - result.width))
        result.origin.y = min(max(result.minY, visible.minY), max(visible.minY, visible.maxY - result.height))
        return result
    }

    func resize(height: CGFloat) {
        guard let panel, height.isFinite else { return }
        let height = max(100, min(height, 430))
        guard abs(panel.frame.height - height) > 0.5 else { return }
        var frame = panel.frame
        frame.origin.y += frame.height - height
        frame.size.height = height
        if let visible = panel.screen?.visibleFrame { frame = clamped(frame, to: visible) }
        panel.setFrame(frame, display: true)
    }

    func send() {
        guard let draftStore, draftStore.canSend, let app else { return }
        app.sendQuickConversation(draftStore)
        hide()
        self.draftStore = nil
        panel?.contentView = nil
        panel = nil
        openMain()
    }

    func openMain() {
        if let modal = NSApp.modalWindow {
            NSApp.activate(ignoringOtherApps: true)
            modal.makeKeyAndOrderFront(nil)
            return
        }
        showMain?()
        NSApp.activate(ignoringOtherApps: true)
        DispatchQueue.main.async {
            if let window = NSApp.windows.first(where: { $0.identifier?.rawValue == "main" }) {
                if window.isMiniaturized { window.deminiaturize(nil) }
                window.makeKeyAndOrderFront(nil)
            }
        }
    }

    func reset() {
        hide()
        draftStore?.shutdown()
        draftStore = nil
        panel?.contentView = nil
        panel = nil
    }

    func stop() {
        reset()
        NotificationCenter.default.removeObserver(self, name: BehaviorSettings.quickInputEnabledDidChange, object: BehaviorSettings.shared)
        observingSettings = false
        if let hotKey { UnregisterEventHotKey(hotKey); self.hotKey = nil }
        if let handler { RemoveEventHandler(handler); self.handler = nil }
    }
}

/// A dedicated grip preserves text selection and interaction with composer controls.
@MainActor struct QuickInputDragHandle: NSViewRepresentable {
    func makeNSView(context: Context) -> DragView {
        let view = DragView()
        view.setAccessibilityRole(.handle)
        view.setAccessibilityLabel(L10n.text("Move quick input"))
        return view
    }
    func updateNSView(_ view: DragView, context: Context) {}

    final class DragView: NSView {
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
        override func mouseDown(with event: NSEvent) { window?.performDrag(with: event) }
        override func resetCursorRects() { addCursorRect(bounds, cursor: .openHand) }
        override func draw(_ dirtyRect: NSRect) {
            NSColor.secondaryLabelColor.withAlphaComponent(0.45).setFill()
            NSBezierPath(roundedRect: NSRect(x: bounds.midX - 16, y: bounds.midY - 1.5, width: 32, height: 3),
                         xRadius: 1.5, yRadius: 1.5).fill()
        }
    }
}

private final class QuickInputPanel: NSPanel {
    var onCancel: (() -> Void)?
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    override func cancelOperation(_ sender: Any?) { onCancel?() }
}

@MainActor private struct QuickInputView: View {
    @Bindable var store: ChatStore
    @Bindable var controller: QuickInputController
    @State private var followResponse = true

    var body: some View {
        VStack(spacing: 0) {
            if let error = store.error {
                Text(error.message).font(.callout).foregroundStyle(.secondary).padding(12)
            }
            ChatComposer(store: store, followResponse: $followResponse, floating: true,
                         focusRequest: controller.focusRequest, onSend: { controller.send() })
        }
        .frame(width: QuickInputController.panelWidth).fixedSize(horizontal: false, vertical: true)
        .modifier(AppAppearance())
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { controller.resize(height: $0) }
        .onExitCommand { controller.hide() }
    }
}
