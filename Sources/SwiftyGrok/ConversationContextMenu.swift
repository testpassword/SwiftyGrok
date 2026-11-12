import AppKit
import SwiftUI
import GrokCore

/// AppKit preserves menu item images and destructive colors on macOS.
/// Only secondary clicks are intercepted; ordinary row selection stays in SwiftUI.
@MainActor struct ConversationContextMenu: NSViewRepresentable {
    let pinned: Bool
    let enabled: Bool
    let sharingEnabled: Bool
    let projects: [GrokProject]
    let moveEnabled: Bool
    let move: (String) -> Void
    let removeFromProject: (() -> Void)?
    let pin: () -> Void
    let rename: () -> Void
    let openInBrowser: () -> Void
    let share: () -> Void
    let delete: () -> Void

    func makeNSView(context: Context) -> MenuView { MenuView() }
    func updateNSView(_ view: MenuView, context: Context) {
        view.configuration = self
    }

    final class MenuView: NSView {
        var configuration: ConversationContextMenu?

        override func hitTest(_ point: NSPoint) -> NSView? {
            guard configuration?.enabled == true, super.hitTest(point) != nil, let event = NSApp.currentEvent else { return nil }
            let secondary = event.type == .rightMouseDown || event.type == .rightMouseUp ||
                (event.type == .leftMouseDown && event.modifierFlags.contains(.control))
            return secondary ? self : nil
        }

        override func rightMouseDown(with event: NSEvent) {
            guard let configuration, configuration.enabled else { return }
            let menu = NSMenu()
            menu.autoenablesItems = false
            menu.addItem(item(configuration.pinned ? L10n.text("Unpin") : L10n.text("Pin"),
                              symbol: configuration.pinned ? "pin.slash" : "pin", action: #selector(pinChat)))
            menu.addItem(item(L10n.text("Rename"), symbol: "pencil", action: #selector(renameChat)))
            menu.addItem(.separator())
            menu.addItem(item(L10n.text("Browser"), symbol: "safari", action: #selector(openChatInBrowser)))
            let sharing = item(L10n.text("Share"), symbol: "square.and.arrow.up", action: #selector(shareChat))
            sharing.isEnabled = configuration.sharingEnabled
            menu.addItem(sharing)
            if !configuration.projects.isEmpty {
                let move = item(L10n.text("Move to project"), symbol: "folder.badge.plus", action: #selector(moveChat(_:)))
                let submenu = NSMenu()
                submenu.autoenablesItems = false
                for project in configuration.projects {
                    let target = item(project.name, symbol: "folder", action: #selector(moveChat(_:)))
                    target.representedObject = project.id
                    target.image = ProjectIconAppearance(encoded: project.icon).menuImage
                    target.isEnabled = configuration.moveEnabled
                    submenu.addItem(target)
                }
                move.submenu = submenu
                move.isEnabled = configuration.moveEnabled
                menu.addItem(move)
            }
            if configuration.removeFromProject != nil {
                let removal = item(L10n.text("Remove from project"), symbol: "folder.badge.minus", action: #selector(removeChatFromProject))
                removal.isEnabled = configuration.moveEnabled
                menu.addItem(removal)
            }
            menu.addItem(.separator())
            let deletion = item(L10n.text("Delete"), symbol: "trash", action: #selector(deleteChat))
            deletion.attributedTitle = NSAttributedString(string: deletion.title, attributes: [.foregroundColor: NSColor.systemRed])
            if let image = deletion.image {
                let colored = NSImage(size: image.size, flipped: false) { rect in
                    image.draw(in: rect)
                    NSColor.systemRed.setFill()
                    rect.fill(using: .sourceAtop)
                    return true
                }
                colored.isTemplate = false
                deletion.image = colored
            }
            menu.addItem(deletion)
            NSMenu.popUpContextMenu(menu, with: event, for: self)
        }

        override func mouseDown(with event: NSEvent) {
            if event.modifierFlags.contains(.control) { rightMouseDown(with: event) }
            else { super.mouseDown(with: event) }
        }

        private func item(_ title: String, symbol: String, action: Selector) -> NSMenuItem {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self
            item.image = AppSymbols.image(symbol, accessibilityDescription: title)
            item.image?.size = NSSize(width: 16, height: 16)
            if #available(macOS 27.0, *) { item.preferredImageVisibility = .visible }
            return item
        }

        @objc private func pinChat() { configuration?.pin() }
        @objc private func renameChat() { configuration?.rename() }
        @objc private func openChatInBrowser() { configuration?.openInBrowser() }
        @objc private func shareChat() {
            let share = configuration?.share
            // Finish closing the native context menu before showing a popover.
            DispatchQueue.main.async { share?() }
        }
        @objc private func removeChatFromProject() {
            guard configuration?.moveEnabled == true else { return }
            configuration?.removeFromProject?()
        }
        @objc private func moveChat(_ sender: NSMenuItem) {
            guard configuration?.moveEnabled == true, let id = sender.representedObject as? String,
                  configuration?.projects.contains(where: { $0.id == id }) == true else { return }
            configuration?.move(id)
        }
        @objc private func deleteChat() { configuration?.delete() }
    }
}
