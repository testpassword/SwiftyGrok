import SwiftUI
import AppKit
import GrokCore
import FinderSync
import GrokUsage

@MainActor struct SettingsView: View {
    @State private var selection: Category? = .appearance
    @State private var appearance = AppearanceSettings.shared
    @State private var behavior = BehaviorSettings.shared
    @Environment(\.colorScheme) private var colorScheme

    init(showWidgets: Bool = false) { _selection = State(initialValue: showWidgets ? .widgets : .appearance) }

    private enum Category: String, CaseIterable, Identifiable {
        case appearance, behavior, widgets
        var id: Self { self }
        var title: String { self == .widgets ? UsageText.text("Widgets") : L10n.text(self == .appearance ? "Appearance" : "Behavior") }
        var icon: String { self == .widgets ? "square.grid.2x2" : self == .appearance ? "paintpalette" : "slider.horizontal.3" }
    }

    var body: some View {
        HStack(spacing: 0) {
            List(Category.allCases, selection: $selection) { category in
                Label(category.title, systemImage: category.icon).tag(category)
            }
            .listStyle(.sidebar)
            .frame(width: 200)
            Divider()
            Group {
                if selection == .appearance {
                    appearanceSettings
                } else if selection == .behavior {
                    behaviorSettings
                } else if selection == .widgets {
                    UsageSettingsView()
                } else {
                    Color.clear.frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .background(appearance.theme.settingsBackground)
        }
        .frame(width: 720, height: 480)
        .modifier(AppAppearance())
    }

    private var appearanceSettings: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                HStack(alignment: .top, spacing: 12) {
                    ForEach(AppTheme.allCases) { theme in themeButton(theme) }
                }
                GroupBox {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            Text(L10n.text("Follow system transparency"))
                            Spacer()
                            Toggle(L10n.text("Follow system transparency"), isOn: Binding(
                                get: { appearance.quickInputFollowsSystemTransparency },
                                set: { appearance.setQuickInputFollowsSystemTransparency($0) }
                            ))
                            .toggleStyle(.switch).labelsHidden().fixedSize()
                        }
                        if !appearance.quickInputFollowsSystemTransparency {
                            Text(L10n.text("Transparency"))
                            Slider(value: Binding(
                                get: { appearance.quickInputTransparency },
                                set: { appearance.setQuickInputTransparency($0) }
                            ), in: 0...1, step: 0.01) {
                                Text(L10n.text("Transparency"))
                            }
                            .labelsHidden()
                            .accessibilityValue(Text(appearance.quickInputTransparency, format: .percent.precision(.fractionLength(0))))
                            HStack {
                                Text(L10n.text("Opaque"))
                                Spacer()
                                Text(L10n.text("Transparent"))
                            }
                            .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                } label: {
                    Text(L10n.text("Floating input"))
                }
            }
            .padding(24)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var behaviorSettings: some View {
        Form {
            Section {
                Picker(L10n.text("Send message with"), selection: Binding(
                    get: { behavior.sendShortcut }, set: { behavior.setSendShortcut($0) }
                )) {
                    ForEach(MessageSendShortcut.allCases) { shortcut in
                        Text(shortcut.title).tag(shortcut)
                    }
                }
                Text(behavior.sendShortcut.explanation)
                    .font(.callout).foregroundStyle(.secondary)
            }
            Section {
                Toggle(L10n.text("Enable quick input"), isOn: Binding(
                    get: { behavior.quickInputEnabled }, set: { behavior.setQuickInputEnabled($0) }
                ))
                Text(L10n.text("Open quick input with ⌥Space or from the File menu."))
                    .font(.callout).foregroundStyle(.secondary)
            }
            Section {
                Button(L10n.text("Configure Finder extension…")) {
                    FIFinderSyncController.showExtensionManagementInterface()
                }
                Text(L10n.text("Enable SwiftyGrok in macOS to attach files from Finder's context menu to the open chat or a new draft."))
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func themeButton(_ theme: AppTheme) -> some View {
        let selected = appearance.theme == theme
        let shape = RoundedRectangle(cornerRadius: 20, style: .continuous)
        return Button { appearance.select(theme) } label: {
            VStack(spacing: 12) {
                Image(systemName: theme.icon)
                    .font(.system(size: 32, weight: .regular))
                    .foregroundStyle(selected ? Color.primary : .secondary)
                    .frame(maxWidth: .infinity).frame(height: 84)
                    .background(selected ? Color.primary.opacity(colorScheme == .dark ? 0.1 : 0.06) : .clear, in: shape)
                    .overlay(shape.strokeBorder(selected ? .clear : Color.primary.opacity(0.15), lineWidth: 1))
                Text(theme.title)
                    .font(.system(size: 15, weight: selected ? .semibold : .regular))
                    .foregroundStyle(selected ? Color.primary : .secondary)
            }
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(theme.title)
        .accessibilityValue(selected ? L10n.text("Selected") : "")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

@MainActor final class SettingsWindowController: NSWindowController {
    init() {
        let size = NSSize(width: 720, height: 480)
        let window = SettingsWindow(contentRect: NSRect(origin: .zero, size: size),
                                    styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.identifier = NSUserInterfaceItemIdentifier("settings")
        window.title = L10n.text("Settings")
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false
        window.tabbingMode = .disallowed
        window.collectionBehavior = [.fullScreenNone]
        window.contentViewController = NSHostingController(rootView: SettingsView())
        window.toolbar = nil
        window.setContentSize(size)
        window.contentMinSize = size
        window.contentMaxSize = size
        super.init(window: window)
        configureButtons()
        window.center()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("Use init()") }

    func show() {
        configureButtons()
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func showWidgets() {
        window?.contentViewController = NSHostingController(rootView: SettingsView(showWidgets: true))
        show()
    }

    private func configureButtons() {
        window?.standardWindowButton(.closeButton)?.isEnabled = true
        window?.standardWindowButton(.miniaturizeButton)?.isEnabled = false
        window?.standardWindowButton(.zoomButton)?.isEnabled = false
    }

}

private final class SettingsWindow: NSWindow {
    override func cancelOperation(_ sender: Any?) { performClose(sender) }
}
