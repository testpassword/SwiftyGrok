import AppKit
import FinderSync

/// Finder only supplies the selection; file reads and uploads belong to the app.
final class FinderSync: FIFinderSync {
    private let resources = Bundle(for: FinderSync.self)

    override init() {
        super.init()
        // Register contextual menus throughout Finder, including mounted volumes.
        // No badges, file scans, or file-system watchers are installed.
        FIFinderSyncController.default().directoryURLs = [URL(fileURLWithPath: "/", isDirectory: true)]
    }

    override func menu(for menuKind: FIMenuKind) -> NSMenu? {
        guard menuKind == .contextualMenuForItems else { return nil }
        let urls = (FIFinderSyncController.default().selectedItemURLs() ?? []).filter {
            $0.isFileURL && ((try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? $0.hasDirectoryPath) != true
        }
        guard !urls.isEmpty else { return nil }
        let title = NSLocalizedString("Add to SwiftyGrok", bundle: resources, comment: "Finder context menu action")
        let item = NSMenuItem(title: title, action: #selector(attachFiles(_:)), keyEquivalent: "")
        item.target = self
        // Keep the selection from menu creation even if Finder's selection changes.
        item.representedObject = urls
        if let imageURL = resources.url(forResource: "icon_32x32@2x", withExtension: "png") {
            item.image = NSImage(contentsOf: imageURL)
            item.image?.size = NSSize(width: 16, height: 16)
        }
        if #available(macOS 27.0, *) { item.preferredImageVisibility = .visible }
        let menu = NSMenu()
        menu.addItem(item)
        return menu
    }

    @objc private func attachFiles(_ sender: NSMenuItem) {
        guard let urls = sender.representedObject as? [URL], !urls.isEmpty else { return }
        // .app/Contents/PlugIns/SwiftyGrokFinder.appex → containing app.
        let appURL = resources.bundleURL.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        configuration.addsToRecentItems = false
        configuration.allowsRunningApplicationSubstitution = true
        // Native document events preserve file URLs, with no custom URL payloads
        // or shared account/keychain access from the sandboxed extension.
        NSWorkspace.shared.open(urls, withApplicationAt: appURL, configuration: configuration) { _, error in
            if let error { NSLog("SwiftyGrok Finder handoff failed: %@", error.localizedDescription) }
        }
    }
}
