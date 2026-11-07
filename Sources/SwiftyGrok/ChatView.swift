import SwiftUI
import AppKit
import GrokCore
import UniformTypeIdentifiers

@MainActor struct ChatView: View {
    @Bindable var store: ChatStore
    @Bindable var app: AppModel
    @State private var followResponse = true
    @State private var appearance = AppearanceSettings.shared
    @State private var confirmSignOut = false
    @State private var chatToRename: ChatSummary?
    @State private var renameTitle = ""
    @State private var showRename = false
    @State private var chatToDelete: ChatSummary?
    @State private var showDelete = false
    @State private var shareTarget: ConversationShareTarget?
    @State private var columnVisibility: NavigationSplitViewVisibility = .automatic
    @FocusState private var searchFocused: Bool
    @FocusState private var historyFocused: Bool
    @Environment(\.openURL) private var openURL
    @Environment(\.colorScheme) private var colorScheme

    private var actionBackground: Color { colorScheme == .dark ? .white : .black }
    private var actionForeground: Color { colorScheme == .dark ? .black : .white }

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            sidebar
                .navigationSplitViewColumnWidth(min: 220, ideal: 280, max: 420)
        } detail: {
            VStack(spacing: 0) {
                if let error = store.error { errorBanner(error) }
                conversation
            }
            .background(appearance.theme.chatBackground.ignoresSafeArea())
            .modifier(ChatFileDropTarget(store: store))
            .navigationTitle(store.title)
            .toolbar {
                ToolbarItemGroup(placement: .primaryAction) {
                    if store.isLoadingMessages { ProgressView().controlSize(.small) }
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
                            shareTarget = ConversationShareTarget(id: id, title: store.title, responseID: responseID)
                        } label: {
                            Label(L10n.text("Share"), systemImage: "square.and.arrow.up")
                        }
                        .help(L10n.text("Share")).accessibilityLabel(L10n.text("Share"))
                        .disabled(store.isSending || store.isLoadingMessages || store.needsReload || store.selectedLeafID == nil || store.updatingConversations.contains(id))
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
        .task(id: store.selectedConversationID) { await store.loadSelectedConversation() }
        .task { await store.loadModes() }
        .task { await store.loadProfile() }
        .sheet(item: $shareTarget) { target in ConversationShareSheet(target: target, store: store) }
        .task(id: store.search) {
            do { try await Task.sleep(for: .milliseconds(300)) } catch { return }
            await store.refreshHistory()
        }
        .confirmationDialog(L10n.text("Sign out of Grok? The session will be removed from Keychain."), isPresented: $confirmSignOut) {
            Button(L10n.text("Sign out"), role: .destructive) { app.signOut() }
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
                ForEach(store.conversations) { chat in
                  Button { store.select(chat.id); historyFocused = true } label: {
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
                    .padding(.vertical, 7).padding(.horizontal, 9)
                  }
                    .buttonStyle(HistoryRowStyle(selected: store.selectedConversationID == chat.id))
                    .overlay {
                        ConversationContextMenu(pinned: chat.isPinned,
                                                enabled: !store.isSending && !store.updatingConversations.contains(chat.id),
                                                sharingEnabled: !store.requiresLogin && (chat.id != store.selectedConversationID ||
                                                    (!store.isLoadingMessages && !store.needsReload && store.selectedLeafID != nil))) {
                            Task { await store.pinConversation(id: chat.id, pinned: !chat.isPinned) }
                        } rename: {
                            chatToRename = chat; renameTitle = chat.title; showRename = true
                        } openInBrowser: {
                            if let url = URL(string: "https://grok.com/c/\(chat.id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? chat.id)") {
                                openURL(url)
                            }
                        } share: {
                            shareTarget = ConversationShareTarget(id: chat.id, title: chat.title,
                                                                  responseID: chat.id == store.selectedConversationID ? store.selectedLeafID : nil)
                        } delete: {
                            chatToDelete = chat; showDelete = true
                        }
                    }
                    .disabled(store.updatingConversations.contains(chat.id))
                    .accessibilityValue(store.selectedConversationID == chat.id ? L10n.text("Selected") : "")
                    .id(chat.id)
                    .listRowSeparator(.hidden)
                    .listRowInsets(EdgeInsets(top: 1, leading: 5, bottom: 1, trailing: 5))
                    .listRowBackground(Color.clear)
                }
                if store.hasMoreHistory {
                    Button(L10n.text("Load more")) { Task { await store.refreshHistory(loadMore: true) } }
                        .disabled(store.isLoadingHistory)
                        .listRowSeparator(.hidden)
                }
        }
            .listStyle(.plain).scrollContentBackground(.hidden)
            .focusable().focused($historyFocused).focusEffectDisabled()
            .background(HistoryKeyboardShortcuts(onKeyDown: handleHistoryShortcut).frame(maxWidth: .infinity, maxHeight: .infinity))
            .environment(\.defaultMinListRowHeight, 38)
            .disabled(store.isSending)
            .onKeyPress(.upArrow) { moveHistorySelection(-1) }
            .onKeyPress(.downArrow) { moveHistorySelection(1) }
            .overlay {
                if store.conversations.isEmpty && !store.isLoadingHistory {
                    Text(store.search.isEmpty ? L10n.text("Your conversations will appear here") : L10n.text("No results"))
                        .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center).padding(24)
                }
            }
    }

    private func moveHistorySelection(_ offset: Int) -> KeyPress.Result {
        guard !store.isSending, !store.conversations.isEmpty else { return .ignored }
        let current = store.conversations.firstIndex { $0.id == store.selectedConversationID } ?? (offset > 0 ? -1 : store.conversations.count)
        let next = min(max(current + offset, 0), store.conversations.count - 1)
        store.select(store.conversations[next].id)
        return .handled
    }

    private func handleHistoryShortcut(_ event: NSEvent) -> Bool {
        guard columnVisibility != .detailOnly, !store.isSending, !store.isTemporary, !searchFocused,
              !showRename, !showDelete, !confirmSignOut, shareTarget == nil, !app.showLogin,
              let chat = store.conversations.first(where: { $0.id == store.selectedConversationID }),
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

    private var accountButton: some View {
            Menu {
                    Text(store.accountName ?? L10n.text("Profile"))
                    Divider()
                    Button(L10n.text("Refresh session…")) { app.showLogin = true }
                    Button(L10n.text("Refresh history")) { Task { await store.refreshHistory() } }
                    Divider()
                    Button(L10n.text("Sign out…"), role: .destructive) { confirmSignOut = true }
            } label: {
                AccountAvatar(url: store.accountImageURL, media: app.media, size: 32)
                    .padding(4).modifier(FloatingGlass(cornerRadius: 20))
            }
            .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
            .disabled(store.isSending).accessibilityLabel(store.accountName ?? L10n.text("Profile"))
            .help(store.accountName ?? L10n.text("Profile"))
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

    private var searchExpanded: Bool { searchFocused || !store.search.isEmpty }

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

    private var emptyConversation: some View {
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
                                    media: app.media, conversationURL: store.isTemporary ? nil : store.selectedConversationID.flatMap { URL(string: "https://grok.com/c/\($0)") })
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

    private var composer: some View {
        ChatComposer(store: store, followResponse: $followResponse)
    }

    private func errorBanner(_ error: DisplayError) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "exclamationmark.circle").foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 8) {
                Text(error.message).font(.callout).textSelection(.enabled)
                HStack {
                    if error.needsLogin || store.requiresLogin {
                        Button(L10n.text("Sign in again")) { app.showLogin = true }
                    } else {
                        if store.isTemporary && store.needsReload {
                            Button(L10n.text("New private conversation")) { store.newChat() }
                        } else if store.selectedConversationID != nil {
                            Button(L10n.text("Refresh chat")) { Task { await store.loadSelectedConversation() } }
                        }
                        Button(L10n.text("Refresh session")) { app.showLogin = true }
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
private struct SidebarMaterial: NSViewRepresentable {
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
