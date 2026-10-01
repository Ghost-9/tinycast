// Contract tests for iCloud sync's pure layer: record names, the ledger, the merge policy, coverage.

import Foundation

@main
@MainActor
struct SyncTest {
    static var failures = 0

    static func main() {
        testRecordNames()
        testCategories()
        testReconcile()
        testDeletes()
        testHolding()
        testApply()
        testMergePolicy()
        testForget()
        testLedgerRoundTrip()
        testSettingsCoverage()

        print(failures == 0 ? "\nALL PASSED" : "\n\(failures) FAILED")
        exit(failures == 0 ? 0 : 1)
    }

    private static func check(_ description: String, _ condition: Bool) {
        print("\(condition ? "PASS" : "FAIL")  \(description)")
        if !condition { failures += 1 }
    }

    // MARK: - Fixtures

    private static let t0 = Date(timeIntervalSince1970: 1_000)
    private static let t1 = Date(timeIntervalSince1970: 2_000)
    private static let t2 = Date(timeIntervalSince1970: 3_000)

    private struct Record {
        let name: String
        let body: Data
        let local: SyncLedger.Local

        init(_ key: String, _ value: String, kind: SyncRecordKind = .alias) {
            name = kind.recordName(for: key)
            body = Data(value.utf8)
            local = .init(kind: kind, key: key, digest: SyncLedger.digest(body))
        }
    }

    private static func current(_ records: Record...) -> [String: SyncLedger.Local] {
        Dictionary(uniqueKeysWithValues: records.map { ($0.name, $0.local) })
    }

    private static func reconcile(
        _ ledger: inout SyncLedger, _ current: [String: SyncLedger.Local], at now: Date,
        syncing kinds: Set<SyncRecordKind> = [.alias], available: Bool = true
    ) -> SyncLedger.Changes {
        ledger.reconcile(current, syncing: kinds, now: now) { _ in available }
    }

    // MARK: - Names

    private static func testRecordNames() {
        check(
            "a plain key names its record directly",
            SyncRecordKind.setting.recordName(for: "general.showInMenuBar")
                == "setting.general.showInMenuBar")

        let digested = SyncRecordKind.alias.recordName(for: "app:com.example.app")
        check(
            "a key CloudKit can't take becomes a digest under its kind",
            digested.hasPrefix("alias~") && digested.count == "alias~".count + 64)
        check(
            "the digest is stable, so the same key always reaches the same record",
            digested == SyncRecordKind.alias.recordName(for: "app:com.example.app"))
        check(
            "different keys never share a digest name",
            digested != SyncRecordKind.alias.recordName(for: "app:com.example.other"))
        check(
            "a non-ASCII key is digested",
            SyncRecordKind.alias.recordName(for: "Café").hasPrefix("alias~"))
        check(
            "an empty key is digested rather than naming the bare kind",
            SyncRecordKind.alias.recordName(for: "").hasPrefix("alias~"))
        let long = SyncRecordKind.setting.recordName(for: String(repeating: "a", count: 300))
        check("a long key fits CloudKit's 255 characters", long.count <= 255)

        let raws = SyncRecordKind.allCases.map(\.rawValue)
        let plain = raws.allSatisfy { raw in
            raw.unicodeScalars.allSatisfy { CharacterSet.alphanumerics.contains($0) }
        }
        check("every kind is a plain prefix, so `.` and `~` can't be confused", plain)
    }

    private static func testCategories() {
        let empty = SyncCategory.allCases.filter { category in
            !SyncRecordKind.allCases.contains { $0.category == category }
        }
        check("every category carries at least one kind", empty.isEmpty)
        check(
            "the stored order is declaration order whatever the set's",
            SyncCategory.ordered(Set(SyncCategory.allCases.reversed())) == SyncCategory.allCases)
    }

    // MARK: - Reconcile

