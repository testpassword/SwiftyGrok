import AppKit
import SwiftUI
import Observation
import GrokCore

@MainActor @Observable final class ClipboardFeedback {
    static let shared = ClipboardFeedback()
    private(set) var sequence = 0

    @discardableResult func copy(_ text: String) -> Bool {
        NSPasteboard.general.clearContents()
        guard NSPasteboard.general.setString(text, forType: .string) else { return false }
        sequence += 1
        return true
    }
}

@MainActor struct CopyFeedbackOverlay: ViewModifier {
    @State private var feedback = ClipboardFeedback.shared
    @State private var visible = false
    @State private var dismissTask: Task<Void, Never>?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content.overlay(alignment: .top) {
            if visible {
                Label(L10n.text("Copied"), systemImage: "checkmark.circle.fill")
                    .font(.system(size: 12, weight: .medium))
                    .padding(.horizontal, 14).padding(.vertical, 9)
                    .modifier(FloatingGlass(cornerRadius: 20))
                    .padding(.top, 12)
                    .transition(.opacity.combined(with: .scale(scale: reduceMotion ? 1 : 0.9)))
                    .allowsHitTesting(false)
            }
        }
        .onChange(of: feedback.sequence) { _, _ in
            dismissTask?.cancel()
            withAnimation(reduceMotion ? nil : .spring(response: 0.25)) { visible = true }
            dismissTask = Task {
                do { try await Task.sleep(for: .milliseconds(1200)) } catch { return }
                withAnimation(reduceMotion ? nil : .easeOut(duration: 0.2)) { visible = false }
            }
        }
        .onDisappear { dismissTask?.cancel() }
    }
}
