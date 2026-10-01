import Foundation

/// One record kind, bound to the store holding it; the sync counterpart of `SettingsFileBinding`.
@MainActor
struct SyncBinding {
    let kind: SyncRecordKind
    /// Every record this Mac holds, by key. It runs under observation, so an edit schedules a sync.
    let read: () -> [String: Data]
    /// Returns false to hold the record: this Mac cannot take it yet, and keeps what it has.
    let write: (_ key: String, _ body: Data) -> Bool
    let remove: (_ key: String) -> Void
    /// False when a missing record names something this Mac lacks, rather than one removed here.
    let isAvailable: (_ key: String) -> Bool

    init(
        kind: SyncRecordKind, read: @escaping () -> [String: Data],
        write: @escaping (_ key: String, _ body: Data) -> Bool,
        remove: @escaping (_ key: String) -> Void,
        isAvailable: @escaping (_ key: String) -> Bool = { _ in true }
    ) {
        self.kind = kind
        self.read = read
        self.write = write
        self.remove = remove
        self.isAvailable = isAvailable
    }

    /// Sorted keys, so the same value always encodes to the same bytes and digest.
    static func encode(_ value: some Encodable) -> Data? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return try? encoder.encode(value)
    }

    static func decode<Value: Decodable>(_ type: Value.Type, from body: Data) -> Value? {
        try? JSONDecoder().decode(type, from: body)
    }
}
