import SwiftUI
import AppKit
import GrokCore

extension ProjectIcon {
    var symbol: String {
        switch self {
        case .folder: return "folder"
        case .book: return "book"
        case .briefcase: return "briefcase"
        case .code: return "chevron.left.forwardslash.chevron.right"
        case .globe: return "globe"
        case .lightbulb: return "lightbulb"
        case .rocket: return "paperplane"
        case .palette: return "paintpalette"
        case .camera: return "camera"
        case .music: return "music.note"
        case .heart: return "heart"
        case .star: return "star"
        case .calendar: return "calendar"
        case .education: return "graduationcap"
        case .science: return "flask"
        case .computer: return "laptopcomputer"
        }
    }

    var label: String {
        let key: String
        switch self {
        case .folder: key = "Folder"
        case .book: key = "Book"
        case .briefcase: key = "Work"
        case .code: key = "Code"
        case .globe: key = "World"
        case .lightbulb: key = "Ideas"
        case .rocket: key = "Rocket"
        case .palette: key = "Art"
        case .camera: key = "Photography"
        case .music: key = "Music"
        case .heart: key = "Heart"
        case .star: key = "Star"
        case .calendar: key = "Calendar"
        case .education: key = "Education"
        case .science: key = "Science"
        case .computer: key = "Computer"
        }
        return L10n.text(key)
    }
}

struct ProjectBadge: View {
    let encoded: String
    private var parts: [Substring] { encoded.split(separator: ":") }
    private var icon: ProjectIcon { parts.count == 3 ? ProjectIcon(rawValue: String(parts[1])) ?? .folder : .folder }
    var body: some View {
        Image(systemName: icon.symbol).foregroundStyle(Color.accentColor).frame(width: 20).accessibilityHidden(true)
    }
}

@MainActor struct CreateProjectSheet: View {
    let projects: ProjectStore
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var description = ""
    @State private var icon = ProjectIcon.book
    @State private var choosingIcon = false
    @FocusState private var nameFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(L10n.text("New project")).font(.title2.weight(.semibold))
            HStack(spacing: 12) {
                Button { choosingIcon.toggle() } label: {
                    Image(systemName: icon.symbol).font(.title2).foregroundStyle(Color.accentColor)
                        .frame(width: 42, height: 42)
                }
                .accessibilityLabel(L10n.text("Project icon"))
                .accessibilityValue(icon.label)
                .popover(isPresented: $choosingIcon) {
                    LazyVGrid(columns: Array(repeating: GridItem(.fixed(40)), count: 4), spacing: 8) {
                        ForEach(ProjectIcon.allCases, id: \.self) { option in
                            Button {
                                icon = option
                                choosingIcon = false
                            } label: {
                                Image(systemName: option.symbol).font(.title3).foregroundStyle(Color.accentColor)
                                    .frame(width: 34, height: 34)
                                    .background(icon == option ? Color.accentColor.opacity(0.2) : .clear, in: RoundedRectangle(cornerRadius: 7))
                            }
                            .buttonStyle(.plain).help(option.label).accessibilityLabel(option.label)
                            .accessibilityAddTraits(icon == option ? .isSelected : [])
                        }
                    }.padding(12)
                }
                TextField(L10n.text("Project name"), text: $name)
                    .textFieldStyle(.roundedBorder).focused($nameFocused)
                    .accessibilityLabel(L10n.text("Project name"))
            }
            .disabled(projects.isCreating)
            VStack(alignment: .leading, spacing: 6) {
                Text(L10n.text("Description")).font(.callout).foregroundStyle(.secondary)
                TextField(L10n.text("What is this project about?"), text: $description, axis: .vertical)
                    .lineLimit(4...6).textFieldStyle(.roundedBorder)
                    .accessibilityLabel(L10n.text("Description"))
            }
            .disabled(projects.isCreating)
            if let error = projects.createError {
                Text(error.message).font(.callout).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Button(L10n.text("Cancel"), role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                    .disabled(projects.isCreating)
                Spacer()
                if projects.isCreating { ProgressView().controlSize(.small) }
                Button(L10n.text("Create project")) {
                    Task {
                        if await projects.create(name: name, description: description, icon: icon) { dismiss() }
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || projects.isBusy)
            }
        }
        .padding(24).frame(width: 420)
        .interactiveDismissDisabled(projects.isCreating)
        .onAppear { projects.clearCreateError(); nameFocused = true }
    }
}

