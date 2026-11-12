import SwiftUI
import AppKit
import GrokCore
import QuickLook
import ImageIO
import UniformTypeIdentifiers

@MainActor struct MarkdownMessage: View {
    let text: String
    let media: MessageMediaLoader?
    var compact = false

    var body: some View {
        MarkdownBlocks(blocks: MarkdownDocument(text).blocks, media: media)
            .environment(\.compactMessageLayout, compact)
            .environment(\.openURL, OpenURLAction { url in
                GrokMessageContent.url(url.absoluteString) != nil ? .systemAction : .discarded
            })
    }
}

private struct CompactMessageLayout: EnvironmentKey { static let defaultValue = false }
private extension EnvironmentValues {
    var compactMessageLayout: Bool {
        get { self[CompactMessageLayout.self] }
        set { self[CompactMessageLayout.self] = newValue }
    }
}

@MainActor private struct MarkdownBlocks: View {
    let blocks: [MarkdownDocument.Block]
    let media: MessageMediaLoader?
    @Environment(\.compactMessageLayout) private var compact

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(blocks) { block in MarkdownBlock(block: block, media: media) }
        }
        .frame(maxWidth: compact ? nil : .infinity, alignment: .leading)
    }
}

@MainActor private struct MarkdownBlock: View {
    let block: MarkdownDocument.Block
    let media: MessageMediaLoader?

    @ViewBuilder var body: some View {
        switch block.kind {
        case .header(let level):
            MarkdownInline(text: block.text, media: media)
                .font(.system(size: level == 1 ? 23 : level == 2 ? 20 : level == 3 ? 17 : 15, weight: .semibold))
                .padding(.top, level < 4 ? 8 : 2)
        case .orderedList, .unorderedList:
            VStack(alignment: .leading, spacing: 6) {
                ForEach(block.children) { item in
                    HStack(alignment: .firstTextBaseline, spacing: 9) {
                        Text(listMarker(item)).foregroundStyle(.secondary)
                            .frame(minWidth: 16, alignment: .trailing)
                        MarkdownBlocks(blocks: item.children, media: media)
                    }
                }
            }
        case .blockQuote:
            HStack(alignment: .top, spacing: 12) {
                RoundedRectangle(cornerRadius: 2).fill(.primary.opacity(0.2)).frame(width: 3)
                MarkdownBlocks(blocks: block.children, media: media).foregroundStyle(.secondary)
            }
            .fixedSize(horizontal: false, vertical: true)
        case .codeBlock(let language):
            if language?.lowercased() == "math" {
                MathFormulaView(expression: MathExpression(latex: String(block.text.characters), display: true))
            } else { code(language: language) }
        case .table(let columns):
            table(columns: columns)
        case .thematicBreak:
            Divider().padding(.vertical, 8)
        default:
            if !block.text.characters.isEmpty { MarkdownInline(text: block.text, media: media) }
            if !block.children.isEmpty { MarkdownBlocks(blocks: block.children, media: media) }
        }
    }

    private func listMarker(_ item: MarkdownDocument.Block) -> String {
        if case .orderedList = block.kind, case .listItem(let ordinal) = item.kind { return "\(ordinal)." }
        return "•"
    }

