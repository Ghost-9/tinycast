import Foundation

/// Everything in Tinycast a global shortcut can be bound to.
enum HotKeyAction: Hashable, Sendable {
    /// The one fixed action with no command row of its own.
    case togglePalette
    /// Parameterised over the catalog, so a new built-in command is bindable with no case here.
    case command(CommandID)
    case app(bundleID: String)
    case settingsPane(bundleID: String)
    case customCommand(id: UUID)
    case systemAction(id: SystemAction.ID)
    case windowCommand(id: WindowCommand.ID)
    case windowLayout(id: UUID)
    case windowRoom(id: UUID)
    case customWindowSize(id: UUID)
    case quicklink(id: UUID)
    case quickAction(id: UUID)
    case appleShortcut(id: UUID)
    case snippet(id: StoredSnippet.ID)
    /// Keyed by `AppEntry.id`, which is what survives a reinstall of the extension.
    case extensionCommand(entryID: String)

    /// The UserDefaults key, and the `HotKeyCenter` registration id: one per action.
    var defaultsKey: String {
        switch self {
        case .togglePalette: "hotkey.togglePalette"
        case .command(let id): "hotkey." + id.rawValue
        case .app(let bundleID): "hotkey.app." + bundleID
        case .settingsPane(let bundleID): "hotkey.pane." + bundleID
        case .customCommand(let id): "hotkey.customCommand." + id.uuidString.lowercased()
        case .systemAction(let id): "hotkey.systemAction." + id.rawValue
        case .windowCommand(let id): "hotkey.windowCommand." + id.rawValue
        case .windowLayout(let id): "hotkey.windowLayout." + id.uuidString.lowercased()
        case .windowRoom(let id): "hotkey.windowRoom." + id.uuidString.lowercased()
        case .customWindowSize(let id):
            "hotkey.customWindowSize." + id.uuidString.lowercased()
        case .quicklink(let id): "hotkey.quicklink." + id.uuidString.lowercased()
        case .quickAction(let id): "hotkey.quickAction." + id.uuidString.lowercased()
        case .appleShortcut(let id): "hotkey.appleShortcut." + id.uuidString.lowercased()
        case .snippet(let id): "hotkey.snippet." + id
        case .extensionCommand(let entryID): "hotkey.extensionCommand." + entryID
        }
    }

    /// `defaultsKey` read back, for a store that keeps only the key.
    init?(defaultsKey: String) {
        let prefix = "hotkey."
        guard defaultsKey.hasPrefix(prefix) else { return nil }
        let rest = String(defaultsKey.dropFirst(prefix.count))
        if rest == "togglePalette" {
            self = .togglePalette
            return
        }
        // Before the namespaces: a command's raw value is matched whole, dots and all.
        if let id = CommandID(rawValue: rest) {
            self = .command(id)
            return
        }
        guard let dot = rest.firstIndex(of: ".") else { return nil }
        let namespace = String(rest[..<dot])
        let value = String(rest[rest.index(after: dot)...])
        if let make = Self.byUUID[namespace] {
            guard let id = UUID(uuidString: value) else { return nil }
            self = make(id)
            return
        }
        switch namespace {
        case "app": self = .app(bundleID: value)
        case "pane": self = .settingsPane(bundleID: value)
        case "snippet": self = .snippet(id: value)
        case "extensionCommand": self = .extensionCommand(entryID: value)
        case "systemAction":
            guard let id = SystemAction.ID(rawValue: value) else { return nil }
            self = .systemAction(id: id)
        case "windowCommand":
            guard let id = WindowCommand.ID(rawValue: value) else { return nil }
            self = .windowCommand(id: id)
        default:
            return nil
        }
    }

    private static let byUUID: [String: @Sendable (UUID) -> HotKeyAction] = [
        "customCommand": { .customCommand(id: $0) },
        "windowLayout": { .windowLayout(id: $0) },
        "windowRoom": { .windowRoom(id: $0) },
        "customWindowSize": { .customWindowSize(id: $0) },
        "quicklink": { .quicklink(id: $0) },
        "quickAction": { .quickAction(id: $0) },
        "appleShortcut": { .appleShortcut(id: $0) }
    ]

    /// The fixed actions every install can bind; the per-item catalogs extend them at launch.
    static let builtInActions: [HotKeyAction] =
        [.togglePalette] + CommandID.allCases.compactMap(\.hotKeyAction)
}
