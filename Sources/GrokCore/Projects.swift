import Foundation
import Observation

/// A subset of the Lucide icon IDs accepted by Grok's project icon picker.
public enum ProjectIcon: String, CaseIterable, Sendable {
    case folder, briefcase, code, globe, lightbulb, rocket, palette, camera, music, heart, star, calendar
    case book = "book-open"
    case education = "graduation-cap"
    case science = "flask-conical"
    case computer = "laptop"

    public var encodedValue: String { "l:\(rawValue):lime" }
}

public struct GrokProject: Identifiable, Equatable, Sendable {
    public let id: String
    public let name: String
    public let description: String
    public let icon: String

    public init(id: String, name: String, description: String = "", icon: String = ProjectIcon.book.encodedValue) {
        self.id = id
        self.name = name
        self.description = description
        self.icon = icon
    }
}

@MainActor public protocol ProjectServing: AnyObject {
    func projects() async throws -> [GrokProject]
    func projectConversations(id: String, pageToken: String?) async throws -> HistoryPage
    func createProject(name: String, description: String, icon: ProjectIcon) async throws -> GrokProject
    func renameProject(id: String, name: String) async throws
    func deleteProject(id: String) async throws
    func addConversationToProject(conversationID: String, projectID: String) async throws
    func removeConversationFromProject(conversationID: String, projectID: String) async throws
}

public enum ProjectFailure: LocalizedError {
    case missingName, invalidResponse

    public var errorDescription: String? {
        switch self {
        case .missingName: return L10n.text("Enter a project name.")
        case .invalidResponse: return L10n.text("Grok did not return a project ID. Refresh the project list before trying again.")
        }
    }
}

@MainActor @Observable public final class ProjectStore {
    public private(set) var items: [GrokProject] = []
    public private(set) var isLoading = false
    public private(set) var isCreating = false
    public private(set) var loadError: DisplayError?
    public private(set) var createError: DisplayError?
    public private(set) var actionError: DisplayError?
    public private(set) var updatingProjectID: String?
    public private(set) var movingConversationID: String?
    public private(set) var conversations: [String: [ChatSummary]] = [:]
    public private(set) var loadingConversations: Set<String> = []
    public private(set) var conversationErrors: [String: DisplayError] = [:]
    public private(set) var conversationRevisions: [String: Int] = [:]
    @ObservationIgnored private var conversationTokens: [String: String] = [:]
    @ObservationIgnored private var conversationRequests: [String: UUID] = [:]
    @ObservationIgnored private var consumedConversationTokens: [String: Set<String>] = [:]
    @ObservationIgnored private let service: any ProjectServing
    @ObservationIgnored private var generation = UUID()
    @ObservationIgnored private var loaded = false

    public init(service: any ProjectServing) { self.service = service }

    public var isBusy: Bool { isLoading || isCreating || updatingProjectID != nil || movingConversationID != nil }

    public func hasMoreConversations(in id: String) -> Bool { conversationTokens[id] != nil }

    public func loadConversations(projectID id: String, loadMore: Bool = false) async {
        guard items.contains(where: { $0.id == id }), !loadingConversations.contains(id),
              !loadMore || conversationTokens[id] != nil else { return }
        let current = generation
        let request = UUID()
        let token = loadMore ? conversationTokens[id] : nil
        conversationRequests[id] = request
        loadingConversations.insert(id)
        conversationErrors[id] = nil
        defer { if conversationRequests[id] == request { loadingConversations.remove(id) } }
        do {
            let page = try await service.projectConversations(id: id, pageToken: token)
            try Task.checkCancellation()
            guard current == generation, conversationRequests[id] == request,
                  items.contains(where: { $0.id == id }) else { return }
            var seen = Set<String>()
            conversations[id] = ((loadMore ? conversations[id] ?? [] : []) + page.items)
                .filter { !$0.id.isEmpty && seen.insert($0.id).inserted }
            if !loadMore { consumedConversationTokens[id] = [] }
            if let token { consumedConversationTokens[id, default: []].insert(token) }
            conversationTokens[id] = page.nextPageToken
            if let next = page.nextPageToken, consumedConversationTokens[id, default: []].contains(next) {
                conversationTokens[id] = nil
            }
        } catch {
            guard current == generation, conversationRequests[id] == request, !Task.isCancelled else { return }
            conversationErrors[id] = DisplayError(error)
        }
    }

    public func updateConversation(_ chat: ChatSummary) {
        for id in Array(loadingConversations) { invalidateConversations(projectID: id) }
        for id in Array(conversations.keys) {
            if let index = conversations[id]?.firstIndex(where: { $0.id == chat.id }) { conversations[id]?[index] = chat }
        }
    }

    public func removeConversation(id: String) {
        for projectID in Array(loadingConversations) { invalidateConversations(projectID: projectID) }
        for projectID in Array(conversations.keys) { conversations[projectID]?.removeAll { $0.id == id } }
    }

