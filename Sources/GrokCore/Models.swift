import Foundation

public struct AccountProfile: Sendable {
    public let name: String?
    public let email: String?
    public let imageURL: URL?

    public init(name: String?, email: String? = nil, imageURL: String? = nil) {
        self.name = name
        self.email = email
        self.imageURL = imageURL.flatMap { value in
            guard !value.isEmpty else { return nil }
            let base = value.hasPrefix("/rest/") ? "https://grok.com" : "https://assets.grok.com/"
            guard let url = URL(string: value, relativeTo: URL(string: base))?.absoluteURL,
                  url.scheme == "https", url.host != nil, url.user == nil, url.password == nil else { return nil }
            return url
        }
    }
}

public struct HistoryPage: Sendable {
    public let items: [ChatSummary]
    public let nextPageToken: String?
    public init(items: [ChatSummary], nextPageToken: String? = nil) {
        self.items = items
        self.nextPageToken = nextPageToken?.isEmpty == false ? nextPageToken : nil
    }
}

public struct PublicChat: Sendable {
    public let summary: ChatSummary
    public let thread: ChatThread
    public init(summary: ChatSummary, thread: ChatThread) {
        self.summary = summary
        self.thread = thread
    }
}

public struct ChatSummary: Identifiable, Equatable, Sendable {
    public let id: String
    public var title: String
    public var preview: String
    public var modifiedAt: Date?
    public var isPinned: Bool

    public init(id: String, title: String, preview: String = "", modifiedAt: Date? = nil, isPinned: Bool = false) {
        self.id = id
        self.title = title.isEmpty ? L10n.text("Untitled") : title
        self.preview = preview
        self.modifiedAt = modifiedAt
        self.isPinned = isPinned
    }
}

public struct ChatMessage: Identifiable, Equatable, Sendable {
    public enum Role: String, Sendable { case user, assistant, other }
    public let id: String
    public let parentID: String?
    public let role: Role
    public var text: String
    public let createdAt: Date?
    public let sources: [MessageSource]
    public let attachments: [MessageAttachment]
    public var reasoning: String?
    public var reasoningDuration: TimeInterval?
    public let failure: String?

    public init(id: String, parentID: String? = nil, role: Role, text: String, createdAt: Date? = nil,
                sources: [MessageSource] = [], attachments: [MessageAttachment] = [], reasoning: String? = nil, reasoningDuration: TimeInterval? = nil, failure: String? = nil) {
        self.id = id
        self.parentID = parentID?.isEmpty == false ? parentID : nil
        self.role = role
        self.text = text
        self.createdAt = createdAt
        self.sources = sources
        self.attachments = attachments
        self.reasoning = reasoning
        self.reasoningDuration = reasoningDuration
        self.failure = failure
    }

    public var displayMarkdown: String { GrokMessageContent.markdown(text, sources: sources) }
}

/// Kept in the draft until the user explicitly sends the message.
public struct DraftFile: Identifiable, Equatable, Sendable {
    public static let maximumTotalSize = 50 * 1024 * 1024
    public let id: UUID
    public let name: String
    public let mimeType: String
    public let data: Data

    public init(name: String, mimeType: String, data: Data) {
        self.id = UUID()
        self.name = name
        self.mimeType = mimeType
        self.data = data
    }
}

public struct ChatBranch: Identifiable, Equatable, Sendable {
    public let id: String
    public let label: String
}

/// Server responses are a tree. A reply must use the leaf of the displayed path.
public struct ChatThread: Sendable {
    public let responses: [ChatMessage]
    public let branches: [ChatBranch]

    public init(responses: [ChatMessage]) throws {
        guard Set(responses.map(\.id)).count == responses.count else { throw ClientFailure.invalidThread }
        self.responses = responses
        let parents = Set(responses.compactMap(\.parentID))
        let leaves = responses.enumerated().filter { !parents.contains($0.element.id) }
        let ordered = leaves.sorted {
            let a = $0.element.createdAt ?? .distantPast
            let b = $1.element.createdAt ?? .distantPast
            return a == b ? $0.offset > $1.offset : a > b
        }
        branches = ordered.map { ChatBranch(id: $0.element.id, label: String($0.element.text.prefix(64))) }
        if !responses.isEmpty && branches.isEmpty { throw ClientFailure.invalidThread }
    }

    public func path(to leafID: String? = nil) throws -> [ChatMessage] {
        let index = Dictionary(uniqueKeysWithValues: responses.map { ($0.id, $0) })
        var next = leafID ?? branches.first?.id
        var seen = Set<String>()
        var result: [ChatMessage] = []
        while let id = next {
            guard seen.insert(id).inserted, let message = index[id] else { throw ClientFailure.invalidThread }
            result.append(message)
            next = message.parentID
        }
        return result.reversed()
    }
}

