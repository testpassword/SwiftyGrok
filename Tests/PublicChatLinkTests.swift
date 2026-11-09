import XCTest
@testable import GrokCore
#if os(macOS)
import AppKit
import UniformTypeIdentifiers
#endif

final class PublicChatLinkTests: XCTestCase {
    func testPublicURLCanonicalizationAndHandoffRoundTrip() throws {
        let link = try XCTUnwrap(PublicChatLink(url: URL(string: "https://www.grok.com/share/legacy_public-token?utm_source=share#messages")!))
        XCTAssertEqual(link.id, "legacy_public-token")
        XCTAssertEqual(link.url.absoluteString, "https://grok.com/share/legacy_public-token")
        XCTAssertEqual(PublicChatLink(handoffURL: link.handoffURL), link)
    }

    func testRejectsForeignHostsPrivateRoutesCredentialsAndPathInjection() {
        for value in [
            "http://grok.com/share/token", "https://grok.com.evil.example/share/token",
            "https://evil.example/share/token", "https://grok.com@evil.example/share/token",
            "https://user@grok.com/share/token", "https://grok.com:443/share/token",
            "file:///share/token", "https://grok.com/c/private-id", "https://grok.com/share/",
            "https://grok.com/share/token/other", "https://grok.com/share/%2e%2e",
            "https://grok.com/share/token%2Fother", "https://grok.com/share/token%3Fprivate",
            "https://grok.com/share/" + String(repeating: "a", count: 2049)
        ] { XCTAssertNil(PublicChatLink(url: URL(string: value)!), value) }
        for value in [
            "swiftygrok://public-chat/token?redirect=evil", "swiftygrok://public-chat/token#fragment",
            "swiftygrok://public-chat/token/other", "swiftygrok://user@public-chat/token",
            "swiftygrok://share/attach?request=token", "https://public-chat/token"
        ] { XCTAssertNil(PublicChatLink(handoffURL: URL(string: value)!), value) }
    }

    #if os(macOS)
    func testURLProviderSupportsNSURLAndDataWithoutReadingFiles() async throws {
        let url = URL(string: "https://grok.com/share/provider-token")!
        let nsurl = NSItemProvider(item: url as NSURL, typeIdentifier: UTType.url.identifier)
        let nsurlLink = try await PublicChatLink.load(from: nsurl)
        XCTAssertEqual(nsurlLink.url, url)
        let data = NSItemProvider()
        data.registerDataRepresentation(forTypeIdentifier: UTType.url.identifier, visibility: .all) { completion in
            completion(url.dataRepresentation, nil)
            return nil
        }
        let dataLink = try await PublicChatLink.load(from: data)
        XCTAssertEqual(dataLink.url, url)
        let foreign = NSItemProvider(item: URL(string: "https://example.com")! as NSURL, typeIdentifier: UTType.url.identifier)
        do {
            _ = try await PublicChatLink.load(from: foreign)
            XCTFail("Foreign websites must not be opened as chats")
        } catch {}
    }
    #endif
}
