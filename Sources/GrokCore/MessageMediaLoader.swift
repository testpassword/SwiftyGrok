import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public final class MessageMediaLoader: @unchecked Sendable {
    private let credentials: SessionCredentials
    private let session: URLSession

    public init(credentials: SessionCredentials) {
        self.credentials = credentials
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false
        config.urlCache = nil
        config.timeoutIntervalForRequest = 45
        session = URLSession(configuration: config, delegate: MediaRedirectDelegate(), delegateQueue: nil)
    }

    deinit { session.invalidateAndCancel() }

    public func request(for url: URL) throws -> URLRequest {
        guard GrokMessageContent.url(url.absoluteString) != nil else { throw URLError(.unsupportedURL) }
        var request = URLRequest(url: url)
        request.httpShouldHandleCookies = false
        request.setValue(credentials.userAgent, forHTTPHeaderField: "User-Agent")
        if ["grok.com", "assets.grok.com"].contains(url.host?.lowercased() ?? ""), url.scheme == "https" {
            request.setValue(credentials.cookies.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: "; "), forHTTPHeaderField: "Cookie")
        }
        return request
    }

    public func data(for url: URL) async throws -> Data {
        let (data, response) = try await session.data(for: request(for: url))
        guard let response = response as? HTTPURLResponse, (200..<300).contains(response.statusCode) else { throw URLError(.badServerResponse) }
        guard data.count <= 25 * 1024 * 1024 else { throw URLError(.dataLengthExceedsMaximum) }
        return data
    }

    public static func redirect(_ request: URLRequest, from url: URL?) -> URLRequest {
        var request = request
        request.httpShouldHandleCookies = false
        if request.url?.host?.lowercased() != url?.host?.lowercased() || request.url?.scheme != "https" {
            request.setValue(nil, forHTTPHeaderField: "Cookie")
            request.setValue(nil, forHTTPHeaderField: "Authorization")
        }
        return request
    }
}

private final class MediaRedirectDelegate: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(MessageMediaLoader.redirect(request, from: response.url))
    }
}
