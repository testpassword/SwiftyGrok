import SwiftUI
import WidgetKit
import AppIntents
import GrokUsage

enum ChatLimitMode: String, AppEnum {
    case fast, expert, heavy
    static var typeDisplayRepresentation: TypeDisplayRepresentation = "Chat mode"
    static var caseDisplayRepresentations: [Self: DisplayRepresentation] = [.fast: "Fast", .expert: "Expert", .heavy: "Heavy"]
}

struct ChatModeConfiguration: WidgetConfigurationIntent {
    static var title: LocalizedStringResource = "Chat limits"
    static var description = IntentDescription("Choose the chat mode shown in the widget.")
    @Parameter(title: "Chat mode", default: .fast) var mode: ChatLimitMode
}

struct UsageEntry: TimelineEntry {
    let date: Date
    let snapshot: UsageSnapshot
    var mode = "fast"
}

enum WidgetData {
    static func read(_ product: UsageProduct, mode: String = "fast", preview: Bool = false) -> UsageEntry {
        if preview { return placeholder(product, mode: mode) }
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let snapshots = UsageSnapshotStore.read(from: UsageSnapshotStore.fileURL(applicationSupport: support)) ?? UsageSnapshots()
        return UsageEntry(date: Date(), snapshot: snapshots[product], mode: mode)
    }

    static func placeholder(_ product: UsageProduct, mode: String = "fast") -> UsageEntry {
        let now = Date()
        let windows: [UsageWindow] = product == .chat
            ? [.init(id: "fast", remaining: 64, resetAt: now.addingTimeInterval(3_600)),
               .init(id: "expert", remaining: 18, resetAt: now.addingTimeInterval(7_200)),
               .init(id: "heavy", remaining: 4, resetAt: now.addingTimeInterval(10_800))]
            : [.init(id: "credits", usedPercent: 24, resetAt: now.addingTimeInterval(400_000), period: "Weekly pool")]
        return UsageEntry(date: now, snapshot: .init(product: product, status: .available, fetchedAt: now,
                                                   windows: windows, prepaidCents: product == .build ? 2_400 : nil), mode: mode)
    }

    static func timeline(_ entry: UsageEntry) -> Timeline<UsageEntry> {
        let next = min(entry.date.addingTimeInterval(300),
                       entry.snapshot.windows.compactMap(\.resetAt).filter { $0 > entry.date }.min() ?? .distantFuture)
        return Timeline(entries: [entry], policy: .after(next.addingTimeInterval(1)))
    }
}

struct ChatUsageProvider: AppIntentTimelineProvider {
    func placeholder(in context: Context) -> UsageEntry { WidgetData.placeholder(.chat) }
    func snapshot(for configuration: ChatModeConfiguration, in context: Context) async -> UsageEntry {
        WidgetData.read(.chat, mode: configuration.mode.rawValue, preview: context.isPreview)
    }
    func timeline(for configuration: ChatModeConfiguration, in context: Context) async -> Timeline<UsageEntry> {
        WidgetData.timeline(WidgetData.read(.chat, mode: configuration.mode.rawValue))
    }
}

struct BuildUsageProvider: TimelineProvider {
    func placeholder(in context: Context) -> UsageEntry { WidgetData.placeholder(.build) }
    func getSnapshot(in context: Context, completion: @escaping (UsageEntry) -> Void) {
        completion(WidgetData.read(.build, preview: context.isPreview))
    }
    func getTimeline(in context: Context, completion: @escaping (Timeline<UsageEntry>) -> Void) {
        completion(WidgetData.timeline(WidgetData.read(.build)))
    }
}

enum UsageWidgetStyle { case limits, resets, credits, overview }