@MainActor struct RenameProjectSheet: View {
    let project: GrokProject
    let projects: ProjectStore
    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @FocusState private var nameFocused: Bool

    init(project: GrokProject, projects: ProjectStore) {
        self.project = project
        self.projects = projects
        _name = State(initialValue: project.name)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(L10n.text("Rename project")).font(.title2.weight(.semibold))
            TextField(L10n.text("Project name"), text: $name)
                .textFieldStyle(.roundedBorder).focused($nameFocused).disabled(projects.isBusy)
            if let error = projects.actionError {
                Text(error.message).font(.callout).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Button(L10n.text("Cancel"), role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction).disabled(projects.isBusy)
                Spacer()
                if projects.updatingProjectID == project.id { ProgressView().controlSize(.small) }
                Button(L10n.text("Save")) {
                    Task { if await projects.rename(id: project.id, name: name) { dismiss() } }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(projects.isBusy || name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(24).frame(width: 400)
        .interactiveDismissDisabled(projects.isBusy)
        .onAppear { projects.clearActionError(); nameFocused = true }
    }
}

/// Native menu rendering retains icons and the destructive action's red tint.
@MainActor struct ProjectContextMenu: NSViewRepresentable {
    let enabled: Bool
    let rename: () -> Void
    let delete: () -> Void

    func makeNSView(context: Context) -> MenuView { MenuView() }
    func updateNSView(_ view: MenuView, context: Context) { view.configuration = self }

    final class MenuView: NSView {
        var configuration: ProjectContextMenu?
        override func hitTest(_ point: NSPoint) -> NSView? {
            guard configuration?.enabled == true, super.hitTest(point) != nil, let event = NSApp.currentEvent else { return nil }
            return event.type == .rightMouseDown || event.type == .rightMouseUp ||
                (event.type == .leftMouseDown && event.modifierFlags.contains(.control)) ? self : nil
        }
        override func rightMouseDown(with event: NSEvent) {
            guard configuration?.enabled == true else { return }
            let menu = NSMenu()
            menu.autoenablesItems = false
            let rename = NSMenuItem(title: L10n.text("Rename"), action: #selector(renameProject), keyEquivalent: "")
            rename.target = self
            rename.image = NSImage(systemSymbolName: "pencil", accessibilityDescription: nil)
            menu.addItem(rename)
            menu.addItem(.separator())
            let deletion = NSMenuItem(title: L10n.text("Delete"), action: #selector(deleteProject), keyEquivalent: "")
            deletion.target = self
            deletion.image = NSImage(systemSymbolName: "trash", accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(paletteColors: [.systemRed]))
            deletion.image?.isTemplate = false
            deletion.attributedTitle = NSAttributedString(string: deletion.title, attributes: [.foregroundColor: NSColor.systemRed])
            menu.addItem(deletion)
            for item in [rename, deletion] {
                item.image?.size = NSSize(width: 16, height: 16)
                if #available(macOS 27.0, *) { item.preferredImageVisibility = .visible }
            }
            NSMenu.popUpContextMenu(menu, with: event, for: self)
        }
        override func mouseDown(with event: NSEvent) {
            if event.modifierFlags.contains(.control) { rightMouseDown(with: event) }
            else { super.mouseDown(with: event) }
        }
        @objc private func renameProject() { configuration?.rename() }
        @objc private func deleteProject() { configuration?.delete() }
    }
}
