import CryptoKit
import Foundation

/// Every kind of record sync writes. A case's name starts each record's, so renaming strands them.
enum SyncRecordKind: String, CaseIterable, Codable, Sendable {
    case setting
    case shortcut
    case favorites
    case alias
    case hiddenItem
    case launcherKinds
    case pinnedEmoji
    case customWindowSize
    case windowLayout
    case room
    case quicklink
    case snippet
    case note
    case aiConnection
    case quickAction
    case customCommand
    case mcpServer
    case installedExtension

    var category: SyncCategory {
        switch self {
        case .setting: .settings
        case .shortcut: .shortcuts
        case .favorites, .alias, .hiddenItem, .launcherKinds, .pinnedEmoji: .launcher
        case .customWindowSize, .windowLayout, .room: .windowManagement
        case .quicklink: .quicklinks
        case .snippet: .snippets
        case .note: .notes
        case .aiConnection, .quickAction: .ai
        case .customCommand: .customCommands
        case .mcpServer: .mcpServers
        case .installedExtension: .extensions
        }
    }

    /// A file's text lives on disk already, so the ledger never keeps a second copy of it.
    var isFileBacked: Bool {
        switch self {
        case .snippet, .note: true
        default: false
        }
    }

    /// The key a kind that holds one whole list stores it under.
    static let wholeListKey = "all"

    /// `kind.key` while the key is short and plain; otherwise a digest, since CloudKit takes ASCII.
    func recordName(for key: String) -> String {
        let plain = key.unicodeScalars.allSatisfy(Self.plainCharacters.contains)
        if plain, !key.isEmpty, rawValue.count + 1 + key.utf8.count <= Self.maximumNameLength {
            return rawValue + "." + key
        }
        let digest = SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined()
        return rawValue + "~" + digest
    }

    private static let maximumNameLength = 255
    private static let plainCharacters = CharacterSet(
        charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.-_")
}
