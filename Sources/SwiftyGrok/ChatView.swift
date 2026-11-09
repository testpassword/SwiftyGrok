import SwiftUI
import AppKit
import GrokCore
import GrokUsage
import UniformTypeIdentifiers

@MainActor private struct AccountLimitsPopover: View {
    let name: String?
    let email: String?
    let modes: [ChatMode]
    @State private var monitor = UsageMonitor.shared

    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            let snapshot = monitor.snapshots.chat
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(name ?? L10n.text("Profile")).font(.headline).lineLimit(1)
                    if let email, email.caseInsensitiveCompare(name ?? "") != .orderedSame {
                        Spacer(minLength: 0)
                        Text(email).font(.caption).foregroundStyle(.secondary)
                            .lineLimit(1).truncationMode(.middle).help(email)
                    }
                }
                Text(UsageText.text("Chat limits")).font(.subheadline.weight(.semibold))
                if snapshot.fetchedAt == nil {
                    if monitor.isRefreshing {
                        ProgressView().controlSize(.small)
                    } else {
                        Text(UsageText.status(snapshot.status)).font(.callout).foregroundStyle(.secondary)
                    }
                } else {
                    ForEach(["fast", "expert", "heavy"], id: \.self) { id in
                        let window = snapshot.windows.first(where: { $0.id == id }) ?? UsageWindow(id: id)
                        let mode = modes.first(where: { $0.id == id }) ?? ChatMode(id: id, name: id.capitalized)
                        HStack(spacing: 12) {
                            Image(systemName: mode.symbolName).font(.system(size: 18, weight: .medium))
                                .frame(width: 38, height: 38)
                                .background(.primary.opacity(0.07), in: Circle())
                                .accessibilityHidden(true)
                            VStack(alignment: .leading, spacing: 3) {
                                HStack {
                                    Text(UsageText.text(id.capitalized)).fontWeight(.medium)
                                    Spacer()
                                    Text(value(window, at: context.date)).monospacedDigit()
                                }.font(.callout)
                                if let percent = window.remainingPercent, !window.hasReset(at: context.date) {
                                    ProgressView(value: percent, total: 100)
                                }
                                if window.hasReset(at: context.date) {
                                    Text(UsageText.text("Awaiting refresh"))
                                } else if let reset = window.resetAt {
                                    Text(UsageText.format("Resets %@", reset.formatted(date: .abbreviated, time: .shortened)))
                                } else {
                                    Text(UsageText.text("Reset not reported"))
                                }
                            }
                            .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    if snapshot.isStale(at: context.date) {
                        Text(UsageText.text("Out of date")).font(.caption).foregroundStyle(.orange)
                    }
                }
            }
            .frame(width: 300, alignment: .leading)
            .padding(16)
        }
        .task {
            if monitor.snapshots.chat.isStale(at: Date()) { await monitor.refresh() }
        }
    }

    private func value(_ window: UsageWindow, at date: Date) -> String {
        guard !window.hasReset(at: date) else { return "—" }
        if let remaining = window.remaining { return UsageText.format("Remaining: %@", String(remaining)) }
        if let percent = window.remainingPercent {
            return UsageText.format("Remaining: %@%%", percent.formatted(.number.precision(.fractionLength(0))))
        }
        return "—"
    }
}

@MainActor struct ChatView: View {
    @Bindable var store: ChatStore
    @Bindable var app: AppModel
    @State private var followResponse = true
    @State private var appearance = AppearanceSettings.shared
    @State private var showAccountLimits = false
    @State private var chatToRename: ChatSummary?
    @State private var renameTitle = ""
    @State private var showRename = false
    @State private var chatToDelete: ChatSummary?
    @State private var showDelete = false
    @State private var shareTarget: ConversationShareTarget?
    @State private var shareAnchor: ShareAnchor?
    @State private var showCreateProject = false
    @State private var projectToRename: GrokProject?
    @State private var projectToDelete: GrokProject?
    @State private var showDeleteProject = false
    @AppStorage("projects.expanded") private var projectsExpanded = true
    @State private var expandedProjectIDs: Set<String> = []
    @State private var composerFocusRequest: UUID?
    @State private var columnVisibility: NavigationSplitViewVisibility = .automatic
    @FocusState private var searchFocused: Bool
    @FocusState private var historyFocused: Bool
    @Environment(\.openURL) private var openURL
    @Environment(\.colorScheme) private var colorScheme

    private enum ShareAnchor: Equatable {
        case toolbar
        case row(String)
    }

    private func sharePresentation(at anchor: ShareAnchor) -> Binding<ConversationShareTarget?> {
        Binding(get: { shareAnchor == anchor ? shareTarget : nil }, set: { target in
            guard shareAnchor == anchor else { return }
            shareTarget = target
            if target == nil { shareAnchor = nil }
        })
    }

