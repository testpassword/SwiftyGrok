import AppKit
import SwiftUI
import GrokCore

struct ConversationShareTarget: Identifiable {
    let id: String
    let title: String
    let responseID: String?
}

@MainActor struct ConversationShareSheet: View {
    let target: ConversationShareTarget
    let store: ChatStore
    @Environment(\.dismiss) private var dismiss
    @State private var url: URL?
    @State private var isCreating = false
    @State private var error: String?
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label(L10n.text("Share chat"), systemImage: "square.and.arrow.up").font(.title2.weight(.semibold))
            Text(target.title).font(.headline).lineLimit(2)
            Text(L10n.text("Anyone with the link can read the selected message thread. Search engine indexing will remain disabled."))
                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if let url {
                Text(url.absoluteString).textSelection(.enabled).font(.callout)
                    .padding(12).frame(maxWidth: .infinity, alignment: .leading)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 10))
            }
            if let error { Text(error).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true) }
            HStack {
                Button(L10n.text("Close"), role: .cancel) { dismiss() }.disabled(isCreating)
                Spacer()
                if let url {
                    Link(L10n.text("Open"), destination: url)
                    Button(copied ? L10n.text("Copied") : L10n.text("Copy link")) {
                        ClipboardFeedback.shared.copy(url.absoluteString)
                        copied = true
                    }.keyboardShortcut(.defaultAction)
                } else {
                    if isCreating { ProgressView().controlSize(.small) }
                    Button(isCreating ? L10n.text("Creating…") : L10n.text("Create public link")) {
                        isCreating = true; error = nil
                        Task {
                            url = await store.shareConversation(id: target.id, responseID: target.responseID)
                            if url == nil { error = store.error?.message ?? L10n.text("Could not create a link.") }
                            isCreating = false
                        }
                    }
                    .disabled(isCreating)
                }
            }
        }
        .padding(24).frame(width: 480)
        .interactiveDismissDisabled(isCreating)
        .modifier(CopyFeedbackOverlay())
    }
}
