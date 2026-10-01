import Foundation

/// One switch in the iCloud Sync pane; `descriptor` is exhaustive, as `BackupCategory`'s is.
enum SyncCategory: String, CaseIterable, Identifiable, Sendable {
    case settings
    case shortcuts
    case launcher
    case quicklinks
    case snippets
    case notes
    case windowManagement
    case ai
    case customCommands
    case mcpServers
    case extensions

    var id: Self { self }

    struct Descriptor: Sendable {
        let label: String
        let detail: String
        /// What switching it on lets another Mac do to this one; set only where that runs code.
        let consent: String?
    }

    var descriptor: Descriptor {
        switch self {
        case .settings:
            return .init(label: "Settings", detail: "Preferences from every pane", consent: nil)
        case .shortcuts:
            return .init(label: "Shortcuts", detail: "Global and per-item shortcuts", consent: nil)
        case .launcher:
            return .init(
                label: "Launcher", detail: "Favorites, aliases, hidden items and pinned emoji",
                consent: nil)
        case .quicklinks:
            return .init(label: "Quicklinks", detail: "Every quicklink", consent: nil)
        case .snippets:
            return .init(
                label: "Snippets", detail: "The files in your snippets folder", consent: nil)
        case .notes:
            return .init(label: "Notes", detail: "The files in your notes folder", consent: nil)
        case .windowManagement:
            return .init(
                label: "Window Management", detail: "Custom sizes, layouts and rooms",
                consent: nil)
        case .ai:
            return .init(
                label: "AI", detail: "API connections and custom quick actions", consent: nil)
        case .customCommands:
            return .init(
                label: "Custom Commands", detail: "Your shell commands",
                consent: "Custom commands from your other Macs can run shell commands on this one.")
        case .mcpServers:
            return .init(
                label: "MCP Servers", detail: "Servers your AI chats can call",
                consent: "MCP servers from your other Macs can start programs on this one.")
        case .extensions:
            return .init(
                label: "Extensions", detail: "Installs, uninstalls and preferences",
                consent: "Extensions installed on your other Macs are installed and run here too.")
        }
    }

    /// What sync starts with: every category that asks nothing, since the rest each ask first.
    static let defaultSelection = Set(allCases.filter { $0.descriptor.consent == nil })

    /// Declaration order, so the pane and the stored selection always list the same way.
    static func ordered(_ selection: Set<SyncCategory>) -> [SyncCategory] {
        allCases.filter(selection.contains)
    }
}