    private func code(language: String?) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Label {
                    Text(language?.isEmpty == false ? language! : L10n.text("Code"))
                } icon: {
                    CodeLanguageIcon(language: language)
                }
                .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button {
                    ClipboardFeedback.shared.copy(String(block.text.characters))
                } label: { Image(appSymbol: "doc.on.doc").font(.caption) }
                .buttonStyle(.plain).foregroundStyle(.secondary)
                .help(L10n.text("Copy code")).accessibilityLabel(L10n.text("Copy code"))
            }
            .padding(12)
            Divider()
            ScrollView(.horizontal) {
                Text(highlightedCode(language: language)).font(.system(size: 12.5, design: .monospaced))
                    .textSelection(.enabled).padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .fixedSize(horizontal: false, vertical: true)
        }
        .background(.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(.primary.opacity(0.1)))
    }

    private func highlightedCode(language: String?) -> AttributedString {
        var result = AttributedString()
        for segment in CodeHighlight.segments(String(block.text.characters), language: language) {
            var text = AttributedString(segment.text)
            switch segment.kind {
            case .keyword: text.foregroundColor = CodeColors.keyword
            case .string: text.foregroundColor = CodeColors.string
            case .comment: text.foregroundColor = .secondary
            case .number: text.foregroundColor = CodeColors.number
            case .type: text.foregroundColor = CodeColors.type
            case .function: text.foregroundColor = CodeColors.function
            case .plain: break
            }
            result.append(text)
        }
        return result
    }

    private func table(columns: [PresentationIntent.TableColumn]) -> some View {
        ScrollView(.horizontal) {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(block.children) { row in
                    HStack(alignment: .top, spacing: 0) {
                        ForEach(Array(row.children.enumerated()), id: \.element.id) { index, cell in
                            MarkdownInline(text: cell.text, media: media)
                                .font(.system(size: 13, weight: row.kind == .tableHeaderRow ? .semibold : .regular))
                                .lineSpacing(4)
                                .frame(width: index == 0 ? 260 : 170, alignment: alignment(columns: columns, index: index))
                                .fixedSize(horizontal: false, vertical: true)
                                .padding(12)
                        }
                    }
                    .background(.primary.opacity(row.kind == .tableHeaderRow ? 0.07 : 0.025))
                    .overlay(alignment: .bottom) { Rectangle().fill(.primary.opacity(0.09)).frame(height: 0.5) }
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.primary.opacity(0.1)))
        }
        .fixedSize(horizontal: false, vertical: true)
        .modifier(ChatHorizontalScroll())
    }

    private func alignment(columns: [PresentationIntent.TableColumn], index: Int) -> Alignment {
        guard columns.indices.contains(index) else { return .topLeading }
        switch columns[index].alignment {
        case .center: return .top
        case .right: return .topTrailing
        default: return .topLeading
        }
    }
}

@MainActor private struct MarkdownInline: View {
    let text: AttributedString
    let media: MessageMediaLoader?
    @Environment(\.compactMessageLayout) private var compact
    @State private var icons = SiteIconStore.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(text.runs[\.imageURL].enumerated()), id: \.offset) { _, run in
                if let url = run.0, GrokMessageContent.url(url.absoluteString) != nil {
                    MessageImage(url: url, name: String(text[run.1].characters), media: media, presentation: compact ? .user : .regular)
                } else {
                    ForEach(mathSections(AttributedString(text[run.1]))) { section in
                        if let formula = section.formula {
                            MathFormulaView(expression: formula)
                        } else {
                            linkedText(section.text).textSelection(.enabled).lineSpacing(4)
                                .frame(maxWidth: compact ? nil : .infinity, alignment: .leading)
                        }
                    }
                }
            }
        }
        .task(id: links) { for url in links { await icons.load(url) } }
        .environment(\.openURL, OpenURLAction { url in
            if let code = codeToCopy(url) {
                ClipboardFeedback.shared.copy(code)
                return .handled
            }
            return GrokMessageContent.url(url.absoluteString) != nil ? .systemAction : .discarded
        })
    }

    private struct Section: Identifiable {
        let id: Int
        let text: AttributedString
        var formula: MathExpression?
    }

    private func mathSections(_ source: AttributedString) -> [Section] {
        var result: [Section] = []
        var cursor = source.startIndex
        for run in source.runs {
            guard let math = run[MathExpressionAttribute.self], math.display else { continue }
            if cursor < run.range.lowerBound {
                result.append(Section(id: result.count, text: AttributedString(source[cursor..<run.range.lowerBound])))
            }
            result.append(Section(id: result.count, text: AttributedString(), formula: math))
            cursor = run.range.upperBound
        }
        if cursor < source.endIndex {
            result.append(Section(id: result.count, text: AttributedString(source[cursor..<source.endIndex])))
        }
        return result
    }

    private var links: [URL] {
        var seen = Set<URL>()
        return text.runs[\.link].compactMap { url, _ in
            guard let url, ["https", "http"].contains(url.scheme ?? ""), seen.insert(url).inserted else { return nil }
            return url
        }
    }

    private func linkedText(_ source: AttributedString) -> Text {
        var result = Text("")
        for (url, range) in source.runs[\.link] {
            if let url, ["https", "http"].contains(url.scheme ?? "") {
                let icon = icons.image(for: url) ?? AppSymbols.image("globe", accessibilityDescription: nil)!
                result = result + Text(Image(nsImage: icon)).font(.system(size: 12)).baselineOffset(-3) + Text(" ")
            }
            let part = AttributedString(source[range])
            for run in part.runs {
                if let math = run[MathExpressionAttribute.self], let rendered = MathTypesetter.render(math, fontSize: 15) {
                    result = result + Text(Image(nsImage: rendered.image)).baselineOffset(-rendered.descent)
                } else {
                    var styled = CodeColors.inline(AttributedString(part[run.range]))
                    if run.inlinePresentationIntent?.contains(.code) == true {
                        var components = URLComponents()
                        components.scheme = "swiftygrok-code"
                        components.host = "copy"
                        components.queryItems = [URLQueryItem(name: "value", value: Data(String(styled.characters).utf8).base64EncodedString())]
                        styled.link = components.url
                        styled.underlineStyle = nil
                    }
                    result = result + Text(styled)
                }
            }
        }
        return result
    }

    private func codeToCopy(_ url: URL) -> String? {
        guard url.scheme == "swiftygrok-code", url.host == "copy",
              let encoded = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "value" })?.value,
              let data = Data(base64Encoded: encoded), let code = String(data: data, encoding: .utf8),
              text.runs.contains(where: { $0.inlinePresentationIntent?.contains(.code) == true && String(text[$0.range].characters) == code }) else { return nil }
        return code
    }
}

