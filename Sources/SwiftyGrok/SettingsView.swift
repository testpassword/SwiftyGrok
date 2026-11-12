import SwiftUI
import AppKit
import GrokCore
import GrokUsage

@MainActor struct SettingsView: View {
    @State private var selection: Category? = .appearance
    @State private var appearance = AppearanceSettings.shared
    @State private var behavior = BehaviorSettings.shared
    @State private var screenshotShortcut = WindowScreenshotShortcut.shared
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
                Label(category.title, appSymbol: category.icon).tag(category)
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)
            .padding(.top, SettingsWindowLayout.titlebarHeight)
            .frame(width: 200)
            .background(SidebarMaterial())
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
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .ignoresSafeArea(.container)
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
                                get: { 1 - appearance.quickInputTransparency },
                                set: { appearance.setQuickInputTransparency(1 - $0) }
                            ), in: 0...1, step: 0.01) {
                                Text(L10n.text("Transparency"))
                            }
                            .labelsHidden()
                            .accessibilityValue(Text(appearance.quickInputTransparency, format: .percent.precision(.fractionLength(0))))
                            HStack {
                                Text(L10n.text("Transparent"))
                                Spacer()
                                Text(L10n.text("Opaque"))
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
                Text(L10n.text("Open quick input with ⌥Space."))
                    .font(.callout).foregroundStyle(.secondary)
            }
            Section {
                Toggle(L10n.text("Window screenshot shortcut"), isOn: Binding(
                    get: { behavior.windowScreenshotEnabled }, set: { behavior.setWindowScreenshotEnabled($0) }
                ))
                Text(L10n.text("Press left ⌘ + right ⌘ to attach a screenshot of the active window."))
                    .font(.callout).foregroundStyle(.secondary)
                if behavior.windowScreenshotEnabled && screenshotShortcut.needsInputMonitoring {
                    Button(L10n.text("Allow Input Monitoring…")) { screenshotShortcut.requestInputMonitoring() }
                    Text(L10n.text("Input Monitoring is required for the global shortcut. Screen recording access is requested when taking the first screenshot."))
                        .font(.callout).foregroundStyle(.secondary)
                    PermissionRecoveryHint()
                }
                if let error = screenshotShortcut.errorMessage {
                    Text(error).font(.callout).foregroundStyle(.secondary)
                }
            }
            Section {
                Button(L10n.text("Configure sharing extension…")) {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.ExtensionsPreferences") {
                        NSWorkspace.shared.open(url)
                    }
                }
                Text(L10n.text("Enable Open in SwiftyGrok in macOS sharing extensions, then use the system Share menu to open public Grok chats or attach files to your open chat or a new draft."))
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
                Image(appSymbol: theme.icon)
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

@MainActor private enum SettingsWindowLayout {
    static let standardStyle: NSWindow.StyleMask = [.titled, .closable, .miniaturizable]
    // Preserve the previous outer size while extending content under the title bar.
    static let size = NSWindow.frameRect(forContentRect: NSRect(x: 0, y: 0, width: 720, height: 480),
                                         styleMask: standardStyle).size
    static let titlebarHeight = size.height - 480
}

@MainActor final class SettingsWindowController: NSWindowController, NSWindowDelegate {
    private var isPresentingModally = false

    init() {
        let size = SettingsWindowLayout.size
        let window = SettingsWindow(contentRect: NSRect(origin: .zero, size: size),
                                    styleMask: SettingsWindowLayout.standardStyle.union(.fullSizeContentView),
                                    backing: .buffered, defer: false)
        window.identifier = NSUserInterfaceItemIdentifier("settings")
        window.title = L10n.text("Settings")
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.titlebarSeparatorStyle = .none
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        window.tabbingMode = .disallowed
        window.collectionBehavior = [.fullScreenNone]
        window.contentViewController = Self.makeContentController()
        window.toolbar = nil
        // Use outer-frame sizing consistently with fullSizeContentView.
        window.minSize = size
        window.maxSize = size
        window.setFrame(NSRect(origin: window.frame.origin, size: size), display: false)
        super.init(window: window)
        window.delegate = self
        configureButtons()
        window.center()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("Use init()") }

    func show() {
        guard let window else { return }
        restoreFixedSize()
        configureButtons()
        showWindow(nil)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        guard !isPresentingModally else { return }
        isPresentingModally = true
        defer {
            isPresentingModally = false
            window.orderOut(nil)
        }
        NSApp.runModal(for: window)
    }

    func windowWillClose(_ notification: Notification) {
        guard isPresentingModally, NSApp.modalWindow === window else { return }
        NSApp.stopModal()
    }

    func showWidgets() {
        window?.contentViewController = Self.makeContentController(showWidgets: true)
        show()
    }

    private static func makeContentController(showWidgets: Bool = false) -> NSHostingController<SettingsView> {
        let controller = NSHostingController(rootView: SettingsView(showWidgets: showWidgets))
        // The window owns its fixed size. SwiftUI's default standardBounds
        // would replace contentMinSize/contentMaxSize during later layout passes.
        controller.sizingOptions = []
        return controller
    }

    private func restoreFixedSize() {
        guard let window else { return }
        let size = SettingsWindowLayout.size
        window.minSize = size
        window.maxSize = size
        guard window.frame.size != size else { return }
        var frame = window.frame
        // Keep the window's top-left position when restoring its dimensions.
        frame.origin.y += frame.height - size.height
        frame.size = size
        window.setFrame(frame, display: false)
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
