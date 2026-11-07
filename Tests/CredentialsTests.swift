import XCTest
@testable import GrokCore

final class CredentialsTests: XCTestCase {
    func testCookieHeaderPreservesEqualsInsideValues() throws {
        let session = try SessionCredentials.importing("Cookie: sso=abc==; sso-rw=xyz; cf_clearance=token")
        XCTAssertEqual(session.cookies["sso"], "abc==")
        XCTAssertEqual(session.cookies["cf_clearance"], "token")
    }

    func testSwiftGrokJSONDictionary() throws {
        let session = try SessionCredentials.importing(#"{"sso":"test","cf_clearance":"clear"}"#)
        XCTAssertEqual(session.cookies.count, 2)
    }

    func testBrowserExportFiltersOtherDomainsAndExpiredCookies() throws {
        let session = try SessionCredentials.importing(#"[{"name":"sso","value":"good","domain":".grok.com"},{"name":"sso","value":"bad","domain":"grok.com.evil.test"},{"name":"old","value":"expired","domain":"grok.com","expirationDate":1}]"#)
        XCTAssertEqual(session.cookies, ["sso": "good"])
    }

    func testRejectsMissingSSOAndHeaderInjection() {
        for header in ["cf_clearance=only", "sso=", "sso=ok\r\nInjected: value", "bad name=v; sso=ok", #"{"sso":"ok;bad=value"}"#] {
            XCTAssertThrowsError(try SessionCredentials.importing(header), header)
        }
        for userAgent in ["UA\rheader", "UA\nheader", "UA\r\nheader"] {
            XCTAssertThrowsError(try SessionCredentials(cookies: ["sso": "test"], userAgent: userAgent))
        }
    }

    func testDomainBoundary() {
        XCTAssertTrue(SessionCredentials.isGrokDomain(".grok.com"))
        XCTAssertTrue(SessionCredentials.isGrokDomain("accounts.grok.com"))
        XCTAssertFalse(SessionCredentials.isGrokDomain("notgrok.com"))
        XCTAssertFalse(SessionCredentials.isGrokDomain("grok.com.attacker.test"))
    }
}