@MainActor private struct MathFormulaView: View {
    let expression: MathExpression

    var body: some View {
        if let rendered = MathTypesetter.render(expression, fontSize: 22) {
            GeometryReader { geometry in
                ScrollView(.horizontal) {
                    Image(nsImage: rendered.image).renderingMode(.template)
                        .foregroundStyle(.primary).padding(.vertical, 8)
                        .frame(minWidth: geometry.size.width)
                }
            }
            .frame(height: rendered.image.size.height + 16)
            .accessibilityLabel(expression.latex)
            .contextMenu {
                Button {
                    ClipboardFeedback.shared.copy(expression.latex)
                } label: { Label(L10n.text("Copy LaTeX"), appSymbol: "doc.on.doc") }
            }
        } else {
            Text(expression.original).font(.system(size: 14, design: .monospaced)).textSelection(.enabled)
        }
    }
}

private enum CodeColors {
    // Dynamic AppKit colors keep the same palette legible in both appearances.
    static let keyword = adaptive(light: (0.10, 0.34, 0.65), dark: (0.58, 0.76, 0.96))
    static let string = adaptive(light: (0.20, 0.42, 0.10), dark: (0.67, 0.85, 0.38))
    static let number = adaptive(light: (0.48, 0.25, 0.65), dark: (0.83, 0.66, 0.94))
    static let type = adaptive(light: (0.00, 0.40, 0.45), dark: (0.45, 0.80, 0.82))
    static let function = adaptive(light: (0.49, 0.33, 0.10), dark: (0.90, 0.80, 0.53))
    static let inlineCode = adaptive(light: (0.72, 0.24, 0.03), dark: (0.96, 0.40, 0.12))

    static func inline(_ source: AttributedString) -> AttributedString {
        var result = source
        for run in source.runs where run.inlinePresentationIntent?.contains(.code) == true {
            result[run.range].foregroundColor = inlineCode
            result[run.range].font = .system(size: 13, design: .monospaced)
        }
        return result
    }

    private static func adaptive(light: (Double, Double, Double), dark: (Double, Double, Double)) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let color = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
            return NSColor(srgbRed: color.0, green: color.1, blue: color.2, alpha: 1)
        })
    }
}