    private var actionBackground: Color { colorScheme == .dark ? .white : .black }
    private var actionForeground: Color { colorScheme == .dark ? .black : .white }

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            sidebar
                .navigationSplitViewColumnWidth(min: 220, ideal: 280, max: 420)
                .disabled(store.isContinuingPublicChat)
        } detail: {
            VStack(spacing: 0) {
                if let error = store.error { errorBanner(error) }
                if let projects = app.projects, let error = projects.actionError, projectToRename == nil {
                    HStack(spacing: 12) {
                        Text(error.message).font(.callout).textSelection(.enabled)
                        Spacer(minLength: 0)
                        if error.needsLogin {
                            Button(L10n.text("Sign in again")) { app.showLogin = true }
                        }
                        Button { projects.clearActionError() } label: { Image(systemName: "xmark") }
                            .buttonStyle(.plain).accessibilityLabel(L10n.text("Close"))
                    }.padding(12).background(.thinMaterial)
                }
                conversation
            }
            .background(appearance.theme.chatBackground.ignoresSafeArea())
            .modifier(ChatFileDropTarget(store: store))
            .navigationTitle(store.selectedConversationID == nil ? selectedProject?.name ?? store.title : store.title)
            .toolbar {
                ToolbarItemGroup(placement: .primaryAction) {
                    if store.isLoadingMessages { ProgressView().controlSize(.small) }
                    if let link = store.publicChatLink {
                        Button { openURL(link.url) } label: {
                            Label(L10n.text("Browser"), systemImage: "safari")
                        }.help(L10n.text("Open in browser"))
                    }
                    if !store.isTemporary, store.branches.count > 1 {
                        Menu {
                            ForEach(Array(store.branches.enumerated()), id: \.element.id) { index, branch in
                                Button {
                                    store.selectBranch(branch.id)
                                } label: {
                                    Label(L10n.format("Branch %@: %@", String(index + 1), branch.label), systemImage: branch.id == store.selectedLeafID ? "checkmark" : "arrow.triangle.branch")
                                }
                            }
                        } label: { Label(L10n.text("Branches"), systemImage: "arrow.triangle.branch") }
                        .disabled(store.isSending || store.isLoadingMessages)
                    }
                    if !store.isTemporary, let id = store.selectedConversationID,
                       let url = URL(string: "https://grok.com/c/\(id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? id)") {
                        Button { openURL(url) } label: {
                            Label(L10n.text("Browser"), systemImage: "safari")
                        }
                        .help(L10n.text("Open in browser")).accessibilityLabel(L10n.text("Open in browser"))
                        Button {
                            guard let responseID = store.selectedLeafID else { return }
                            shareAnchor = .toolbar
                            shareTarget = ConversationShareTarget(id: id, title: store.title, responseID: responseID)
                        } label: {
                            Label(L10n.text("Share"), systemImage: "square.and.arrow.up")
                        }
                        .help(L10n.text("Share")).accessibilityLabel(L10n.text("Share"))
                        .disabled(store.isSending || store.isLoadingMessages || store.needsReload || store.selectedLeafID == nil || store.updatingConversations.contains(id))
                        .popover(item: sharePresentation(at: .toolbar), arrowEdge: .top) { target in
                            ConversationSharePopover(target: target, store: store)
                        }
                        if !projectTargets.isEmpty {
                            Menu {
                                ForEach(projectTargets) { project in
                                    Button { moveConversation(id, to: project.id) } label: {
                                        Label { Text(project.name) } icon: { ProjectBadge(encoded: project.icon) }
                                    }
                                }
                            } label: {
                                Label(L10n.text("Move to project"), systemImage: "folder.badge.plus")
                            }
                            .help(L10n.text("Move to project"))
                            .disabled(!canMoveConversation(id))
                        }
                        if let projectID = store.selectedProjectID {
                            Button { removeConversation(id, from: projectID) } label: {
                                Label(L10n.text("Remove from project"), systemImage: "folder.badge.minus")
                            }
                            .help(L10n.text("Remove from project"))
                            .disabled(!canMoveConversation(id))
                        }
                        Button(role: .destructive) {
                            chatToDelete = ChatSummary(id: id, title: store.title); showDelete = true
                        } label: {
                            Label(L10n.text("Delete chat"), systemImage: "trash")
                        }
                        .help(L10n.text("Delete chat")).accessibilityLabel(L10n.text("Delete chat"))
                        .disabled(store.isSending || store.updatingConversations.contains(id))
                    }
                }
            }
        }
        .focusedSceneValue(\.chatSearch, activateSearch)
        .task(id: store.selectionID) { await store.loadSelectedConversation() }
        .task { await store.loadModes() }
        .task { await store.loadProfile() }
        .task { await app.projects?.load(ifNeeded: true) }
        .onChange(of: app.projects?.items.map(\.id) ?? []) { _, ids in
            if let id = store.selectedProjectID, !ids.contains(id), app.projects?.isLoading == false { store.leaveProject(id) }
        }
        .sheet(isPresented: $showCreateProject) {
            if let projects = app.projects { CreateProjectSheet(projects: projects) }
        }
        .sheet(item: $projectToRename) { project in
            if let projects = app.projects { RenameProjectSheet(project: project, projects: projects) }
        }
        .task(id: store.search) {
            do { try await Task.sleep(for: .milliseconds(300)) } catch { return }
            await store.refreshHistory()
        }
        .confirmationDialog(L10n.text("Delete project?"), isPresented: $showDeleteProject, titleVisibility: .visible, presenting: projectToDelete) { project in
            Button(L10n.text("Delete"), role: .destructive) {
                Task { if await app.projects?.delete(id: project.id) == true { await store.refreshHistory() } }
            }
            Button(L10n.text("Cancel"), role: .cancel) { projectToDelete = nil }
        } message: { project in
            Text(L10n.format("“%@” will be deleted.", project.name))
        }
        .alert(L10n.text("Rename chat"), isPresented: $showRename) {
            TextField(L10n.text("Title"), text: $renameTitle)
            Button(L10n.text("Cancel"), role: .cancel) { chatToRename = nil }
            Button(L10n.text("Save")) {
                guard let chat = chatToRename else { return }
                let title = renameTitle
                chatToRename = nil
                Task { await store.renameConversation(id: chat.id, title: title) }
            }
            .disabled(renameTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .confirmationDialog(L10n.text("Delete chat?"), isPresented: $showDelete, titleVisibility: .visible, presenting: chatToDelete) { chat in
            Button(L10n.text("Delete"), role: .destructive) { Task { await store.deleteConversation(id: chat.id) } }
            Button(L10n.text("Cancel"), role: .cancel) { chatToDelete = nil }
        } message: { chat in
            Text(L10n.format("“%@” will be deleted from your Grok history.", chat.title))
        }
    }

    @ViewBuilder private var conversation: some View {
        if #available(macOS 26.0, *) {
            conversationContent
                .scrollEdgeEffectHidden(true, for: .bottom)
                .safeAreaBar(edge: .bottom, spacing: 0) { composer }
        } else {
            conversationContent.safeAreaInset(edge: .bottom, spacing: 0) { composer }
        }
    }

    @ViewBuilder private var conversationContent: some View {
        if store.isLoadingMessages && store.messages.isEmpty {
            ProgressView(L10n.text("Loading messages…"))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if store.messages.isEmpty {
            emptyConversation
        } else {
            transcript
        }
    }

    @ViewBuilder private var sidebar: some View {
        Group {
            if #available(macOS 26.0, *) {
                historyList
                    .scrollEdgeEffectStyle(.soft, for: [.top, .bottom])
                    .scrollEdgeEffectHidden(false, for: .top)
                    .safeAreaBar(edge: .bottom, spacing: 0) { historyControls }
            } else {
                historyList
                    .safeAreaInset(edge: .bottom, spacing: 0) { historyControls }
            }
        }
        .background(SidebarMaterial().ignoresSafeArea())
    }

    private var historyList: some View {
        List {
            projectsHeader
                .listRowInsets(EdgeInsets())
                .listRowSeparator(.hidden)
                .listRowBackground(Color.clear)
            Group {
                if projectsExpanded, let projects = app.projects {
                    ForEach(projects.items) { project in
                        projectRow(project, projects: projects)
                            .task(id: "\(expandedProjectIDs.contains(project.id))-\(projects.conversationRevisions[project.id, default: 0])") {
                                guard expandedProjectIDs.contains(project.id) else { return }
                                if let chats = projects.conversations[project.id] {
                                    store.registerProjectConversations(chats)
                                } else {
                                    await loadProjectConversations(project.id)
                                }
                            }
                        if expandedProjectIDs.contains(project.id) {
                            projectChatRows(project, projects: projects)
                        }
                    }
                    if projects.isLoading {
                        ProgressView().controlSize(.small).frame(maxWidth: .infinity).listRowSeparator(.hidden)
                    } else if let error = projects.loadError {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(error.message).font(.caption).foregroundStyle(.secondary)
                            Button(L10n.text("Retry")) { Task { await projects.load() } }
                        }.listRowSeparator(.hidden)
                    } else if projects.items.isEmpty {
                        Text(L10n.text("No projects yet")).font(.caption).foregroundStyle(.secondary)
                            .listRowSeparator(.hidden)
                    }
                }
                ForEach(store.conversations) { chat in
                    conversationRow(chat)
                }
                if store.hasMoreHistory {
                    Button(L10n.text("Load more")) { Task { await store.refreshHistory(loadMore: true) } }
                        .disabled(store.isLoadingHistory)
                        .listRowSeparator(.hidden)
                }
            }
            .disabled(store.isSending)
        }
            .listStyle(.plain).scrollContentBackground(.hidden)
            .focusable().focused($historyFocused).focusEffectDisabled()
            .background(HistoryKeyboardShortcuts(onKeyDown: handleHistoryShortcut).frame(maxWidth: .infinity, maxHeight: .infinity))
            .environment(\.defaultMinListRowHeight, 38)
            .onKeyPress(.upArrow) { moveHistorySelection(-1) }
            .onKeyPress(.downArrow) { moveHistorySelection(1) }
            .overlay {
                if store.conversations.isEmpty && !store.isLoadingHistory && (!projectsExpanded || app.projects?.items.isEmpty != false) {
                    Text(store.search.isEmpty ? L10n.text("Your conversations will appear here") : L10n.text("No results"))
                        .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center).padding(24)
                }
            }
    }

    private func projectRow(_ project: GrokProject, projects: ProjectStore) -> some View {
        HStack(spacing: 8) {
            Button {
                store.selectProject(project.id)
                historyFocused = false
                searchFocused = false
                composerFocusRequest = UUID()
            } label: {
                HStack(spacing: 8) {
                    ProjectBadge(encoded: project.icon)
                    Text(project.name).font(.system(size: 13)).lineLimit(1)
                    Spacer(minLength: 0)
                }.contentShape(Rectangle())
            }
            .buttonStyle(.plain).disabled(projects.updatingProjectID == project.id)
            .accessibilityAddTraits(store.selectedProjectID == project.id && store.selectedConversationID == nil ? .isSelected : [])
            if projects.updatingProjectID == project.id { ProgressView().controlSize(.mini) }
            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    if !expandedProjectIDs.insert(project.id).inserted { expandedProjectIDs.remove(project.id) }
                }
            } label: {
                Image(systemName: expandedProjectIDs.contains(project.id) ? "chevron.down" : "chevron.right")
                    .font(.system(size: 11, weight: .semibold)).frame(width: 24, height: 24)
            }
            .buttonStyle(.borderless)
            .accessibilityLabel(L10n.format(expandedProjectIDs.contains(project.id) ? "Collapse %@" : "Expand %@", project.name))
        }
        .padding(.horizontal, 9).padding(.vertical, 4)
        .background(store.selectedProjectID == project.id && store.selectedConversationID == nil ? Color.accentColor.opacity(0.16) : .clear,
                    in: RoundedRectangle(cornerRadius: 8))
        .contentShape(Rectangle())
        .overlay {
            ProjectContextMenu(enabled: !projects.isBusy) {
                projectToRename = project
            } delete: {
                projectToDelete = project
                showDeleteProject = true
            }
        }
        .help(project.description)
        .listRowSeparator(.hidden)
        .listRowInsets(EdgeInsets(top: 1, leading: 5, bottom: 1, trailing: 5))
        .listRowBackground(Color.clear)
    }

    @ViewBuilder private func projectChatRows(_ project: GrokProject, projects: ProjectStore) -> some View {
        let chats = projects.conversations[project.id] ?? []
        ForEach(chats) { chat in
            conversationRow(chat, scope: "project-\(project.id)", indentation: 24, projectID: project.id)
        }
        if projects.loadingConversations.contains(project.id) {
            ProgressView().controlSize(.mini).frame(maxWidth: .infinity).listRowSeparator(.hidden)
        } else if let error = projects.conversationErrors[project.id] {
            VStack(alignment: .leading, spacing: 6) {
                Text(error.message).font(.caption).foregroundStyle(.secondary)
                Button(L10n.text("Retry")) { Task { await loadProjectConversations(project.id) } }
            }.padding(.leading, 24).listRowSeparator(.hidden)
        } else if projects.conversations[project.id] != nil && chats.isEmpty {
            Text(L10n.text("No chats in this project")).font(.caption).foregroundStyle(.secondary)
                .padding(.leading, 24).listRowSeparator(.hidden)
        } else if projects.hasMoreConversations(in: project.id) {
            Button(L10n.text("Load more")) { Task { await loadProjectConversations(project.id, loadMore: true) } }
                .padding(.leading, 24).listRowSeparator(.hidden)
        }
    }

    private func loadProjectConversations(_ id: String, loadMore: Bool = false) async {
        guard let projects = app.projects else { return }
        await projects.loadConversations(projectID: id, loadMore: loadMore)
        store.registerProjectConversations(projects.conversations[id] ?? [])
    }

    private func conversationRow(_ summary: ChatSummary, scope: String = "history", indentation: CGFloat = 0, projectID: String? = nil) -> some View {
        let chat = store.summary(id: summary.id) ?? summary
        return Button { store.select(chat.id, projectID: projectID); historyFocused = true } label: {
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(chat.title).font(.system(size: 13)).lineLimit(2)
                    if chat.isPinned {
                        Image(systemName: "pin.fill").font(.system(size: 10)).foregroundStyle(.secondary)
                            .accessibilityLabel(L10n.text("Pinned"))
                    }
                    if store.updatingConversations.contains(chat.id) { ProgressView().controlSize(.mini) }
                }
                if let date = chat.modifiedAt {
                    if Calendar.current.isDateInToday(date) {
                        Text(date, format: .dateTime.hour().minute()).font(.caption).foregroundStyle(.secondary)
                    } else {
                        Text(date, format: .dateTime.day().month().year()).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 7).padding(.leading, 9 + indentation).padding(.trailing, 9)
        }
            .buttonStyle(HistoryRowStyle(selected: store.selectedConversationID == chat.id))
            .overlay {
                ConversationContextMenu(pinned: chat.isPinned,
                                        enabled: !store.isSending && !store.updatingConversations.contains(chat.id),
                                        sharingEnabled: !store.requiresLogin && (chat.id != store.selectedConversationID ||
                                            (!store.isLoadingMessages && !store.needsReload && store.selectedLeafID != nil)),
                                        projects: projectTargets, moveEnabled: canMoveConversation(chat.id),
                                        move: { projectID in moveConversation(chat.id, to: projectID) },
                                        removeFromProject: projectID.map { id in { removeConversation(chat.id, from: id) } }) {
                    Task { await store.pinConversation(id: chat.id, pinned: !chat.isPinned) }
                } rename: {
                    chatToRename = chat; renameTitle = chat.title; showRename = true
                } openInBrowser: {
                    if let url = URL(string: "https://grok.com/c/\(chat.id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? chat.id)") {
                        openURL(url)
                    }
                } share: {
                    shareAnchor = .row("\(scope)-\(chat.id)")
                    shareTarget = ConversationShareTarget(id: chat.id, title: chat.title,
                                                          responseID: chat.id == store.selectedConversationID ? store.selectedLeafID : nil)
                } delete: {
                    chatToDelete = chat; showDelete = true
                }
            }
            .disabled(store.updatingConversations.contains(chat.id))
            .popover(item: sharePresentation(at: .row("\(scope)-\(chat.id)")), arrowEdge: .leading) { target in
                ConversationSharePopover(target: target, store: store)
            }
            .accessibilityValue(store.selectedConversationID == chat.id ? L10n.text("Selected") : "")
            .id("\(scope)-\(chat.id)")
            .listRowSeparator(.hidden)
            .listRowInsets(EdgeInsets(top: 1, leading: 5, bottom: 1, trailing: 5))
            .listRowBackground(Color.clear)
    }

    private func moveHistorySelection(_ offset: Int) -> KeyPress.Result {
        let chats = visibleHistoryChats
        guard !store.isSending, !chats.isEmpty else { return .ignored }
        let current = chats.firstIndex { $0.id == store.selectedConversationID } ?? (offset > 0 ? -1 : chats.count)
        let next = min(max(current + offset, 0), chats.count - 1)
        let id = chats[next].id
        let projectID = projectsExpanded ? app.projects?.items.first(where: {
            expandedProjectIDs.contains($0.id) && app.projects?.conversations[$0.id]?.contains(where: { $0.id == id }) == true
        })?.id : nil
        store.select(id, projectID: projectID)
        return .handled
    }

    private func handleHistoryShortcut(_ event: NSEvent) -> Bool {
        guard columnVisibility != .detailOnly, !store.isSending, !store.isContinuingPublicChat, !store.isTemporary, !searchFocused,
              !showRename, !showDelete, !app.confirmSignOut, !showCreateProject, projectToRename == nil,
              !showDeleteProject, shareTarget == nil, !app.showLogin,
              let chat = visibleHistoryChats.first(where: { $0.id == store.selectedConversationID }),
              !store.updatingConversations.contains(chat.id) else { return false }
        guard !event.isARepeat else { return true }
        switch event.keyCode {
        case 51, 117: // Delete, Forward Delete
            chatToDelete = chat
            showDelete = true
        case 36, 76: // Return, numeric keypad Enter
            chatToRename = chat
            renameTitle = chat.title
            showRename = true
        default: return false
        }
        return true
    }

    private var visibleHistoryChats: [ChatSummary] {
        let nested = projectsExpanded ? (app.projects?.items ?? []).filter { expandedProjectIDs.contains($0.id) }
            .flatMap { app.projects?.conversations[$0.id] ?? [] } : []
        var seen = Set<String>()
        return (nested + store.conversations).filter { seen.insert($0.id).inserted }
            .map { store.summary(id: $0.id) ?? $0 }
    }

    private var accountButton: some View {
        Button { showAccountLimits.toggle() } label: {
            AccountAvatar(url: store.accountImageURL, media: app.media, size: 32)
                .padding(4).modifier(FloatingGlass(cornerRadius: 20))
        }
        .buttonStyle(.plain).fixedSize()
        .accessibilityLabel(store.accountName ?? L10n.text("Profile"))
        .help(store.accountName ?? L10n.text("Profile"))
        .popover(isPresented: $showAccountLimits, arrowEdge: .bottom) {
            AccountLimitsPopover(name: store.accountName, email: store.accountEmail, modes: store.modes)
        }
    }

    private var projectsHeader: some View {
        HStack(spacing: 8) {
            Label(L10n.text("Projects"), systemImage: "folder")
                .labelStyle(.titleAndIcon)
                .font(.system(size: 13, weight: .semibold)).foregroundStyle(.primary)
            Button { showCreateProject = true } label: {
                Image(systemName: "plus").font(.system(size: 12, weight: .medium)).frame(width: 22, height: 22)
            }
            .buttonStyle(.borderless).help(L10n.text("New project"))
            .accessibilityLabel(L10n.text("New project"))
            .disabled(app.projects == nil || app.projects?.isBusy == true)
            Spacer(minLength: 8)
            Button {
                withAnimation(.easeInOut(duration: 0.2)) { projectsExpanded.toggle() }
            } label: {
                Image(systemName: projectsExpanded ? "chevron.down" : "chevron.right")
                    .font(.system(size: 11, weight: .semibold)).frame(width: 24, height: 24)
            }
            .buttonStyle(.borderless)
            .accessibilityLabel(L10n.text(projectsExpanded ? "Collapse projects" : "Expand projects"))
        }
        .padding(.horizontal, 14).padding(.vertical, 6)
    }

    private var historyControls: some View {
        HStack(spacing: 8) {
            if !searchExpanded { accountButton.transition(.opacity.combined(with: .scale(scale: 0.85))) }
            HStack(spacing: 8) {
                if store.isLoadingHistory { ProgressView().controlSize(.mini) }
                else { Image(systemName: "magnifyingglass").foregroundStyle(.secondary) }
                TextField(L10n.text("Search"), text: $store.search).textFieldStyle(.plain)
                    .accessibilityLabel(L10n.text("Search chats"))
                    .focused($searchFocused)
                    .onExitCommand { store.search = ""; searchFocused = false }
                if searchExpanded {
                    Button { store.search = ""; searchFocused = false } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                        .buttonStyle(.plain).accessibilityLabel(L10n.text("Close search"))
                }
            }
            .padding(.horizontal, 13).frame(height: 42)
            .modifier(FloatingGlass(cornerRadius: 21))
            if !searchExpanded { newChatButton
                .help(L10n.text("New chat · ⌘N")).accessibilityLabel(L10n.text("New chat")).disabled(store.isSending)
                .transition(.opacity.combined(with: .scale(scale: 0.85)))
            }
        }
        .animation(.easeInOut(duration: 0.2), value: searchExpanded)
        .padding(.horizontal, 10).padding(.top, 10).padding(.bottom, 14)
    }

    private func activateSearch() {
        columnVisibility = .all
        historyFocused = false
        // Focus after SwiftUI has restored the sidebar when it was hidden.
        DispatchQueue.main.async { searchFocused = true }
    }

    private var searchExpanded: Bool { searchFocused || !store.search.isEmpty }

    private var projectTargets: [GrokProject] { app.projects?.items ?? [] }
    private var selectedProject: GrokProject? { app.projects?.items.first { $0.id == store.selectedProjectID } }

    private func canMoveConversation(_ id: String) -> Bool {
        !store.isSending && !store.requiresLogin && !store.updatingConversations.contains(id) &&
        app.projects?.isBusy == false && !(store.isTemporary && store.selectedConversationID == id)
    }

    private func moveConversation(_ id: String, to projectID: String) {
        guard canMoveConversation(id), let projects = app.projects else { return }
        Task { _ = await store.moveConversation(id: id, to: projectID, projects: projects) }
    }

    private func removeConversation(_ id: String, from projectID: String) {
        guard canMoveConversation(id), let projects = app.projects else { return }
        Task { _ = await store.removeConversation(id: id, from: projectID, projects: projects) }
    }

    @ViewBuilder private var newChatButton: some View {
        if #available(macOS 26.0, *) {
            Button { store.newChat() } label: {
                Image(systemName: "square.and.pencil").font(.system(size: 18, weight: .medium))
                    .frame(width: 18, height: 18)
            }
            .buttonStyle(.glassProminent).buttonBorderShape(.circle).controlSize(.extraLarge)
            .tint(actionBackground).foregroundStyle(actionForeground)
        } else {
            Button { store.newChat() } label: {
                Image(systemName: "square.and.pencil").font(.system(size: 18, weight: .medium))
                    .foregroundStyle(actionForeground).frame(width: 42, height: 42).background(actionBackground, in: Circle())
            }.buttonStyle(.plain)
        }
    }

    @ViewBuilder private var emptyConversation: some View {
        if store.publicChatLink != nil {
            ContentUnavailableView {
                Label(L10n.text("Public chat"), systemImage: "bubble.left.and.bubble.right")
            } description: {
                Text(L10n.text("Could not load this public chat."))
            } actions: {
                Button(L10n.text("Retry")) { Task { await store.loadSelectedConversation() } }
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if selectedProject != nil && store.selectedConversationID == nil {
            VStack(spacing: 18) {
                Image(systemName: "bubble.left").font(.system(size: 32, weight: .regular))
                    .frame(width: 88, height: 88)
                    .background(.primary.opacity(0.06), in: Circle()).accessibilityHidden(true)
                Text(L10n.text("Start a conversation in this project"))
                    .font(.system(size: 22, weight: .semibold))
                Text(L10n.text("Use this project to keep conversations and files in one place"))
                    .font(.system(size: 16)).foregroundStyle(.secondary)
            }
            .multilineTextAlignment(.center).frame(maxWidth: 460).padding(24)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ordinaryEmptyConversation
        }
    }

    private var ordinaryEmptyConversation: some View {
        VStack(spacing: 16) {
            Spacer()
            if store.isTemporary {
                PrivateChatSymbol().stroke(.secondary.opacity(0.45), style: StrokeStyle(lineWidth: 5, dash: [11, 7]))
                    .frame(width: 68, height: 68).padding(.bottom, 8).accessibilityHidden(true)
            } else {
                GrokLogo().frame(width: 78, height: 78)
            }
            if store.isTemporary {
                Text(L10n.text("Private conversation"))
                    .font(.system(size: 28, weight: .medium, design: .rounded))
                Text(L10n.text("This conversation will not appear in your history and will be permanently deleted"))
                    .font(.system(size: 14)).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    .frame(maxWidth: 370)
                    .help(L10n.text("Grok usually deletes private conversations within 30 days; exceptions may apply under its policies."))
            } else if store.selectedConversationID != nil {
                Text(L10n.text("No messages in this chat yet"))
                    .font(.system(size: 28, weight: .medium, design: .rounded))
            }
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 18) {
                    ForEach(store.messages) { message in
                        MessageView(message: message, isStreaming: store.isSending && message.id == store.messages.last?.id,
                                    isThinking: store.isSending && store.isThinking && message.id == store.messages.last?.id,
                                    media: app.media, conversationURL: store.publicChatLink?.url ?? (store.isTemporary ? nil : store.selectedConversationID.flatMap { URL(string: "https://grok.com/c/\($0)") }))
                            .id(message.id)
                    }
                    Color.clear.frame(height: 1).id("bottom")
                }
                .frame(maxWidth: 960).padding(.horizontal, 18).padding(.top, 16).padding(.bottom, 14)
                .frame(maxWidth: .infinity)
            }
            .onAppear { proxy.scrollTo("bottom", anchor: .bottom) }
            .onChange(of: store.messages.count) { _, _ in
                if !store.isSending || followResponse { proxy.scrollTo("bottom", anchor: .bottom) }
            }
            .onChange(of: store.messages.last?.text) { _, _ in
                if store.isSending && followResponse { proxy.scrollTo("bottom", anchor: .bottom) }
            }
            .onChange(of: store.selectedLeafID) { _, _ in proxy.scrollTo("bottom", anchor: .bottom) }
        }
    }

    @ViewBuilder private var composer: some View {
        if store.publicChatLink != nil {
            continueChatButton
                .disabled(store.isLoadingMessages || store.needsReload || store.requiresLogin || store.isContinuingPublicChat)
                .help(L10n.text("Create a copy in your chat history"))
                .padding(.horizontal, 18).padding(.vertical, 14)
                .frame(maxWidth: .infinity)
        } else {
            ChatComposer(store: store, followResponse: $followResponse, focusRequest: composerFocusRequest, onSend: {
                guard store.selectedProjectID == nil || app.projects?.updatingProjectID != store.selectedProjectID else { return }
                store.send()
            })
            .disabled(store.selectedProjectID != nil && app.projects?.updatingProjectID == store.selectedProjectID)
        }
    }

    @ViewBuilder private var continueChatButton: some View {
        if #available(macOS 26.0, *) {
            Button { Task { await store.continuePublicChat() } } label: { continueChatLabel }
                .buttonStyle(.glass).buttonBorderShape(.capsule).controlSize(.regular)
        } else {
            Button { Task { await store.continuePublicChat() } } label: {
                continueChatLabel.padding(.horizontal, 16).padding(.vertical, 10)
                    .modifier(FloatingGlass(cornerRadius: 22))
            }.buttonStyle(.plain)
        }
    }

    private var continueChatLabel: some View {
        HStack(spacing: 8) {
            if store.isContinuingPublicChat { ProgressView().controlSize(.small) }
            else { Image(systemName: "bubble.left.and.bubble.right") }
            Text(L10n.text("Continue chat"))
        }.font(.system(size: 14, weight: .semibold)).padding(.horizontal, 6).frame(minHeight: 26)
    }

    private func errorBanner(_ error: DisplayError) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "exclamationmark.circle").foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 8) {
                Text(error.message).font(.callout).textSelection(.enabled)
                if error.systemPermission == .screenRecording { PermissionRecoveryHint() }
                HStack {
                    if let permission = error.systemPermission {
                        Button(L10n.text("Open System Settings")) { openURL(permission.settingsURL) }
                    }
                    if error.needsLogin || store.requiresLogin {
                        Button(L10n.text("Sign in again")) { app.showLogin = true }
                    } else {
                        if error.systemPermission == nil && (store.needsReload || error.allowsSessionRefresh) {
                            if store.isTemporary && store.needsReload {
                                Button(L10n.text("New private conversation")) { store.newChat() }
                            } else if store.selectionID != nil {
                                Button(L10n.text("Refresh chat")) { Task { await store.loadSelectedConversation() } }
                            }
                        }
                        if error.allowsSessionRefresh {
                            Button(L10n.text("Refresh session")) { app.showLogin = true }
                        }
                    }
                    if let text = store.recoveryText {
                        Button(L10n.text("Copy sent text")) {
                            ClipboardFeedback.shared.copy(text)
                        }
                    }
                }
                .disabled(store.isSending || store.isLoadingMessages)
            }
            Spacer(minLength: 0)
            if !store.needsReload && !store.requiresLogin {
                Button { store.error = nil } label: { Image(systemName: "xmark") }.buttonStyle(.plain)
            }
        }
        .padding(14).frame(maxWidth: .infinity, alignment: .leading).background(.orange.opacity(0.08))
    }
}

