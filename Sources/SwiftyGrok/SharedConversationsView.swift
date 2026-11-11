import SwiftUI
import AppKit
import GrokCore

@MainActor struct SharedConversationsView: View {
    @Bindable var store: SharedConversationStore
    @Environment(\.openURL) private var openURL
    @State private var revokeTarget: SharedConversation?
    @State private var appearance = AppearanceSettings.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                Text(L10n.text("Shared conversations")).font(.title2.weight(.semibold))
                Spacer()
                if store.isLoading { ProgressView().controlSize(.small) }
                Button { Task { await store.load() } } label: {
                    Label(L10n.text("Refresh"), systemImage: "arrow.clockwise")
                        .font(.system(size: 16, weight: .medium)).frame(width: 22, height: 22)
                }
                .labelStyle(.iconOnly).help(L10n.text("Refresh"))
                .buttonBorderShape(.circle)
                .disabled(store.isBusy || store.requiresLogin)
            }
            Text(L10n.text("Anyone with these links can view the shared conversations."))
                .font(.callout).foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)

            if let error = store.error {
                VStack(alignment: .leading, spacing: 6) {
                    Text(error.message).textSelection(.enabled)
                    if store.requiresLogin {
                        Text(L10n.text("Close this window and sign in again to manage shared conversations."))
                    } else {
                        Button { Task { await store.load() } } label: {
                            Text(L10n.text("Retry")).frame(minHeight: 22)
                        }.disabled(store.isBusy)
                    }
                }.font(.callout).foregroundStyle(.secondary)
            }

            if store.isLoading && store.items.isEmpty {
                ProgressView(L10n.text("Loading shared conversations…"))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if store.items.isEmpty && !store.hasMore {
                ContentUnavailableView {
                    Label(L10n.text(store.error == nil ? "No shared conversations" : "Could not load shared conversations"),
                          systemImage: store.error == nil ? "link" : "exclamationmark.triangle")
                } description: {
                    if store.error == nil { Text(L10n.text("Public links you create will appear here.")) }
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(store.items) { item in
                            row(item)
                            if item.id != store.items.last?.id { Divider().padding(.horizontal, 16) }
                        }
                        if store.hasMore {
                            Button { Task { await store.load(more: true) } } label: {
                                Text(L10n.text("Load more")).frame(minHeight: 22)
                            }.disabled(store.isBusy || store.requiresLogin).padding(16)
                        }
                    }
                    .background(.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 14))
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            Text(L10n.text("Revoking a link does not delete the original conversation."))
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(22)
        .padding(.top, SharedConversationsWindowLayout.titlebarHeight)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(appearance.theme.settingsBackground)
        .ignoresSafeArea(.container)
        .controlSize(.large)
        .modifier(SharingGlassButtons())
        .modifier(AppAppearance())
        .modifier(CopyFeedbackOverlay())
        .task { await store.load() }
        .onDisappear { store.shutdown() }
        .confirmationDialog(L10n.text("Stop sharing this conversation?"),
                            isPresented: Binding(get: { revokeTarget != nil }, set: { if !$0 { revokeTarget = nil } }),
                            titleVisibility: .visible, presenting: revokeTarget) { item in
            Button(L10n.text("Stop sharing"), role: .destructive) { Task { await store.revoke(item) } }
            Button(L10n.text("Cancel"), role: .cancel) {}
        } message: { item in
            Text(L10n.format("The public link to “%@” will stop working. Your original chat will be kept.", item.title))
        }
    }

    private func row(_ item: SharedConversation) -> some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 7) {
                Text(item.title).font(.system(size: 14, weight: .medium)).lineLimit(3)
                    .frame(maxWidth: .infinity, alignment: .leading)
                HStack(spacing: 10) {
                    Label(views(item.views), systemImage: "eye")
                    if let date = item.createdAt {
                        Text(date, format: .dateTime.day().month().year())
                            .help(L10n.text("Published"))
                    }
                }.font(.caption).foregroundStyle(.secondary)
            }
            HStack(spacing: 8) {
                Button { if let url = item.url { ClipboardFeedback.shared.copy(url.absoluteString) } } label: {
                    Label(L10n.text("Copy link"), systemImage: "doc.on.doc")
                        .font(.system(size: 16, weight: .medium)).frame(width: 22, height: 22)
                }.labelStyle(.iconOnly).buttonBorderShape(.circle)
                    .help(L10n.text("Copy link")).disabled(item.url == nil)
                Button { if let url = item.url { openURL(url) } } label: {
                    Label(L10n.text("Open in browser"), systemImage: "safari")
                        .font(.system(size: 16, weight: .medium)).frame(width: 22, height: 22)
                }.labelStyle(.iconOnly).buttonBorderShape(.circle)
                    .help(L10n.text("Open in browser")).disabled(item.url == nil)
                if store.revoking.contains(item.id) { ProgressView().controlSize(.small).frame(width: 120, height: 38) }
                else {
                    Button(role: .destructive) { revokeTarget = item } label: {
                        Text(L10n.text("Stop sharing"))
                            .font(.system(size: 14, weight: .medium)).frame(minHeight: 22)
                    }.disabled(store.isLoading || store.requiresLogin)
                }
            }
        }.padding(16)
    }

    private func views(_ count: Int?) -> String {
        guard let count else { return L10n.text("View count unavailable") }
        return count == 0 ? L10n.text("No views") : L10n.format("Views: %@", count.formatted())
    }
}