public struct ReplyEvent: Sendable {
    public let conversationID: String
    public let responseID: String
    public let text: String
    public let isThinking: Bool
    public let isFinal: Bool
    public let sources: [MessageSource]
    public let attachments: [MessageAttachment]
    public let reasoning: String?
    public let reasoningDuration: TimeInterval?
    public let failure: String?

    public init(conversationID: String, responseID: String, text: String, isThinking: Bool = false, isFinal: Bool = false,
                sources: [MessageSource] = [], attachments: [MessageAttachment] = [], reasoning: String? = nil, reasoningDuration: TimeInterval? = nil, failure: String? = nil) {
        self.conversationID = conversationID
        self.responseID = responseID
        self.text = text
        self.isThinking = isThinking
        self.isFinal = isFinal
        self.sources = sources
        self.attachments = attachments
        self.reasoning = reasoning
        self.reasoningDuration = reasoningDuration
        self.failure = failure
    }
}

public struct ChatMode: Identifiable, Equatable, Sendable {
    public let id: String
    public let name: String
    public let summary: String
    public let iconHint: String?
    public let badgeText: String?
    public let isAvailable: Bool
    public let unavailableReason: String?
    public let minimumSubscriptionTier: String?
    public init(id: String, name: String, summary: String = "", iconHint: String? = nil, badgeText: String? = nil,
                isAvailable: Bool = true, unavailableReason: String? = nil, minimumSubscriptionTier: String? = nil) {
        self.id = id; self.name = name; self.summary = summary; self.iconHint = iconHint
        let badge = badgeText?.trimmingCharacters(in: .whitespacesAndNewlines.union(.controlCharacters))
        self.badgeText = badge?.isEmpty == false ? badge : nil
        self.isAvailable = isAvailable; self.unavailableReason = unavailableReason; self.minimumSubscriptionTier = minimumSubscriptionTier
    }
    public var availabilityExplanation: String? {
        guard !isAvailable else { return nil }
        if let reason = unavailableReason, !reason.isEmpty { return L10n.text(reason) }
        if let tier = minimumSubscriptionTier, !tier.isEmpty {
            let names = ["TIER_SUPERGROK": "SuperGrok", "TIER_SUPERGROK_HEAVY": "SuperGrok Heavy", "TIER_SUPERGROK_LITE": "SuperGrok Lite"]
            if let name = names[tier] { return L10n.format("Requires %@", name) }
            return tier.hasPrefix("TIER_") ? L10n.text("Requires a subscription") : L10n.format("Requires %@", tier)
        }
        return L10n.text("Unavailable for this account")
    }
    public static let fallback = [
        ChatMode(id: "fast", name: L10n.text("Fast"), summary: L10n.text("Quick responses"), iconHint: "lightning"),
        ChatMode(id: "auto", name: L10n.text("Auto"), summary: L10n.text("Chooses Fast or Expert"), iconHint: "rocket")
    ]
}

public enum ClientFailure: Error, LocalizedError {
    case invalidThread, emptyConversation, emptyReply, interruptedReply, temporaryReplyInterrupted, invalidCookies, noSession, uploadFailed, filesTooLarge, noSpeech
    public var errorDescription: String? {
        switch self {
        case .invalidThread: return L10n.text("Could not restore the message thread. Refresh the chat before replying.")
        case .emptyConversation: return L10n.text("No messages in this chat yet")
        case .emptyReply: return L10n.text("Grok returned no response text. Refresh the chat to check whether the message was saved.")
        case .interruptedReply: return L10n.text("The connection was interrupted. Refresh the chat before sending again: your message may have been saved.")
        case .temporaryReplyInterrupted: return L10n.text("The response was interrupted. Start a new private conversation: delivery of the last message could not be confirmed.")
        case .invalidCookies: return L10n.text("Cookies with a nonempty sso or sso-rw value for grok.com are required.")
        case .noSession: return L10n.text("Sign in to your Grok account.")
        case .uploadFailed: return L10n.text("Could not confirm the file upload. Please try again.")
        case .filesTooLarge: return L10n.text("The total size of attached files must not exceed 50 MB.")
        case .noSpeech: return L10n.text("No speech was recognized. Please try again.")
        }
    }
}

public enum GrokDate {
    public static func parse(_ value: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: value) ?? ISO8601DateFormatter().date(from: value)
    }
}
