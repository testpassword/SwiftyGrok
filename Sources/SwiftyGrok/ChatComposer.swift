import SwiftUI
import AppKit
import UniformTypeIdentifiers
import GrokCore

@MainActor struct ChatComposer: View {
    @Bindable var store: ChatStore
    @Binding var followResponse: Bool
    var floating = false
    var focusRequest: UUID? = nil
    var onSend: (() -> Void)? = nil
    @State private var showFilePicker = false
    @State private var behavior = BehaviorSettings.shared
    @State private var appearance = AppearanceSettings.shared
    @Environment(\.colorScheme) private var colorScheme

    private var actionBackground: Color { colorScheme == .dark ? .white : .black }
    private var actionForeground: Color { colorScheme == .dark ? .black : .white }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if store.isDictating { DictationStatus(store: store) }
            if !store.draftFiles.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(store.draftFiles) { file in
                            HStack(spacing: 7) {
                                Image(appSymbol: file.mimeType.hasPrefix("image/") ? "photo" : "doc")
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(file.name).lineLimit(1)
                                    Text(ByteCountFormatter.string(fromByteCount: Int64(file.data.count), countStyle: .file))
                                        .font(.system(size: 10)).foregroundStyle(.secondary)
                                }
                                Button { store.removeFile(file.id) } label: { Image(appSymbol: "xmark.circle.fill").foregroundStyle(.secondary) }
                                    .buttonStyle(.plain).accessibilityLabel(L10n.format("Remove %@", file.name))
                            }
                            .font(.system(size: 12)).padding(8)
                            .background(.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 12))
                        }
                    }
                }
            }
            if store.isUploadingFiles { ProgressView(L10n.text("Uploading files…")).controlSize(.small).font(.caption) }
            // Measure with the same font so the editor grows up to six lines.
            Text(store.draft.isEmpty ? " " : store.draft)
                .font(.system(size: 15))
                .lineLimit(1...6)
                .padding(.horizontal, 5).padding(.vertical, 5)
                .frame(maxWidth: .infinity, minHeight: 30, alignment: .topLeading)
                .hidden()
                .overlay(alignment: .topLeading) {
                    ZStack(alignment: .topLeading) {
                        if store.draft.isEmpty {
                            Text(store.needsReload ? L10n.text("Refresh the chat to continue…") : L10n.text("Ask anything"))
                                .font(.system(size: 15)).foregroundStyle(.secondary)
                                .padding(.horizontal, 5).padding(.top, 5)
                                .allowsHitTesting(false)
                        }
                        ComposerTextEditor(text: $store.draft,
                                           contextID: "\(store.isTemporary):\(store.selectedProjectID ?? "__none"):\(store.selectedConversationID ?? "__new")",
                                           isEnabled: !store.isSending,
                                           focusRequest: focusRequest,
                                           sendShortcut: behavior.sendShortcut,
                                           onSend: { sendMessage() },
                                           onPasteFiles: { importFiles(.success($0)) },
                                           onPasteImages: { importClipboardImages($0) },
                                           canAttachFiles: { store.canAttachFiles })
                            .accessibilityLabel(L10n.text("Message Grok"))
                    }
                }
            ViewThatFits(in: .horizontal) {
                composerActions(compact: false)
                composerActions(compact: true)
            }
        }
        .padding(10)
        .modifier(FloatingGlass(cornerRadius: 28,
                                backgroundOpacity: floating ? appearance.quickInputBackgroundOpacity : 0,
                                followsSystemTransparency: floating && appearance.quickInputFollowsSystemTransparency))
        .shadow(color: .black.opacity(0.07), radius: 12, y: 4)
        .frame(maxWidth: 960)
        .padding(.horizontal, floating ? 12 : 18).padding(.bottom, floating ? 12 : 14)
        .padding(.top, floating ? 12 : 0)
        .overlay(alignment: .top) {
            if floating {
                QuickInputDragHandle().frame(width: 80, height: 12).padding(.top, 12)
                    .help(L10n.text("Move quick input"))
            }
        }
        .modifier(ChatFileDropTarget(store: store))
        .fileImporter(isPresented: $showFilePicker, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
            importFiles(result)
        }
        .onDisappear { VoiceDictation.shared.cancel(in: store) }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.willCloseNotification)) { notification in
            let window = notification.object as? NSWindow
            if window?.identifier?.rawValue == (floating ? "quick-input" : "main") {
                VoiceDictation.shared.cancel(in: store)
            }
        }
    }

    private func composerActions(compact: Bool) -> some View {
            HStack(spacing: compact ? 8 : 12) {
                AttachmentPickerButton(store: store) { showFilePicker = true }
                ModePickerButton(store: store, compact: compact)
                if store.selectedProjectID == nil && (store.selectedConversationID == nil || store.isTemporary) {
                    Toggle(isOn: Binding(get: { store.isTemporary }, set: { store.setTemporary($0) })) {
                        if compact { Image(appSymbol: "grok-privacy").accessibilityHidden(true) }
                        else { Text(L10n.text("Private chat")) }
                    }
                        .toggleStyle(.switch).controlSize(.mini).font(.system(size: 12))
                        .fixedSize().disabled(store.isSending || !store.updatingConversations.isEmpty)
                        .accessibilityLabel(L10n.text("Private chat"))
                        .help(L10n.text("A new private conversation that is not saved in your history"))
                }
                Spacer(minLength: 8)
                DictationButton(store: store)
                if store.isSending {
                    Button { followResponse.toggle() } label: {
                        Image(appSymbol: followResponse ? "arrow.down.to.line.circle.fill" : "arrow.down.to.line.circle")
                            .font(.system(size: 19)).foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain).help(L10n.text("Follow response"))
                    .accessibilityLabel(L10n.text("Follow response"))
                    .accessibilityValue(followResponse ? L10n.text("On") : L10n.text("Off"))
                } else if !compact {
                    Text(behavior.sendShortcut.hint).font(.caption).foregroundStyle(.tertiary)
                }
                Button {
                    if store.isSending { store.stopSending() }
                    else { sendMessage() }
                } label: {
                    Image(appSymbol: store.isSending ? "stop.fill" : "arrow.up")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(actionForeground.opacity(store.isSending || store.canSend ? 1 : 0.45))
                        .frame(width: 34, height: 34)
                        .background(actionBackground, in: Circle())
                        .contentShape(Circle())
                }
                .buttonStyle(ComposerSendStyle())
                .disabled(!store.isSending && (!store.canSend || store.isReadingFiles))
                .help(store.isSending ? L10n.text("Stop response") : behavior.sendShortcut.help)
                .accessibilityLabel(store.isSending ? L10n.text("Stop response") : L10n.text("Send message"))
            }
    }

    private func sendMessage() {
        guard store.canSend, !store.isReadingFiles else { return }
        if let onSend { onSend() } else { store.send() }
    }

    private func importFiles(_ result: Result<[URL], Error>) {
        guard case let .success(urls) = result, !urls.isEmpty else { return }
        Task { await store.importFiles(urls) }
    }

    private func importClipboardImages(_ images: [Data]) {
        let remaining = DraftFile.maximumTotalSize - store.draftFiles.reduce(0) { $0 + $1.data.count }
        Task {
            await store.importFiles(resolvingDraftFiles: {
                try await Task.detached(priority: .userInitiated) {
                    try ClipboardImageReader.read(images, maximumBytes: remaining)
                }.value
            })
        }
    }
}

