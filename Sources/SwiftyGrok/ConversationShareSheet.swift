import AppKit
import SwiftUI
import GrokCore

struct ConversationShareTarget: Identifiable {
    let id: String
    let title: String
    let responseID: String?
}

@MainActor struct ConversationSharePopover: View {
    let target: ConversationShareTarget
    let store: ChatStore
    @Environment(\.dismiss) private var dismiss
    @State private var isCreating = false
    @State private var error: String?
    @State private var creationTask: Task<Void, Never>?

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            VStack(alignment: .leading, spacing: 6) {
                Text(L10n.text("Share chat")).font(.system(size: 14, weight: .semibold))
                Text(target.title).font(.system(size: 12, weight: .medium)).lineLimit(2)
                Text(L10n.text("Anyone with the link can read the selected message thread. Search engine indexing will remain disabled."))
                    .font(.system(size: 12)).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }.padding(12)
            ShareActionRow(title: isCreating ? L10n.text("Creating…") : L10n.text("Create public link"),
                           symbol: "link", isBusy: isCreating, action: createLink)
                .disabled(isCreating)
                .keyboardShortcut(.defaultAction)
            if let error {
                Text(error).font(.system(size: 12)).foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true).padding(12)
            }
        }
        .padding(8).frame(width: 340)
        .onExitCommand { dismiss() }
        .onDisappear { creationTask?.cancel(); creationTask = nil }
    }

    private func createLink() {
        guard !isCreating else { return }
        isCreating = true
        error = nil
        creationTask = Task {
            defer { isCreating = false; creationTask = nil }
            let result = await store.shareConversation(id: target.id, responseID: target.responseID)
            guard !Task.isCancelled else { return }
            guard let result else {
                error = store.error?.message ?? L10n.text("Could not create a link.")
                return
            }
            guard ClipboardFeedback.shared.copy(result.absoluteString) else {
                error = L10n.text("Could not copy the link. Please try again.")
                return
            }
            // The main window's shared CopyFeedbackOverlay survives dismissal
            // and shows the same confirmation as copying code.
            dismiss()
        }
    }
}

@MainActor private struct ShareActionRow: View {
    let title: String
    let symbol: String
    var isBusy = false
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Group {
                    if isBusy { ProgressView().controlSize(.small) }
                    else { Image(appSymbol: symbol).font(.system(size: 18, weight: .medium)) }
                }
                .frame(width: 38, height: 38)
                .background(.primary.opacity(0.07), in: Circle())
                Text(title).font(.system(size: 14, weight: .medium))
                Spacer(minLength: 0)
            }
            .padding(8).contentShape(Rectangle())
            .background(hovered ? Color.primary.opacity(0.06) : .clear,
                        in: RoundedRectangle(cornerRadius: 10))
        }
        .modifier(SharingGlassButtons())
        .onHover { hovered = $0 }
    }
}
