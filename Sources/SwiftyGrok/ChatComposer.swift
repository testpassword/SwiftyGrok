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
            if !store.draftFiles.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(store.draftFiles) { file in
                            HStack(spacing: 7) {
                                Image(systemName: file.mimeType.hasPrefix("image/") ? "photo" : "doc")
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(file.name).lineLimit(1)
                                    Text(ByteCountFormatter.string(fromByteCount: Int64(file.data.count), countStyle: .file))
                                        .font(.system(size: 10)).foregroundStyle(.secondary)
                                }
                                Button { store.removeFile(file.id) } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
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
                                           contextID: "\(store.isTemporary):\(store.selectedConversationID ?? "__new")",
                                           isEnabled: !store.isSending,
                                           focusRequest: focusRequest,
                                           sendShortcut: behavior.sendShortcut,
                                           onSend: { sendMessage() },
                                           onPasteFiles: { importFiles(.success($0)) },
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
    }

    private func composerActions(compact: Bool) -> some View {
            HStack(spacing: compact ? 8 : 12) {
                Button { showFilePicker = true } label: {
                    if store.isReadingFiles { ProgressView().controlSize(.small).frame(width: 30, height: 30) }
                    else { Image(systemName: "plus").font(.system(size: 18, weight: .medium)).frame(width: 30, height: 30) }
                }
                .buttonStyle(.plain).contentShape(Circle())
                .help(L10n.text("Attach files")).accessibilityLabel(L10n.text("Attach files"))
                .disabled(store.isSending || store.isReadingFiles)
                Menu {
                    Picker(L10n.text("Mode"), selection: $store.modeID) {
                        ForEach(store.modes) { mode in Text(mode.name).tag(mode.id) }
                    }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "bolt")
                        if !compact {
                            Text(store.modes.first { $0.id == store.modeID }?.name ?? store.modeID)
                            Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold))
                        }
                    }
                    .font(.system(size: 13, weight: .medium))
                    .padding(.horizontal, 12).padding(.vertical, 8)
                    .background(.primary.opacity(0.06), in: Capsule())
                }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                .disabled(store.isSending).accessibilityLabel(L10n.text("Response mode"))
                if store.selectedConversationID == nil || store.isTemporary {
                    Toggle(isOn: Binding(get: { store.isTemporary }, set: { store.setTemporary($0) })) {
                        if compact { Image(systemName: "eye.slash").accessibilityHidden(true) }
                        else { Text(L10n.text("Private chat")) }
                    }
                        .toggleStyle(.switch).controlSize(.mini).font(.system(size: 12))
                        .fixedSize().disabled(store.isSending || !store.updatingConversations.isEmpty)
                        .accessibilityLabel(L10n.text("Private chat"))
                        .help(L10n.text("A new private conversation that is not saved in your history"))
                }
                Spacer(minLength: 8)
                if store.isSending {
                    Button { followResponse.toggle() } label: {
                        Image(systemName: followResponse ? "arrow.down.to.line.circle.fill" : "arrow.down.to.line.circle")
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
                    Image(systemName: store.isSending ? "stop.fill" : "arrow.up")
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
}