    private static func testReconcile() {
        var ledger = SyncLedger(deviceID: "this")
        let original = Record("app:a", "\"x\"")
        var changes = reconcile(&ledger, current(original), at: t0)
        check("a new local record is sent", changes.saves == [original.name])
        check("its edit time is when it was first seen", ledger.entries[original.name]?.editedAt == t0)

        changes = reconcile(&ledger, current(original), at: t1)
        check(
            "an unsent record stays queued without moving its edit time",
            changes.saves == [original.name] && ledger.entries[original.name]?.editedAt == t0)

        ledger.didSend(original.name, body: original.body, systemFields: Data([1]))
        changes = reconcile(&ledger, current(original), at: t1)
        check("a confirmed record is not sent again", changes == .init())
        check(
            "a confirmed record keeps its system fields and body",
            ledger.entries[original.name]?.systemFields == Data([1])
                && ledger.entries[original.name]?.body == original.body)

        let edited = Record("app:a", "\"y\"")
        changes = reconcile(&ledger, current(edited), at: t2)
        check(
            "an edit is sent, stamped with when it was made",
            changes.saves == [edited.name] && ledger.entries[edited.name]?.editedAt == t2)

        changes = reconcile(&ledger, current(original), at: t2)
        check(
            "an edit undone before it was sent is no longer pending",
            changes == .init() && ledger.entries[original.name]?.pending == nil)

        let other = Record("app:b", "true", kind: .hiddenItem)
        changes = reconcile(&ledger, current(original, other), at: t2)
        check("a kind not being synced is left alone", ledger.entries[other.name] == nil)

        _ = reconcile(&ledger, current(edited), at: t2)
        let third = Record("app:a", "\"z\"")
        _ = reconcile(&ledger, current(third), at: t2)
        ledger.didSend(third.name, body: edited.body, systemFields: Data([3]))
        check(
            "confirming an older payload leaves the newer edit pending",
            ledger.entries[third.name]?.pending == third.local.digest
                && ledger.entries[third.name]?.agreed == edited.local.digest)
    }

    private static func testDeletes() {
        var ledger = SyncLedger(deviceID: "this")
        let record = Record("app:a", "\"x\"")
        _ = reconcile(&ledger, current(record), at: t0)
        ledger.didSend(record.name, body: record.body, systemFields: Data([1]))

        var changes = reconcile(&ledger, [:], at: t1)
        check("a record removed here is deleted", changes.deletes == [record.name])
        check("its entry goes with it", ledger.entries[record.name] == nil)
        check("the delete is remembered until confirmed", ledger.pendingDeletes == [record.name])

        changes = reconcile(&ledger, current(record), at: t2)
        check(
            "re-creating it cancels the delete",
            changes.saves == [record.name] && ledger.pendingDeletes.isEmpty)

        var other = SyncLedger(deviceID: "this")
        _ = reconcile(&other, current(record), at: t0)
        changes = reconcile(&other, [:], at: t1, available: false)
        check(
            "a record that never reached iCloud is dropped even when unavailable",
            changes.deletes == [record.name] && other.entries.isEmpty)
    }

    // MARK: - Holding

    private static func testHolding() {
        var ledger = SyncLedger(deviceID: "this")
        let record = Record("hotkey.app.com.example", "{}", kind: .shortcut)
        let kinds: Set<SyncRecordKind> = [.shortcut]
        _ = reconcile(&ledger, current(record), at: t0, syncing: kinds)
        ledger.didSend(record.name, body: record.body, systemFields: Data([1]))

        let changes = reconcile(&ledger, [:], at: t1, syncing: kinds, available: false)
        check("a record this Mac can no longer hold is never deleted", changes.deletes.isEmpty)
        check("it is held instead, with the payload to retry", ledger.entries[record.name]?.isHeld == true)
        check("the held count reports it", ledger.heldCount == 1)

        let back = reconcile(&ledger, current(record), at: t2, syncing: kinds)
        check("a held record is never sent from here", back.saves.isEmpty)

        var applied = SyncLedger(deviceID: "this")
        applied.didApply(
            record.name, kind: .shortcut, key: "hotkey.app.com.example", body: record.body,
            localDigest: nil, systemFields: nil)
        check(
            "an apply the store did not keep is held, not agreed",
            applied.entries[record.name]?.isHeld == true
                && applied.entries[record.name]?.agreed == nil)
    }

