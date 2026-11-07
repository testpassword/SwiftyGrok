import Foundation

/// Native document-open events may arrive before sign-in or while the draft is busy.
@MainActor public final class FinderAttachmentInbox {
    private var pendingURLs: [URL] = []
    private var isDelivering = false

    public init() {}
    public var isEmpty: Bool { pendingURLs.isEmpty }

    public func enqueue(_ urls: [URL]) {
        var seen = Set(pendingURLs.map(\.standardizedFileURL))
        pendingURLs += urls.filter { $0.isFileURL && seen.insert($0.standardizedFileURL).inserted }
    }

    public func removeAll() { pendingURLs.removeAll() }

    /// Import one batch into the existing draft. This never selects or sends a chat.
    public func deliver(to store: ChatStore) async {
        guard !isDelivering, !pendingURLs.isEmpty, !store.requiresLogin, store.canAttachFiles else { return }
        isDelivering = true
        defer { isDelivering = false }
        let urls = pendingURLs
        pendingURLs.removeAll()
        await store.importFiles(urls)
    }
}