struct UsageWidgetView: View {
    @Environment(\.widgetContentMargins) private var contentMargins
    let entry: UsageEntry
    let style: UsageWidgetStyle
    private var isBuild: Bool { entry.snapshot.product == .build }
    private var windows: [UsageWindow] {
        if isBuild || style == .overview { return entry.snapshot.windows }
        return [entry.snapshot.windows.first(where: { $0.id == entry.mode }) ?? UsageWindow(id: entry.mode)]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Image("GrokLogo", bundle: .main)
                    .renderingMode(.template).resizable().scaledToFit()
                    .frame(width: 18, height: 18)
                    .foregroundStyle(.primary)
                    .accessibilityHidden(true)
                if isBuild {
                    Text("Build").font(.headline.weight(.semibold))
                        .lineLimit(1).minimumScaleFactor(0.8)
                }
                Spacer(minLength: 4)
            }
            if entry.snapshot.fetchedAt == nil {
                Text(UsageText.status(entry.snapshot.status))
                    .font(.caption).foregroundStyle(.secondary).lineLimit(5)
                Spacer(minLength: 0)
            } else if style == .credits {
                credits
                Spacer(minLength: 0)
                if let reset = windows.first?.resetAt {
                    if reset <= entry.date { Text(UsageText.text("Awaiting refresh")).font(.caption2).foregroundStyle(.secondary) }
                    else { resetText(reset, absolute: true).font(.caption2).foregroundStyle(.secondary) }
                }
            } else if style == .overview {
                HStack(alignment: .top, spacing: 14) {
                    rows
                    Divider()
                    if isBuild {
                        VStack(alignment: .leading, spacing: 5) {
                            credits
                            ForEach(entry.snapshot.products.sorted { $0.percent > $1.percent }.prefix(2)) { product in
                                Text("\(productName(product.id)) · \(product.percent.formatted(.number.precision(.fractionLength(0))))%")
                                    .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                            }
                        }
                        .frame(width: 110, alignment: .leading)
                    } else {
                        VStack(alignment: .leading, spacing: 5) {
                            Text(UsageText.text("Next reset")).font(.caption).foregroundStyle(.secondary)
                            if let date = windows.compactMap(\.resetAt).filter({ $0 > entry.date }).min() {
                                Text(date, style: .time).font(.title3.weight(.semibold).monospacedDigit())
                            } else { Text("—").font(.title3) }
                            Text(UsageText.text("Messages left by mode")).font(.caption2).foregroundStyle(.secondary)
                        }.frame(width: 110, alignment: .leading)
                    }
                }
                Spacer(minLength: 0)
            } else {
                rows
                Spacer(minLength: 0)
            }
            footer
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(.vertical, 12)
        .padding(.leading, max(16, contentMargins.leading) + 2)
        .padding(.trailing, max(16, contentMargins.trailing) + 2)
        .containerBackground(.background, for: .widget)
        .widgetURL(UsageSnapshotStore.refreshURL)
    }

    private var rows: some View {
        VStack(alignment: .leading, spacing: style == .overview ? 7 : 10) {
            ForEach(windows) { window in
                VStack(alignment: .leading, spacing: 4) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(UsageText.text(window.period ?? window.id.capitalized)).font(.caption.weight(.semibold))
                        Spacer(minLength: 4)
                        Text(value(window)).font(style == .overview ? .caption.monospacedDigit() : .title2.weight(.semibold).monospacedDigit())
                            .foregroundStyle(tint(window)).lineLimit(1).minimumScaleFactor(0.7)
                    }
                    if let percent = window.remainingPercent, !window.hasReset(at: entry.date) {
                        ProgressView(value: percent, total: 100).tint(tint(window))
                    }
                    if style != .overview || isBuild {
                        if window.hasReset(at: entry.date) {
                            Text(UsageText.text("Awaiting refresh")).font(.caption2).foregroundStyle(.secondary)
                        } else if let reset = window.resetAt {
                            resetText(reset, absolute: style == .resets).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                        } else {
                            Text(UsageText.text("Reset not reported")).font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

    private var credits: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(UsageText.text("Credit balance")).font(.caption).foregroundStyle(.secondary)
            Text(creditBalance).font(.title2.weight(.semibold).monospacedDigit())
                .foregroundStyle(entry.snapshot.isStale(at: entry.date) ? Color.secondary : .blue)
                .lineLimit(1).minimumScaleFactor(0.6)
        }
    }

    private var creditBalance: String {
        guard let cents = entry.snapshot.prepaidCents else { return "—" }
        return (Double(cents) / 100).formatted(.currency(code: "USD"))
    }

    private func value(_ window: UsageWindow) -> String {
        guard !window.hasReset(at: entry.date) else { return "—" }
        if let percent = window.remainingPercent {
            return UsageText.format("%@%% left", percent.formatted(.number.precision(.fractionLength(0))))
        }
        if let remaining = window.remaining { return UsageText.format("%@ left", String(remaining)) }
        return "—"
    }

    private func tint(_ window: UsageWindow) -> Color {
        if entry.snapshot.isStale(at: entry.date) || window.hasReset(at: entry.date) { return .secondary }
        if let remaining = window.remainingPercent { return remaining <= 15 ? .red : remaining <= 35 ? .orange : .green }
        guard window.remaining != nil else { return .secondary }
        return window.remaining == 0 ? .red : .blue
    }

    private func resetText(_ date: Date, absolute: Bool) -> Text {
        if absolute {
            let formatter = DateFormatter()
            formatter.setLocalizedDateFormatFromTemplate(Calendar.current.isDate(date, inSameDayAs: entry.date) ? "HHmm" : "dMMMHHmm")
            return Text(UsageText.format("Resets %@", formatter.string(from: date)))
        }
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = date.timeIntervalSince(entry.date) >= 86_400 ? [.day, .hour] : [.hour, .minute]
        formatter.unitsStyle = .abbreviated; formatter.maximumUnitCount = 2
        return Text(UsageText.format("Resets in %@", formatter.string(from: max(0, date.timeIntervalSince(entry.date))) ?? "—"))
    }

    private var footer: some View {
        HStack(spacing: 4) {
            if let date = entry.snapshot.fetchedAt {
                if entry.snapshot.isStale(at: entry.date) {
                    Label(UsageText.text("Out of date"), systemImage: "clock.badge.exclamationmark").foregroundStyle(.orange)
                        .lineLimit(1).minimumScaleFactor(0.7)
                } else {
                    Text(UsageText.text("Updated"))
                }
                Text(date, style: .time)
            }
            Spacer(minLength: 0)
        }.font(.caption2).foregroundStyle(.secondary)
    }

    private func productName(_ id: String) -> String {
        switch id {
        case "GrokChat": return "Chat"
        case "GrokBuild": return "Build"
        case "GrokImagine": return "Imagine"
        case "GrokVoice": return "Voice"
        default: return id
        }
    }
}

struct GrokChatLimits: Widget {
    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: "GrokChatLimits", intent: ChatModeConfiguration.self, provider: ChatUsageProvider()) {
            UsageWidgetView(entry: $0, style: .limits)
        }.configurationDisplayName("Grok Chat Limits").description("Messages remaining in the selected chat mode.")
            .supportedFamilies([.systemSmall]).contentMarginsDisabled()
    }
}
struct GrokChatResets: Widget {
    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: "GrokChatResets", intent: ChatModeConfiguration.self, provider: ChatUsageProvider()) {
            UsageWidgetView(entry: $0, style: .resets)
        }.configurationDisplayName("Grok Chat Reset Times").description("The remaining chat limit and its reset time.")
            .supportedFamilies([.systemSmall]).contentMarginsDisabled()
    }
}
struct GrokChatOverview: Widget {
    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: "GrokChatOverview", intent: ChatModeConfiguration.self, provider: ChatUsageProvider()) {
            UsageWidgetView(entry: $0, style: .overview)
        }.configurationDisplayName("Grok Chat Overview").description("Fast, Expert and Heavy limits together.")
            .supportedFamilies([.systemMedium]).contentMarginsDisabled()
    }
}
struct GrokBuildLimits: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "GrokBuildLimits", provider: BuildUsageProvider()) { UsageWidgetView(entry: $0, style: .limits) }
            .configurationDisplayName("Grok Build Limits").description("The remaining shared subscription allowance.")
            .supportedFamilies([.systemSmall]).contentMarginsDisabled()
    }
}
struct GrokBuildResets: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "GrokBuildResets", provider: BuildUsageProvider()) { UsageWidgetView(entry: $0, style: .resets) }
            .configurationDisplayName("Grok Build Reset Times").description("The shared allowance and its reset time.")
            .supportedFamilies([.systemSmall]).contentMarginsDisabled()
    }
}
struct GrokBuildCredits: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "GrokBuildCredits", provider: BuildUsageProvider()) { UsageWidgetView(entry: $0, style: .credits) }
            .configurationDisplayName("Grok Build Credits").description("Extra usage credit balance and the next reset.")
            .supportedFamilies([.systemSmall]).contentMarginsDisabled()
    }
}
struct GrokBuildOverview: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "GrokBuildOverview", provider: BuildUsageProvider()) { UsageWidgetView(entry: $0, style: .overview) }
            .configurationDisplayName("Grok Build Overview").description("Shared allowance, credits and usage breakdown.")
            .supportedFamilies([.systemMedium]).contentMarginsDisabled()
    }
}

@main struct SwiftyGrokWidgetBundle: WidgetBundle {
    var body: some Widget {
        GrokChatLimits()
        GrokChatResets()
        GrokChatOverview()
        GrokBuildLimits()
        GrokBuildResets()
        GrokBuildCredits()
        GrokBuildOverview()
    }
}
