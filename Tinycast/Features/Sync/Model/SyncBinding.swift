import Foundation

/// One record kind, bound to the store holding it; the sync counterpart of `SettingsFileBinding`.
@MainActor
struct SyncBinding {
    let kind: SyncRecordKind
    /// Touches each value `read` depends on; it runs under observation, so an edit schedules sync.
    let observe: () -> Void
    /// Every record this Mac holds, by key; nil while its store hasn't loaded, skipping the pass.
    let read: () async -> [String: SyncPayload]?
    /// Returns false to hold the record: this Mac cannot take it yet, and keeps what it has.
    let write: (_ key: String, _ payload: SyncPayload) async -> Bool
    let remove: (_ key: String) async -> Void
    /// False when a missing record names something this Mac lacks, rather than one removed here.
    let isAvailable: (_ key: String) -> Bool
    /// Where the records come from; when it moves, the kind meets iCloud afresh instead of diffing.
    let scope: (() -> String)?
    /// Saves a rival version beside the original, for a kind where neither side may lose its text.
    let keepCopy: ((_ key: String, _ body: Data) async -> Bool)?

    init(
        kind: SyncRecordKind, observe: @escaping () -> Void,
        read: @escaping () async -> [String: SyncPayload]?,
        write: @escaping (_ key: String, _ payload: SyncPayload) async -> Bool,
        remove: @escaping (_ key: String) async -> Void,
        isAvailable: @escaping (_ key: String) -> Bool = { _ in true },
        scope: (() -> String)? = nil,
        keepCopy: ((_ key: String, _ body: Data) async -> Bool)? = nil
    ) {
        self.kind = kind
        self.observe = observe
        self.read = read
        self.write = write
        self.remove = remove
        self.isAvailable = isAvailable
        self.scope = scope
        self.keepCopy = keepCopy
    }

    /// A store held in memory, cheap enough to read that reading it is also observing it.
    init(
        kind: SyncRecordKind, read: @escaping () -> [String: Data]?,
        write: @escaping (_ key: String, _ body: Data) -> Bool,
        remove: @escaping (_ key: String) -> Void,
        isAvailable: @escaping (_ key: String) -> Bool = { _ in true }
    ) {
        self.init(
            kind: kind, observe: { _ = read() },
            read: { read()?.mapValues { SyncPayload(body: $0) } },
            write: { write($0, $1.body) }, remove: { remove($0) }, isAvailable: isAvailable)
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
