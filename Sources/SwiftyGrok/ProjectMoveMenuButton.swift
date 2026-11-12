import AppKit
import SwiftUI
import GrokCore

/// A native pull-down button owns its menu, including project images and actions.
@MainActor struct ProjectMoveMenuButton: NSViewRepresentable {
    let conversationID: String
    let projects: [GrokProject]
    let move: (String) -> Void
    @Environment(\.isEnabled) private var isEnabled

    func makeNSView(context: Context) -> MenuButton { MenuButton() }

    func updateNSView(_ button: MenuButton, context: Context) {
        button.configure(conversationID: conversationID, projects: projects, enabled: isEnabled, move: move)
    }

    static func dismantleNSView(_ button: MenuButton, coordinator: ()) {
        button.isEnabled = false
        button.menu?.cancelTracking()
    }

    final class MenuButton: NSPopUpButton, NSMenuDelegate {
        private var conversationID = ""
        private var projects: [GrokProject] = []
        private var move: ((String) -> Void)?
        private var menuConversationID: String?

        init() {
            super.init(frame: .zero, pullsDown: true)
            bezelStyle = .toolbar
            imagePosition = .imageOnly
            preferredEdge = .minY
            autoenablesItems = false
            let title = L10n.text("Move to project")
            toolTip = title
            setAccessibilityLabel(title)
            setAccessibilityIdentifier("swiftygrok.moveToProject")
            let menu = NSMenu(title: title)
            menu.autoenablesItems = false
            menu.delegate = self
            // Pull-down buttons use the first item as their static label and
            // omit it from the choices, including on macOS 14.
            let label = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            label.image = AppSymbols.image("folder.badge.plus", accessibilityDescription: title)
            label.image?.size = NSSize(width: 16, height: 16)
            menu.addItem(label)
            self.menu = menu
            sizeToFit()
        }

        required init?(coder: NSCoder) { nil }

        func configure(conversationID: String, projects: [GrokProject], enabled: Bool, move: @escaping (String) -> Void) {
            self.conversationID = conversationID
            self.projects = projects
            self.move = move
            isEnabled = enabled && !projects.isEmpty
        }

        func menuNeedsUpdate(_ menu: NSMenu) {
            guard menu === self.menu else { return }
            menuConversationID = conversationID
            while menu.numberOfItems > 1 { menu.removeItem(at: menu.numberOfItems - 1) }
            for project in projects {
                let item = NSMenuItem(title: project.name, action: #selector(moveProject(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = project.id
                item.image = ProjectIconAppearance(encoded: project.icon).menuImage
                item.isEnabled = isEnabled
                if #available(macOS 27.0, *) { item.preferredImageVisibility = .visible }
                menu.addItem(item)
            }
        }

        @objc private func moveProject(_ item: NSMenuItem) {
            guard isEnabled, menuConversationID == conversationID,
                  item.menu === menu, let id = item.representedObject as? String,
                  projects.contains(where: { $0.id == id }) else { return }
            move?(id)
        }
    }
}
