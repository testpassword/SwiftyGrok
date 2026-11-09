import Foundation

/// Document-open and Share Extension requests may arrive before sign-in or while busy.
@MainActor public final class AttachmentInbox {
    private enum Batch { case urls([URL]), files([DraftFile]) }
    private var pending: [Batch] = []
    private var isDelivering = false

    public init() {}
    public var isEmpty: Bool { pending.isEmpty }

    public func enqueue(_ urls: [URL]) {
        let queued = pending.flatMap { batch -> [URL] in
            if case let .urls(urls) = batch { return urls }
            return []
        }
        var seen = Set(queued.map(\.standardizedFileURL))
        let added = urls.filter { $0.isFileURL && seen.insert($0.standardizedFileURL).inserted }
        if !added.isEmpty { pending.append(.urls(added)) }
    }

    @discardableResult public func enqueue(files: [DraftFile]) -> Bool {
        guard !files.isEmpty else { return true }
        let queuedSize = pending.reduce(0) { total, batch in
            if case let .files(files) = batch { return total + files.reduce(0) { $0 + $1.data.count } }
            return total
        }
        guard files.reduce(queuedSize, { $0 + $1.data.count }) <= DraftFile.maximumTotalSize else { return false }
        pending.append(.files(files))
        return true
    }

    public func removeAll() { pending.removeAll() }

    /// Import one batch into the existing draft. This never selects or sends a chat.
    public func deliver(to store: ChatStore) async {
        guard !isDelivering, !pending.isEmpty, !store.requiresLogin, store.canAttachFiles else { return }
        isDelivering = true
        defer { isDelivering = false }
        let batch = pending.removeFirst()
        switch batch {
        case let .urls(urls): await store.importFiles(urls)
        case let .files(files): await store.importFiles(resolvingDraftFiles: { files })
        }
    }
}
