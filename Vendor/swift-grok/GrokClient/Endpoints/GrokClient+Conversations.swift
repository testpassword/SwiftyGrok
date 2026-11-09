import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// MARK: - GrokClient Conversations
extension GrokClient {
    public struct SharedConversation: Decodable {
        public let conversation: Conversation
        public let responses: [Response]?
        public let isPublic: Bool?
    }

    public func sharedConversation(shareLinkId: String) async throws -> SharedConversation {
        try await decodeJSON(path: endpointPath(["share_links_data", shareLinkId], queryItems: []), method: "GET")
    }

    /// Creates a conversation owned by the signed-in account. Never call this
    /// just to preview a link or automatically retry a successful creation.
    public func cloneSharedConversation(shareLinkId: String) async throws -> Conversation {
        let result: SharedConversation = try await decodeJSON(
            path: endpointPath(["share_links", shareLinkId, "clone"], queryItems: []), payload: [:])
        return result.conversation
    }

    /// Resolve legacy attachment IDs to their asset path and media metadata.
    public func assetMetadata(id: String) async throws -> [String: AnyCodable] {
        let path = try endpointPath(["assets", id], queryItems: [])
        let json = try await sendJSON(path: path, method: "GET", namespace: .root)
        guard let object = json as? [String: Any] else { throw GrokError.apiError("Invalid asset metadata") }
        return object.mapValues(AnyCodable.init)
    }

    /// GrokMac: retain the server cursor instead of discarding it in listConversations.
    public func listConversationPage(pageSize: Int = 100, pageToken: String? = nil, searchQuery: String? = nil, workspaceId: String? = nil, excludeProjects: Bool? = nil) async throws -> ConversationsResponse {
        var items = [URLQueryItem(name: "pageSize", value: String(pageSize))]
        if let excludeProjects { items.append(URLQueryItem(name: "excludeProjects", value: String(excludeProjects))) }
        if let workspaceId, !workspaceId.isEmpty { items.append(URLQueryItem(name: "workspaceId", value: workspaceId)) }
        if let pageToken, !pageToken.isEmpty { items.append(URLQueryItem(name: "pageToken", value: pageToken)) }
        if let query = searchQuery?.trimmingCharacters(in: .whitespacesAndNewlines), !query.isEmpty {
            items.append(URLQueryItem(name: "searchQuery", value: query))
        }
        let path = try endpointPath(["conversations"], queryItems: items)
        let request = try makeRequest(path: path, method: "GET")
        let (data, response) = try await session.data(for: request)
        try validateHTTPResponse(response, data: data)
        let decoder = JSONDecoder()
        if let wrapped = try? decoder.decode(ConversationsResponse.self, from: data) { return wrapped }
        return ConversationsResponse(conversations: try decoder.decode([Conversation].self, from: data))
    }

    /// Fetch a list of past conversations
    /// - Parameters:
    ///   - pageSize: The number of conversations to fetch (default 100)
    ///   - searchQuery: Optional query to search saved conversation threads.
    /// - Returns: An array of Conversation objects
    /// - Throws: Network, decoding, or API errors
    public func listConversations(pageSize: Int = 100, searchQuery: String? = nil) async throws -> [Conversation] {
        var queryItems = [
            URLQueryItem(name: "pageSize", value: String(pageSize))
        ]
        if let searchQuery = searchQuery?.trimmingCharacters(in: .whitespacesAndNewlines),
           !searchQuery.isEmpty {
            queryItems.append(URLQueryItem(name: "searchQuery", value: searchQuery))
        }

        let path = try endpointPath(["conversations"], queryItems: queryItems)
        let request = try makeRequest(path: path, method: "GET")

        if isDebug {
            print("Debug URL: \(request.url?.absoluteString ?? "")")
        }

        let (data, response) = try await session.data(for: request)
        try validateHTTPResponse(response, data: data)

        if isDebug {
            if let jsonString = String(data: data, encoding: .utf8) {
                print("Debug: Raw JSON response:")
                print(jsonString)
                if let jsonDict = try? JSONSerialization.jsonObject(with: data, options: []) {
                    print("Debug: JSON as Dictionary/Array:")
                    print(jsonDict)
                }
            }
        }

        let decoder = JSONDecoder()
        do {
            // new API format
            let conversationsResponse = try decoder.decode(ConversationsResponse.self, from: data)
            return conversationsResponse.conversations
        } catch {
            // old API format
            return try decoder.decode([Conversation].self, from: data)
        }
    }

    public func softDeleteConversation(conversationId: String) async throws {
        let path = try endpointPath(["conversations", "soft", conversationId], queryItems: [])
        try await sendVoid(path: path, method: "DELETE")
    }

