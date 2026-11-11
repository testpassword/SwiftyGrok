import SwiftUI
import AppKit

private struct ChatScrollInsetKey: EnvironmentKey { static let defaultValue: CGFloat = 0 }

extension EnvironmentValues {
    var chatScrollInset: CGFloat {
        get { self[ChatScrollInsetKey.self] }
        set { self[ChatScrollInsetKey.self] = newValue }
    }
}

/// Let horizontal scroll views reach the split-view edges while their first
/// item stays aligned with the message text, as in Apple's Landmarks sample.
struct ChatHorizontalScroll: ViewModifier {
    @Environment(\.chatScrollInset) private var inset

    func body(content: Content) -> some View {
        content
            .contentMargins(.horizontal, inset, for: .scrollContent)
            .padding(.horizontal, -inset)
    }
}

/// Observe only the transcript's native scroll view. Live-scroll notifications
/// distinguish user input from layout changes and programmatic scrollTo calls.
struct TranscriptScrollObserver: NSViewRepresentable {
    var onFollowChange: (Bool) -> Void

    func makeNSView(context: Context) -> TranscriptScrollTrackingView {
        let view = TranscriptScrollTrackingView()
        view.onFollowChange = onFollowChange
        return view
    }

    func updateNSView(_ view: TranscriptScrollTrackingView, context: Context) {
        view.onFollowChange = onFollowChange
        view.track(view.enclosingScrollView)
    }

    static func dismantleNSView(_ view: TranscriptScrollTrackingView, coordinator: ()) { view.track(nil) }
}

@MainActor final class TranscriptScrollTrackingView: NSView {
    var onFollowChange: ((Bool) -> Void)?
    private weak var scrollView: NSScrollView?
    private var lastOffset: CGFloat = 0
    private var previousOffset: CGFloat = 0

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func viewDidMoveToSuperview() { super.viewDidMoveToSuperview(); track(enclosingScrollView) }
    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); track(enclosingScrollView) }

    func track(_ scrollView: NSScrollView?) {
        guard self.scrollView !== scrollView else { return }
        NotificationCenter.default.removeObserver(self)
        self.scrollView = scrollView
        guard let scrollView else { return }
        lastOffset = offset(in: scrollView)
        previousOffset = lastOffset
        scrollView.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(boundsChanged),
            name: NSView.boundsDidChangeNotification, object: scrollView.contentView)
        NotificationCenter.default.addObserver(self, selector: #selector(userScrolled),
            name: NSScrollView.didLiveScrollNotification, object: scrollView)
    }

    private func offset(in scrollView: NSScrollView) -> CGFloat {
        scrollView.contentView.bounds.minY * (scrollView.documentView?.isFlipped == true ? 1 : -1)
    }

    @objc private func boundsChanged() {
        guard let scrollView else { return }
        let offset = offset(in: scrollView)
        guard offset != lastOffset else { return }
        previousOffset = lastOffset
        lastOffset = offset
    }

    @objc private func userScrolled() {
        guard let scrollView, let document = scrollView.documentView else { return }
        let movement = lastOffset - previousOffset
        previousOffset = lastOffset
        if movement < 0 {
            onFollowChange?(false)
        } else if movement > 0 {
            let visible = scrollView.documentVisibleRect
            let distance = document.isFlipped ? document.bounds.maxY - visible.maxY : visible.minY - document.bounds.minY
            if distance <= 24 { onFollowChange?(true) }
        }
    }

    deinit { NotificationCenter.default.removeObserver(self) }
}