struct PermissionRecoveryHint: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(L10n.text("If access was already granted, remove SwiftyGrok from this permission list, add the app again, and enable access."))
                .foregroundStyle(.secondary).textSelection(.enabled)
            Link(L10n.text("Learn more"),
                 destination: URL(string: "https://github.com/testpassword/SwiftyGrok/issues/1")!)
        }
        .font(.callout)
    }
}

private struct PrivateChatSymbol: Shape {
    func path(in rect: CGRect) -> Path {
        let center = CGPoint(x: rect.midX, y: rect.minY + rect.height * 0.46)
        let radius = min(rect.width, rect.height) * 0.39
        var path = Path()
        path.addArc(center: center, radius: radius, startAngle: .degrees(106), endAngle: .degrees(146), clockwise: true)
        path.addQuadCurve(to: CGPoint(x: rect.minX + rect.width * 0.1, y: rect.minY + rect.height * 0.91),
                          control: CGPoint(x: rect.minX + rect.width * 0.21, y: rect.minY + rect.height * 0.77))
        let angle = Angle.degrees(106).radians
        path.addQuadCurve(to: CGPoint(x: center.x + CGFloat(cos(angle)) * radius, y: center.y + CGFloat(sin(angle)) * radius),
                          control: CGPoint(x: rect.minX + rect.width * 0.26, y: rect.minY + rect.height * 0.95))
        return path
    }
}