    private func invalidateConversations(projectID id: String) {
        conversationRequests[id] = UUID()
        loadingConversations.remove(id)
        conversations[id] = nil
        conversationTokens[id] = nil
        consumedConversationTokens[id] = nil
        conversationErrors[id] = nil
        conversationRevisions[id, default: 0] += 1
    }

    public func conversationCreated(in projectID: String) {
        guard items.contains(where: { $0.id == projectID }) else { return }
        invalidateConversations(projectID: projectID)
    }

    public func load(ifNeeded: Bool = false) async {
        guard !isBusy, !(ifNeeded && loaded) else { return }
        let current = generation
        isLoading = true
        loadError = nil
        defer { if current == generation { isLoading = false } }
        do {
            let projects = try await service.projects()
            try Task.checkCancellation()
            guard current == generation else { return }
            var seen = Set<String>()
            items = projects.filter { !$0.id.isEmpty && seen.insert($0.id).inserted }
            loaded = true
        } catch {
            guard current == generation, !Task.isCancelled else { return }
            loadError = DisplayError(error)
        }
    }

    public func create(name: String, description: String, icon: ProjectIcon) async -> Bool {
        guard !isBusy else { return false }
        createError = nil
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { createError = DisplayError(ProjectFailure.missingName); return false }
        let current = generation
        isCreating = true
        defer { if current == generation { isCreating = false } }
        do {
            let project = try await service.createProject(name: name, description: description.trimmingCharacters(in: .whitespacesAndNewlines), icon: icon)
            try Task.checkCancellation()
            guard current == generation else { return false }
            guard !project.id.isEmpty else { throw ProjectFailure.invalidResponse }
            items.removeAll { $0.id == project.id }
            items.insert(project, at: 0)
            return true
        } catch {
            guard current == generation, !Task.isCancelled else { return false }
            createError = DisplayError(error)
            return false
        }
    }

    public func clearCreateError() { createError = nil }
    public func clearActionError() { actionError = nil }

    public func rename(id: String, name: String) async -> Bool {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !isBusy, let project = items.first(where: { $0.id == id }) else { return false }
        guard !name.isEmpty else { actionError = DisplayError(ProjectFailure.missingName); return false }
        return await update(id: id) {
            try await self.service.renameProject(id: id, name: name)
        } commit: {
            if let index = self.items.firstIndex(where: { $0.id == id }) {
                self.items[index] = GrokProject(id: id, name: name, description: project.description, icon: project.icon)
            }
        }
    }

    public func delete(id: String) async -> Bool {
        guard !isBusy, items.contains(where: { $0.id == id }) else { return false }
        return await update(id: id) {
            try await self.service.deleteProject(id: id)
        } commit: {
            self.items.removeAll { $0.id == id }
            self.invalidateConversations(projectID: id)
        }
    }

    public func moveConversation(id: String, to projectID: String) async -> Bool {
        guard !isBusy, !id.isEmpty, items.contains(where: { $0.id == projectID }) else { return false }
        let current = generation
        actionError = nil
        movingConversationID = id
        defer { if current == generation { movingConversationID = nil } }
        do {
            try await service.addConversationToProject(conversationID: id, projectID: projectID)
            try Task.checkCancellation()
            guard current == generation else { return false }
            invalidateConversations(projectID: projectID)
            return true
        } catch {
            guard current == generation, !Task.isCancelled else { return false }
            actionError = DisplayError(error)
            return false
        }
    }

    private func update(id: String, operation: () async throws -> Void, commit: () -> Void) async -> Bool {
        let current = generation
        actionError = nil
        updatingProjectID = id
        defer { if current == generation { updatingProjectID = nil } }
        do {
            try await operation()
            try Task.checkCancellation()
            guard current == generation else { return false }
            commit()
            return true
        } catch {
            guard current == generation, !Task.isCancelled else { return false }
            actionError = DisplayError(error)
            return false
        }
    }

    public func removeConversation(id: String, from projectID: String) async -> Bool {
        guard !isBusy, !id.isEmpty, items.contains(where: { $0.id == projectID }) else { return false }
        let current = generation
        movingConversationID = id
        actionError = nil
        defer { if current == generation { movingConversationID = nil } }
        do {
            try await service.removeConversationFromProject(conversationID: id, projectID: projectID)
            try Task.checkCancellation()
            guard current == generation else { return false }
            invalidateConversations(projectID: projectID)
            return true
        } catch {
            guard current == generation, !Task.isCancelled else { return false }
            actionError = DisplayError(error)
            return false
        }
    }

    public func shutdown() {
        generation = UUID()
        items = []
        loaded = false
        isLoading = false
        isCreating = false
        loadError = nil
        createError = nil
        actionError = nil
        updatingProjectID = nil
        movingConversationID = nil
        conversations = [:]
        loadingConversations = []
        conversationErrors = [:]
        conversationRevisions = [:]
        conversationRequests = [:]
        conversationTokens = [:]
        consumedConversationTokens = [:]
    }
}
