import SwiftUI
import AppKit
import GrokCore

extension ProjectIcon {
    var label: String {
        let key: String
        switch self {
        case .folder: key = "Folder"
        case .flag: key = "Flag"
        case .home: key = "Home"
        case .star: key = "Star"
        case .heart: key = "Heart"
        case .globe: key = "World"
        case .unlock: key = "Unlocked"
        case .smile: key = "Smile"
        case .shield: key = "Shield"
        case .bell: key = "Bell"
        case .mail: key = "Mail"
        case .phone: key = "Phone"
        case .user: key = "Person"
        case .stethoscope: key = "Health"
        case .calendar: key = "Calendar"
        case .clock: key = "Clock"
        case .hourglass: key = "Hourglass"
        case .sun: key = "Sun"
        case .moon: key = "Moon"
        case .monitor: key = "Monitor"
        case .umbrella: key = "Umbrella"
        case .leaf: key = "Leaf"
        case .bug: key = "Bug"
        case .science: key = "Science"
        case .rocket: key = "Rocket"
        case .plane: key = "Plane"
        case .car: key = "Car"
        case .camera: key = "Photography"
        case .video: key = "Video"
        case .music: key = "Music"
        case .headphones: key = "Headphones"
        case .microscope: key = "Microscope"
        case .archive: key = "Archive"
        case .book: key = "Book"
        case .zap: key = "Lightning"
        case .wrench: key = "Tools"
        case .stickyNote: key = "Note"
        case .scale: key = "Scales"
        case .film: key = "Film"
        case .palette: key = "Art"
        case .cpu: key = "Processor"
        case .calculator: key = "Calculator"
        case .computer: key = "Computer"
        case .briefcase: key = "Work"
        case .clipboardList: key = "Tasks"
        case .building: key = "Building"
        case .flame: key = "Fire"
        case .play: key = "Play"
        case .database: key = "Database"
        case .shirt: key = "Clothing"
        case .gem: key = "Gem"
        case .gamepad: key = "Games"
        case .chefHat: key = "Cooking"
        case .dollarSign: key = "Money"
        case .tag: key = "Tag"
        case .education: key = "Education"
        case .pin: key = "Location"
        case .compass: key = "Compass"
        case .code: key = "Code"
        case .box: key = "Box"
        case .sparkles: key = "Sparkles"
        case .key: key = "Key"
        case .lightbulb: key = "Ideas"
        case .bookmark: key = "Bookmark"
        }
        return L10n.text(key)
    }
}

extension ProjectColor {
    var label: String {
        let key: String
        switch self {
        case .inherit: key = "Inherit"
        case .blue: key = "Blue"
        case .orange: key = "Orange"
        case .pink: key = "Pink"
        case .purple: key = "Purple"
        case .teal: key = "Teal"
        case .red: key = "Red"
        case .green: key = "Green"
        }
        return L10n.text(key)
    }
}

@MainActor extension ProjectIconAppearance {
    var symbol: String {
        let icon: String
        switch name {
        case "highlighter": icon = "folder"
        case "book-open": icon = "book"
        case "palette": icon = "art"
        case "graduation-cap": icon = "education"
        case "flask-conical": icon = "science"
        case "laptop", "laptop-2": icon = "device-laptop"
        case "unlock": icon = "lock-unlocked"
        case "smile": icon = "emoji-smile"
        case "mail": icon = "envelope"
        case "user": icon = "person"
        case "stethoscope": icon = "health"
        case "monitor": icon = "screen"
        case "leaf": icon = "nature"
        case "plane": icon = "travel"
        case "car": icon = "racing-car"
        case "video": icon = "camera-video"
        case "zap": icon = "bolt"
        case "film": icon = "film-roll"
        case "cpu": icon = "technology"
        case "clipboard-list": icon = "clipboard"
        case "building-2": icon = "building"
        case "flame": icon = "fire"
        case "shirt": icon = "fashion"
        case "gem", "diamond": icon = "jewel"
        case "gamepad", "gamepad-2": icon = "gaming"
        case "chef-hat": icon = "food"
        case "dollar-sign": icon = "cash"
        case "tag": icon = "tag-tilt-left"
        case "pin": icon = "location-pin"
        case "compass": icon = "safari"
        case "box": icon = "cube"
        case "music2": icon = "music"
        case "code-2": icon = "code"
        default: icon = name
        }
        let asset = icon.hasPrefix("grok-") ? icon : "grok-\(icon)"
        if AppSymbols.assetName(for: asset) != nil { return asset }
        let fallback: String
        switch name {
        case "archive": fallback = "archivebox"
        case "sticky-note": fallback = "note.text"
        case "scale": fallback = "scalemass"
        case "play": fallback = "play.fill"
        default: fallback = name
        }
        return NSImage(systemSymbolName: fallback, accessibilityDescription: nil) == nil ? "folder" : fallback
    }

