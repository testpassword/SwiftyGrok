import Foundation
import Observation
import GrokCore

enum MessageSendShortcut: String, CaseIterable, Identifiable {
    case commandEnter, enter
    var id: Self { self }
    var title: String { self == .commandEnter ? "⌘Enter" : "Enter" }
    var hint: String { self == .commandEnter ? "⌘↩" : "↩" }
    var help: String { L10n.text(self == .commandEnter ? "Send · ⌘↩" : "Send · ↩") }
    var explanation: String {
        L10n.text(self == .commandEnter
                  ? "⌘Enter sends; Enter inserts a new line."
                  : "Enter sends; ⌘Enter inserts a new line.")
    }
}

@MainActor @Observable final class BehaviorSettings {
    static let shared = BehaviorSettings()
    static let quickInputEnabledDidChange = Notification.Name("SwiftyGrok.quickInputEnabledDidChange")
    private(set) var sendShortcut: MessageSendShortcut
    private(set) var quickInputEnabled: Bool
    @ObservationIgnored private let defaults: UserDefaults
    private static let sendShortcutKey = "behavior.sendShortcut"
    private static let quickInputKey = "behavior.quickInputEnabled"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        sendShortcut = defaults.string(forKey: Self.sendShortcutKey).flatMap(MessageSendShortcut.init(rawValue:)) ?? .commandEnter
        quickInputEnabled = defaults.object(forKey: Self.quickInputKey) as? Bool ?? true
    }

    func setSendShortcut(_ shortcut: MessageSendShortcut) {
        guard sendShortcut != shortcut else { return }
        sendShortcut = shortcut
        defaults.set(shortcut.rawValue, forKey: Self.sendShortcutKey)
    }

    func setQuickInputEnabled(_ enabled: Bool) {
        guard quickInputEnabled != enabled else { return }
        quickInputEnabled = enabled
        defaults.set(enabled, forKey: Self.quickInputKey)
        NotificationCenter.default.post(name: Self.quickInputEnabledDidChange, object: self)
    }
}