extension ChatMode {
    var symbolName: String {
        switch iconHint {
        case "lightning": return "bolt"
        case "lightbulb": return "lightbulb"
        case "rocket": return "paperplane"
        case "connected_apps": return "grok-connectors"
        case "moon": return "moon"
        case "cube": return "cube"
        case "blackhole": return "circle.dotted"
        case "hammer": return "hammer"
        case "circuit_board": return "cpu"
        case "imagine": return "grok-imagine"
        default:
            switch id {
            case "fast": return "bolt"
            case "expert": return "lightbulb"
            case "heavy": return "grok-heavy-grid"
            case "auto": return "paperplane"
            default: return "slider.horizontal.3"
            }
        }
    }
}

@MainActor private struct ModePickerButton: View {
    let store: ChatStore
    let compact: Bool
    @State private var presented = false
    private var selected: ChatMode? { store.modes.first { $0.id == store.modeID } }

    var body: some View {
        Button { presented.toggle() } label: {
            HStack(spacing: 6) {
                Image(appSymbol: selected?.symbolName ?? "slider.horizontal.3")
                if !compact {
                    Text(selected?.name ?? L10n.text("Mode"))
                    Image(appSymbol: "chevron.down").font(.system(size: 9, weight: .semibold))
                }
            }
            .font(.system(size: 13, weight: .medium))
            .padding(.horizontal, 12).padding(.vertical, 8)
            .background(.primary.opacity(0.06), in: Capsule())
        }
        .buttonStyle(.plain).fixedSize().disabled(store.isSending)
        .accessibilityLabel(L10n.text("Response mode"))
        .accessibilityValue(selected?.name ?? L10n.text("Mode"))
        .help(L10n.text("Response mode"))
        .popover(isPresented: $presented, arrowEdge: .bottom) {
            ModePickerPopover(store: store) { presented = false }
        }
        .onChange(of: store.isSending) { _, sending in if sending { presented = false } }
    }
}