struct ComposerSendStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.opacity(configuration.isPressed ? 0.8 : 1)
    }
}

/// Use the system sidebar material so wallpaper tint, contrast and accessibility
/// preferences are applied by AppKit rather than an opaque SwiftUI background.
struct SidebarMaterial: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .sidebar
        view.blendingMode = .behindWindow
        view.state = .followsWindowActiveState
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {}
}

struct FloatingGlass: ViewModifier {
    var cornerRadius: CGFloat
    var backgroundOpacity: Double = 0
    var followsSystemTransparency = false
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius)
        let backed = content.background(Color(nsColor: .windowBackgroundColor).opacity(backgroundOpacity), in: shape)
        if #available(macOS 26.0, *) {
            // Regular glass follows the system's appearance without an added tint.
            // Manual density uses clear glass plus the selected background opacity.
            backed.glassEffect(followsSystemTransparency || reduceTransparency || contrast == .increased ? .regular : .clear, in: shape)
        } else {
            backed
                .background(.ultraThinMaterial, in: shape)
                .overlay(shape.strokeBorder(.primary.opacity(0.1)))
        }
    }
}

private struct GrokLogo: View {
    private var bundle: Bundle {
        #if SWIFT_PACKAGE
        Bundle.module
        #else
        Bundle.main
        #endif
    }

