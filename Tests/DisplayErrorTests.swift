import XCTest
import GrokClient
@testable import GrokCore

private struct PermissionFailure: LocalizedError, SystemPermissionError {
    let systemPermission: SystemPermission?
    var errorDescription: String? { "Permission denied" }
}

final class DisplayErrorTests: XCTestCase {
    func testPermissionErrorsOfferMatchingSettingsWithoutSessionRefresh() {
        let permissions: [(SystemPermission, String)] = [
            (.screenRecording, "Privacy_ScreenCapture"),
            (.microphone, "Privacy_Microphone"),
            (.camera, "Privacy_Camera")
        ]
        for (permission, pane) in permissions {
            let error = DisplayError(PermissionFailure(systemPermission: permission))
            XCTAssertEqual(error.message, "Permission denied")
            XCTAssertEqual(error.systemPermission, permission)
            XCTAssertEqual(error.systemPermission?.settingsURL.absoluteString,
                           "x-apple.systempreferences:com.apple.preference.security?\(pane)")
            XCTAssertFalse(error.needsLogin)
            XCTAssertFalse(error.allowsSessionRefresh)
        }
    }

    func testLocalFailuresDoNotSuggestRefreshingGrokSession() {
        let failures: [Error] = [
            CocoaError(.fileReadNoPermission), URLError(.notConnectedToInternet),
            ClientFailure.noSpeech, PermissionFailure(systemPermission: nil)
        ]
        for failure in failures {
            let error = DisplayError(failure)
            XCTAssertFalse(error.allowsSessionRefresh)
            XCTAssertFalse(error.needsLogin)
            XCTAssertNil(error.systemPermission)
        }
    }

    func testGrokFailuresKeepSessionRecoveryAndExpiredSessionRequiresLogin() {
        let failures: [(GrokError, Bool)] = [
            (.unauthorized, true), (.invalidCredentials, true),
            (.antiBotRejected("Verification required"), false), (.accessDenied("Access denied"), false),
            (.networkError(URLError(.notConnectedToInternet)), false)
        ]
        for (failure, needsLogin) in failures {
            let error = DisplayError(failure)
            XCTAssertTrue(error.allowsSessionRefresh)
            XCTAssertEqual(error.needsLogin, needsLogin)
            XCTAssertNil(error.systemPermission)
        }
    }
}
