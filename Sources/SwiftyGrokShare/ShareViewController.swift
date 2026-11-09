import AppKit
import UniformTypeIdentifiers

/// A system Share service for public Grok links and file attachments. Opening a
/// link never clones or sends a conversation; the app owns those actions.
@MainActor final class ShareViewController: NSViewController {
    private var transfer: Task<Void, Never>?
    private var didStart = false
    private var isOpeningApp = false
    private var request: URL?

    private static func text(_ key: String) -> String {
        NSLocalizedString(key, bundle: Bundle(for: ShareViewController.self), comment: "Share extension")
    }

    override func loadView() {
        view = NSView(frame: NSRect(x: 0, y: 0, width: 320, height: 100))
        let progress = NSProgressIndicator()
        progress.style = .spinning
        progress.controlSize = .small
        progress.startAnimation(nil)
        let label = NSTextField(wrappingLabelWithString: Self.text("Opening in SwiftyGrok…"))
        let status = NSStackView(views: [progress, label])
        status.spacing = 10
        let cancel = NSButton(title: Self.text("Cancel"), target: self, action: #selector(cancelSharing))
        cancel.keyEquivalent = "\u{1b}"
        let stack = NSStackView(views: [status, cancel])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),
            stack.topAnchor.constraint(equalTo: view.topAnchor, constant: 18),
            stack.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -18)
        ])
        preferredContentSize = view.frame.size
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        guard !didStart, let context = extensionContext else { return }
        didStart = true
        transfer = Task {
            do {
                let providers = (context.inputItems as? [NSExtensionItem] ?? []).flatMap { $0.attachments ?? [] }
                guard !providers.isEmpty, providers.count <= ShareAttachmentHandoff.maximumFileCount else {
                    throw Self.failure("Choose files or photos to add to SwiftyGrok.")
                }
                let web = providers.filter {
                    !$0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) &&
                    $0.hasItemConformingToTypeIdentifier(UTType.url.identifier)
                }
                let request: URL
                if !web.isEmpty {
                    guard web.count == 1 else { throw Self.failure("Choose one public Grok chat link.") }
                    do { request = try await PublicChatLink.load(from: web[0]).handoffURL }
                    catch { throw Self.failure("Choose a public chat link from grok.com, or files to attach.") }
                } else {
                    var files: [SharedFile] = []
                    var remaining = ShareAttachmentHandoff.maximumTotalSize
                    for provider in providers {
                        try Task.checkCancellation()
                        let file = try await SharedFileReader.load(provider, maximumBytes: remaining)
                        remaining -= file.data.count
                        files.append(file)
                    }
                    try Task.checkCancellation()
                    request = try ShareAttachmentHandoff.prepare(files)
                }
                self.request = request
                try Task.checkCancellation()
                isOpeningApp = true
                let appURL = Bundle(for: Self.self).bundleURL
                    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
                let configuration = NSWorkspace.OpenConfiguration()
                configuration.activates = true
                configuration.addsToRecentItems = false
                configuration.allowsRunningApplicationSubstitution = true
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                    NSWorkspace.shared.open([request], withApplicationAt: appURL, configuration: configuration) { _, error in
                        if let error { continuation.resume(throwing: error) }
                        else { continuation.resume() }
                    }
                }
                self.request = nil // The app now owns the one-time request.
                context.completeRequest(returningItems: nil, completionHandler: nil)
            } catch {
                if let request { ShareAttachmentHandoff.discard(request); self.request = nil }
                context.cancelRequest(withError: Task.isCancelled ? CocoaError(.userCancelled) : error)
            }
        }
    }

    override func viewDidDisappear() {
        super.viewDidDisappear()
        if !isOpeningApp { transfer?.cancel() }
    }

    @objc private func cancelSharing() {
        guard !isOpeningApp else { return }
        transfer?.cancel()
        extensionContext?.cancelRequest(withError: CocoaError(.userCancelled))
    }

    nonisolated private static func failure(_ key: String) -> NSError {
        NSError(domain: "app.swiftygrok.share", code: 1,
                userInfo: [NSLocalizedDescriptionKey: NSLocalizedString(key, bundle: Bundle(for: ShareViewController.self), comment: "Share error")])
    }
}
