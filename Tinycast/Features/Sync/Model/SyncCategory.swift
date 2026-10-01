import Foundation

/// One switch in the iCloud Sync pane; `descriptor` is exhaustive, as `BackupCategory`'s is.
enum SyncCategory: String, CaseIterable, Identifiable, Sendable {
    case settings
    case shortcuts
    case launcher
    case windowManagement

    var id: Self { self }

    struct Descriptor: Sendable {
        let label: String
        let detail: String
    }

    var descriptor: Descriptor {
        switch self {
        case .settings:
            return .init(label: "Settings", detail: "Preferences from every pane")
        case .shortcuts:
            return .init(label: "Shortcuts", detail: "Global and per-item shortcuts")
        case .launcher:
            return .init(
                label: "Launcher", detail: "Favorites, aliases, hidden items and pinned emoji")
        case .windowManagement:
            return .init(label: "Window Management", detail: "Custom sizes, layouts and rooms")
        }
    }

    /// Declaration order, so the pane and the stored selection always list the same way.
    static func ordered(_ selection: Set<SyncCategory>) -> [SyncCategory] {
        allCases.filter(selection.contains)
    }
}
