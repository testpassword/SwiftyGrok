import Foundation
import GrokClient
import GrokUsage
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

@MainActor
public protocol GrokServing: AnyObject {
    func history(pageToken: String?, search: String) async throws -> HistoryPage
    func thread(id: String) async throws -> ChatThread
    func modes() async throws -> [ChatMode]
    func profile() async throws -> AccountProfile
    func renameConversation(id: String, title: String) async throws
    func pinConversation(id: String, pinned: Bool) async throws
    func deleteConversation(id: String) async throws
    func shareConversation(id: String, responseID: String) async throws -> URL
    func upload(file: DraftFile) async throws -> String
    func reply(conversationID: String?, parentID: String?, text: String, modeID: String, temporary: Bool, fileIDs: [String]) async throws -> AsyncThrowingStream<ReplyEvent, Error>
}

@MainActor
public final class GrokService: GrokServing {
    private let client: GrokClient
    private var assetCache: [String: MessageAttachment] = [:]

    public func usageLimit(modeID: String) async throws -> UsageWindow {
        let limit = try await client.rateLimits(modelName: modeID)
        let remaining = limit.remainingResponses.flatMap { $0 >= 0 ? $0 : nil }
        let reset = limit.resetAt ?? limit.resetAfterSeconds.map { limit.fetchedAt.addingTimeInterval(Double($0)) }
        // A window duration is not a reset countdown; do not manufacture a reset date.
        return UsageWindow(id: modeID, remaining: remaining, resetAt: reset)
    }

    public init(credentials: SessionCredentials, session: URLSession? = nil) throws {
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false
        config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.timeoutIntervalForRequest = 90
        config.timeoutIntervalForResource = 600
        client = try GrokClient(
            cookies: credentials.cookies,
            baseURL: "https://grok.com/rest",
            session: session ?? URLSession(configuration: config),
            userAgent: credentials.userAgent
        )
    }

    public func history(pageToken: String?, search: String) async throws -> HistoryPage {
        let page = try await client.listConversationPage(pageToken: pageToken, searchQuery: search)
        let items = page.conversations.filter { !$0.temporary }.map {
            ChatSummary(id: $0.conversationId, title: $0.title, preview: $0.preview, modifiedAt: GrokDate.parse($0.modifyTime), isPinned: $0.starred)
        }
        return HistoryPage(items: items, nextPageToken: page.nextPageToken)
    }

    public func modes() async throws -> [ChatMode] {
        try await client.listModes().filter(\.isAvailable).map { ChatMode(id: $0.id, name: $0.displayName) }
    }

    public func profile() async throws -> AccountProfile {
        let profile = try await client.userProfile()
        return AccountProfile(name: profile.name, imageURL: profile.imageURL)
    }

    public func renameConversation(id: String, title: String) async throws {
        try await client.updateConversation(conversationId: id, title: title)
    }

    public func pinConversation(id: String, pinned: Bool) async throws {
        try await client.updateConversation(conversationId: id, starred: pinned)
    }

    public func deleteConversation(id: String) async throws {
        try await client.softDeleteConversation(conversationId: id)
    }

    public func shareConversation(id: String, responseID: String) async throws -> URL {
        try await client.publicConversationURL(conversationId: id, responseId: responseID)
    }

