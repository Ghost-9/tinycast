import CloudKit

/// `CKRecord` in and out. Every user field goes in `encryptedValues`, so iCloud stores ciphertext.
enum CloudSyncRecords {
    static let itemType = "SyncItem"
    static let deviceType = "SyncDevice"
    static let devicePrefix = "device."

    struct Item {
        let kind: SyncRecordKind
        let key: String
        let body: Data
        let editedAt: Date?
    }

    static func item(
        id: CKRecord.ID, systemFields: Data?, kind: SyncRecordKind, key: String, body: Data,
        editedAt: Date, deviceID: String
    ) -> CKRecord {
        let record = record(type: itemType, id: id, systemFields: systemFields)
        record.encryptedValues[Field.kind] = kind.rawValue
        record.encryptedValues[Field.key] = key
        record.encryptedValues[Field.body] = body
        record.encryptedValues[Field.editedAt] = editedAt
        record.encryptedValues[Field.deviceID] = deviceID
        return record
    }

    static func item(from record: CKRecord) -> Item? {
        guard record.recordType == itemType,
            let kind = (record.encryptedValues[Field.kind] as String?).flatMap(SyncRecordKind.init),
            let key = record.encryptedValues[Field.key] as String?,
            let body = record.encryptedValues[Field.body] as Data?
        else { return nil }
        let editedAt = record.encryptedValues[Field.editedAt] as Date?
        return Item(kind: kind, key: key, body: body, editedAt: editedAt)
    }

    static func deviceRecordID(_ deviceID: String, zoneID: CKRecordZone.ID) -> CKRecord.ID {
        CKRecord.ID(recordName: devicePrefix + deviceID, zoneID: zoneID)
    }

    /// The device a record name points at, or nil for an item.
    static func deviceID(of recordID: CKRecord.ID) -> String? {
        let name = recordID.recordName
        guard name.hasPrefix(devicePrefix) else { return nil }
        return String(name.dropFirst(devicePrefix.count))
    }

    static func device(
        _ device: SyncDevice, zoneID: CKRecordZone.ID, systemFields: Data?
    ) -> CKRecord {
        let id = deviceRecordID(device.id, zoneID: zoneID)
        let record = record(type: deviceType, id: id, systemFields: systemFields)
        record.encryptedValues[Field.name] = device.name
        record.encryptedValues[Field.appVersion] = device.appVersion
        record.encryptedValues[Field.lastSeen] = device.lastSeen
        return record
    }

    static func device(from record: CKRecord) -> SyncDevice? {
        guard record.recordType == deviceType, let id = deviceID(of: record.recordID),
            let name = record.encryptedValues[Field.name] as String?,
            let lastSeen = record.encryptedValues[Field.lastSeen] as Date?
        else { return nil }
        return SyncDevice(
            id: id, name: name,
            appVersion: record.encryptedValues[Field.appVersion] as String? ?? "",
            lastSeen: lastSeen)
    }

    static func systemFields(of record: CKRecord) -> Data {
        let coder = NSKeyedArchiver(requiringSecureCoding: true)
        record.encodeSystemFields(with: coder)
        coder.finishEncoding()
        return coder.encodedData
    }

    /// Rebuilt from saved system fields, so the save carries the change tag CloudKit expects.
    private static func record(type: String, id: CKRecord.ID, systemFields: Data?) -> CKRecord {
        guard let systemFields, let coder = try? NSKeyedUnarchiver(forReadingFrom: systemFields)
        else { return CKRecord(recordType: type, recordID: id) }
        coder.requiresSecureCoding = true
        defer { coder.finishDecoding() }
        guard let record = CKRecord(coder: coder), record.recordID == id else {
            return CKRecord(recordType: type, recordID: id)
        }
        return record
    }

    private enum Field {
        static let kind = "kind"
        static let key = "key"
        static let body = "body"
        static let editedAt = "editedAt"
        static let deviceID = "deviceID"
        static let name = "name"
        static let appVersion = "appVersion"
        static let lastSeen = "lastSeen"
    }
}
