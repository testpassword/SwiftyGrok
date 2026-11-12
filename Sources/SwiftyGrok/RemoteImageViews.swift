import AppKit
import SwiftUI
import Observation
import GrokCore

@MainActor struct AccountAvatar: View {
    let url: URL?
    let media: MessageMediaLoader?
    var size: CGFloat = 32
    @State private var image: NSImage?

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image).renderingMode(.original).resizable().scaledToFill()
            } else {
                Image(appSymbol: "person.fill").font(.system(size: 16))
                    .foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(.quaternary)
            }
        }
        .frame(width: size, height: size).clipShape(Circle())
        .overlay(Circle().strokeBorder(.primary.opacity(0.1)))
        .task(id: url) {
            image = nil
            guard let url, let media else { return }
            if let data = try? await media.data(for: url), !Task.isCancelled { image = NSImage(data: data) }
        }
    }
}

@MainActor struct SiteIcon: View {
    let url: URL
    var size: CGFloat = 16
    @State private var icons = SiteIconStore.shared

    var body: some View {
        Group {
            if let image = icons.image(for: url) {
                Image(nsImage: image).resizable().scaledToFit()
            } else {
                Image(appSymbol: "globe").foregroundStyle(.secondary)
            }
        }
        .frame(width: size, height: size).clipShape(RoundedRectangle(cornerRadius: 3))
        .accessibilityHidden(true)
        .task(id: url) { await icons.load(url) }
    }
}

/// Fetch site artwork directly, using only the origin (never a chat URL's query
/// or private path). This session has no Grok credentials or cookie storage.
@MainActor @Observable final class SiteIconStore {
    static let shared = SiteIconStore()
    private var images: [URL: NSImage] = [:]
    @ObservationIgnored private var pending: [URL: Task<NSImage?, Never>] = [:]
    @ObservationIgnored private var attempted = Set<URL>()
    @ObservationIgnored private let session: URLSession

    private init() {
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false
        config.timeoutIntervalForRequest = 10
        config.timeoutIntervalForResource = 20
        session = URLSession(configuration: config)
    }

    private func origin(_ url: URL) -> URL? {
        guard ["https", "http"].contains(url.scheme?.lowercased() ?? ""), let host = url.host, !host.isEmpty else { return nil }
        var components = URLComponents()
        components.scheme = "https"
        components.host = host
        components.port = url.port
        components.path = "/"
        return components.url
    }

    func image(for url: URL) -> NSImage? { origin(url).flatMap { images[$0] } }

    func load(_ url: URL) async {
        guard let origin = origin(url), images[origin] == nil else { return }
        if let task = pending[origin] {
            if let image = await task.value { images[origin] = image }
            return
        }
        guard attempted.insert(origin).inserted else { return }
        let task = Task { await fetch(origin) }
        pending[origin] = task
        if let image = await task.value { images[origin] = image }
        pending[origin] = nil
    }

    private func fetch(_ origin: URL) async -> NSImage? {
        if let image = await fetchImage(origin.appendingPathComponent("favicon.ico")) { return image }
        guard let data = await data(origin, limit: 1024 * 1024), let html = String(data: data, encoding: .utf8),
              let tags = try? NSRegularExpression(pattern: "<link\\b[^>]*>", options: .caseInsensitive) else { return nil }
        let source = html as NSString
        for tag in tags.matches(in: html, range: NSRange(location: 0, length: source.length)) {
            let value = source.substring(with: tag.range)
            guard let rel = attribute("rel", in: value), rel.lowercased().split(separator: " ").contains(where: { $0 == "icon" || $0 == "apple-touch-icon" }),
                  let href = attribute("href", in: value), let url = URL(string: href.replacingOccurrences(of: "&amp;", with: "&"), relativeTo: origin)?.absoluteURL,
                  url.scheme == "https", url.user == nil, url.password == nil else { continue }
            if let image = await fetchImage(url) { return image }
        }
        return nil
    }

    private func attribute(_ name: String, in tag: String) -> String? {
        let pattern = "\\b" + name + "\\s*=\\s*(?:\"([^\"]*)\"|'([^']*)'|([^\\s>]+))"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
              let match = regex.firstMatch(in: tag, range: NSRange(location: 0, length: (tag as NSString).length)) else { return nil }
        for index in 1..<match.numberOfRanges where match.range(at: index).location != NSNotFound {
            return (tag as NSString).substring(with: match.range(at: index))
        }
        return nil
    }

    private func fetchImage(_ url: URL) async -> NSImage? {
        guard let data = await data(url, limit: 2 * 1024 * 1024), let image = NSImage(data: data), image.isValid else { return nil }
        return NSImage(size: NSSize(width: 16, height: 16), flipped: false) { rect in
            image.draw(in: rect)
            return true
        }
    }

    private func data(_ url: URL, limit: Int) async -> Data? {
        var request = URLRequest(url: url)
        request.httpShouldHandleCookies = false
        guard let (data, response) = try? await session.data(for: request), let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode), data.count <= limit else { return nil }
        return data
    }
}
