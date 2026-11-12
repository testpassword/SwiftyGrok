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
    func publicChat(_ link: PublicChatLink) async throws -> PublicChat
    func continuePublicChat(_ link: PublicChatLink) async throws -> ChatSummary
    func upload(file: DraftFile) async throws -> String
    func transcribe(audio: Data) async throws -> String
    func reply(conversationID: String?, parentID: String?, text: String, modeID: String, temporary: Bool, fileIDs: [String], projectID: String?) async throws -> AsyncThrowingStream<ReplyEvent, Error>
}

@MainActor
public final class GrokService: GrokServing, ProjectServing, SharedConversationServing {
    private let client: GrokClient
    private var assetCache: [String: MessageAttachment] = [:]
    private let cardHistory: any ResponseCardHistoryLoading
    private var cardCache: [String: ResponseCardContent] = [:]

    public func usageLimit(modeID: String) async throws -> UsageWindow {
        let limit = try await client.rateLimits(modelName: modeID)
        let remaining = limit.remainingResponses.flatMap { $0 >= 0 ? $0 : nil }
        let reset = limit.resetAt ?? limit.resetAfterSeconds.map { limit.fetchedAt.addingTimeInterval(Double($0)) }
        // A window duration is not a reset countdown; do not manufacture a reset date.
        return UsageWindow(id: modeID, remaining: remaining, resetAt: reset)
    }

    public func subscriptionName() async throws -> String {
        let subscriptions = try await client.subscriptionsResponse()
        return subscriptions.currentSubscription?.displayName ?? "Free"
    }

    public func accountUsage() async throws -> UsageSnapshot {
        let response = try await client.creditsResponse()
        return try CreditsUsageParser.parse(JSONSerialization.data(withJSONObject: response.value), product: .chat)
    }

    public init(credentials: SessionCredentials, session: URLSession? = nil, cardHistory: (any ResponseCardHistoryLoading)? = nil) throws {
        self.cardHistory = cardHistory ?? GatewayCardHistory(credentials: credentials)
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
        let page = try await client.listConversationPage(pageToken: pageToken, searchQuery: search, excludeProjects: true)
        let items = page.conversations.filter { !$0.temporary }.map {
            ChatSummary(id: $0.conversationId, title: $0.title, preview: $0.preview, modifiedAt: GrokDate.parse($0.modifyTime), isPinned: $0.starred)
        }
        return HistoryPage(items: items, nextPageToken: page.nextPageToken)
    }

    public func modes() async throws -> [ChatMode] {
        try await client.listModes(locale: L10n.languageCode).map {
            ChatMode(id: $0.id, name: $0.displayName, summary: $0.summary, iconHint: $0.iconHint, badgeText: $0.badgeText,
                     isAvailable: $0.isAvailable, unavailableReason: $0.unavailableReason, minimumSubscriptionTier: $0.minimumSubscriptionTier)
        }
    }

    public func projects() async throws -> [GrokProject] {
        var workspaces: [GrokWorkspace] = []
        var token: String?
        var consumed = Set<String>()
        repeat {
            try Task.checkCancellation()
            let page = try await client.listWorkspacesResponse(options: GrokWorkspaceListOptions(pageToken: token))
            workspaces += page.workspaces
            token = page.nextPageToken
            if let token, !consumed.insert(token).inserted { throw GrokError.decodingError(CocoaError(.coderReadCorrupt)) }
        } while token != nil
        return workspaces.compactMap { workspace in
            guard let id = workspace.workspaceId ?? workspace.id, !id.isEmpty else { return nil }
            return GrokProject(id: id, name: workspace.name ?? workspace.title ?? L10n.text("Untitled"),
                               description: workspace.customPersonality ?? "", icon: workspace.icon ?? ProjectIcon.book.encodedValue)
        }
    }

