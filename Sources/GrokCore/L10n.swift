import Foundation

/// Shared by SwiftUI, AppKit and core errors. Bundle selects the system's
/// preferred supported language; the package development language is English.
public enum L10n {
    public static func text(_ key: String) -> String {
        NSLocalizedString(key, bundle: .module, comment: "")
    }

    public static func format(_ key: String, _ arguments: CVarArg...) -> String {
        String(format: text(key), locale: Locale.current, arguments: arguments)
    }
}