@MainActor private struct ModePickerPopover: View {
    let store: ChatStore
    let close: () -> Void
    @State private var hovered: String?
    @FocusState private var focused: String?

    private func rowHeight(_ mode: ChatMode) -> CGFloat {
        guard !mode.summary.isEmpty else { return 46 }
        // Text width after the popover padding, row insets, icons and spacing.
        let bounds = (mode.summary as NSString).boundingRect(
            with: NSSize(width: 240, height: CGFloat.greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: NSFont.systemFont(ofSize: 12)]
        )
        return max(46, 36 + min(30, ceil(bounds.height)))
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(spacing: 2) {
                    ForEach(store.modes) { mode in row(mode).id(mode.id) }
                    if store.modes.isEmpty {
                        Text(L10n.text("No modes available")).font(.callout).foregroundStyle(.secondary).padding()
                    }
                }.padding(8)
            }
            .frame(width: 360, height: min(420, max(64, store.modes.reduce(CGFloat(16)) { $0 + rowHeight($1) + 2 })))
            .onAppear { restoreFocus() }
            .onChange(of: store.modes) { _, _ in restoreFocus() }
            .onChange(of: focused) { _, id in if let id { proxy.scrollTo(id) } }
            .onMoveCommand { direction in
                let available = store.modes.filter(\.isAvailable)
                guard !available.isEmpty, direction == .up || direction == .down else { return }
                let index = available.firstIndex { $0.id == focused } ?? 0
                focused = available[min(max(index + (direction == .up ? -1 : 1), 0), available.count - 1)].id
            }
            .onKeyPress(.return) {
                guard let id = focused, store.modes.contains(where: { $0.id == id && $0.isAvailable }) else { return .ignored }
                select(id)
                return .handled
            }
            .onExitCommand(perform: close)
        }
        .task { await store.loadModes() }
    }

    private func row(_ mode: ChatMode) -> some View {
        Button { select(mode.id) } label: {
            HStack(alignment: .center, spacing: 12) {
                Image(appSymbol: mode.symbolName).font(.system(size: 18, weight: .medium))
                    .frame(width: 38, height: 38)
                    .background(.primary.opacity(0.07), in: Circle())
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(mode.name).font(.system(size: 14, weight: .medium)).lineLimit(1)
                        if let badge = mode.badgeText, !badge.isEmpty {
                            Text(badge).font(.system(size: 9, weight: .semibold)).lineLimit(1)
                                .padding(.horizontal, 6).padding(.vertical, 3)
                                .background(.quaternary, in: Capsule())
                        }
                    }
                    if !mode.summary.isEmpty {
                        Text(mode.summary).font(.system(size: 12)).foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
                Image(appSymbol: "checkmark").font(.system(size: 14, weight: .semibold))
                    .opacity(store.modeID == mode.id ? 1 : 0).frame(width: 18)
            }
            .padding(.horizontal, 12).frame(height: rowHeight(mode))
            .foregroundStyle(mode.isAvailable ? Color.primary : Color.secondary)
            .background(hovered == mode.id || focused == mode.id ? Color.primary.opacity(0.06) : .clear,
                        in: RoundedRectangle(cornerRadius: 10))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain).disabled(!mode.isAvailable || store.isSending)
        .focused($focused, equals: mode.id)
        .onHover { hovered = $0 ? mode.id : nil }
        .help(mode.availabilityExplanation ?? mode.summary)
        .accessibilityHint(mode.availabilityExplanation ?? "")
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(store.modeID == mode.id ? .isSelected : [])
    }

    private func restoreFocus() {
        if store.modes.contains(where: { $0.id == focused && $0.isAvailable }) { return }
        focused = store.modes.first { $0.id == store.modeID && $0.isAvailable }?.id ?? store.modes.first { $0.isAvailable }?.id
    }

    private func select(_ id: String) {
        guard !store.isSending, store.modes.contains(where: { $0.id == id && $0.isAvailable }) else { return }
        store.selectMode(id)
        close()
    }
}