    private var tint: NSColor? {
        switch color {
        case "lime", "green": return .systemGreen
        case "red": return .systemRed
        case "orange", "yellow": return .systemOrange
        case "teal": return .systemTeal
        case "blue": return .systemBlue
        case "purple": return .systemPurple
        case "pink": return .systemPink
        default: return nil
        }
    }

    var foreground: Color { tint.map { Color(nsColor: $0) } ?? .primary }

    var menuImage: NSImage? {
        guard let image = AppSymbols.image(symbol) else { return nil }
        let size = NSSize(width: 16, height: 16)
        guard let tint else { image.size = size; return image }
        let colored = NSImage(size: size, flipped: false) { rect in
            image.draw(in: rect)
            tint.setFill()
            rect.fill(using: .sourceAtop)
            return true
        }
        colored.isTemplate = false
        return colored
    }
}

struct ProjectBadge: View {
    let encoded: String
    private var appearance: ProjectIconAppearance { .init(encoded: encoded) }
    var body: some View {
        Image(appSymbol: appearance.symbol).foregroundStyle(appearance.foreground).frame(width: 20).accessibilityHidden(true)
    }
}

@MainActor struct ProjectEditorSheet: View {
    let projects: ProjectStore
    let project: GrokProject?
    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var description: String
    @State private var iconName: String
    @State private var color: String
    @State private var choosingIcon = false
    @FocusState private var nameFocused: Bool

    init(projects: ProjectStore, project: GrokProject? = nil) {
        self.projects = projects
        self.project = project
        let appearance = ProjectIconAppearance(encoded: project?.icon ?? ProjectIcon.book.encodedValue(color: .green))
        _name = State(initialValue: project?.name ?? "")
        _description = State(initialValue: project?.description ?? "")
        _iconName = State(initialValue: ProjectIcon(serverValue: appearance.name)?.rawValue ?? appearance.name)
        _color = State(initialValue: appearance.color)
    }

    private var encodedIcon: String {
        if let project {
            let original = ProjectIconAppearance(encoded: project.icon)
            let originalName = ProjectIcon(serverValue: original.name)?.rawValue ?? original.name
            if iconName == originalName && color == original.color { return project.icon }
        }
        if let icon = ProjectIcon(rawValue: iconName), let color = ProjectColor(serverValue: color) {
            return icon.encodedValue(color: color)
        }
        return "l:\(iconName):\(color)"
    }

    private var appearance: ProjectIconAppearance { .init(encoded: encodedIcon) }
    private var error: DisplayError? { project == nil ? projects.createError : projects.actionError }
    private var isSubmitting: Bool { project == nil ? projects.isCreating : projects.updatingProjectID == project?.id }
    private var hasChanges: Bool {
        guard let project else { return true }
        return name != project.name || description != project.description || encodedIcon != project.icon
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(L10n.text(project == nil ? "New project" : "Edit project")).font(.title2.weight(.semibold))
            HStack(spacing: 12) {
                Button { choosingIcon.toggle() } label: {
                    Image(appSymbol: appearance.symbol).font(.title2).foregroundStyle(appearance.foreground)
                        .frame(width: 42, height: 42)
                }
                .modifier(ProjectGlassButtonStyle())
                .buttonBorderShape(.circle)
                .accessibilityLabel(L10n.text("Project icon"))
                .accessibilityValue(ProjectIcon(serverValue: iconName)?.label ?? L10n.text("Project icon"))
                .popover(isPresented: $choosingIcon) { iconPicker }
                TextField(L10n.text("Project name"), text: $name)
                    .textFieldStyle(.roundedBorder).focused($nameFocused)
                    .accessibilityLabel(L10n.text("Project name"))
            }
            .disabled(projects.isBusy)
            VStack(alignment: .leading, spacing: 8) {
                Text(L10n.text("Project color")).font(.callout).foregroundStyle(.secondary)
                colorPicker
            }
            .disabled(projects.isBusy)
            VStack(alignment: .leading, spacing: 6) {
                Text(L10n.text("Description")).font(.callout).foregroundStyle(.secondary)
                TextField(L10n.text("What is this project about?"), text: $description, axis: .vertical)
                    .lineLimit(4...6).textFieldStyle(.roundedBorder)
                    .accessibilityLabel(L10n.text("Description"))
            }
            .disabled(projects.isBusy)
            if let error {
                Text(error.message).font(.callout).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Button(L10n.text("Cancel"), role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                    .modifier(ProjectGlassButtonStyle()).buttonBorderShape(.capsule)
                    .disabled(isSubmitting)
                Spacer()
                if isSubmitting { ProgressView().controlSize(.small) }
                Button(L10n.text(project == nil ? "Create project" : "Save"), action: submit)
                    .modifier(ProjectGlassButtonStyle(prominent: true)).buttonBorderShape(.capsule)
                    .keyboardShortcut(.defaultAction)
                    .disabled(projects.isBusy || name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !hasChanges)
            }
        }
        .padding(24).frame(width: 440)
        .interactiveDismissDisabled(isSubmitting)
        .onAppear {
            if project == nil { projects.clearCreateError() } else { projects.clearActionError() }
            nameFocused = true
        }
    }

