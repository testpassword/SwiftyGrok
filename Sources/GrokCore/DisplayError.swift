import Foundation
import GrokClient

public enum SystemPermission: Equatable, Sendable {
    case camera, microphone, screenRecording

    public var settingsURL: URL {
        let pane: String
        switch self {
        case .camera: pane = "Privacy_Camera"
        case .microphone: pane = "Privacy_Microphone"
        case .screenRecording: pane = "Privacy_ScreenCapture"
        }
        return URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)")!
    }
}

/// Local capture errors identify their permission without inspecting message text.
public protocol SystemPermissionError: Error {
    var systemPermission: SystemPermission? { get }
}

public struct DisplayError: Identifiable, Equatable, Sendable {
    public let id = UUID()
    public let message: String
    public let needsLogin: Bool
    public let allowsSessionRefresh: Bool
    public let systemPermission: SystemPermission?

    public init(_ error: Error) {
        needsLogin = (error as? GrokError) == .unauthorized || (error as? GrokError) == .invalidCredentials
        allowsSessionRefresh = error is GrokError
        systemPermission = (error as? any SystemPermissionError)?.systemPermission
        switch error {
        case GrokError.unauthorized, GrokError.invalidCredentials:
            message = L10n.text("Your Grok session has expired. Sign in again to load your history and send messages.")
        case GrokError.antiBotRejected:
            message = L10n.text("Grok requested browser verification. Open the sign-in window, complete verification, and connect the session again. If needed, import cookies from your regular browser along with its User-Agent.")
        case GrokError.accessDenied:
            message = L10n.text("Grok rejected the request. Check that your account has access to the selected mode, or refresh your session.")
        case GrokError.notFound:
            message = L10n.text("The chat or API endpoint was not found. Refresh your history; Grok may have changed its web API.")
        case GrokError.decodingError, is DecodingError:
            message = L10n.text("Could not read the Grok response. The web API format may have changed.")
        case GrokError.networkError(let underlying):
            message = L10n.format("Network error: %@", underlying.localizedDescription)
        case GrokError.streamingError:
            message = L10n.text("Could not read Grok streaming response")
        case GrokError.apiError(let detail):
            message = L10n.text(detail)
        default: message = error.localizedDescription
        }
    }
}
