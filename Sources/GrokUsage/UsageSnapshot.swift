import Foundation

public enum UsageProduct: String, Codable, Sendable { case chat, build }
public enum UsageStatus: String, Codable, Sendable {
    case available, signIn, buildLogin, ambiguousBuildAccount, unavailable
}

public struct UsageWindow: Codable, Sendable, Identifiable {
    public let id: String
    public var remaining: Int?
    public var total: Int?
    public var usedPercent: Double?
    public var resetAt: Date?
    public var period: String?

    public init(id: String, remaining: Int? = nil, total: Int? = nil, usedPercent: Double? = nil,
                resetAt: Date? = nil, period: String? = nil) {
        self.id = id; self.remaining = remaining; self.total = total
        self.usedPercent = usedPercent; self.resetAt = resetAt; self.period = period
    }

    public var remainingPercent: Double? {
        if let usedPercent, usedPercent.isFinite, (0...100).contains(usedPercent) { return 100 - usedPercent }
        if let remaining, let total, total > 0, remaining >= 0, remaining <= total {
            return Double(remaining) / Double(total) * 100
        }
        return nil
    }

    public func hasReset(at date: Date) -> Bool { resetAt.map { $0 <= date } ?? false }
}

public struct ProductUsage: Codable, Sendable, Identifiable {
    public let id: String
    public let percent: Double
}

/// Display data only. Never include cookies, tokens, account IDs or raw responses.
public struct UsageSnapshot: Codable, Sendable {
    public let product: UsageProduct
    public var status: UsageStatus
    public var fetchedAt: Date?
    public var windows: [UsageWindow]
    public var prepaidCents: Int64?
    public var products: [ProductUsage]

    public init(product: UsageProduct, status: UsageStatus, fetchedAt: Date? = nil,
                windows: [UsageWindow] = [], prepaidCents: Int64? = nil, products: [ProductUsage] = []) {
        self.product = product; self.status = status; self.fetchedAt = fetchedAt
        self.windows = windows; self.prepaidCents = prepaidCents; self.products = products
    }

    public func isStale(at date: Date) -> Bool {
        guard let fetchedAt else { return true }
        return date.timeIntervalSince(fetchedAt) > 900 || fetchedAt.timeIntervalSince(date) > 60 || status != .available
            || windows.contains(where: { $0.hasReset(at: date) })
    }
}

public struct UsageSnapshots: Codable, Sendable {
    public let schemaVersion: Int
    public var chat: UsageSnapshot
    public var build: UsageSnapshot

    public init(chat: UsageSnapshot = .init(product: .chat, status: .signIn),
                build: UsageSnapshot = .init(product: .build, status: .buildLogin)) {
        schemaVersion = 1; self.chat = chat; self.build = build
    }

    public subscript(_ product: UsageProduct) -> UsageSnapshot {
        product == .chat ? chat : build
    }
}

public enum UsageSnapshotStore {
    public static let extensionIdentifier = "app.swiftygrok.native.widgets"
    public static let refreshURL = URL(string: "swiftygrok://widgets/refresh")!

    public static func fileURL(applicationSupport: URL) -> URL {
        applicationSupport.appendingPathComponent("SwiftyGrok", isDirectory: true).appendingPathComponent("usage.json")
    }

    public static func read(from url: URL) -> UsageSnapshots? {
        guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= 262_144,
              let data = try? Data(contentsOf: url), let value = try? JSONDecoder().decode(UsageSnapshots.self, from: data),
              value.schemaVersion == 1, value.chat.product == .chat, value.build.product == .build else { return nil }
        return value
    }

    public static func write(_ value: UsageSnapshots, to url: URL) throws {
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        try JSONEncoder().encode(value).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}

public enum UsageText {
    public static func text(_ key: String) -> String { NSLocalizedString(key, bundle: .module, comment: "") }
    public static func format(_ key: String, _ arguments: CVarArg...) -> String {
        String(format: text(key), locale: .current, arguments: arguments)
    }
    public static func status(_ status: UsageStatus) -> String {
        switch status {
        case .available: return text("Up to date")
        case .signIn: return text("Sign in to Grok in SwiftyGrok.")
        case .buildLogin: return text("Run grok login to connect Grok Build.")
        case .ambiguousBuildAccount: return text("Multiple Grok Build accounts. Select one in widget settings.")
        case .unavailable: return text("Usage is unavailable. Try refreshing.")
        }
    }
}