    private static func testApply() {
        var ledger = SyncLedger(deviceID: "this")
        let incoming = Record("app:a", "\"  x\"")
        let normalized = Record("app:a", "\"x\"")
        ledger.didApply(
            incoming.name, kind: .alias, key: "app:a", body: incoming.body,
            localDigest: normalized.local.digest, systemFields: Data([9]))
        let changes = reconcile(&ledger, current(normalized), at: t0)
        check("a value the store normalized on apply is not echoed back", changes == .init())
        check(
            "the applied record carries the server's system fields",
            ledger.entries[incoming.name]?.systemFields == Data([9]))
    }

    // MARK: - Merge

    private static func testMergePolicy() {
        func decide(
            _ entry: SyncLedger.Entry?, server: Date?, first: SyncFirstContact = .preferICloud
        ) -> SyncMergePolicy.Decision {
            SyncMergePolicy.decide(local: entry, serverEditedAt: server, firstContact: first)
        }

        var entry = SyncLedger.Entry(kind: .alias, key: "k")
        check("no local record takes the server's", decide(nil, server: t1) == .takeServer)
        check("no local edit takes the server's", decide(entry, server: t1) == .takeServer)

        entry.pending = "local"
        entry.editedAt = t2
        check(
            "first contact prefers iCloud by default",
            decide(entry, server: t1) == .takeServer)
        check(
            "first contact can keep this Mac's",
            decide(entry, server: t1, first: .preferThisMac) == .keepLocal)

        entry.agreed = "before"
        check("a newer local edit wins", decide(entry, server: t1) == .keepLocal)
        entry.editedAt = t0
        check("an older local edit loses", decide(entry, server: t1) == .takeServer)
        entry.editedAt = t1
        check("a tie goes to the server, which every Mac agrees on", decide(entry, server: t1) == .takeServer)
        check("an undated server record wins", decide(entry, server: nil) == .takeServer)
    }

    private static func testForget() {
        var ledger = SyncLedger(deviceID: "this")
        let alias = Record("app:a", "\"x\"")
        let hidden = Record("app:b", "true", kind: .hiddenItem)
        _ = reconcile(&ledger, current(alias, hidden), at: t0, syncing: [.alias, .hiddenItem])
        ledger.forget([.alias])
        check(
            "forgetting a kind drops only its entries",
            ledger.entries[alias.name] == nil && ledger.entries[hidden.name] != nil)
    }

    private static func testLedgerRoundTrip() {
        var ledger = SyncLedger(deviceID: "this")
        let record = Record("app:a", "\"x\"")
        _ = reconcile(&ledger, current(record), at: t0)
        ledger.devices["this"] = SyncDevice(id: "this", name: "Mac", appVersion: "1.0", lastSeen: t0)
        ledger.engineState = Data([1, 2, 3])
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        let decoded = (try? encoder.encode(ledger)).flatMap {
            try? PropertyListDecoder().decode(SyncLedger.self, from: $0)
        }
        check("the ledger survives a relaunch unchanged", decoded == ledger)

        let device = SyncDevice(id: "d", name: "Mac", appVersion: "1", lastSeen: t0)
        check(
            "a device republishes only once its record is an hour old",
            !device.isStale(asOf: t0.addingTimeInterval(59 * 60))
                && device.isStale(asOf: t0.addingTimeInterval(60 * 60)))
    }

    // MARK: - Coverage

    private static func testSettingsCoverage() {
        let carried = SyncSettingsCoverage.carriedByRecords
        let local = SyncSettingsCoverage.local
        let both = carried.keys.filter { local[$0] != nil }
        check("no key is both carried by records and kept local", both.isEmpty)
        check(
            "a key carried by records never names the setting kind",
            !carried.values.contains(.setting))
        check(
            "every local key gives its reason",
            local.values.allSatisfy { !$0.trimmingCharacters(in: .whitespaces).isEmpty })
        check(
            "folders stay on the Mac that names them",
            local[.notesFolder] != nil && local[.snippetsFolder] != nil)
        check(
            "window lists sync item by item, never as one list",
            [.windowShortcuts, .customWindowSizes, .windowLayouts, .windowRooms].allSatisfy {
                carried[$0] != nil
            })
        check(
            "everything else syncs",
            SettingsFileKey.allCases.filter(SyncSettingsCoverage.syncs).count
                == SettingsFileKey.allCases.count - carried.count - local.count)
    }
}
