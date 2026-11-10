import Foundation
import Observation

public struct SharedConversation: Identifiable, Equatable, Sendable {
    /// The management ID is distinct from the public route token and chat ID.
    public let id: String
    public let conversationID: String?
    public let title: String
    public let url: URL?
    public let views: Int?
    public let createdAt: Date?

    public init(id: String, conversationID: String? = nil, title: String, url: URL? = nil,
                views: Int? = nil, createdAt: Date? = nil) {
        self.id = id; self.conversationID = conversationID
        self.title = title.isEmpty ? L10n.text("Untitled") : title
        self.url = url; self.views = views; self.createdAt = createdAt
    }
}

public struct SharedConversationPage: Sendable {
    public let items: [SharedConversation]
    public let nextPageToken: String?
    public init(items: [SharedConversation], nextPageToken: String? = nil) {
        self.items = items
        self.nextPageToken = nextPageToken?.isEmpty == false ? nextPageToken : nil
    }
}

@MainActor public protocol SharedConversationServing: AnyObject {
    func sharedConversations(pageToken: String?) async throws -> SharedConversationPage
    func revokeSharedConversation(id: String) async throws
}

@MainActor @Observable public final class SharedConversationStore: Identifiable {
    public nonisolated let id = UUID()
    public private(set) var items: [SharedConversation] = []
    public private(set) var isLoading = false
    public private(set) var revoking: Set<String> = []
    public private(set) var error: DisplayError?
    public private(set) var requiresLogin = false
    public var hasMore: Bool { nextPageToken != nil }
    public var isBusy: Bool { isLoading || !revoking.isEmpty }
    @ObservationIgnored private let service: any SharedConversationServing
    @ObservationIgnored private var generation = UUID()
    @ObservationIgnored private var active = true
    @ObservationIgnored private var nextPageToken: String?
    @ObservationIgnored private var consumedTokens: Set<String> = []

    public init(service: any SharedConversationServing) { self.service = service }

    public func load(more: Bool = false) async {
        guard active, !requiresLogin, !isBusy, !more || hasMore else { return }
        let current = generation
        let token = more ? nextPageToken : nil
        isLoading = true
        error = nil
        defer { if current == generation { isLoading = false } }
        do {
            let page = try await service.sharedConversations(pageToken: token)
            try Task.checkCancellation()
            guard active, current == generation else { return }
            var seen = Set<String>()
            items = ((more ? items : []) + page.items).filter { !$0.id.isEmpty && seen.insert($0.id).inserted }
            if !more { consumedTokens = [] }
            if let token { consumedTokens.insert(token) }
            nextPageToken = page.nextPageToken.flatMap { consumedTokens.contains($0) ? nil : $0 }
        } catch {
            guard !Task.isCancelled, active, current == generation else { return }
            record(error)
        }
    }

    public func revoke(_ item: SharedConversation) async {
        guard active, !requiresLogin, !isLoading, items.contains(where: { $0.id == item.id }),
              revoking.insert(item.id).inserted else { return }
        let current = generation
        error = nil
        defer { revoking.remove(item.id) }
        do {
            try await service.revokeSharedConversation(id: item.id)
            try Task.checkCancellation()
            guard active, current == generation else { return }
            items.removeAll { $0.id == item.id }
        } catch {
            guard !Task.isCancelled, active, current == generation else { return }
            record(error)
        }
    }

    private func record(_ underlying: Error) {
        let display = DisplayError(underlying)
        requiresLogin = requiresLogin || display.needsLogin
        error = display
    }

    public func shutdown() {
        active = false
        generation = UUID()
        items = []; revoking = []; isLoading = false; error = nil
    }
}
