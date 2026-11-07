import AppKit
import Foundation
import Observation
import WidgetKit
import GrokCore
import GrokUsage

@MainActor @Observable final class UsageMonitor {
    static let shared = UsageMonitor()
    private(set) var snapshots = UsageSnapshots()
    private(set) var isRefreshing = false
    private(set) var storageFailed = false
    private(set) var buildAccounts: [BuildAccount] = []
    private(set) var selectedBuildAccount = UserDefaults.standard.string(forKey: "widgets.buildAccount") ?? ""
    @ObservationIgnored private var service: GrokService?
    @ObservationIgnored private var chatGeneration = UUID()
    @ObservationIgnored private var buildGeneration = UUID()
    @ObservationIgnored private var timer: Task<Void, Never>?
    @ObservationIgnored private var refreshAgain = false
    @ObservationIgnored private let buildClient = BuildUsageClient()

    func start() {
        guard timer == nil else { return }
        timer = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                do { try await Task.sleep(for: .seconds(300)) } catch { return }
            }
        }
    }

    func stop() { timer?.cancel(); timer = nil }

    func setChatService(_ service: GrokService?) {
        chatGeneration = UUID()
        self.service = service
        snapshots.chat = UsageSnapshot(product: .chat, status: service == nil ? .signIn : .unavailable)
        publish()
        Task { await refresh() }
    }

    func selectBuildAccount(_ id: String) {
        guard id != selectedBuildAccount else { return }
        selectedBuildAccount = id
        UserDefaults.standard.set(id, forKey: "widgets.buildAccount")
        buildGeneration = UUID()
        snapshots.build = UsageSnapshot(product: .build, status: .buildLogin)
        publish()
        Task { await refresh() }
    }

    func refresh() async {
        guard !isRefreshing else { refreshAgain = true; return }
        isRefreshing = true
        defer {
            isRefreshing = false
            if refreshAgain { refreshAgain = false; Task { await refresh() } }
        }
        let chatRevision = chatGeneration
        let buildRevision = buildGeneration
        async let chat = fetchChat(service)
        async let build = fetchBuild()
        let (chatValue, buildValue) = await (chat, build)
        guard !Task.isCancelled else { return }
        if chatRevision == chatGeneration { snapshots.chat = chatValue }
        if buildRevision == buildGeneration { snapshots.build = buildValue }
        publish()
    }

    private func fetchChat(_ service: GrokService?) async -> UsageSnapshot {
        guard let service else { return .init(product: .chat, status: .signIn) }
        let results = await withTaskGroup(of: (UsageWindow, Bool, Bool).self) { group in
            for mode in ["fast", "expert", "heavy"] {
                group.addTask {
                    do { return (try await service.usageLimit(modeID: mode), true, false) }
                    catch { return (UsageWindow(id: mode), false, DisplayError(error).needsLogin) }
                }
            }
            var values: [(UsageWindow, Bool, Bool)] = []
            for await value in group { values.append(value) }
            return values
        }
        let windows = results.map(\.0).sorted {
            ["fast", "expert", "heavy"].firstIndex(of: $0.id)! < ["fast", "expert", "heavy"].firstIndex(of: $1.id)!
        }
        if !results.contains(where: \.1) {
            if results.contains(where: \.2) { return .init(product: .chat, status: .signIn) }
            var cached = snapshots.chat; cached.status = .unavailable; return cached
        }
        return .init(product: .chat, status: .available, fetchedAt: Date(), windows: windows)
    }

    private func fetchBuild() async -> UsageSnapshot {
        buildAccounts = []
        do {
            let environment = ProcessInfo.processInfo.environment
            let home = environment["GROK_HOME"].flatMap { $0.isEmpty ? nil : $0 }
                .map { URL(fileURLWithPath: $0, isDirectory: true) }
                ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".grok", isDirectory: true)
            let url = environment["GROK_AUTH_PATH"].flatMap { $0.isEmpty ? nil : $0 }
                .map { URL(fileURLWithPath: $0) } ?? home.appendingPathComponent("auth.json")
            guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= 1_048_576 else {
                throw BuildUsageError.loginRequired
            }
            let accounts = try BuildAuthReader.accounts(from: Data(contentsOf: url))
            buildAccounts = accounts
            let account: BuildAccount
            if !selectedBuildAccount.isEmpty {
                guard let selected = accounts.first(where: { $0.id == selectedBuildAccount }) else { throw BuildUsageError.loginRequired }
                account = selected
            } else {
                guard accounts.count == 1 else {
                    if accounts.isEmpty { throw BuildUsageError.loginRequired }
                    throw BuildUsageError.ambiguousAccount
                }
                account = accounts[0]
            }
            return try await buildClient.fetch(account: account)
        } catch BuildUsageError.ambiguousAccount {
            return .init(product: .build, status: .ambiguousBuildAccount)
        } catch BuildUsageError.loginRequired {
            return .init(product: .build, status: .buildLogin)
        } catch {
            var cached = snapshots.build; cached.status = .unavailable; return cached
        }
    }

    private func publish() {
        do {
            let extensionURL = Bundle.main.bundleURL.appendingPathComponent("Contents/PlugIns/SwiftyGrokWidgets.appex")
            guard Bundle(url: extensionURL)?.bundleIdentifier == UsageSnapshotStore.extensionIdentifier else {
                storageFailed = true; return
            }
            // Same container handoff as the reference host, with display data only.
            // The WidgetKit extension needs neither network nor credential access.
            let library = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
            let support = library.appendingPathComponent("Containers", isDirectory: true)
                .appendingPathComponent(UsageSnapshotStore.extensionIdentifier, isDirectory: true)
                .appendingPathComponent("Data/Library/Application Support", isDirectory: true)
            try UsageSnapshotStore.write(snapshots, to: UsageSnapshotStore.fileURL(applicationSupport: support))
            storageFailed = false
            for kind in ["GrokChatLimits", "GrokChatResets", "GrokChatOverview", "GrokBuildLimits", "GrokBuildResets", "GrokBuildCredits", "GrokBuildOverview"] {
                WidgetCenter.shared.reloadTimelines(ofKind: kind)
            }
        } catch { storageFailed = true }
    }
}
