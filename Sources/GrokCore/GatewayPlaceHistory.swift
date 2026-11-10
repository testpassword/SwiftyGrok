import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

@MainActor public protocol PlaceHistoryLoading: AnyObject {
    func load(conversationID: String, responseIDs: [String]) async throws -> [String: PlaceResponseContent]
}

@MainActor protocol PlaceHistorySocket: AnyObject {
    func send(_ data: Data) async throws
    func receive() async throws -> Data
    func close()
}

/// Supplemental read-only history. Generation, queue changes, and model updates
/// stay on the existing transport; this connection can only load known responses.
@MainActor public final class GatewayPlaceHistory: PlaceHistoryLoading {
    private let credentials: SessionCredentials
    private let factory: (URLRequest) -> any PlaceHistorySocket
    private let timeout: TimeInterval

    public convenience init(credentials: SessionCredentials) {
        self.init(credentials: credentials, timeout: 8, factory: { NativePlaceHistorySocket(request: $0) })
    }

    init(credentials: SessionCredentials, timeout: TimeInterval,
         factory: @escaping (URLRequest) -> any PlaceHistorySocket) {
        self.credentials = credentials; self.timeout = timeout; self.factory = factory
    }

    static func sessionEvent(conversationID: String) -> [String: Any] {
        ["type": "session.create", "event_id": "evt_places_" + UUID().uuidString,
         "session": ["model": "auto", "x_grok": [
            "protocol_capabilities": ["conversation_attached", "custom_methods_v1"],
            "conversation_id": conversationID, "load_existing": true, "needs_history": false,
            "use_chunk": true, "accept_interleaved_phases": true
         ]]]
    }

    public func load(conversationID: String, responseIDs: [String]) async throws -> [String: PlaceResponseContent] {
        guard !conversationID.isEmpty, !responseIDs.isEmpty else { return [:] }
        let requested = Set(responseIDs)
        let end = Date().addingTimeInterval(timeout)
        for attempt in 0..<3 {
            try Task.checkCancellation()
            let remaining = end.timeIntervalSinceNow
            guard remaining > 0 else { throw URLError(.timedOut) }
            var url = URLComponents(string: "wss://grok.com/ws/mgw/")!
            if let uid = credentials.cookies["x-userid"] ?? credentials.cookies["uid"] {
                url.queryItems = [URLQueryItem(name: "uid", value: uid)]
            }
            var request = URLRequest(url: url.url!)
            request.setValue(credentials.userAgent, forHTTPHeaderField: "User-Agent")
            request.setValue("https://grok.com", forHTTPHeaderField: "Origin")
            request.setValue(credentials.cookies.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: "; "), forHTTPHeaderField: "Cookie")
            let socket = factory(request)
            let timer = Task { @MainActor in
                try? await Task.sleep(nanoseconds: UInt64(remaining * 1_000_000_000))
                if !Task.isCancelled { socket.close() }
            }
            defer { timer.cancel(); socket.close() }
            do {
                return try await withTaskCancellationHandler {
                    try await read(socket, conversationID: conversationID, requested: requested)
                } onCancel: { Task { @MainActor in socket.close() } }
            } catch GatewayHistoryError.moved where attempt < 2 { continue }
        }
        throw URLError(.badServerResponse)
    }

    private func read(_ socket: any PlaceHistorySocket, conversationID: String,
                      requested: Set<String>) async throws -> [String: PlaceResponseContent] {
        func send(_ event: [String: Any]) async throws {
            try Task.checkCancellation()
            try await socket.send(JSONSerialization.data(withJSONObject: ["session_id": conversationID, "event": event]))
        }
        try await send(Self.sessionEvent(conversationID: conversationID))
        var created = false, attached = false, sentLoads = false
        var pending: [String: String] = [:]
        var result: [String: PlaceResponseContent] = [:]
        var bytes = 0
        for _ in 0..<2_000 {
            try Task.checkCancellation()
            let data = try await socket.receive()
            bytes += data.count
            guard bytes <= 32 * 1024 * 1024,
                  let envelope = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let event = envelope["event"] as? [String: Any] else { throw URLError(.cannotParseResponse) }
            let type = event["type"] as? String ?? ""
            if type == "session.moved" { throw GatewayHistoryError.moved }
            // Live updates from other conversations on a shared account are never consumed.
            if let id = envelope["session_id"] as? String, id != conversationID { continue }
            switch type {
            case "session.created": created = true
            case "conversation.attached":
                guard PlaceJSON.object(event, "conversation")["id"] as? String == conversationID else { throw URLError(.badServerResponse) }
                attached = true
            case "error", "session.ended": throw URLError(.badServerResponse)
            case "conversation.history.item":
                guard let load = event["load_id"] as? String, let expected = pending[load],
                      let item = event["item"] as? [String: Any], item["id"] as? String == expected else { continue }
                let grok = PlaceJSON.object(item, "x_grok")
                guard let chunks = grok["output_chunks"] as? [[String: Any]] else { throw URLError(.cannotParseResponse) }
                result[expected] = PlaceResponseContent(chunks: chunks)
            case "conversation.history.done":
                guard let load = event["load_id"] as? String, let expected = pending[load] else { continue }
                guard event["errored"] as? Bool != true, result[expected] != nil else { throw URLError(.cannotParseResponse) }
                pending.removeValue(forKey: load)
                if sentLoads && pending.isEmpty { return result }
            default: break
            }
            if created && attached && !sentLoads {
                sentLoads = true
                for id in requested.sorted() {
                    let load = UUID().uuidString
                    pending[load] = id
                    try await send(["type": "conversation.history.load", "event_id": "evt_places_" + load,
                                    "load_id": load, "leaf_id": id, "limit": 1])
                }
            }
        }
        throw URLError(.dataLengthExceedsMaximum)
    }
}

private enum GatewayHistoryError: Error { case moved }

@MainActor private final class NativePlaceHistorySocket: PlaceHistorySocket {
    private let session: URLSession
    private let task: URLSessionWebSocketTask

    init(request: URLRequest) {
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil; config.httpShouldSetCookies = false; config.urlCache = nil
        config.timeoutIntervalForRequest = 8
        session = URLSession(configuration: config, delegate: PlaceSocketRedirectDelegate(), delegateQueue: nil)
        task = session.webSocketTask(with: request)
        task.maximumMessageSize = 8 * 1024 * 1024
        task.resume()
    }
    func send(_ data: Data) async throws { try await task.send(.string(String(decoding: data, as: UTF8.self))) }
    func receive() async throws -> Data {
        switch try await task.receive() {
        case .data(let data): return data
        case .string(let text): return Data(text.utf8)
        @unknown default: throw URLError(.cannotParseResponse)
        }
    }
    func close() { task.cancel(with: .normalClosure, reason: nil); session.invalidateAndCancel() }
}

private final class PlaceSocketRedirectDelegate: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
