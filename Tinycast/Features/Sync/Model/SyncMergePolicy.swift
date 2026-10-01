import Foundation

/// Who wins when iCloud brings a record this Mac has also changed.
enum SyncMergePolicy {
    enum Decision: Equatable, Sendable {
        case takeServer
        case keepLocal
    }

    static func decide(
        local entry: SyncLedger.Entry?, serverEditedAt: Date?, firstContact: SyncFirstContact
    ) -> Decision {
        guard let entry, entry.pending != nil, !entry.isHeld else { return .takeServer }
        guard entry.agreed != nil else {
            return firstContact == .preferThisMac ? .keepLocal : .takeServer
        }
        guard let editedAt = entry.editedAt, let serverEditedAt else { return .takeServer }
        return editedAt > serverEditedAt ? .keepLocal : .takeServer
    }
}
