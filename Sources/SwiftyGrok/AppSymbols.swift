import AppKit
import SwiftUI

/// Original Grok artwork, with SF Symbols retained where the IPA has no equivalent.
@MainActor enum AppSymbols {
    static let grokBundle: Bundle? = {
        #if SWIFT_PACKAGE
        let resources = Bundle.module
        #else
        let resources = Bundle.main
        #endif
        return resources.url(forResource: "GrokIcons", withExtension: "bundle").flatMap(Bundle.init(url:))
    }()

    private static let iconNames: Set<String> = {
        guard let url = grokBundle?.url(forResource: "IconNames", withExtension: "json"),
              let data = try? Data(contentsOf: url), let names = try? JSONDecoder().decode([String].self, from: data) else { return [] }
        return Set(names)
    }()

    static func assetName(for symbol: String) -> String? {
        if iconNames.contains(symbol) { return symbol }
        let name: String
        switch symbol {
        case "arrow.clockwise": name = "grok-reload"
        case "arrow.triangle.branch": name = "grok-git-branch"
        case "arrow.up": name = "grok-arrow-up"
        case "arrow.down": name = "grok-arrow-down"
        case "arrow.left": name = "grok-arrow-left"
        case "arrow.up.right": name = "grok-arrow-up-right"
        case "arrow.up.left.and.arrow.down.right", "arrow.down.left.and.arrow.up.right": name = "grok-expand"
        case "arrow.down.right.and.arrow.up.left", "arrow.up.right.and.arrow.down.left": name = "grok-contract"
        case "bolt": name = "grok-bolt"
        case "book", "book.closed", "book.fill": name = "grok-book"
        case "bookmark": name = "grok-bookmark"
        case "briefcase": name = "grok-briefcase"
        case "bubble.left", "bubble.left.and.bubble.right": name = "grok-chat"
        case "calendar": name = "grok-calendar"
        case "camera": name = "grok-camera"
        case "checkmark": name = "grok-checkmark"
        case "checkmark.circle": name = "grok-checkmark-circle"
        case "checkmark.circle.fill": name = "grok-checkmark-circle-fill"
        case "chevron.down": name = "grok-chevron-down"
        case "chevron.up": name = "grok-chevron-up"
        case "chevron.left": name = "grok-chevron-left"
        case "chevron.right": name = "grok-chevron-right"
        case "chevron.left.forwardslash.chevron.right": name = "grok-code"
        case "clock": name = "grok-clock"
        case "cloud": name = "grok-cloud"
        case "cpu": name = "grok-technology"
        case "cube": name = "grok-cube"
        case "doc": name = "grok-document"
        case "doc.on.doc": name = "grok-copy"
        case "ellipsis": name = "grok-3-dots"
        case "exclamationmark.circle": name = "grok-error-circle"
        case "exclamationmark.triangle": name = "grok-warning"
        case "eye": name = "grok-eye"
        case "eye.slash": name = "grok-eye-slash"
        case "flask": name = "grok-science"
        case "folder": name = "grok-folder"
        case "folder.badge.plus": name = "grok-folder-plus"
        case "gearshape": name = "grok-gear"
        case "globe": name = "grok-globe"
        case "graduationcap": name = "grok-education"
        case "hammer": name = "grok-hammer"
        case "heart": name = "grok-heart"
        case "laptopcomputer": name = "grok-device-laptop"
        case "lightbulb": name = "grok-lightbulb"
        case "link": name = "grok-link"
        case "lock.shield": name = "grok-shield-check"
        case "magnifyingglass": name = "grok-search"
        case "mappin.and.ellipse": name = "grok-location-pin"
        case "mic": name = "grok-mic"
        case "moon", "moon.fill": name = "grok-moon"
        case "music.note": name = "grok-music"
        case "paintpalette": name = "grok-art"
        case "paperplane": name = "grok-rocket"
        case "pencil": name = "grok-edit"
        case "person.fill": name = "grok-account"
        case "phone": name = "grok-phone"
        case "photo": name = "grok-image"
        case "photo.on.rectangle": name = "grok-photo-library"
        case "pin": name = "grok-pin"
        case "pin.fill": name = "grok-pin-fill"
        case "pin.slash": name = "grok-pin-off"
        case "play.rectangle": name = "grok-camera-video"
        case "plus": name = "grok-plus"
        case "safari": name = "grok-safari"
        case "slider.horizontal.3": name = "grok-sliders"
        case "sparkle": name = "grok-sparkle"
        case "sparkles": name = "grok-sparkles"
        case "square.and.arrow.up": name = "grok-share-ios"
        case "square.and.pencil": name = "grok-compose"
        case "square.grid.2x2": name = "grok-grid"
        case "star": name = "grok-star"
        case "star.fill": name = "grok-star-fill"
        case "stop.fill": name = "grok-player-stop"
        case "sun.max", "sun.max.fill": name = "grok-sun"
        case "terminal": name = "grok-console"
        case "trash": name = "grok-trash"
        case "waveform": name = "grok-waveform"
        case "xmark": name = "grok-close"
        case "xmark.circle.fill": name = "grok-close-circle-lg"
        default: return nil
        }
        return iconNames.contains(name) ? name : nil
    }

    /// Return a separate image so menu sizing and tinting cannot mutate another control.
    static func image(_ symbol: String, accessibilityDescription: String? = nil) -> NSImage? {
        if let name = assetName(for: symbol), let image = grokBundle?.image(forResource: NSImage.Name(name))?.copy() as? NSImage {
            image.isTemplate = true
            return image
        }
        return NSImage(systemSymbolName: symbol, accessibilityDescription: accessibilityDescription)
    }
}

extension Image {
    @MainActor init(appSymbol: String) {
        if let name = AppSymbols.assetName(for: appSymbol), let bundle = AppSymbols.grokBundle {
            self = Image(name, bundle: bundle).renderingMode(.template)
        } else {
            self.init(systemName: appSymbol)
        }
    }
}

extension Label where Title == Text, Icon == Image {
    @MainActor init(_ titleKey: LocalizedStringKey, appSymbol: String) {
        self.init { Text(titleKey) } icon: { Image(appSymbol: appSymbol) }
    }

    @MainActor init<S: StringProtocol>(_ title: S, appSymbol: String) {
        self.init { Text(title) } icon: { Image(appSymbol: appSymbol) }
    }
}
