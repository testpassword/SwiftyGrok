import SwiftUI
import GrokUsage

@MainActor struct UsageSettingsView: View {
    @State private var monitor = UsageMonitor.shared

    var body: some View {
        Form {
            Section {
                Text(UsageText.text("Add SwiftyGrok widgets from the macOS widget gallery."))
                Text(UsageText.text("Keep SwiftyGrok running to update widgets. Updates are requested every five minutes; macOS controls when widgets refresh."))
                    .font(.callout).foregroundStyle(.secondary)
                Button {
                    Task { await monitor.refresh() }
                } label: {
                    Label(UsageText.text("Refresh widgets"), systemImage: "arrow.clockwise")
                }
                .disabled(monitor.isRefreshing)
                if monitor.isRefreshing { ProgressView().controlSize(.small) }
                if monitor.storageFailed {
                    Text(UsageText.text("Widget data could not be saved. Use the complete SwiftyGrok app bundle."))
                        .font(.callout).foregroundStyle(.orange)
                }
            }
            Section("Grok Chat") {
                status(monitor.snapshots.chat)
                Text(UsageText.text("Compact chat widgets let you choose Fast, Expert or Heavy. The overview shows all three."))
                    .font(.callout).foregroundStyle(.secondary)
            }
            Section("Grok Build") {
                status(monitor.snapshots.build)
                if !monitor.buildAccounts.isEmpty {
                    Picker(UsageText.text("Grok Build account"), selection: Binding(
                        get: { monitor.selectedBuildAccount }, set: { monitor.selectBuildAccount($0) }
                    )) {
                        Text(UsageText.text("Automatic (one account)")).tag("")
                        ForEach(monitor.buildAccounts) { account in Text(account.label).tag(account.id) }
                    }
                }
                Text(UsageText.text("Run grok login to connect Grok Build."))
                    .font(.callout).textSelection(.enabled)
                Text(UsageText.text("Build uses the local Grok CLI session. If it expires, open Grok CLI to renew it, then refresh widgets."))
                    .font(.callout).foregroundStyle(.secondary)
                Text(UsageText.text("Build and Chat may use different accounts. The Build percentage describes its shared subscription allowance."))
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped).scrollContentBackground(.hidden)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func status(_ snapshot: UsageSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(UsageText.status(snapshot.status)).foregroundStyle(snapshot.status == .available ? Color.primary : .secondary)
            if let date = snapshot.fetchedAt {
                HStack {
                    Text(UsageText.text("Updated"))
                    Text(date, style: .time)
                    if snapshot.isStale(at: Date()) { Text(UsageText.text("Out of date")).foregroundStyle(.orange) }
                }.font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}