    private var iconPicker: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVGrid(columns: Array(repeating: GridItem(.fixed(36)), count: 8), spacing: 6) {
                    ForEach(ProjectIcon.allCases, id: \.self) { option in
                        let preview = ProjectIconAppearance(encoded: option.encodedValue(color: ProjectColor(serverValue: color) ?? .inherit))
                        Button {
                            iconName = option.rawValue
                            choosingIcon = false
                        } label: {
                            Image(appSymbol: preview.symbol).font(.title3).foregroundStyle(preview.foreground)
                                .frame(width: 24, height: 24)
                        }
                        .modifier(ProjectGlassButtonStyle()).buttonBorderShape(.circle).controlSize(.small)
                        .frame(width: 36, height: 36)
                        .overlay(Circle().strokeBorder(preview.foreground.opacity(iconName == option.rawValue ? 0.65 : 0), lineWidth: 2)
                            .allowsHitTesting(false))
                        .help(option.label).accessibilityLabel(option.label)
                        .accessibilityAddTraits(iconName == option.rawValue ? .isSelected : [])
                        .id(option.rawValue)
                    }
                }.padding(12)
            }
            .frame(width: 354, height: 300)
            .onAppear { proxy.scrollTo(iconName, anchor: .center) }
        }
    }

    private var colorPicker: some View {
        HStack(spacing: 8) {
            ForEach(ProjectColor.allCases, id: \.self) { option in
                let selected = ProjectColor(serverValue: color) == option
                let preview = ProjectIconAppearance(encoded: "l:folder:\(option.rawValue)")
                Button { color = option.rawValue } label: {
                    Group {
                        if option == .inherit {
                            Image(appSymbol: "circle.lefthalf.filled").font(.system(size: 24)).foregroundStyle(.primary)
                        } else {
                            Circle().fill(preview.foreground).frame(width: 24, height: 24)
                        }
                    }
                    .frame(width: 24, height: 24)
                    .contentShape(Circle())
                }
                .modifier(ProjectGlassButtonStyle()).buttonBorderShape(.circle).controlSize(.small)
                .frame(width: 36, height: 36)
                .overlay(Circle().strokeBorder(.primary.opacity(selected ? 0.65 : 0), lineWidth: 2)
                    .allowsHitTesting(false))
                .help(option.label)
                .accessibilityLabel(L10n.format("Project color: %@", option.label))
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
    }

    private func submit() {
        Task {
            let success: Bool
            if let project {
                success = await projects.edit(id: project.id, name: name, description: description, icon: encodedIcon)
            } else {
                guard let icon = ProjectIcon(rawValue: iconName), let color = ProjectColor(serverValue: color) else { return }
                success = await projects.create(name: name, description: description, icon: icon, color: color)
            }
            if success { dismiss() }
        }
    }
}

private struct ProjectGlassButtonStyle: ViewModifier {
    var prominent = false

    @ViewBuilder func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            if prominent { content.buttonStyle(.glassProminent) }
            else { content.buttonStyle(.glass) }
        } else {
            if prominent { content.buttonStyle(.borderedProminent) }
            else { content.buttonStyle(.bordered) }
        }
    }
}


/// Native menu rendering retains icons and the destructive action's red tint.
@MainActor struct ProjectContextMenu: NSViewRepresentable {
    let enabled: Bool
    let edit: () -> Void
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
            let edit = NSMenuItem(title: L10n.text("Edit"), action: #selector(editProject), keyEquivalent: "")
            edit.target = self
            edit.image = AppSymbols.image("pencil", accessibilityDescription: nil)
            menu.addItem(edit)
            menu.addItem(.separator())
            let deletion = NSMenuItem(title: L10n.text("Delete"), action: #selector(deleteProject), keyEquivalent: "")
            deletion.target = self
            deletion.image = AppSymbols.image("trash", accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(paletteColors: [.systemRed]))
            deletion.image?.isTemplate = false
            deletion.attributedTitle = NSAttributedString(string: deletion.title, attributes: [.foregroundColor: NSColor.systemRed])
            menu.addItem(deletion)
            for item in [edit, deletion] {
                item.image?.size = NSSize(width: 16, height: 16)
                if #available(macOS 27.0, *) { item.preferredImageVisibility = .visible }
            }
            NSMenu.popUpContextMenu(menu, with: event, for: self)
        }
        override func mouseDown(with event: NSEvent) {
            if event.modifierFlags.contains(.control) { rightMouseDown(with: event) }
            else { super.mouseDown(with: event) }
        }
        @objc private func editProject() { configuration?.edit() }
        @objc private func deleteProject() { configuration?.delete() }
    }
}
