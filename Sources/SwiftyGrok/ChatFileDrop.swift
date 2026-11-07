import AppKit
import SwiftUI
import UniformTypeIdentifiers
import GrokCore

@MainActor struct ChatFileDropTarget: ViewModifier {
    @Bindable var store: ChatStore
    @State private var targeted = false

    func body(content: Content) -> some View {
        content
            .contentShape(Rectangle())
            .onDrop(of: [UTType.fileURL.identifier], isTargeted: $targeted) { providers in
                guard store.canAttachFiles else { return false }
                let files = providers.filter { $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) }
                guard !files.isEmpty else { return false }
                Task {
                    await store.importFiles(resolvingURLs: {
                        var urls: [URL] = []
                        for provider in files { urls.append(try await FileDropInput.url(from: provider)) }
                        return urls
                    })
                }
                return true
            }
            .overlay {
                if targeted && store.canAttachFiles {
                    RoundedRectangle(cornerRadius: 16)
                        .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 2, dash: [7, 4]))
                        .padding(6).allowsHitTesting(false)
                }
            }
    }
}

enum FileDropInput {
    static func urls(from pasteboard: NSPasteboard) -> [URL] {
        (pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
    }

    static func url(from provider: NSItemProvider) async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, error in
                if let error { continuation.resume(throwing: error); return }
                let url = (item as? URL)
                    ?? (item as? Data).flatMap { URL(dataRepresentation: $0, relativeTo: nil) }
                    ?? (item as? String).flatMap(URL.init(string:))
                guard let url, url.isFileURL else {
                    continuation.resume(throwing: URLError(.unsupportedURL)); return
                }
                continuation.resume(returning: url)
            }
        }
    }
}