@MainActor struct MessageImage: View {
    enum Presentation { case regular, user, generated }
    let url: URL
    let name: String
    let media: MessageMediaLoader?
    var presentation: Presentation = .regular
    @State private var image: NSImage?
    @State private var imageData: Data?
    @State private var failed = false
    @State private var loadAttempt = 0
    @State private var availableWidth: CGFloat = 600
    @State private var previewURL: URL?
    @State private var previewError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Group {
                if presentation == .generated {
                    VStack(spacing: 0) {
                        HStack {
                            Label("Imagine", appSymbol: "sparkles")
                                .font(.system(size: 14, weight: .medium))
                                .labelStyle(.titleAndIcon)
                            Spacer()
                            Button(action: showPreview) {
                                Image(appSymbol: "arrow.up.left.and.arrow.down.right").font(.system(size: 13))
                            }
                            .buttonStyle(.plain).disabled(imageData == nil)
                            .accessibilityLabel(L10n.text("Preview Imagine"))
                        }
                        .padding(.horizontal, 12).padding(.vertical, 10)
                        Divider()
                        imageContent.padding(10)
                    }
                    .frame(width: image.map { displaySize($0).width + 20 })
                    .background(.primary.opacity(0.015), in: RoundedRectangle(cornerRadius: 20))
                    .overlay(RoundedRectangle(cornerRadius: 20).strokeBorder(.primary.opacity(0.16), lineWidth: 1))
                } else {
                    imageContent
                }
            }
            if let previewError { Text(previewError).font(.caption).foregroundStyle(.secondary) }
        }
        .frame(minWidth: 0, maxWidth: .infinity, alignment: presentation == .user ? .trailing : .leading)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { availableWidth = $0 }
        .quickLookPreview($previewURL)
        .onChange(of: previewURL) { old, new in
            if old != new { removePreview(old) }
        }
        .onDisappear {
            removePreview(previewURL)
            previewURL = nil
        }
        .task(id: "\(url.absoluteString)#\(loadAttempt)") {
            image = nil; imageData = nil; failed = false
            do {
                guard let media else { throw URLError(.unsupportedURL) }
                let data = try await media.data(for: url)
                try Task.checkCancellation()
                guard let loaded = NSImage(data: data), loaded.size.width > 0, loaded.size.height > 0 else {
                    throw URLError(.cannotDecodeContentData)
                }
                imageData = data
                image = loaded
            } catch { if !Task.isCancelled { failed = true } }
        }
    }

    @ViewBuilder private var imageContent: some View {
        if let image {
            DraggableChatImage(image: image, file: imageData.flatMap { try? ImageFileExport(data: $0, name: name) },
                               name: name, onOpen: showPreview)
                .frame(width: displaySize(image).width, height: displaySize(image).height)
                .clipShape(RoundedRectangle(cornerRadius: presentation == .user ? 12 : 16))
                .help(L10n.text("Quick Look"))
        } else if failed {
            Button { loadAttempt += 1 } label: {
                Label(L10n.text("Retry loading image"), appSymbol: "arrow.clockwise")
                    .padding(16).frame(maxWidth: .infinity, alignment: .leading)
                    .background(.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 14))
            }
            .buttonStyle(.plain)
        } else {
            ProgressView().frame(maxWidth: .infinity, minHeight: presentation == .user ? 70 : 140)
        }
    }

    private func displaySize(_ image: NSImage) -> CGSize {
        let ratio = image.size.width / image.size.height
        let scale: CGFloat = presentation == .user ? 0.5 : 1
        let width = max(1, min(max(1, availableWidth - (presentation == .generated ? 20 : 0)) * scale, 420 * scale * ratio))
        return CGSize(width: width, height: width / ratio)
    }

    private func showPreview() {
        guard let imageData else { return }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("SwiftyGrok-Preview-\(UUID().uuidString)", isDirectory: true)
        do {
            let exported = try ImageFileExport(data: imageData, name: name)
            let file = directory.appendingPathComponent(exported.filename)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            try exported.write(to: file)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
            previewError = nil
            previewURL = file
        } catch {
            try? FileManager.default.removeItem(at: directory)
            previewError = L10n.format("Could not open preview: %@", error.localizedDescription)
        }
    }

    private func removePreview(_ url: URL?) {
        guard let url else { return }
        try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
    }
}