/// Apply the native glass button style to all sharing controls, with the
/// existing bordered appearance on macOS versions without Liquid Glass.
struct SharingGlassButtons: ViewModifier {
    @ViewBuilder func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content.buttonStyle(.glass).buttonBorderShape(.capsule)
        } else {
            content.buttonStyle(.bordered).buttonBorderShape(.capsule)
        }
    }
}

@MainActor private enum SharedConversationsWindowLayout {
    static let style: NSWindow.StyleMask = [.titled, .closable, .miniaturizable]
    static let size = NSWindow.frameRect(forContentRect: NSRect(x: 0, y: 0, width: 660, height: 500),
                                         styleMask: style).size
    static let titlebarHeight = size.height - 500
}

@MainActor final class SharedConversationsWindowController: NSWindowController, NSWindowDelegate {
    private var isPresentingModally = false

    init(store: SharedConversationStore) {
        let size = SharedConversationsWindowLayout.size
        let window = SharedConversationsWindow(contentRect: NSRect(origin: .zero, size: size),
            styleMask: SharedConversationsWindowLayout.style.union(.fullSizeContentView), backing: .buffered, defer: false)
        window.identifier = NSUserInterfaceItemIdentifier("shared-conversations")
        window.title = L10n.text("Shared conversations")
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.titlebarSeparatorStyle = .none
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        window.tabbingMode = .disallowed
        window.collectionBehavior = [.fullScreenNone]
        let controller = NSHostingController(rootView: SharedConversationsView(store: store))
        controller.sizingOptions = []
        window.contentViewController = controller
        window.toolbar = nil
        window.minSize = size
        window.maxSize = size
        window.setFrame(NSRect(origin: window.frame.origin, size: size), display: false)
        super.init(window: window)
        window.delegate = self
        window.standardWindowButton(.closeButton)?.isEnabled = true
        window.standardWindowButton(.miniaturizeButton)?.isEnabled = false
        window.standardWindowButton(.zoomButton)?.isEnabled = false
        window.center()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("Use init(store:)") }

    func show() {
        guard let window else { return }
        showWindow(nil)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        guard !isPresentingModally else { return }
        isPresentingModally = true
        defer { isPresentingModally = false; window.orderOut(nil) }
        NSApp.runModal(for: window)
    }

    func windowWillClose(_ notification: Notification) {
        guard isPresentingModally, NSApp.modalWindow === window else { return }
        NSApp.stopModal()
    }
}

private final class SharedConversationsWindow: NSWindow {
    override func cancelOperation(_ sender: Any?) { performClose(sender) }
}
