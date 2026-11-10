import SwiftUI
import AppKit
import GrokCore

@MainActor struct MessageView: View {
    let message: ChatMessage
    let isStreaming: Bool
    let isThinking: Bool
    let media: MessageMediaLoader?
    let conversationURL: URL?
    var retryPlaces: (() -> Void)? = nil
    private let sourceIconSize: CGFloat = 14
    private let sourceFont = Font.system(size: 12)
    @State private var appearance = AppearanceSettings.shared
    @Environment(\.colorScheme) private var colorScheme
    private var userBubbleBackground: Color {
        if appearance.theme == .black { return Color(white: 0.12) }
        return colorScheme == .dark ? Color(white: 0.2) : .white
    }
    private var userBubble: RoundedRectangle {
        RoundedRectangle(cornerRadius: 20, style: .continuous)
    }

    var body: some View {
        Group {
            if message.role == .user {
                VStack(alignment: .trailing, spacing: 8) {
                  attachments.padding(.leading, 64)
                  HStack(alignment: .top, spacing: 0) {
                    Spacer(minLength: 64)
                    if !message.text.isEmpty { MarkdownMessage(text: message.text, media: media, compact: true)
                        .padding(.horizontal, 14).padding(.vertical, 10)
                        .background(userBubbleBackground, in: userBubble)
                        .overlay(userBubble.strokeBorder(Color.gray.opacity(0.28), lineWidth: 1))
                        .frame(maxWidth: 620, alignment: .trailing)
                    }
                  }
                }
                .frame(maxWidth: .infinity, alignment: .trailing)
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    if let reasoning = message.reasoning {
                        DisclosureGroup(reasoningTitle) {
                            MarkdownMessage(text: reasoning, media: media).foregroundStyle(.secondary).padding(.top, 8)
                        }
                        .foregroundStyle(.secondary)
                        .disclosureGroupStyle(ClickableDisclosureStyle())
                    } else if message.reasoningDuration != nil {
                        Text(reasoningTitle).font(.callout).foregroundStyle(.secondary)
                    }
                    if message.text.isEmpty && message.attachments.isEmpty && message.placeBlocks.isEmpty && message.failure == nil {
                        HStack(spacing: 8) {
                            if isThinking { ProgressView().controlSize(.small) }
                            Text(isStreaming ? (isThinking ? L10n.text("Grok is thinking…") : L10n.text("Waiting for a response…")) : L10n.text("No response text received"))
                                .font(.callout).foregroundStyle(.secondary)
                        }
                    } else {
                        answerBody
                        if isThinking { Text(L10n.text("Grok is thinking…")).font(.caption).foregroundStyle(.secondary) }
                    }
                    attachments
                    if message.placesUnavailable {
                        HStack(spacing: 8) {
                            Label(L10n.text("Could not load places"), systemImage: "mappin.slash")
                                .foregroundStyle(.secondary)
                            if let retryPlaces { Button(L10n.text("Retry"), action: retryPlaces) }
                        }.font(.callout)
                    }
                    if let failure = message.failure {
                        Label(failure, systemImage: "exclamationmark.circle").font(.callout).foregroundStyle(.orange)
                            .textSelection(.enabled)
                    }
                    if !message.sources.isEmpty {
                        DisclosureGroup {
                            VStack(alignment: .leading, spacing: 8) {
                                ForEach(uniqueSources) { source in
                                    Link(destination: source.url) {
                                        HStack(alignment: .top, spacing: 8) {
                                            SiteIcon(url: source.url, size: sourceIconSize).padding(.top, 1)
                                            VStack(alignment: .leading, spacing: 3) {
                                                Text(source.title).font(sourceFont).lineLimit(2)
                                                Text(source.url.host ?? "").font(.system(size: 10)).foregroundStyle(.secondary)
                                            }
                                        }
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                            .padding(.top, 8)
                        } label: {
                            HStack(spacing: 6) {
                                HStack(spacing: -4) {
                                    ForEach(Array(sourceSites.prefix(3).enumerated()), id: \.element) { index, url in
                                        SiteIcon(url: url, size: sourceIconSize)
                                            .background(Color(nsColor: .textBackgroundColor), in: Circle())
                                            .clipShape(Circle())
                                            .overlay(Circle().strokeBorder(Color(nsColor: .textBackgroundColor), lineWidth: 1))
                                            .zIndex(Double(3 - index))
                                    }
                                }
                                Text(L10n.format("%@ Sources", String(uniqueSources.count))).font(sourceFont)
                            }
                            .padding(.horizontal, 10).padding(.vertical, 5)
                            .background(Color(nsColor: .textBackgroundColor).opacity(0.6), in: Capsule())
                            .overlay(Capsule().strokeBorder(.primary.opacity(0.2), lineWidth: 0.75))
                            .contentShape(Capsule())
                        }
                        .disclosureGroupStyle(SourcesDisclosureStyle())
                    }
                    if !isStreaming && !message.text.isEmpty {
                        Button(action: copyMessage) {
                            Image(systemName: "doc.on.doc").font(.system(size: 12))
                        }
                        .buttonStyle(.plain).foregroundStyle(.tertiary)
                        .help(L10n.text("Copy response")).accessibilityLabel(L10n.text("Copy response"))
                        .padding(.top, 2)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .font(.system(size: 14))
        .contextMenu {
            Button(L10n.text("Copy message"), systemImage: "doc.on.doc", action: copyMessage)
                .disabled(message.text.isEmpty)
            if let date = message.createdAt {
                Text(date, format: .dateTime.day().month().hour().minute())
            }
        }
    }

    @ViewBuilder private var answerBody: some View {
        if message.placeBlocks.isEmpty {
            MarkdownMessage(text: message.displayMarkdown, media: media)
        } else {
            ForEach(Array(message.placeBlocks.enumerated()), id: \.offset) { _, block in
                switch block {
                case .text(let text): MarkdownMessage(text: GrokMessageContent.markdown(text, sources: message.sources), media: media)
                case .gallery(let gallery): PlaceCardsView(gallery: gallery, media: media)
                }
            }
        }
    }

    private func copyMessage() {
        ClipboardFeedback.shared.copy(message.role == .user ? message.text : message.displayMarkdown)
    }

    private var reasoningTitle: String {
        guard let duration = message.reasoningDuration else { return L10n.text("Thinking") }
        return L10n.format("Thinking · %@ s", duration.formatted(.number.precision(.fractionLength(0))))
    }

    private var uniqueSources: [MessageSource] {
        var urls = Set<URL>()
        return message.sources.filter { urls.insert($0.url).inserted }
    }

    private var sourceSites: [URL] {
        var hosts = Set<String>()
        return uniqueSources.map(\.url).filter { hosts.insert($0.host ?? $0.absoluteString).inserted }
    }

    @ViewBuilder private var attachments: some View {
      if !message.attachments.isEmpty {
        VStack(alignment: message.role == .user ? .trailing : .leading, spacing: 8) {
            ForEach(message.attachments) { attachment in
                if attachment.kind == .image, let url = attachment.url {
                    MessageImage(url: url, name: attachment.name, media: media,
                                 presentation: message.role == .user ? .user : attachment.isGenerated ? .generated : .regular)
                } else if let url = attachment.url ?? conversationURL {
                    Link(destination: url) {
                        HStack(spacing: 10) {
                            Image(systemName: attachment.kind == .video ? "play.rectangle" : attachment.kind == .audio ? "waveform" : "doc")
                                .font(.system(size: 21)).foregroundStyle(.secondary)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(attachment.name).lineLimit(2)
                                Text(attachment.url == nil ? L10n.text("Open in Grok") : L10n.text("Open")).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 8)
                            Image(systemName: "arrow.up.right").font(.caption).foregroundStyle(.secondary)
                        }
                        .padding(14).background(.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 14))
                    }
                    .buttonStyle(.plain)
                } else {
                    Label(attachment.name, systemImage: "doc").font(.callout)
                        .padding(10).background(.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 12))
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: message.role == .user ? .trailing : .leading)
      }
    }
}

private struct SourcesDisclosureStyle: DisclosureGroupStyle {
    func makeBody(configuration: Configuration) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.easeInOut(duration: 0.16)) { configuration.isExpanded.toggle() }
            } label: { configuration.label }
                .buttonStyle(.plain)
                .accessibilityValue(configuration.isExpanded ? L10n.text("Expanded") : L10n.text("Collapsed"))
            if configuration.isExpanded { configuration.content }
        }
    }
}

private struct ClickableDisclosureStyle: DisclosureGroupStyle {
    func makeBody(configuration: Configuration) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.easeInOut(duration: 0.16)) { configuration.isExpanded.toggle() }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold))
                        .rotationEffect(.degrees(configuration.isExpanded ? 90 : 0))
                    configuration.label
                    Spacer(minLength: 0)
                }
                .padding(.vertical, 3).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityValue(configuration.isExpanded ? L10n.text("Expanded") : L10n.text("Collapsed"))
            if configuration.isExpanded { configuration.content }
        }
    }
}
