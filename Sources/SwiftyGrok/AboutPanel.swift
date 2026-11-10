import AppKit
import GrokCore

@MainActor enum AboutPanel {
    private static let repositoryURL = URL(string: "https://github.com/testpassword/SwiftyGrok")!

    static func show() {
        var options: [NSApplication.AboutPanelOptionKey: Any] = [
            .applicationName: "SwiftyGrok",
            .applicationVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.5.0",
            .version: Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "90",
            .credits: credits
        ]
        if let icon = ApplicationIcon.current { options[.applicationIcon] = icon }
        NSApp.orderFrontStandardAboutPanel(options: options)
        NSApp.activate(ignoringOtherApps: true)
    }

    private static var credits: NSAttributedString {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        paragraph.lineSpacing = 3
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize),
            .foregroundColor: NSColor.secondaryLabelColor,
            .paragraphStyle: paragraph
        ]
        let body = NSMutableAttributedString(string: "")
        func append(_ text: String, link: URL? = nil) {
            var style = attributes
            if let link {
                style[.link] = link
                style[.foregroundColor] = NSColor.linkColor
                style[.underlineStyle] = NSUnderlineStyle.single.rawValue
            }
            body.append(NSAttributedString(string: text, attributes: style))
        }
        append(L10n.text("A native, unofficial Grok client for macOS: chats, files, and quick input."))
        append("\n\n")
        append(L10n.text("GitHub Repository"), link: repositoryURL)
        append("\n\n")
        append(L10n.text("Third-party components"))
        append("\n")
        append("swift-grok", link: URL(string: "https://github.com/0xSMW/swift-grok")!)
        append(" · MIT\n")
        append("SwiftMath", link: URL(string: "https://github.com/mgriebling/SwiftMath")!)
        append(" · MIT\n")
        append("Devicon", link: URL(string: "https://github.com/devicons/devicon")!)
        append(" · MIT\n")
        append(L10n.text("Math fonts"), link: URL(string: "https://github.com/mgriebling/SwiftMath/tree/HEAD/Sources/SwiftMath/mathFonts.bundle")!)
        append(" · GUST / SIL OFL\n")
        append(L10n.text("Grok artwork"), link: URL(string: "https://x.ai/")!)
        append(" · xAI\n\n")
        append(L10n.text("Notices and licenses"), link: repositoryURL.appendingPathComponent("blob/HEAD/THIRD_PARTY_NOTICES.md"))
        return body
    }
}
