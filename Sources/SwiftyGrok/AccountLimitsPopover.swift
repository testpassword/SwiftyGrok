import SwiftUI
import GrokCore
import GrokUsage

@MainActor struct AccountLimitsPopover: View {
    let name: String?
    let email: String?
    @State private var monitor = UsageMonitor.shared

    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            let snapshot = monitor.accountUsage
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(name ?? L10n.text("Profile")).font(.headline).lineLimit(1)
                    if let email, email.caseInsensitiveCompare(name ?? "") != .orderedSame {
                        Spacer(minLength: 0)
                        Text(email).font(.caption).foregroundStyle(.secondary)
                            .lineLimit(1).truncationMode(.middle).help(email)
                    }
                }
                if let subscription = monitor.chatSubscriptionName {
                    Text(subscription).font(.subheadline.weight(.semibold)).lineLimit(1)
                }
                if snapshot.fetchedAt == nil {
                    if monitor.isRefreshing {
                        ProgressView().controlSize(.small)
                    } else {
                        Text(UsageText.status(snapshot.status)).font(.callout).foregroundStyle(.secondary)
                    }
                } else {
                    allowance(snapshot, at: context.date)
                    credits(snapshot)
                    if snapshot.isStale(at: context.date) {
                        Text(UsageText.text("Out of date")).font(.caption).foregroundStyle(.orange)
                    }
                }
            }
            .frame(width: 300, alignment: .leading)
            .padding(16)
        }
        .task {
            if monitor.accountUsage.isStale(at: Date()) { await monitor.refresh() }
        }
    }

    @ViewBuilder private func allowance(_ snapshot: UsageSnapshot, at date: Date) -> some View {
        let window = snapshot.windows.first ?? UsageWindow(id: "credits")
        let percent = window.hasReset(at: date) ? nil : window.usedPercent
        let products = window.hasReset(at: date) ? [] : snapshot.products.sorted {
            $0.percent == $1.percent ? $0.id < $1.id : $0.percent > $1.percent
        }
        VStack(alignment: .leading, spacing: 10) {
            Text(UsageText.text(limitTitle(window))).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .top, spacing: 12) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(percent.map(percentage) ?? "—")
                            .font(.system(size: 26, weight: .semibold)).monospacedDigit()
                        Text(UsageText.text("Used")).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                    Group {
                        if window.hasReset(at: date) {
                            Text(UsageText.text("Awaiting refresh"))
                        } else if let reset = window.resetAt {
                            Text(UsageText.format("Renews %@", reset.formatted(date: .abbreviated, time: .shortened)))
                        } else {
                            Text(UsageText.text("Reset not reported"))
                        }
                    }
                    .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.trailing)
                    .frame(maxWidth: 155, alignment: .trailing)
                }
                usageBar(percent: percent, products: products)
                if !products.isEmpty {
                    VStack(spacing: 0) {
                        ForEach(Array(products.enumerated()), id: \.element.id) { index, product in
                            if index > 0 { Divider().padding(.leading, 18) }
                            HStack(spacing: 10) {
                                Circle().fill(productColor(product.id)).frame(width: 8, height: 8)
                                    .accessibilityHidden(true)
                                Text(productName(product.id))
                                Spacer(minLength: 4)
                                Text(UsageText.format("%@%% of total", number(product.percent)))
                                    .foregroundStyle(.secondary).monospacedDigit()
                            }
                            .font(.callout).padding(.vertical, 10)
                        }
                    }
                    .padding(.bottom, -10)
                }
            }
            .padding(14)
            .background(.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 18))
            Text(UsageText.text(allowanceNote(window))).font(.caption).foregroundStyle(.secondary)
        }
    }

    private func usageBar(percent: Double?, products: [ProductUsage]) -> some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Rectangle().fill(.primary.opacity(0.08))
                if let percent {
                    if products.isEmpty {
                        Rectangle().fill(.blue).frame(width: geometry.size.width * percent / 100)
                    } else {
                        HStack(spacing: 0) {
                            ForEach(products) { product in
                                Rectangle().fill(productColor(product.id))
                                    .frame(width: geometry.size.width * product.percent / 100)
                            }
                        }
                    }
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 3))
        }
        .frame(height: 10).accessibilityHidden(true)
    }

    private func credits(_ snapshot: UsageSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(UsageText.text("Extra usage credits")).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                .padding(.top, 4)
            HStack {
                Text(UsageText.text("Balance"))
                Spacer()
                Text(snapshot.prepaidCents.map { (Decimal($0) / 100).formatted(.currency(code: "USD")) } ?? "—")
                    .foregroundStyle(.secondary).monospacedDigit()
            }
            .font(.callout).padding(14)
            .background(.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 18))
            Text(UsageText.text("Used after your included allowance is exhausted."))
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func limitTitle(_ window: UsageWindow) -> String {
        switch window.period {
        case "Weekly pool": return "Weekly limit"
        case "Monthly pool": return "Monthly limit"
        default: return "Shared allowance"
        }
    }

    private func allowanceNote(_ window: UsageWindow) -> String {
        switch window.period {
        case "Weekly pool": return "Included in your subscription. Renews weekly. Used before extra credits."
        case "Monthly pool": return "Included in your subscription. Renews monthly. Used before extra credits."
        default: return "Included in your subscription. Used before extra credits."
        }
    }

    private func productKey(_ id: String) -> String {
        if id.hasPrefix("PRODUCT_GROK_") { return String(id.dropFirst("PRODUCT_GROK_".count)).lowercased() }
        if id.hasPrefix("Grok") { return String(id.dropFirst("Grok".count)).lowercased() }
        return id.lowercased()
    }

    private func productName(_ id: String) -> String {
        switch productKey(id) {
        case "build": return UsageText.text("Build")
        case "chat": return UsageText.text("Chat")
        case "imagine": return "Imagine"
        case "voice": return UsageText.text("Voice")
        case "bot": return "Grok Bot"
        default: return productKey(id).replacingOccurrences(of: "_", with: " ").capitalized
        }
    }

    private func productColor(_ id: String) -> Color {
        switch productKey(id) {
        case "build": return .blue
        case "chat": return .blue.opacity(0.75)
        case "imagine": return .blue.opacity(0.5)
        case "voice": return .teal
        default: return .blue.opacity(0.35)
        }
    }

    private func number(_ value: Double) -> String { value.formatted(.number.precision(.fractionLength(0...1))) }
    private func percentage(_ value: Double) -> String { UsageText.format("%@%%", number(value)) }
}