    /// Publish the selected response path while preserving existing team access.
    /// The creation response's shareLinkId is the public route token used by the
    /// web client. Existing sharing metadata exposes that route as publicId.
    public func publicConversationURL(conversationId: String, responseId: String) async throws -> URL {
        let sharingPath = try endpointPath(["conversations", conversationId, "sharing"],
                                          queryItems: [URLQueryItem(name: "responseId", value: responseId)])
        func sharing() async throws -> [String: Any] {
            let json = try await sendJSON(path: sharingPath, method: "GET") as? [String: Any]
            return json?["sharing"] as? [String: Any] ?? [:]
        }
        func routeURL(for id: String?) -> URL? {
            guard let id = id?.trimmingCharacters(in: .whitespacesAndNewlines), !id.isEmpty else { return nil }
            var allowed = CharacterSet.urlPathAllowed
            allowed.remove(charactersIn: "/?#%")
            guard let encoded = id.addingPercentEncoding(withAllowedCharacters: allowed) else { return nil }
            return URL(string: "https://grok.com/share/\(encoded)")
        }
        func publicURL(_ object: [String: Any]) -> URL? {
            guard object["scope"] as? String == "SHARING_SCOPE_PUBLIC" else { return nil }
            return routeURL(for: object["publicId"] as? String)
        }
        let current = try await sharing()
        if let url = publicURL(current) { return url }
        let path = try endpointPath(["conversations", conversationId, "share"], queryItems: [])
        let payload: [String: Any] = [
            "responseId": responseId, "sharePublicly": true, "allowIndexing": false,
            "teamMembersToShare": (current["users"] as? [[String: Any]] ?? []).compactMap { $0["userId"] as? String },
            "targetTeamIds": (current["teams"] as? [[String: Any]] ?? []).compactMap { $0["teamId"] as? String },
            "shareWithTeamMembers": current["sharedWithOwnTeam"] as? Bool ?? false,
            "shareWithOrg": current["scope"] as? String == "SHARING_SCOPE_ORGANIZATION"
        ]
        let published = try await sendJSON(path: path, payload: payload) as? [String: Any]
        try Task.checkCancellation()
        if let url = routeURL(for: published?["shareLinkId"] as? String) { return url }
        // Sharing metadata can lag behind the successful POST. Retry reads only;
        // repeating the publication request could create another public link.
        for attempt in 0..<3 {
            if let url = publicURL(try await sharing()) { return url }
            if attempt < 2 { try await Task.sleep(nanoseconds: 200_000_000) }
        }
        throw GrokError.apiError("Grok did not return a public link. Check access to the chat on grok.com before publishing again.")
    }

    /// PUT accepts partial updates; omit unchanged fields to preserve server state.
    public func updateConversation(conversationId: String, title: String? = nil, starred: Bool? = nil) async throws {
        var payload: [String: Any] = [:]
        if let title { payload["title"] = title }
        if let starred { payload["starred"] = starred }
        guard !payload.isEmpty else { return }
        let path = try endpointPath(["conversations", conversationId], queryItems: [])
        try await sendVoid(path: path, method: "PUT", payload: payload)
    }