    public func thread(id: String) async throws -> ChatThread {
        // Fetch topology explicitly: a failed node request must never silently choose a parent.
        let nodes = try await client.getResponseNodes(conversationId: id, includeThreads: true)
        guard !nodes.isEmpty else { return try ChatThread(responses: []) }
        let responses = try await loadResponses(conversationID: id, ids: nodes.map(\.responseId))
        var byID = Dictionary(responses.map { ($0.responseId, $0) }, uniquingKeysWith: { _, last in last })
        guard nodes.allSatisfy({ byID[$0.responseId] != nil }) else { throw ClientFailure.invalidThread }

        func parentID(_ node: ResponseNode) -> String? {
            [byID[node.responseId]?.parentResponseId, node.parentResponseId].compactMap { $0 }.first { !$0.isEmpty }
        }

        // Grok can omit the hidden system root from response-node. Verify its type
        // before ending a path there, so a genuinely missing message is still an error.
        let externalParents = Set(nodes.compactMap(parentID)).subtracting(nodes.map(\.responseId))
        let missingParents = externalParents.filter { byID[$0] == nil }.sorted()
        if !missingParents.isEmpty {
            for response in try await loadResponses(conversationID: id, ids: missingParents) {
                byID[response.responseId] = response
            }
        }
        var hiddenRoots = Set(nodes.filter {
            byID[$0.responseId]?.sender.lowercased() == "system" && parentID($0) == nil
        }.map(\.responseId))
        for parent in externalParents {
            guard let root = byID[parent], root.sender.lowercased() == "system",
                  (root.parentResponseId ?? "").isEmpty else { throw ClientFailure.invalidThread }
            hiddenRoots.insert(parent)
        }

        var messages: [ChatMessage] = []
        for node in nodes where !hiddenRoots.contains(node.responseId) {
            guard let response = byID[node.responseId] else { throw ClientFailure.invalidThread }
            let sender = response.sender.lowercased()
            let role: ChatMessage.Role = sender == "human" || sender == "user" ? .user :
                (sender == "assistant" || sender == "model" || sender == "grok" ? .assistant : .other)
            let parent = parentID(node).flatMap { hiddenRoots.contains($0) ? nil : $0 }
            let content = GrokMessageContent(response.richContent)
            let attachments = try await resolveAttachments(content.attachments)
            messages.append(ChatMessage(id: response.responseId, parentID: parent,
                               role: role, text: response.message, createdAt: GrokDate.parse(response.createTime),
                               sources: content.sources, attachments: attachments, reasoning: content.reasoning, reasoningDuration: content.reasoningDuration, failure: content.failure))
        }
        return try ChatThread(responses: messages)
    }

    private func resolveAttachments(_ attachments: [MessageAttachment]) async throws -> [MessageAttachment] {
        var result: [MessageAttachment] = []
        var seen = Set<String>()
        for attachment in attachments {
            try Task.checkCancellation()
            var resolved = attachment
            if attachment.url == nil, UUID(uuidString: attachment.id) != nil {
                if let cached = assetCache[attachment.id] { resolved = cached }
                else {
                    do {
                        let metadata = try await client.assetMetadata(id: attachment.id)
                        if let asset = GrokMessageContent.resolvedAttachment(id: attachment.id, metadata: metadata) {
                            assetCache[attachment.id] = asset
                            resolved = asset
                        }
                    } catch { try Task.checkCancellation() }
                }
            }
            if seen.insert(resolved.url?.absoluteString ?? resolved.id).inserted { result.append(resolved) }
        }
        return result
    }

    private func loadResponses(conversationID: String, ids: [String]) async throws -> [Response] {
        var responses: [Response] = []
        for offset in stride(from: 0, to: ids.count, by: 100) {
            try Task.checkCancellation()
            responses += try await client.loadResponses(
                conversationId: conversationID,
                specificResponseIds: Array(ids[offset..<min(offset + 100, ids.count)])
            )
        }
        return responses
    }

    public func upload(file: DraftFile) async throws -> String {
        let result = try await client.uploadFile(fileName: file.name, fileMimeType: file.mimeType, contentBase64: file.data.base64EncodedString())
        guard let id = result.uploadedFileId, !id.isEmpty else { throw ClientFailure.uploadFailed }
        return id
    }

    public func reply(conversationID: String?, parentID: String?, text: String, modeID: String, temporary: Bool = false, fileIDs: [String] = []) async throws -> AsyncThrowingStream<ReplyEvent, Error> {
        let options = GrokMessageOptions(temporary: temporary, modeId: modeID, fileAttachments: fileIDs)
        let source: AsyncThrowingStream<ConversationResponse, Error>
        if let conversationID {
            source = try await client.continueConversation(conversationId: conversationID, parentResponseId: parentID, message: text, options: options)
        } else {
            source = try await client.streamMessage(message: text, options: options)
        }
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    for try await event in source {
                        try Task.checkCancellation()
                        if temporary && event.isFinal && event.richContent.isEmpty {
                            // EOF-only synthesis is not a server acknowledgement.
                            // A temporary chat cannot reload history to reconcile it.
                            throw ClientFailure.interruptedReply
                        }
                        let content = GrokMessageContent(event.richContent)
                        let attachments = temporary ? try await resolveAttachments(content.attachments) : content.attachments
                        continuation.yield(ReplyEvent(conversationID: event.conversationId, responseID: event.responseId,
                                                      text: event.message, isThinking: event.isThinking, isFinal: event.isFinal,
                                                      sources: content.sources, attachments: attachments, reasoning: content.reasoning, reasoningDuration: content.reasoningDuration, failure: content.failure))
                    }
                    continuation.finish()
                } catch { continuation.finish(throwing: error) }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