    var body: some View {
        Image("GrokLogo", bundle: bundle).renderingMode(.template).resizable().scaledToFit()
            .foregroundStyle(Color.primary.opacity(0.2)).accessibilityLabel("Grok")
    }
}

private struct HistoryRowStyle: ButtonStyle {
    let selected: Bool
    @State private var hovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(selected ? Color(nsColor: .alternateSelectedControlTextColor) : Color.primary)
            .contentShape(RoundedRectangle(cornerRadius: 10))
            .background(selected ? Color(nsColor: .selectedContentBackgroundColor) :
                            Color.primary.opacity(configuration.isPressed ? 0.07 : hovering ? 0.035 : 0),
                        in: RoundedRectangle(cornerRadius: 10))
            .onHover { hovering = $0 }
    }
}

private struct ChatSearchKey: FocusedValueKey {
    typealias Value = () -> Void
}

extension FocusedValues {
    var chatSearch: (() -> Void)? {
        get { self[ChatSearchKey.self] }
        set { self[ChatSearchKey.self] = newValue }
    }
}

/// Handle plain history shortcuts before a focused row's Button consumes Enter.
/// Native text editors, sheets, menus and other windows keep their own keys.
@MainActor private struct HistoryKeyboardShortcuts: NSViewRepresentable {
    let onKeyDown: (NSEvent) -> Bool