    /// Get the response nodes for a conversation
    public func getResponseNodes(conversationId: String, includeThreads: Bool = false) async throws -> [ResponseNode] {
        let queryItems = includeThreads
            ? [URLQueryItem(name: "includeThreads", value: "true")]
            : []
        let path = try endpointPath(["conversations", conversationId, "response-node"], queryItems: queryItems)
        let request = try makeRequest(path: path, method: "GET")

        if isDebug {
            print("Debug URL: \(request.url?.absoluteString ?? "")")
        }

        let (data, response) = try await session.data(for: request)
        try validateHTTPResponse(response, data: data)

        if isDebug {
            if let jsonString = String(data: data, encoding: .utf8) {
                print("Debug: Response JSON from response-node:")
                print(jsonString)
            }
        }

        let decoder = JSONDecoder()
        do {
            // common wrapper keys
            struct ResponseNodesWrapper: Codable {
                let responseNodes: [ResponseNode]
            }
            struct NodesWrapper: Codable {
                let nodes: [ResponseNode]
            }
            struct ResponsesWrapper: Codable {
                let responses: [ResponseNode]
            }

            do {
                let wrapper = try decoder.decode(ResponseNodesWrapper.self, from: data)
                return wrapper.responseNodes
            } catch {
                do {
                    let wrapper = try decoder.decode(NodesWrapper.self, from: data)
                    return wrapper.nodes
                } catch {
                    do {
                        let wrapper = try decoder.decode(ResponsesWrapper.self, from: data)
                        return wrapper.responses
                    } catch {
                        if let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] {
                            for (_, value) in json {
                                if let nodesArray = value as? [[String: Any]] {
                                    var nodes = [ResponseNode]()
                                    for nodeDict in nodesArray {
                                        if let responseId = nodeDict["responseId"] as? String,
                                           let sender = nodeDict["sender"] as? String {
                                            let parentResponseId = nodeDict["parentResponseId"] as? String
                                            nodes.append(ResponseNode(
                                                responseId: responseId,
                                                sender: sender,
                                                parentResponseId: parentResponseId
                                            ))
                                        }
                                    }
                                    if !nodes.isEmpty {
                                        return nodes
                                    }
                                }
                            }
                        }
                        // fallback
                        return try decoder.decode([ResponseNode].self, from: data)
                    }
                }
            }
        } catch {
            throw GrokError.decodingError(error)
        }
    }

    /// Load the detailed responses for a conversation
    /// - Parameter conversationId: The ID of the conversation
    /// - Parameter specificResponseIds: Optional array of specific response IDs to load, if nil will fetch all
    /// - Returns: An array of Response objects
    /// - Throws: Network, decoding, or API errors
    public func loadResponses(conversationId: String, specificResponseIds: [String]? = nil) async throws -> [Response] {
        var responseIds: [String] = []

        if let specificIds = specificResponseIds, !specificIds.isEmpty {
            responseIds = specificIds
        } else {
            do {
                let responseNodes = try await getResponseNodes(conversationId: conversationId)
                responseIds = responseNodes.map { $0.responseId }
                if isDebug {
                    print("Debug: Found \(responseIds.count) response IDs for this conversation")
                }
            } catch {
                if isDebug {
                    print("Debug: Failed to get response nodes: \(error)")
                }
            }
        }

        var requestBody: [String: Any] = [:]
        if !responseIds.isEmpty {
            requestBody["responseIds"] = responseIds
        }

        let path = try endpointPath(["conversations", conversationId, "load-responses"], queryItems: [])
        let request = try makeRequest(path: path, payload: requestBody)

        if isDebug {
            print("Debug URL: \(request.url?.absoluteString ?? "")")
        }

        let (data, response) = try await session.data(for: request)
        try validateHTTPResponse(response, data: data)

        if isDebug {
            if let jsonString = String(data: data, encoding: .utf8) {
                print("Debug: Response JSON:")
                print(jsonString)
            }
        }

        let decoder = JSONDecoder()
        struct ResponsesWrapper: Codable {
            let responses: [Response]
        }

        do {
            let wrapper = try decoder.decode(ResponsesWrapper.self, from: data)
            return wrapper.responses
        } catch {
            do {
                return try decoder.decode([Response].self, from: data)
            } catch {
                if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let responsesArray = json["responses"] as? [[String: Any]] {
                    var responses: [Response] = []
                    for item in responsesArray {
                        if let responseId = item["responseId"] as? String,
                           let message = item["message"] as? String,
                           let sender = item["sender"] as? String,
                           let createTime = item["createTime"] as? String {
                            let parentResponseId = item["parentResponseId"] as? String
                            responses.append(Response(
                                responseId: responseId,
                                message: message,
                                sender: sender,
                                createTime: createTime,
                                parentResponseId: parentResponseId
                            ))
                        }
                    }
                    if !responses.isEmpty {
                        return responses
                    }
                }
                throw GrokError.decodingError(error)
            }
        }
    }

    public func getConversationV2(
        conversationId: String,
        includeWorkspaces: Bool = true,
        includeTaskResult: Bool = true
    ) async throws -> GrokConversationV2Response {
        let path = try endpointPath(
            ["conversations_v2", conversationId],
            queryItems: [
                URLQueryItem(name: "includeWorkspaces", value: String(includeWorkspaces)),
                URLQueryItem(name: "includeTaskResult", value: String(includeTaskResult))
            ]
        )
        let request = try makeRequest(path: path, method: "GET")
        let json = try await jsonObject(for: request)

        return makeConversationsEndpointConversationV2Response(from: json)
    }

    private func makeConversationsEndpointConversationV2Response(from json: Any) -> GrokConversationV2Response {
        let conversation = conversationsEndpointFirstDictionary(from: json, preferredKeys: ["conversation", "data", "result"])
        let conversationId = conversationsEndpointStringValue(conversation, keys: ["conversationId", "conversation_id", "id"])
        return GrokConversationV2Response(conversationId: conversationId, rawJSON: AnyCodable(json))
    }

    private func conversationsEndpointFirstDictionary(
        from json: Any,
        preferredKeys: [String]
    ) -> [String: Any]? {
        if let dictionary = json as? [String: Any] {
            for key in preferredKeys {
                if let nested = dictionary[key] as? [String: Any] {
                    return nested
                }
                if let nested = dictionary[key] as? [String: AnyCodable] {
                    return nested.mapValues(\.value)
                }
            }
            return dictionary
        }

        if let dictionary = json as? [String: AnyCodable] {
            for key in preferredKeys {
                if let nested = dictionary[key]?.value as? [String: Any] {
                    return nested
                }
                if let nested = dictionary[key]?.value as? [String: AnyCodable] {
                    return nested.mapValues(\.value)
                }
            }
            return dictionary.mapValues(\.value)
        }

        return nil
    }

    private func conversationsEndpointStringValue(
        _ dictionary: [String: Any]?,
        keys: [String]
    ) -> String? {
        guard let dictionary else {
            return nil
        }

        for key in keys {
            if let value = dictionary[key] as? String, !value.isEmpty {
                return value
            }
            if let value = dictionary[key] as? CustomStringConvertible {
                let string = value.description
                if !string.isEmpty {
                    return string
                }
            }
        }

        return nil
    }
}
