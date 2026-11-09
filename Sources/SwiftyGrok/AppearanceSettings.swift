import AppKit
import SwiftUI
import Observation
import GrokCore

enum AppTheme: String, CaseIterable, Identifiable {
    case system, light, dark, black
    var id: Self { self }

    var title: String {
        switch self {
        case .system: return L10n.text("Auto")
        case .light: return L10n.text("Light")
        case .dark: return L10n.text("Dark")
        case .black: return L10n.text("Black")
        }
    }

    var icon: String {
        switch self {
        case .system: return "circle.lefthalf.filled"
        case .light: return "sun.max.fill"
        case .dark: return "moon.fill"
        case .black: return "moon.stars.fill"
        }
    }

    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light: return .light
        case .dark, .black: return .dark
        }
    }

    var appearance: NSAppearance? {
        switch self {
        case .system: return nil
        case .light: return NSAppearance(named: .aqua)
        case .dark, .black: return NSAppearance(named: .darkAqua)
        }
    }

    var chatBackground: Color {
        self == .black ? .black : Color(nsColor: .textBackgroundColor)
    }

    var settingsBackground: Color {
        self == .black ? .black : Color(nsColor: .windowBackgroundColor)
    }
}

@MainActor @Observable final class AppearanceSettings {
    static let shared = AppearanceSettings()
    private(set) var theme: AppTheme
    private(set) var quickInputFollowsSystemTransparency: Bool
    private(set) var quickInputTransparency: Double
    @ObservationIgnored private let defaults: UserDefaults
    private static let themeKey = "appearance.theme"
    private static let quickInputFollowsSystemTransparencyKey = "appearance.quickInputFollowsSystemTransparency"
    private static let quickInputTransparencyKey = "appearance.quickInputTransparency"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        theme = defaults.string(forKey: Self.themeKey).flatMap(AppTheme.init(rawValue:)) ?? .system
        quickInputFollowsSystemTransparency = defaults.object(forKey: Self.quickInputFollowsSystemTransparencyKey) as? Bool ?? true
        if let saved = defaults.object(forKey: Self.quickInputTransparencyKey) as? Double, saved.isFinite {
            quickInputTransparency = min(max(saved, 0), 1)
        } else {
            quickInputTransparency = 0.5
        }
    }

    var quickInputBackgroundOpacity: Double {
        quickInputFollowsSystemTransparency ? 0 : 1 - quickInputTransparency
    }

    func setQuickInputFollowsSystemTransparency(_ enabled: Bool) {
        guard quickInputFollowsSystemTransparency != enabled else { return }
        quickInputFollowsSystemTransparency = enabled
        defaults.set(enabled, forKey: Self.quickInputFollowsSystemTransparencyKey)
    }

    func setQuickInputTransparency(_ value: Double) {
        guard value.isFinite else { return }
        let value = min(max(value, 0), 1)
        guard quickInputTransparency != value else { return }
        quickInputTransparency = value
        defaults.set(value, forKey: Self.quickInputTransparencyKey)
    }

    func select(_ theme: AppTheme) {
        guard self.theme != theme else { return }
        self.theme = theme
        defaults.set(theme.rawValue, forKey: Self.themeKey)
        apply()
    }

    func apply() {
        // nil restores live system appearance; no global macOS setting is changed.
        NSApp.appearance = theme.appearance
        ApplicationIcon.apply()
    }
}

@MainActor enum ApplicationIcon {
    private static let light = load("AppIconLight")
    private static let dark = load("AppIcon")

    static var current: NSImage? {
        let isLight: Bool
        switch AppearanceSettings.shared.theme {
        case .light: isLight = true
        case .dark, .black: isLight = false
        case .system:
            isLight = NSApp.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) != .darkAqua
        }
        return isLight ? light ?? dark : dark ?? light
    }

    static func apply() {
        guard let icon = current else { return }
        NSApp.applicationIconImage = icon
        NSApp.dockTile.display()
        for window in NSApp.windows where !(window is NSPanel) {
            (window.dockTile.contentView as? MinimizedWindowTile)?.icon = icon
            window.dockTile.display()
        }
    }

    static func prepareMinimizedWindow(_ window: NSWindow) {
        guard let icon = current, let view = window.contentView?.superview ?? window.contentView,
              let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        let image = NSImage(size: view.bounds.size)
        image.addRepresentation(bitmap)
        let tile = MinimizedWindowTile(image: image, icon: icon)
        window.dockTile.contentView = tile
        window.dockTile.display()
    }

    private static func load(_ name: String) -> NSImage? {
        #if SWIFT_PACKAGE
        let bundle = Bundle.module
        #else
        let bundle = Bundle.main
        #endif
        return bundle.url(forResource: name, withExtension: "icns").flatMap(NSImage.init(contentsOf:))
    }
}

private final class MinimizedWindowTile: NSView {
    private let image: NSImage
    var icon: NSImage { didSet { needsDisplay = true } }

    init(image: NSImage, icon: NSImage) {
        self.image = image
        self.icon = icon
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { return nil }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard bounds.width > 0, bounds.height > 0, image.size.width > 0, image.size.height > 0 else { return }
        let scale = min(bounds.width / image.size.width, bounds.height / image.size.height)
        let size = NSSize(width: image.size.width * scale, height: image.size.height * scale)
        let rect = NSRect(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2,
                          width: size.width, height: size.height)
        image.draw(in: rect)
        let badgeSize = min(bounds.width, bounds.height) * 0.36
        icon.draw(in: NSRect(x: bounds.maxX - badgeSize, y: bounds.minY,
                             width: badgeSize, height: badgeSize))
    }
}

@MainActor struct AppAppearance: ViewModifier {
    @State private var preferences = AppearanceSettings.shared

    func body(content: Content) -> some View {
        content.preferredColorScheme(preferences.theme.colorScheme)
    }
}
