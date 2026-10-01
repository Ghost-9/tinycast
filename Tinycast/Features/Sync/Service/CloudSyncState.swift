import Foundation

/// What the iCloud Sync pane shows; the manager writes it, and nothing here is persisted.
@MainActor
@Observable
final class CloudSyncState {
    enum Availability: Equatable, Sendable {
        case off
        case checking
        case noAccount
        case restricted
        case available
    }

    /// Fixed at launch: only a build signed for the container can sync at all.
    let isSupported: Bool
    var availability: Availability = .off
    var isSyncing = false
    var lastFetch: Date?
    var lastSend: Date?
    var devices: [SyncDevice] = []
    var thisDeviceID: String?
    var heldCount = 0
    var lastError: String?

    init(isSupported: Bool) {
        self.isSupported = isSupported
    }
}
