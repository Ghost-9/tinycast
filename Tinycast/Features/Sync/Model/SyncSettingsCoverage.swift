import Foundation

/// Which settings.json keys sync, written out so a new key has to be considered.
enum SyncSettingsCoverage {
    /// Keys a record kind of their own carries item by item, so the list would only duplicate it.
    static let carriedByRecords: [SettingsFileKey: SyncRecordKind] = [
        .windowShortcuts: .shortcut,
        .customWindowSizes: .customWindowSize,
        .windowLayouts: .windowLayout,
        .windowRooms: .room
    ]

    /// Keys that stay on this Mac, each with the reason.
    static let local: [SettingsFileKey: String] = [
        .notesFolder: "Names a folder on this Mac; another Mac may not have it.",
        .snippetsFolder: "Names a folder on this Mac; another Mac may not have it.",
        .autoSwitchInputSource: "Names an input source installed on this Mac; another may lack it.",
        .meetingBrowser: "Names a browser installed on this Mac; another Mac may not have it."
    ]

    static func syncs(_ key: SettingsFileKey) -> Bool {
        carriedByRecords[key] == nil && local[key] == nil
    }
}
