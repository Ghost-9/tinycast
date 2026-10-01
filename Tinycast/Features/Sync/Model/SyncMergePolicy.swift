import Foundation

/// Who wins when iCloud brings a record this Mac has also changed.
enum SyncMergePolicy {
    enum Decision: Equatable, Sendable {
        case takeServer
        case keepLocal
        /// The local version stays, and the server's is saved beside it.
        case keepBoth
    }

    /// `keepsBoth` is for text a person wrote, where losing either side's edit is never right.
    static func decide(
        local entry: SyncLedger.Entry?, serverDigest: String, serverEditedAt: Date?,
        firstContact: SyncFirstContact, keepsBoth: Bool
    ) -> Decision {
        guard let entry, let pending = entry.pending, !entry.isHeld, pending != serverDigest else {
            return .takeServer
        }
        if keepsBoth { return .keepBoth }
        guard entry.agreed != nil else {
            return firstContact == .preferThisMac ? .keepLocal : .takeServer
        }
        guard let editedAt = entry.editedAt, let serverEditedAt else { return .takeServer }
        return editedAt > serverEditedAt ? .keepLocal : .takeServer
    }
}
