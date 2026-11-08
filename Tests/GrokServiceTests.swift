import XCTest
import Foundation
import GrokClient
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import GrokCore

private final class FixtureProtocol: URLProtocol {
    static var handler: ((URLRequest) throws -> (Int, Data))?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            var normalizedRequest = request
            // Darwin URLSession may expose a POST body as a stream to URLProtocol.
            if normalizedRequest.httpBody == nil, let stream = normalizedRequest.httpBodyStream {
                stream.open()
                defer { stream.close() }
                var body = Data()
                var buffer = [UInt8](repeating: 0, count: 4096)
                while stream.hasBytesAvailable {
                    let count = stream.read(&buffer, maxLength: buffer.count)
                    guard count > 0 else { break }
                    body.append(contentsOf: buffer.prefix(count))
                }
                normalizedRequest.httpBody = body
            }
            let (status, data) = try Self.handler!(normalizedRequest)
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}

final class GrokServiceTests: XCTestCase {
    @MainActor func testGeneralHistoryExcludesProjectsForSearchAndPagination() async throws {
        FixtureProtocol.handler = { request in
            let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!
            XCTAssertEqual(query.first { $0.name == "excludeProjects" }?.value, "true")
            XCTAssertNil(query.first { $0.name == "workspaceId" })
            return (200, Data(#"{"conversations":[],"nextPageToken":"more"}"#.utf8))
        }
        let service = try service()
        _ = try await service.history(pageToken: nil, search: "")
        _ = try await service.history(pageToken: "cursor", search: "query")
    }

    @MainActor func testRemovingProjectMembershipUsesDeleteWithoutDeletingChat() async throws {
        FixtureProtocol.handler = { request in
            XCTAssertEqual(request.httpMethod, "DELETE")
            XCTAssertEqual(request.url?.path, "/rest/workspaces/project/conversations/chat")
            XCTAssertNil(request.httpBody)
            return (204, Data())
        }
        try await service().removeConversationFromProject(conversationID: "chat", projectID: "project")
    }

    @MainActor func testProjectReplyIncludesWorkspaceButPrivateReplyDoesNot() async throws {
        for temporary in [false, true] {
            for id in [nil, "chat"] as [String?] {
                FixtureProtocol.handler = { request in
                    let body = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any]
                    XCTAssertEqual(body["workspaceIds"] as? [String], temporary ? nil : ["project"])
                    return (200, Data((#"{"result":{"conversation":{"conversationId":"chat"},"response":{"modelResponse":{"responseId":"answer","message":"Done"}}}}"# + "\n").utf8))
                }
                let stream = try await service().reply(conversationID: id, parentID: id == nil ? nil : "parent", text: "Question", modeID: "fast", temporary: temporary, projectID: "project")
                for try await _ in stream {}
            }
        }
    }

    @MainActor func testEmptyProjectIDCannotRequestGlobalHistory() async throws {
        FixtureProtocol.handler = { _ in
            XCTFail("A missing project ID must never fall back to global history")
            return (200, Data(#"{"conversations":[]}"#.utf8))
        }
        do { _ = try await service().projectConversations(id: " \n", pageToken: nil); XCTFail("Expected invalid project ID") }
        catch { XCTAssertEqual(error as? GrokError, .notFound) }
    }

    @MainActor func testProjectConversationPageUsesWorkspaceFilterAndExcludesPrivateChats() async throws {
        FixtureProtocol.handler = { request in
            XCTAssertEqual(request.httpMethod, "GET")
            XCTAssertEqual(request.url?.path, "/rest/app-chat/conversations")
            let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!
            XCTAssertEqual(query.first { $0.name == "workspaceId" }?.value, "project")
            XCTAssertNil(query.first { $0.name == "excludeProjects" })
            XCTAssertEqual(query.first { $0.name == "pageToken" }?.value, "cursor")
            return (200, Data(#"{"conversations":[{"conversationId":"saved","title":"Project chat","starred":true},{"conversationId":"private","title":"Private","temporary":true}],"nextPageToken":"more"}"#.utf8))
        }
        let page = try await service().projectConversations(id: "project", pageToken: "cursor")
        XCTAssertEqual(page.items.map(\.id), ["saved"])
        XCTAssertEqual(page.items.first?.title, "Project chat")
        XCTAssertEqual(page.items.first?.isPinned, true)
        XCTAssertEqual(page.nextPageToken, "more")
    }

    @MainActor func testProjectRenameUsesPartialPUTAndAcceptsEmptyAcknowledgement() async throws {
        FixtureProtocol.handler = { request in
            XCTAssertEqual(request.httpMethod, "PUT")
            XCTAssertEqual(request.url?.path, "/rest/workspaces/project")
            let body = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: String]
            XCTAssertEqual(body, ["name": "Renamed"])
            return (204, Data())
        }
        try await service().renameProject(id: "project", name: " Renamed \n")
    }

    @MainActor func testProjectDeletionAndChatMoveUseWorkspaceEndpoints() async throws {
        var calls = 0
        FixtureProtocol.handler = { request in
            calls += 1
            if calls == 1 {
                XCTAssertEqual(request.httpMethod, "POST")
                XCTAssertEqual(request.url?.path, "/rest/workspaces/project/conversations")
                let body = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: String]
                XCTAssertEqual(body, ["conversationId": "chat"])
            } else {
                XCTAssertEqual(request.httpMethod, "DELETE")
                XCTAssertEqual(request.url?.path, "/rest/workspaces/project")
                XCTAssertNil(request.httpBody)
            }
            return (204, Data())
        }
        let service = try service()
        try await service.addConversationToProject(conversationID: "chat", projectID: "project")
        try await service.deleteProject(id: "project")
        XCTAssertEqual(calls, 2)
    }

    @MainActor func testProjectsLoadAllPagesAndKeepServerIconAndDescription() async throws {
        var calls = 0
        FixtureProtocol.handler = { request in
            XCTAssertEqual(request.httpMethod, "GET")
            XCTAssertEqual(request.url?.path, "/rest/workspaces")
            let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!
            XCTAssertEqual(query.first { $0.name == "orderBy" }?.value, "ORDER_BY_LAST_USE_TIME")
            calls += 1
            if calls == 1 {
                XCTAssertNil(query.first { $0.name == "pageToken" })
                return (200, Data(#"{"workspaces":[{"workspaceId":"one","name":"Work","icon":"l:briefcase:blue","customPersonality":"Research"}],"nextPageToken":"next"}"#.utf8))
            }
            XCTAssertEqual(query.first { $0.name == "pageToken" }?.value, "next")
            return (200, Data(#"{"workspaces":[{"id":"two","title":"Study"},{"name":"No ID"}]}"#.utf8))
        }
        let projects = try await service().projects()
        XCTAssertEqual(projects.map(\.id), ["one", "two"])
        XCTAssertEqual(projects[0].icon, "l:briefcase:blue")
        XCTAssertEqual(projects[0].description, "Research")
        XCTAssertEqual(projects[1].name, "Study")
        XCTAssertEqual(calls, 2)
    }

    @MainActor func testCreateProjectUsesWorkspacePayloadAndServerIdentity() async throws {
        FixtureProtocol.handler = { request in
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.url?.path, "/rest/workspaces")
            let body = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any]
            XCTAssertEqual(body["name"] as? String, "Study")
            XCTAssertEqual(body["customPersonality"] as? String, "Read papers")
            XCTAssertEqual(body["icon"] as? String, "l:graduation-cap:lime")
            XCTAssertEqual(body["preferredModel"] as? String, "auto")
            return (200, Data(#"{"workspace":{"workspaceId":"created","name":"Study","icon":"l:graduation-cap:lime","customPersonality":"Read papers"}}"#.utf8))
        }
        let project = try await service().createProject(name: " Study\n", description: "Read papers", icon: .education)
        XCTAssertEqual(project.id, "created")
        XCTAssertEqual(project.description, "Read papers")
    }

    @MainActor func testProjectCreationRejectsBlankNamesAndMissingServerID() async throws {
        var calls = 0
        FixtureProtocol.handler = { _ in calls += 1; return (200, Data(#"{"workspace":{"name":"Missing ID"}}"#.utf8)) }
        let service = try service()
        do {
            _ = try await service.createProject(name: " \n", description: "", icon: .book)
            XCTFail("Empty names must not be sent")
        } catch { XCTAssertEqual(calls, 0) }
        do {
            _ = try await service.createProject(name: "Study", description: "", icon: .book)
            XCTFail("Only a server ID can confirm creation")
        } catch { XCTAssertTrue(error is ProjectFailure) }
        XCTAssertEqual(calls, 1)
    }

    @MainActor func testProjectsRejectRepeatedPageTokenInsteadOfLooping() async throws {
        var calls = 0
        FixtureProtocol.handler = { _ in
            calls += 1
            return (200, Data(#"{"workspaces":[],"nextPageToken":"same"}"#.utf8))
        }
        do { _ = try await service().projects(); XCTFail("Repeated cursors must stop the load") }
        catch { XCTAssertEqual(calls, 2) }
    }

    @MainActor func testFileUploadAndAttachmentIDsForNewAndContinuedReplies() async throws {
        for conversationID in [nil, "chat"] as [String?] {
            var uploaded = false
            FixtureProtocol.handler = { request in
                let body = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any]
                if request.url?.path == "/rest/app-chat/upload-file" {
                    XCTAssertEqual(body["fileName"] as? String, "note.txt")
                    XCTAssertEqual(body["fileMimeType"] as? String, "text/plain")
                    XCTAssertEqual(Data(base64Encoded: body["content"] as! String), Data("Hello".utf8))
                    uploaded = true
                    return (200, Data(#"{"fileMetadataId":"file-1"}"#.utf8))
                }
                XCTAssertTrue(uploaded)
                XCTAssertEqual(body["fileAttachments"] as? [String], ["file-1"])
                XCTAssertEqual(request.url?.path, conversationID == nil ? "/rest/app-chat/conversations/new" : "/rest/app-chat/conversations/chat/responses")
                return (200, Data((#"{"result":{"conversation":{"conversationId":"chat"},"response":{"modelResponse":{"responseId":"answer","message":"Read"}}}}"# + "\n").utf8))
            }
            let client = try service()
            let id = try await client.upload(file: DraftFile(name: "note.txt", mimeType: "text/plain", data: Data("Hello".utf8)))
            let stream = try await client.reply(conversationID: conversationID, parentID: nil, text: "Read", modeID: "fast", fileIDs: [id])
            for try await _ in stream {}
        }
    }

    @MainActor func testFileUploadWithoutIDIsRejected() async throws {
        FixtureProtocol.handler = { _ in (200, Data(#"{"fileName":"note.txt"}"#.utf8)) }
        do {
            _ = try await service().upload(file: DraftFile(name: "note.txt", mimeType: "text/plain", data: Data()))
            XCTFail("An upload without an acknowledged ID cannot be attached")
        } catch { XCTAssertEqual(error as? ClientFailure, .uploadFailed) }
    }

    @MainActor func testHistoryOmitsTemporaryConversationsFromServer() async throws {
        FixtureProtocol.handler = { _ in
            (200, Data(#"{"conversations":[{"conversationId":"normal","title":"Saved"},{"conversationId":"private","title":"Secret","temporary":true}]}"#.utf8))
        }
        let page = try await service().history(pageToken: nil, search: "")
        XCTAssertEqual(page.items.map(\.id), ["normal"])
    }

    @MainActor func testTemporaryRequestsDisableMemoryForNewAndContinuedTurnsAndKeepRichContent() async throws {
        for conversationID in [nil, "private"] as [String?] {
            FixtureProtocol.handler = { request in
                XCTAssertEqual(request.url?.path, conversationID == nil ? "/rest/app-chat/conversations/new" : "/rest/app-chat/conversations/private/responses")
                let body = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any]
                XCTAssertEqual(body["temporary"] as? Bool, true)
                XCTAssertEqual(body["disableMemory"] as? Bool, true)
                if conversationID != nil { XCTAssertEqual(body["parentResponseId"] as? String, "previous") }
                return (200, Data((#"{"result":{"conversation":{"conversationId":"private"},"response":{"modelResponse":{"responseId":"answer","message":"Private answer","webSearchResults":[{"url":"https://example.com","title":"Source"}],"generatedImageUrls":["https://assets.grok.com/image.jpg"]}}}}"# + "\n").utf8))
            }
            let stream = try await service().reply(conversationID: conversationID, parentID: conversationID == nil ? nil : "previous", text: "Secret", modeID: "fast", temporary: true)
            var final: ReplyEvent?
            for try await event in stream where event.isFinal { final = event }
            XCTAssertEqual(final?.responseID, "answer")
            XCTAssertEqual(final?.sources.first?.title, "Source")
            XCTAssertEqual(final?.attachments.first?.url?.absoluteString, "https://assets.grok.com/image.jpg")
        }
    }

    @MainActor func testTemporaryTokenOnlyEOFDoesNotAcknowledgeCompletion() async throws {
        FixtureProtocol.handler = { _ in
            (200, Data((#"{"result":{"conversation":{"conversationId":"private"},"response":{"responseId":"partial","token":"Incomplete"}}}"# + "\n").utf8))
        }
        do {
            let stream = try await service().reply(conversationID: nil, parentID: nil, text: "Secret", modeID: "fast", temporary: true)
            for try await _ in stream {}
            XCTFail("Temporary chat must require an explicit model response acknowledgement")
        } catch { XCTAssertEqual(error as? ClientFailure, .interruptedReply) }
    }

    @MainActor func testSharePublishesSelectedPathAndUsesPublicID() async throws {
        var reads = 0
        FixtureProtocol.handler = { request in
            if request.httpMethod == "GET" {
                XCTAssertEqual(request.url?.path, "/rest/app-chat/conversations/chat/sharing")
                XCTAssertEqual(URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems?.first?.value, "leaf")
                reads += 1
                let json = reads == 1 ? #"{"sharing":{"scope":"SHARING_SCOPE_PRIVATE","users":[{"userId":"member"}],"teams":[{"teamId":"team"}],"sharedWithOwnTeam":true}}"# : #"{"sharing":{"scope":"SHARING_SCOPE_PUBLIC","shareLinkId":"internal-id","publicId":"public-id"}}"#
                return (200, Data(json.utf8))
            }
            XCTAssertEqual(request.url?.path, "/rest/app-chat/conversations/chat/share")
            XCTAssertEqual(request.httpMethod, "POST")
            let body = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any]
            XCTAssertEqual(body["responseId"] as? String, "leaf")
            XCTAssertEqual(body["sharePublicly"] as? Bool, true)
            XCTAssertEqual(body["allowIndexing"] as? Bool, false)
            XCTAssertEqual(body["teamMembersToShare"] as? [String], ["member"])
            XCTAssertEqual(body["targetTeamIds"] as? [String], ["team"])
            XCTAssertEqual(body["shareWithTeamMembers"] as? Bool, true)
            return (200, Data(#"{"shareLinkId":"internal-id"}"#.utf8))
        }
        let url = try await service().shareConversation(id: "chat", responseID: "leaf")
        XCTAssertEqual(url.absoluteString, "https://grok.com/share/public-id")
        XCTAssertEqual(reads, 2)
    }

    @MainActor func testShareReusesExistingPublicLinkWithoutPosting() async throws {
        FixtureProtocol.handler = { request in
            XCTAssertEqual(request.httpMethod, "GET")
            return (200, Data(#"{"sharing":{"scope":"SHARING_SCOPE_PUBLIC","publicId":"existing"}}"#.utf8))
        }
        let url = try await service().shareConversation(id: "chat", responseID: "leaf")
        XCTAssertEqual(url.absoluteString, "https://grok.com/share/existing")
    }

    @MainActor func testShareWaitsForMetadataWithoutRepeatingPublication() async throws {
        var reads = 0, publications = 0
        FixtureProtocol.handler = { request in
            if request.httpMethod == "POST" {
                publications += 1
                return (200, Data(#"{"shareLinkId":"internal"}"#.utf8))
            }
            reads += 1
            return (200, Data((reads < 3 ? #"{"sharing":{"scope":"SHARING_SCOPE_PRIVATE"}}"# : #"{"sharing":{"scope":"SHARING_SCOPE_PUBLIC","publicId":"ready"}}"#).utf8))
        }
        let url = try await service().shareConversation(id: "chat", responseID: "leaf")
        XCTAssertEqual(url.absoluteString, "https://grok.com/share/ready")
        XCTAssertEqual(publications, 1)
        XCTAssertEqual(reads, 3)
    }

    @MainActor func testShareCannotGuessURLFromInternalShareLinkID() async throws {
        FixtureProtocol.handler = { _ in (200, Data(#"{"shareLinkId":"internal-only"}"#.utf8)) }
        do {
            _ = try await service().shareConversation(id: "chat", responseID: "leaf")
            XCTFail("Missing public ID must be reported instead of producing a broken link")
        } catch {
            XCTAssertEqual(error as? GrokError, .apiError("Grok did not return a public link. Check access to the chat on grok.com before publishing again."))
        }
    }

    @MainActor func testProfileUsesAuthenticatedNameAndHandlesMissingNames() async throws {
        let fixtures = [
            (#"{"user":{"givenName":"  Test ","familyName":" User ","email":"fixture@example.com"}}"#, "Test User"),
            (#"{"givenName":"","familyName":null,"xUsername":"fixture"}"#, "fixture"),
            (#"{"user":{"email":"fixture@example.com"}}"#, "fixture@example.com")
        ]
        for (json, expected) in fixtures {
            FixtureProtocol.handler = { request in
                XCTAssertEqual(request.url?.path, "/rest/auth/get-user")
                XCTAssertEqual(request.httpMethod, "GET")
                XCTAssertEqual(request.value(forHTTPHeaderField: "Cookie"), "sso=fixture")
                return (200, Data(json.utf8))
            }
            let profile = try await service().profile()
            XCTAssertEqual(profile.name, expected)
        }
    }

    @MainActor func testProfileKeepsAvatarAndRejectsUnsafeURLs() async throws {
        for (image, expected) in [
            ("https://assets.grok.com/avatar.jpg", "https://assets.grok.com/avatar.jpg"),
            ("users/fixture/avatar.jpg", "https://assets.grok.com/users/fixture/avatar.jpg"),
            ("", nil),
            ("/rest/auth/profile-image/avatar", "https://grok.com/rest/auth/profile-image/avatar"),
            ("http://example.com/avatar.jpg", nil),
            ("file:///tmp/avatar.jpg", nil),
            ("https://user:password@example.com/avatar.jpg", nil)
        ] as [(String, String?)] {
            FixtureProtocol.handler = { _ in
                let json: [String: Any] = ["user": ["givenName": "Test", "profileImage": image]]
                return (200, try JSONSerialization.data(withJSONObject: json))
            }
            let profile = try await service().profile()
            XCTAssertEqual(profile.imageURL?.absoluteString, expected)
        }
    }

    @MainActor func testConversationMutationsUsePartialUpdatesAndSoftDelete() async throws {
        var calls = 0
        FixtureProtocol.handler = { request in
            XCTAssertEqual(request.value(forHTTPHeaderField: "Cookie"), "sso=fixture")
            if calls < 2 {
                XCTAssertEqual(request.url?.path, "/rest/app-chat/conversations/chat")
                XCTAssertEqual(request.httpMethod, "PUT")
                let body = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any]
                if calls == 0 {
                    XCTAssertEqual(body["title"] as? String, "Название")
                    XCTAssertNil(body["starred"])
                } else {
                    XCTAssertEqual(body["starred"] as? Bool, true)
                    XCTAssertNil(body["title"])
                }
                XCTAssertEqual(body.count, 1)
            } else {
                XCTAssertEqual(request.url?.path, "/rest/app-chat/conversations/soft/chat")
                XCTAssertEqual(request.httpMethod, "DELETE")
                XCTAssertNil(request.httpBody)
            }
            calls += 1
            return (204, Data())
        }
        let service = try service()
        try await service.renameConversation(id: "chat", title: "Название")
        try await service.pinConversation(id: "chat", pinned: true)
        try await service.deleteConversation(id: "chat")
        XCTAssertEqual(calls, 3)
    }

    @MainActor private func service() throws -> GrokService {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [FixtureProtocol.self]
        return try GrokService(credentials: SessionCredentials(cookies: ["sso": "fixture"], userAgent: "FixtureBrowser/1"), session: URLSession(configuration: config))
    }

    @MainActor func testHistoryUsesActualEndpointCookieAndSearch() async throws {
        FixtureProtocol.handler = { request in
            XCTAssertEqual(request.url?.path, "/rest/app-chat/conversations")
            XCTAssertEqual(request.httpMethod, "GET")
            let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!
            XCTAssertEqual(query.first { $0.name == "pageSize" }?.value, "100")
            XCTAssertEqual(query.first { $0.name == "pageToken" }?.value, "cursor")
            XCTAssertEqual(query.first { $0.name == "searchQuery" }?.value, "кириллица & question?")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Cookie"), "sso=fixture")
            XCTAssertEqual(request.value(forHTTPHeaderField: "User-Agent"), "FixtureBrowser/1")
            XCTAssertNil(request.value(forHTTPHeaderField: "sec-ch-ua"))
            return (200, Data(#"{"conversations":[{"conversationId":"chat","title":"Saved chat"}],"nextPageToken":"next"}"#.utf8))
        }
        let result = try await service().history(pageToken: "cursor", search: "кириллица & question?")
        XCTAssertEqual(result.items.first?.title, "Saved chat")
        XCTAssertEqual(result.nextPageToken, "next")
    }

    @MainActor func testThreadLoadsBodiesInBatchesAndUsesNodeParents() async throws {
        var batchSizes: [Int] = []
        FixtureProtocol.handler = { request in
            if request.url!.path.hasSuffix("response-node") {
                XCTAssertTrue(request.url!.query!.contains("includeThreads=true"))
                let nodes: [[String: Any]] = (0..<101).map { index in
                    var node: [String: Any] = ["responseId": "r\(index)", "sender": "assistant"]
                    if index > 0 { node["parentResponseId"] = "r\(index - 1)" }
                    return node
                }
                return (200, try JSONSerialization.data(withJSONObject: ["responseNodes": nodes]))
            }
            XCTAssertTrue(request.url!.path.hasSuffix("load-responses"))
            let payload = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: [String]]
            let ids = payload["responseIds"]!
            batchSizes.append(ids.count)
            let responses = ids.reversed().map { ["responseId": $0, "message": $0, "sender": "assistant", "createTime": "2026-11-06T00:00:00Z"] }
            return (200, try JSONSerialization.data(withJSONObject: ["responses": responses]))
        }
        let thread = try await service().thread(id: "chat")
        XCTAssertEqual(batchSizes, [100, 1])
        XCTAssertEqual(try thread.path().count, 101)
        XCTAssertEqual(try thread.path().last?.id, "r100")
    }

    @MainActor func testThreadResolvesHiddenSystemRootAndPreservesBranches() async throws {
        var requestedBatches: [[String]] = []
        FixtureProtocol.handler = { request in
            if request.url!.path.hasSuffix("response-node") {
                return (200, Data(#"{"responseNodes":[{"responseId":"user","sender":"human","parentResponseId":"system"},{"responseId":"old","sender":"assistant","parentResponseId":"user"},{"responseId":"new","sender":"assistant","parentResponseId":"user"}]}"#.utf8))
            }
            let payload = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: [String]]
            let ids = payload["responseIds"]!
            requestedBatches.append(ids)
            if ids == ["system"] {
                return (200, Data(#"{"responses":[{"responseId":"system","sender":"system"}]}"#.utf8))
            }
            return (200, Data(#"{"responses":[{"responseId":"new","sender":"assistant","message":"New answer","createTime":"2026-11-06T00:00:03Z","parentResponseId":"user"},{"responseId":"user","sender":"human","message":"Question","createTime":"2026-11-06T00:00:01Z","parentResponseId":"system"},{"responseId":"old","sender":"assistant","message":"Old answer","createTime":"2026-11-06T00:00:02Z","parentResponseId":"user"}]}"#.utf8))
        }
        let thread = try await service().thread(id: "chat")
        XCTAssertEqual(requestedBatches, [["user", "old", "new"], ["system"]])
        XCTAssertEqual(try thread.path().map(\.id), ["user", "new"])
        XCTAssertEqual(try thread.path(to: "old").map(\.id), ["user", "old"])
        XCTAssertEqual(thread.branches.count, 2)
        XCTAssertFalse(thread.responses.contains { $0.id == "system" })
    }

    @MainActor func testThreadOmitsListedSystemRoot() async throws {
        FixtureProtocol.handler = { request in
            if request.url!.path.hasSuffix("response-node") {
                return (200, Data(#"{"responseNodes":[{"responseId":"system","sender":"system"},{"responseId":"user","sender":"human","parentResponseId":"system"}]}"#.utf8))
            }
            return (200, Data(#"{"responses":[{"responseId":"system","sender":"system"},{"responseId":"user","sender":"human","message":"Question","createTime":"2026-11-06T00:00:01Z","parentResponseId":"system"}]}"#.utf8))
        }
        let thread = try await service().thread(id: "chat")
        XCTAssertEqual(try thread.path().map(\.id), ["user"])
        XCTAssertEqual(thread.branches.map(\.id), ["user"])
    }

    @MainActor func testThreadKeepsResponsesWithoutTextAndFallsBackFromEmptyParent() async throws {
        FixtureProtocol.handler = { request in
            if request.url!.path.hasSuffix("response-node") {
                return (200, Data(#"{"responseNodes":[{"responseId":"user","sender":"human"},{"responseId":"answer","sender":"assistant","parentResponseId":"user"}]}"#.utf8))
            }
            return (200, Data(#"{"responses":[{"responseId":"user","sender":"human","message":"Question","createTime":"2026-11-06T00:00:01Z"},{"responseId":"answer","sender":"assistant","parentResponseId":"","message":null,"createTime":null,"streamErrors":[{"message":"Model unavailable"}]}]}"#.utf8))
        }
        let thread = try await service().thread(id: "chat")
        let path = try thread.path()
        XCTAssertEqual(path.map(\.id), ["user", "answer"])
        XCTAssertEqual(path.last?.text, "")
        XCTAssertNil(path.last?.createdAt)
    }

    @MainActor func testThreadRejectsUnresolvedOrNonSystemParents() async throws {
        for parent in [#"[]"#, #"[{"responseId":"missing","sender":"human","message":"Earlier question","createTime":"2026-11-06T00:00:00Z"}]"#, #"[{"responseId":"missing","sender":"system","parentResponseId":"another","message":"","createTime":""}]"#] {
            FixtureProtocol.handler = { request in
                if request.url!.path.hasSuffix("response-node") {
                    return (200, Data(#"{"responseNodes":[{"responseId":"user","sender":"human","parentResponseId":"missing"}]}"#.utf8))
                }
                let payload = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: [String]]
                if payload["responseIds"] == ["missing"] {
                    return (200, Data("{\"responses\":\(parent)}".utf8))
                }
                return (200, Data(#"{"responses":[{"responseId":"user","sender":"human","message":"Question","createTime":"2026-11-06T00:00:01Z"}]}"#.utf8))
            }
            do {
                _ = try await service().thread(id: "chat")
                XCTFail("Must reject an unverified parent")
            } catch {
                XCTAssertEqual(error as? ClientFailure, .invalidThread)
            }
        }
    }

    @MainActor func testThreadRejectsMissingVisibleResponses() async throws {
        FixtureProtocol.handler = { request in
            if request.url!.path.hasSuffix("response-node") {
                return (200, Data(#"{"responseNodes":[{"responseId":"user","sender":"human"},{"responseId":"answer","sender":"assistant","parentResponseId":"user"}]}"#.utf8))
            }
            return (200, Data(#"{"responses":[{"responseId":"user","sender":"human","message":"Question","createTime":"2026-11-06T00:00:01Z"}]}"#.utf8))
        }
        do {
            _ = try await service().thread(id: "chat")
            XCTFail("Must reject a missing message body")
        } catch {
            XCTAssertEqual(error as? ClientFailure, .invalidThread)
        }
    }

    @MainActor func testThreadResolvesLegacyAssetIDsAndRemovesDuplicateImageCards() async throws {
        let assetID = "00000000-0000-0000-0000-000000000001"
        var assetLoads = 0
        FixtureProtocol.handler = { request in
            if request.url!.path.hasSuffix("response-node") {
                return (200, Data(#"{"responseNodes":[{"responseId":"answer","sender":"assistant"}]}"#.utf8))
            }
            if request.url!.path == "/rest/assets/\(assetID)" {
                assetLoads += 1
                XCTAssertEqual(request.httpMethod, "GET")
                XCTAssertEqual(request.value(forHTTPHeaderField: "Cookie"), "sso=fixture")
                return (200, Data(#"{"key":"users/user/generated/image.jpg","name":"image.jpg","mimeType":"image/jpeg"}"#.utf8))
            }
            return (200, Data("{\"responses\":[{\"responseId\":\"answer\",\"sender\":\"assistant\",\"generatedImageUrls\":[\"https://assets.grok.com/users/user/generated/image.jpg\"],\"fileAttachments\":[\"\(assetID)\"]}]}".utf8))
        }
        let thread = try await service().thread(id: "chat")
        XCTAssertEqual(assetLoads, 1)
        XCTAssertEqual(thread.responses[0].attachments.count, 1)
        XCTAssertEqual(thread.responses[0].attachments[0].kind, .image)
        XCTAssertTrue(thread.responses[0].attachments[0].isGenerated)
    }

    @MainActor func testReplyUsesExistingConversationAndParent() async throws {
        FixtureProtocol.handler = { request in
            XCTAssertEqual(request.url?.path, "/rest/app-chat/conversations/chat/responses")
            let body = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any]
            XCTAssertEqual(body["parentResponseId"] as? String, "leaf")
            XCTAssertEqual(body["message"] as? String, "Continue")
            XCTAssertEqual(body["modeId"] as? String, "fast")
            XCTAssertEqual(body["temporary"] as? Bool, false)
            return (200, Data("{\"result\":{\"response\":{\"modelResponse\":{\"message\":\"Answer\",\"responseId\":\"answer\"}}}}\n".utf8))
        }
        let stream = try await service().reply(conversationID: "chat", parentID: "leaf", text: "Continue", modeID: "fast")
        var events: [ReplyEvent] = []
        for try await event in stream { events.append(event) }
        XCTAssertEqual(events.last?.text, "Answer")
        XCTAssertEqual(events.last?.conversationID, "chat")
        XCTAssertEqual(events.last?.responseID, "answer")
        XCTAssertEqual(events.last?.isFinal, true)
    }

    @MainActor func test401And403AreNotDecodedAsEmptyHistory() async throws {
        FixtureProtocol.handler = { _ in (401, Data("{}".utf8)) }
        do { _ = try await service().history(pageToken: nil, search: ""); XCTFail("Must reject unauthorized") }
        catch { XCTAssertTrue(DisplayError(error).needsLogin) }
        FixtureProtocol.handler = { _ in (403, Data("<html>Cloudflare challenge</html>".utf8)) }
        do { _ = try await service().history(pageToken: nil, search: ""); XCTFail("Must reject challenge") }
        catch {
            guard case GrokError.antiBotRejected = error else { return XCTFail("Expected browser verification, got \(error)") }
            XCTAssertFalse(DisplayError(error).needsLogin)
        }
    }
}
