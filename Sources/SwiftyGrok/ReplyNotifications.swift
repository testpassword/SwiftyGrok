import AppKit
import UserNotifications
import GrokCore

@MainActor final class ReplyNotifications: NSObject, UNUserNotificationCenterDelegate {
    static let shared = ReplyNotifications()
    private static let sessionKey = "notifications.sessionID"
    private var sessionID: String
    private var authorizationTask: Task<Void, Never>?
    private var openConversation: ((String?) -> Void)?
    private var pendingOpen: (sessionID: String, conversationID: String?)?

    private override init() {
        sessionID = UserDefaults.standard.string(forKey: Self.sessionKey) ?? UUID().uuidString
        super.init()
        UserDefaults.standard.set(sessionID, forKey: Self.sessionKey)
    }

    private var center: UNUserNotificationCenter? {
        // UserNotifications requires a real application bundle, not swift run.
        guard Bundle.main.bundleURL.pathExtension == "app", Bundle.main.bundleIdentifier != nil else { return nil }
        return UNUserNotificationCenter.current()
    }

    private var chatWindowIsFocused: Bool {
        NSApp.isActive && NSApp.keyWindow?.identifier?.rawValue == "main"
    }

    func start() { center?.delegate = self }

    func configure(openConversation: @escaping (String?) -> Void) {
        self.openConversation = openConversation
        if let pendingOpen {
            self.pendingOpen = nil
            if pendingOpen.sessionID == sessionID { openConversation(pendingOpen.conversationID) }
        }
    }

    func prepareAuthorization() {
        guard authorizationTask == nil, let center else { return }
        authorizationTask = Task { [weak self] in
            defer { self?.authorizationTask = nil }
            let settings = await center.notificationSettings()
            guard !Task.isCancelled, settings.authorizationStatus == .notDetermined else { return }
            do { _ = try await center.requestAuthorization(options: [.alert, .sound]) }
            catch { NSLog("SwiftyGrok could not request notification permission: %@", error.localizedDescription) }
        }
    }

    func show(_ reply: ReplyCompletion) {
        guard !chatWindowIsFocused, let center else { return }
        let scope = sessionID
        let authorization = authorizationTask
        Task { [weak self] in
            await authorization?.value
            guard let self, scope == sessionID else { return }
            let settings = await center.notificationSettings()
            guard scope == sessionID, !chatWindowIsFocused,
                  settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional else { return }
            let content = UNMutableNotificationContent()
            content.title = L10n.text("Grok replied")
            content.body = reply.preview.isEmpty ? L10n.text("Your reply is ready. Open the chat to view it.") : reply.preview
            content.sound = .default
            content.threadIdentifier = reply.isTemporary ? "private-replies" : "chat-\(reply.conversationID)"
            content.userInfo = ["kind": "reply", "sessionID": scope]
            // A private conversation has no reloadable history; don't persist its ID.
            if !reply.isTemporary { content.userInfo["conversationID"] = reply.conversationID }
            let identifier = "reply-\(reply.requestID)"
            do {
                try await center.add(UNNotificationRequest(identifier: identifier, content: content, trigger: nil))
                if scope != sessionID {
                    center.removePendingNotificationRequests(withIdentifiers: [identifier])
                    center.removeDeliveredNotifications(withIdentifiers: [identifier])
                }
            } catch { NSLog("SwiftyGrok could not deliver a reply notification: %@", error.localizedDescription) }
        }
    }

    func reset() {
        sessionID = UUID().uuidString
        UserDefaults.standard.set(sessionID, forKey: Self.sessionKey)
        pendingOpen = nil
        center?.removeAllPendingNotificationRequests()
        center?.removeAllDeliveredNotifications()
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                           withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        let scope = notification.request.content.userInfo["sessionID"] as? String
        let kind = notification.request.content.userInfo["kind"] as? String
        Task { @MainActor [weak self] in
            guard let self, kind == "reply", scope == sessionID, !chatWindowIsFocused else {
                completionHandler([])
                return
            }
            completionHandler([.banner, .list, .sound])
        }
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                           withCompletionHandler completionHandler: @escaping () -> Void) {
        let scope = response.notification.request.content.userInfo["sessionID"] as? String
        let conversationID = response.notification.request.content.userInfo["conversationID"] as? String
        let kind = response.notification.request.content.userInfo["kind"] as? String
        let isDefaultAction = response.actionIdentifier == UNNotificationDefaultActionIdentifier
        Task { @MainActor [weak self] in
            defer { completionHandler() }
            guard let self, isDefaultAction, kind == "reply", scope == sessionID else { return }
            if let openConversation { openConversation(conversationID) }
            else { pendingOpen = (sessionID, conversationID) }
        }
    }
}
