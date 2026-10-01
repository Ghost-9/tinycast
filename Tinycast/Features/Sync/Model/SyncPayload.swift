import CryptoKit
import Foundation

/// One record's content; `secrets` is sent and compared, but never written into the ledger on disk.
struct SyncPayload: Sendable, Equatable {
    var body: Data
    var secrets: Data?

    init(body: Data, secrets: Data? = nil) {
        self.body = body
        self.secrets = secrets
    }

    /// Covers the secrets too, so turning them on or off sends every record that carries one.
    var digest: String {
        var hash = SHA256()
        hash.update(data: body)
        if let secrets {
            hash.update(data: Data([0]))
            hash.update(data: secrets)
        }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