    func makeNSView(context: Context) -> ShortcutView { ShortcutView() }
    func updateNSView(_ view: ShortcutView, context: Context) { view.onKeyDown = onKeyDown }
    static func dismantleNSView(_ view: ShortcutView, coordinator: ()) { view.stop() }

    final class ShortcutView: NSView {
        var onKeyDown: ((NSEvent) -> Bool)?
        private var monitor: Any?
        private var trackingMenus = Set<ObjectIdentifier>()

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            stop()
            guard window != nil else { return }
            NotificationCenter.default.addObserver(self, selector: #selector(menuBegan(_:)), name: NSMenu.didBeginTrackingNotification, object: nil)
            NotificationCenter.default.addObserver(self, selector: #selector(menuEnded(_:)), name: NSMenu.didEndTrackingNotification, object: nil)
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self, let window = self.window,
                      window.isKeyWindow, event.window === window,
                      !self.isHiddenOrHasHiddenAncestor, !self.visibleRect.isEmpty,
                      window.attachedSheet == nil, NSApp.modalWindow == nil, self.trackingMenus.isEmpty,
                      !(window.firstResponder is NSTextView), !(window.firstResponder is NSTextField),
                      event.modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty,
                      [36, 76, 51, 117].contains(event.keyCode),
                      self.onKeyDown?(event) == true else { return event }
                return nil
            }
        }

        func stop() {
            if let monitor { NSEvent.removeMonitor(monitor); self.monitor = nil }
            NotificationCenter.default.removeObserver(self)
            trackingMenus.removeAll()
        }

        @objc private func menuBegan(_ notification: Notification) {
            if let menu = notification.object as? NSMenu { trackingMenus.insert(ObjectIdentifier(menu)) }
        }
        @objc private func menuEnded(_ notification: Notification) {
            if let menu = notification.object as? NSMenu { trackingMenus.remove(ObjectIdentifier(menu)) }
        }
    }
}