    public func createProject(name: String, description: String, icon: ProjectIcon, color: ProjectColor = .green) async throws -> GrokProject {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw ProjectFailure.missingName }
        let encodedIcon = icon.encodedValue(color: color)
        let result = try await client.createWorkspace(name: name, icon: encodedIcon, customPersonality: description, preferredModel: "auto")
        guard let workspace = result.workspace, let id = workspace.workspaceId ?? workspace.id, !id.isEmpty else {
            throw ProjectFailure.invalidResponse
        }
        return GrokProject(id: id, name: workspace.name ?? name, description: workspace.customPersonality ?? description,
                           icon: workspace.icon ?? encodedIcon)
    }

    public func updateProject(id: String, name: String, description: String, icon: String) async throws {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw ProjectFailure.missingName }
        try await client.updateWorkspace(workspaceId: id, name: name, customPersonality: description, icon: icon)
    }

    public func projectConversations(id: String, pageToken: String?) async throws -> HistoryPage {
        guard !id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw GrokError.notFound }
        let page = try await client.listConversationPage(pageToken: pageToken, workspaceId: id)
        return HistoryPage(items: page.conversations.filter { !$0.temporary }.map {
            ChatSummary(id: $0.conversationId, title: $0.title, preview: $0.preview,
                        modifiedAt: GrokDate.parse($0.modifyTime), isPinned: $0.starred)
        }, nextPageToken: page.nextPageToken)
    }

    public func deleteProject(id: String) async throws {
        _ = try await client.deleteWorkspace(workspaceId: id)
    }

    public func addConversationToProject(conversationID: String, projectID: String) async throws {
        _ = try await client.addConversationToWorkspace(workspaceId: projectID, conversationId: conversationID)
    }

    public func removeConversationFromProject(conversationID: String, projectID: String) async throws {
        try await client.removeConversationFromWorkspace(workspaceId: projectID, conversationId: conversationID)
    }

    public func profile() async throws -> AccountProfile {
        let profile = try await client.userProfile()
        return AccountProfile(name: profile.name, email: profile.email, imageURL: profile.imageURL)
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

    public func sharedConversations(pageToken: String?) async throws -> SharedConversationPage {
        let page = try await client.ownedShareLinks(pageToken: pageToken)
        let items = page.shareLinks.compactMap { link -> SharedConversation? in
            guard link.isPublic == true, !link.shareLinkId.isEmpty else { return nil }
            let token = link.publicId.flatMap { $0.isEmpty ? nil : $0 } ?? link.shareLinkId
            var parts = URLComponents()
            parts.scheme = "https"; parts.host = "grok.com"; parts.path = "/share/\(token)"
            let url = parts.url.flatMap { PublicChatLink(url: $0)?.url }
            return SharedConversation(id: link.shareLinkId, conversationID: link.conversationId,
                title: link.title ?? L10n.text("Untitled"), url: url, views: link.viewCount,
                createdAt: GrokDate.parse(link.createTime ?? ""))
        }
        return SharedConversationPage(items: items, nextPageToken: page.nextPageToken)
    }

    public func revokeSharedConversation(id: String) async throws {
        try await client.revokeShareLink(id: id)
    }

    public func publicChat(_ link: PublicChatLink) async throws -> PublicChat {
        let snapshot = try await client.sharedConversation(shareLinkId: link.id)
        guard snapshot.isPublic == true, let responses = snapshot.responses else { throw GrokError.notFound }
        let visible = responses.filter { $0.sender.lowercased() != "system" }
        let ids = Set(visible.map(\.responseId))
        var messages: [ChatMessage] = []
        for response in visible {
            try Task.checkCancellation()
            let sender = response.sender.lowercased()
            let role: ChatMessage.Role = ["human", "user"].contains(sender) ? .user :
                (["assistant", "model", "grok"].contains(sender) ? .assistant : .other)
            let content = GrokMessageContent(response.richContent)
            // Public snapshots omit the system root or the unshared prefix.
            // Never fetch missing private nodes from the original conversation.
            let parent = response.parentResponseId.flatMap { ids.contains($0) ? $0 : nil }
            messages.append(ChatMessage(id: response.responseId, parentID: parent, role: role, text: response.message,
                createdAt: GrokDate.parse(response.createTime), sources: content.sources,
                attachments: try await resolveAttachments(content.attachments), reasoning: content.reasoning,
                reasoningDuration: content.reasoningDuration, failure: content.failure))
        }
        let thread = try ChatThread(responses: messages)
        var reached = Set<String>()
        for branch in thread.branches { reached.formUnion(try thread.path(to: branch.id).map(\.id)) }
        guard reached.count == messages.count else { throw ClientFailure.invalidThread }
        guard !messages.isEmpty else { throw ClientFailure.emptyConversation }
        return PublicChat(summary: ChatSummary(id: snapshot.conversation.conversationId,
            title: snapshot.conversation.title), thread: thread)
    }

    public func continuePublicChat(_ link: PublicChatLink) async throws -> ChatSummary {
        let owned = try await client.cloneSharedConversation(shareLinkId: link.id)
        guard !owned.conversationId.isEmpty, !owned.temporary else { throw ClientFailure.invalidThread }
        return ChatSummary(id: owned.conversationId, title: owned.title,
                           modifiedAt: GrokDate.parse(owned.modifyTime) ?? Date(), isPinned: owned.starred)
    }

    public func transcribe(audio: Data) async throws -> String {
        try await client.speechToText(audioData: audio, audioFormat: "m4a").text
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
        let candidates = responses.filter { ResponseCardContent.needsHistory($0.richContent) }.map(\.responseId)
        let missing = candidates.filter { cardCache[$0] == nil }
        var cardsFailed = false
        if !missing.isEmpty {
            do {
                let loaded = try await cardHistory.load(conversationID: id, responseIDs: missing)
                try Task.checkCancellation()
                if cardCache.count + loaded.count > 256 { cardCache.removeAll() }
                cardCache.merge(loaded) { _, new in new }
            } catch {
                try Task.checkCancellation()
                cardsFailed = true
            }
        }
        for index in messages.indices where candidates.contains(messages[index].id) {
            if let cards = cardCache[messages[index].id] {
                messages[index].contentBlocks = cards.blocks(matching: messages[index].text)
            } else { messages[index].cardsUnavailable = cardsFailed }
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

    public func reply(conversationID: String?, parentID: String?, text: String, modeID: String, temporary: Bool = false, fileIDs: [String] = [], projectID: String? = nil) async throws -> AsyncThrowingStream<ReplyEvent, Error> {
        if !temporary, let projectID, projectID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { throw GrokError.notFound }
        let options = GrokMessageOptions(temporary: temporary, modeId: modeID, fileAttachments: fileIDs,
                                         workspaceIds: temporary ? [] : projectID.map { [$0] } ?? [])
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
