import AppKit
import CoreGraphics
import IOKit.hidsystem
import ScreenCaptureKit
import ImageIO
import UniformTypeIdentifiers
import Observation
import GrokCore

@MainActor @Observable final class WindowScreenshotShortcut: NSObject {
    static let shared = WindowScreenshotShortcut()
    private(set) var needsInputMonitoring = false
    private(set) var errorMessage: String?
    @ObservationIgnored private var action: (() -> Void)?
    @ObservationIgnored private var tap: CFMachPort?
    @ObservationIgnored private var source: CFRunLoopSource?
    @ObservationIgnored private var chord = DualCommandChord()
    @ObservationIgnored private var observing = false
    @ObservationIgnored private var requestedAccess = false

    func configure(action: @escaping () -> Void) {
        self.action = action
        if !observing {
            observing = true
            NotificationCenter.default.addObserver(self, selector: #selector(settingChanged),
                                                  name: BehaviorSettings.windowScreenshotEnabledDidChange, object: BehaviorSettings.shared)
            NotificationCenter.default.addObserver(self, selector: #selector(applicationActivated),
                                                  name: NSApplication.didBecomeActiveNotification, object: nil)
        }
        let request = !requestedAccess
        requestedAccess = true
        refresh(requestPermission: request)
    }

    func requestInputMonitoring() {
        refresh(requestPermission: true)
        if needsInputMonitoring,
           let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent") {
            NSWorkspace.shared.open(url)
        }
    }

    @objc private func settingChanged() { refresh(requestPermission: true) }
    @objc private func applicationActivated() { refresh() }

    private func refresh(requestPermission: Bool = false) {
        stopListening()
        needsInputMonitoring = false
        errorMessage = nil
        guard action != nil, BehaviorSettings.shared.windowScreenshotEnabled else { return }
        let allowed = CGPreflightListenEventAccess() || (requestPermission && CGRequestListenEventAccess())
        guard allowed else { needsInputMonitoring = true; return }
        resetChord()
        let mask = CGEventMask(1) << CGEventType.flagsChanged.rawValue
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap,
                                         options: .listenOnly, eventsOfInterest: mask, callback: { _, type, event, info in
            guard let info else { return Unmanaged.passUnretained(event) }
            let controller = Unmanaged<WindowScreenshotShortcut>.fromOpaque(info).takeUnretainedValue()
            // This tap's run-loop source is installed exclusively on the main loop.
            MainActor.assumeIsolated { controller.handle(type, flags: event.flags) }
            return Unmanaged.passUnretained(event)
        }, userInfo: Unmanaged.passUnretained(self).toOpaque()),
              let source = CFMachPortCreateRunLoopSource(nil, tap, 0) else {
            errorMessage = L10n.text("Could not enable the screenshot shortcut. Try turning it off and on again.")
            return
        }
        self.tap = tap
        self.source = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    private func handle(_ type: CGEventType, flags: CGEventFlags) {
        guard BehaviorSettings.shared.windowScreenshotEnabled else { return }
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            resetChord()
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return
        }
        let other: CGEventFlags = [.maskShift, .maskControl, .maskAlternate, .maskSecondaryFn]
        if chord.update(leftPressed: flags.rawValue & UInt64(NX_DEVICELCMDKEYMASK) != 0,
                        rightPressed: flags.rawValue & UInt64(NX_DEVICERCMDKEYMASK) != 0,
                        otherModifiers: !flags.intersection(other).isEmpty) {
            action?()
        }
    }

    private func resetChord() {
        let flags = CGEventSource.flagsState(.combinedSessionState).rawValue
        chord = DualCommandChord(leftPressed: flags & UInt64(NX_DEVICELCMDKEYMASK) != 0,
                                 rightPressed: flags & UInt64(NX_DEVICERCMDKEYMASK) != 0)
    }

    private func stopListening() {
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        if let tap { CGEvent.tapEnable(tap: tap, enable: false); CFMachPortInvalidate(tap) }
        source = nil
        tap = nil
        chord = DualCommandChord()
    }

    func stop() {
        stopListening()
        NotificationCenter.default.removeObserver(self)
        observing = false
        action = nil
    }
}

/// Pin the window before permission prompts or activating SwiftyGrok can change focus.
@MainActor struct WindowScreenshotTarget {
    let processID: pid_t
    let windowID: CGWindowID

    static func frontmost() throws -> Self {
        guard let processID = NSWorkspace.shared.frontmostApplication?.processIdentifier else {
            throw WindowScreenshotError.noWindow
        }
        if processID == ProcessInfo.processInfo.processIdentifier, let window = NSApp.keyWindow {
            return Self(processID: processID, windowID: CGWindowID(window.windowNumber))
        }
        let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        // Window Server returns these front-to-back; never fall back to another app.
        guard let window = windows.first(where: {
            ($0[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == processID &&
            ($0[kCGWindowLayer as String] as? NSNumber)?.intValue == 0
        }), let id = window[kCGWindowNumber as String] as? NSNumber else { throw WindowScreenshotError.noWindow }
        return Self(processID: processID, windowID: id.uint32Value)
    }

    func capture() async throws -> DraftFile {
        try Task.checkCancellation()
        guard BehaviorSettings.shared.windowScreenshotEnabled else { throw CancellationError() }
        guard CGPreflightScreenCaptureAccess() || CGRequestScreenCaptureAccess() else {
            throw WindowScreenshotError.screenPermission
        }
        try Task.checkCancellation()
        let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
        guard let window = content.windows.first(where: { $0.windowID == windowID && $0.owningApplication?.processID == processID }) else {
            throw WindowScreenshotError.noWindow
        }
        guard BehaviorSettings.shared.windowScreenshotEnabled else { throw CancellationError() }
        let filter = SCContentFilter(desktopIndependentWindow: window)
        let configuration = SCStreamConfiguration()
        configuration.width = max(1, Int((filter.contentRect.width * CGFloat(filter.pointPixelScale)).rounded()))
        configuration.height = max(1, Int((filter.contentRect.height * CGFloat(filter.pointPixelScale)).rounded()))
        configuration.showsCursor = false
        configuration.ignoreShadowsSingleWindow = true
        let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
        try Task.checkCancellation()
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else {
            throw WindowScreenshotError.encoding
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw WindowScreenshotError.encoding }
        return DraftFile(name: "Screenshot-\(UUID().uuidString.prefix(8)).png", mimeType: "image/png", data: data as Data)
    }
}

enum WindowScreenshotError: LocalizedError {
    case noWindow, screenPermission, encoding, draftBusy
    var errorDescription: String? {
        switch self {
        case .noWindow: return L10n.text("The active window is not available for a screenshot.")
        case .screenPermission: return L10n.text("Allow screen recording for SwiftyGrok in System Settings → Privacy & Security → Screen Recording.")
        case .encoding: return L10n.text("Could not create the screenshot.")
        case .draftBusy: return L10n.text("Wait for the current reply or file import before attaching a screenshot.")
        }
    }
}
