import Foundation

/// One Mac that syncs, as the pane lists it.
struct SyncDevice: Codable, Sendable, Equatable, Identifiable {
    let id: String
    var name: String
    var appVersion: String
    var lastSeen: Date

    /// Republishing more often than this would rewrite the record on every launch for no reader.
    static let refreshInterval: TimeInterval = 60 * 60

    func isStale(asOf now: Date) -> Bool {
        now.timeIntervalSince(lastSeen) >= Self.refreshInterval
    }
}
