import CryptoKit
import Foundation

/// What this Mac and iCloud last agreed on, so a relaunch neither re-sends nor misses a change.
struct SyncLedger: Codable, Sendable, Equatable {
    struct Entry: Codable, Sendable, Equatable {
        let kind: SyncRecordKind
        let key: String
        /// This Mac's digest of the record when both sides last matched; nil until they have.
        var agreed: String?
        /// The local digest waiting to reach iCloud, and when this Mac made that change.
        var pending: String?
        var editedAt: Date?
        /// The payload both sides last settled on, so a held record can still be applied later.
        var body: Data?
        /// Waiting until this Mac can take `body`; never sent or deleted from here meanwhile.
        var isHeld = false
        /// The server's system fields, so a save carries the change tag it was based on.
        var systemFields: Data?

        init(kind: SyncRecordKind, key: String) {
            self.kind = kind
            self.key = key
        }
    }

    /// A record this Mac holds right now.
    struct Local: Sendable, Equatable {
        let kind: SyncRecordKind
        let key: String
        let digest: String
    }

    /// Record names to send and to delete, in name order so a run is reproducible.
    struct Changes: Sendable, Equatable {
        var saves: [String] = []
        var deletes: [String] = []
    }

    let deviceID: String
    var firstContact: SyncFirstContact = .preferICloud
    /// `CKSyncEngine`'s own state, opaque here so this file never needs CloudKit.
    var engineState: Data?
    var entries: [String: Entry] = [:]
    /// Deletes not yet confirmed, re-queued on every engine start so a fresh state cannot drop one.
    var pendingDeletes: Set<String> = []
    var devices: [String: SyncDevice] = [:]
    var deviceSystemFields: Data?
    var lastFetch: Date?
    var lastSend: Date?

    init(deviceID: String) {
        self.deviceID = deviceID
    }

    static func digest(_ body: Data) -> String {
        SHA256.hash(data: body).map { String(format: "%02x", $0) }.joined()
    }

    var heldCount: Int { entries.values.count(where: \.isHeld) }

    /// A record gone because this Mac can't hold it (`isAvailable` false) is held, never deleted.
    mutating func reconcile(
        _ current: [String: Local], syncing kinds: Set<SyncRecordKind>, now: Date,
        isAvailable: (Entry) -> Bool
    ) -> Changes {
        var changes = Changes()
        for (name, local) in current where kinds.contains(local.kind) {
            var entry = entries[name] ?? Entry(kind: local.kind, key: local.key)
            guard !entry.isHeld else { continue }
            if entry.agreed == local.digest {
                entry.pending = nil
                entry.editedAt = nil
            } else {
                if entry.pending != local.digest {
                    entry.pending = local.digest
                    entry.editedAt = now
                }
                changes.saves.append(name)
            }
            entries[name] = entry
        }
        for (name, entry) in entries
        where kinds.contains(entry.kind) && current[name] == nil && !entry.isHeld {
            if entry.body == nil || isAvailable(entry) {
                entries[name] = nil
                changes.deletes.append(name)
            } else {
                entries[name]?.isHeld = true
            }
        }
        changes.saves.sort()
        changes.deletes.sort()
        pendingDeletes.subtract(changes.saves)
        pendingDeletes.formUnion(changes.deletes)
        return changes
    }

    /// iCloud took `body`; a later local edit stays pending.
    mutating func didSend(_ name: String, body: Data, systemFields: Data) {
        guard var entry = entries[name] else { return }
        let digest = Self.digest(body)
        entry.agreed = digest
        entry.body = body
        entry.systemFields = systemFields
        if entry.pending == digest {
            entry.pending = nil
            entry.editedAt = nil
        }
        entries[name] = entry
    }

    /// `localDigest` is the store's re-read: agreeing on the payload would echo a normalized one.
    mutating func didApply(
        _ name: String, kind: SyncRecordKind, key: String, body: Data, localDigest: String?,
        systemFields: Data?
    ) {
        guard let localDigest else {
            return hold(name, kind: kind, key: key, body: body, systemFields: systemFields)
        }
        var entry = Entry(kind: kind, key: key)
        entry.agreed = localDigest
        entry.body = body
        entry.systemFields = systemFields
        entries[name] = entry
    }

    mutating func hold(
        _ name: String, kind: SyncRecordKind, key: String, body: Data, systemFields: Data?
    ) {
        var entry = entries[name] ?? Entry(kind: kind, key: key)
        entry.body = body
        entry.isHeld = true
        entry.pending = nil
        entry.editedAt = nil
        entry.systemFields = systemFields
        entries[name] = entry
    }

    /// Turning a category off forgets it, so turning it back on meets iCloud afresh.
    mutating func forget(_ kinds: Set<SyncRecordKind>) {
        entries = entries.filter { !kinds.contains($0.value.kind) }
    }
}

/// Which side wins a key both hold before they have ever agreed on it.
enum SyncFirstContact: String, Codable, Sendable {
    case preferICloud
    case preferThisMac
}
