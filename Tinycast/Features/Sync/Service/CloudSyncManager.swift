import AppKit
import CloudKit
import SystemConfiguration

/// Runs `CKSyncEngine` over the enabled bindings: sends this Mac's edits, applies other Macs'.
@MainActor
final class CloudSyncManager {
    static let zoneID = CKRecordZone.ID(zoneName: "Tinycast", ownerName: CKCurrentUserDefaultName)
    private static let zone = CKRecordZone(zoneID: zoneID)

    /// One container per channel, keyed by bundle ID like every other store.
    static var containerIdentifier: String {
        "iCloud." + (Bundle.main.bundleIdentifier ?? "com.tinycast.app")
    }

    /// Asked once, when this Mac first meets data another Mac put in iCloud; nil stops the start.
    var chooseFirstContact: (() async -> SyncFirstContact?)?
    /// Another Mac deleted the iCloud data, so sync has already stopped here.
    var onRemoteReset: (() -> Void)?

    private struct Snapshot {
        var locals: [String: SyncLedger.Local] = [:]
        var bodies: [String: Data] = [:]
    }

    private struct Applied {
        let name: String
        let kind: SyncRecordKind
        let key: String
        let body: Data
        let systemFields: Data?
    }

    private let state: CloudSyncState
    private let bindings: [SyncRecordKind: SyncBinding]
    private let ledgerURL: URL
    private var ledger: SyncLedger
    private var kinds: Set<SyncRecordKind> = []
    private var engine: CKSyncEngine?
    /// Changed payloads waiting to be sent, by record name; nothing unchanged is held in memory.
    private var outgoing: [String: Data] = [:]
    /// The payload each record in flight was built from, which its confirmation agrees on.
    private var inFlight: [String: Data] = [:]
    private var bootTask: Task<Void, Never>?
    private var reconcileTask: Task<Void, Never>?
    private var persistTask: Task<Void, Never>?
    private var writeTask: Task<Void, Never>?
    private var wakeObserver: NotificationToken?
    private var accountObserver: NotificationToken?

    private static let reconcileDelay = Duration.seconds(2)
    private static let persistDelay = Duration.seconds(1)

    init(state: CloudSyncState, bindings: [SyncBinding], ledgerURL: URL) {
        self.state = state
        self.bindings = Dictionary(uniqueKeysWithValues: bindings.map { ($0.kind, $0) })
        self.ledgerURL = ledgerURL
        ledger = Self.loadLedger(from: ledgerURL) ?? SyncLedger(deviceID: UUID().uuidString)
        state.thisDeviceID = ledger.deviceID
        publishStatus()
    }

    isolated deinit {
        bootTask?.cancel()
        reconcileTask?.cancel()
        persistTask?.cancel()
    }

    // MARK: - Lifecycle

    func start(categories: Set<SyncCategory>) {
        kinds = Self.kinds(for: categories)
        observeAccount()
        restart()
    }

    /// `forgetting` drops what this Mac agreed with iCloud, so turning sync on again starts afresh.
    func stop(forgetting: Bool) {
        bootTask?.cancel()
        tearDownEngine()
        accountObserver = nil
        if forgetting { ledger = SyncLedger(deviceID: ledger.deviceID) }
        state.availability = .off
        state.isSyncing = false
        state.lastError = nil
        publishStatus()
        flush()
    }

    /// A category switched on is fetched in full: this Mac never kept the records it skipped.
    func setCategories(_ categories: Set<SyncCategory>) {
        let wanted = Self.kinds(for: categories)
        guard wanted != kinds else { return }
        let added = wanted.subtracting(kinds)
        let removed = kinds.subtracting(wanted)
        kinds = wanted
        let dropped = ledger.entries.filter { removed.contains($0.value.kind) }.keys
        for name in dropped { outgoing[name] = nil }
        ledger.forget(removed)
        publishStatus()
        schedulePersist()
        guard !added.isEmpty else { return }
        ledger.engineState = nil
        restart()
    }

    func syncNow() async {
        guard let engine else { return }
        do {
            try await engine.fetchChanges()
            try await engine.sendChanges()
        } catch {
            report(error)
        }
    }

    func removeDevice(id: String) {
        guard let engine, id != ledger.deviceID else { return }
        ledger.devices[id] = nil
        let recordID = CloudSyncRecords.deviceRecordID(id, zoneID: Self.zoneID)
        engine.state.add(pendingRecordZoneChanges: [.deleteRecord(recordID)])
        publishStatus()
        schedulePersist()
    }

    /// Deletes the zone, which every other Mac reads as a reset; the caller then stops sync here.
    func deleteAllData() async -> Bool {
        guard let engine else { return false }
        // Nothing may be sent meanwhile: a save after the delete would recreate the zone.
        let syncing = kinds
        kinds = []
        reconcileTask?.cancel()
        reconcileTask = nil
        engine.state.remove(pendingRecordZoneChanges: engine.state.pendingRecordZoneChanges)
        engine.state.add(pendingDatabaseChanges: [.deleteZone(Self.zoneID)])
        do {
            try await engine.sendChanges()
        } catch {
            report(error)
        }
        let deleted = !engine.state.pendingDatabaseChanges.contains {
            if case .deleteZone = $0 { true } else { false }
        }
        if !deleted {
            engine.state.remove(pendingDatabaseChanges: [.deleteZone(Self.zoneID)])
            kinds = syncing
            reconcile()
        }
        return deleted
    }

    /// Records this Mac held for want of an app or a free shortcut get another try.
    func retryHeld() {
        guard engine != nil else { return }
        let applied = ledger.entries.compactMap { name, entry -> Applied? in
            guard entry.isHeld, kinds.contains(entry.kind), let body = entry.body,
                bindings[entry.kind]?.write(entry.key, body) == true
            else { return nil }
            return Applied(
                name: name, kind: entry.kind, key: entry.key, body: body,
                systemFields: entry.systemFields)
        }
        settle(applied)
        publishStatus()
    }

    /// Synchronous, for termination: a pending write must land before the process goes.
    func flush() {
        persistTask?.cancel()
        persistTask = nil
        guard let data = try? Self.encodeLedger(ledger) else { return }
        try? data.write(to: ledgerURL, options: .atomic)
    }

    private func restart() {
        bootTask?.cancel()
        tearDownEngine()
        bootTask = Task { [weak self] in await self?.boot() }
    }

    private func boot() async {
        guard state.isSupported else { return }
        state.availability = .checking
        let container = CKContainer(identifier: Self.containerIdentifier)
        guard await accountIsAvailable(container), !Task.isCancelled else { return }
        if ledger.engineState == nil, ledger.entries.isEmpty, await iCloudHasData(container) {
            guard !Task.isCancelled, let choice = await chooseFirstContact?() else { return }
            ledger.firstContact = choice
        }
        guard !Task.isCancelled else { return }
        state.availability = .available
        engine = makeEngine(container)
        reconcile()
        publishDeviceIfStale()
        observeWake()
        NSApplication.shared.registerForRemoteNotifications()
        await syncNow()
    }

    private func makeEngine(_ container: CKContainer) -> CKSyncEngine {
        let saved = ledger.engineState.flatMap {
            try? JSONDecoder().decode(CKSyncEngine.State.Serialization.self, from: $0)
        }
        let configuration = CKSyncEngine.Configuration(
            database: container.privateCloudDatabase, stateSerialization: saved, delegate: self)
        let engine = CKSyncEngine(configuration)
        if saved == nil {
            engine.state.add(pendingDatabaseChanges: [.saveZone(Self.zone)])
        }
        engine.state.add(
            pendingRecordZoneChanges: ledger.pendingDeletes.map { .deleteRecord(recordID($0)) })
        return engine
    }

    private func tearDownEngine() {
        reconcileTask?.cancel()
        reconcileTask = nil
        wakeObserver = nil
        outgoing = [:]
        inFlight = [:]
        guard let engine else { return }
        self.engine = nil
        Task { await engine.cancelOperations() }
    }

    private func accountIsAvailable(_ container: CKContainer) async -> Bool {
        do {
            switch try await container.accountStatus() {
            case .available:
                return true
            case .restricted:
                state.availability = .restricted
            default:
                state.availability = .noAccount
            }
        } catch {
            state.availability = .noAccount
            report(error)
        }
        return false
    }

    /// Anything but a definite "no zone" counts as data, so an offline first run still asks.
    private func iCloudHasData(_ container: CKContainer) async -> Bool {
        do {
            _ = try await container.privateCloudDatabase.recordZone(for: Self.zoneID)
            return true
        } catch let error as CKError where error.code == .zoneNotFound {
            return false
        } catch {
            return true
        }
    }

    // MARK: - Local changes

    private func scheduleReconcile() {
        guard engine != nil, reconcileTask == nil else { return }
        reconcileTask = Task { [weak self] in
            try? await Task.sleep(for: Self.reconcileDelay)
            guard !Task.isCancelled else { return }
            self?.reconcile()
        }
    }

    private func reconcile() {
        reconcileTask = nil
        guard let engine else { return }
        retryHeld()
        let snapshot = observedSnapshot()
        let bindings = bindings
        let changes = ledger.reconcile(snapshot.locals, syncing: kinds, now: .now) { entry in
            bindings[entry.kind]?.isAvailable(entry.key) ?? true
        }
        for name in changes.saves { outgoing[name] = snapshot.bodies[name] }
        for name in changes.deletes { outgoing[name] = nil }
        queue(saves: changes.saves, deletes: changes.deletes, on: engine)
        publishStatus()
        schedulePersist()
    }

    /// Re-armed on every pass: the tracking is one-shot, and each pass re-reads every store anyway.
    private func observedSnapshot() -> Snapshot {
        withObservationTracking {
            snapshot(of: kinds)
        } onChange: { [weak self] in
            Task { @MainActor in self?.scheduleReconcile() }
        }
    }

    private func snapshot(of kinds: Set<SyncRecordKind>) -> Snapshot {
        var snapshot = Snapshot()
        for kind in kinds {
            guard let binding = bindings[kind] else { continue }
            for (key, body) in binding.read() {
                let name = kind.recordName(for: key)
                snapshot.locals[name] = .init(kind: kind, key: key, digest: SyncLedger.digest(body))
                snapshot.bodies[name] = body
            }
        }
        return snapshot
    }

    private func queue(saves: [String], deletes: [String], on engine: CKSyncEngine) {
        let saveIDs = saves.map(recordID)
        let deleteIDs = deletes.map(recordID)
        typealias Change = CKSyncEngine.PendingRecordZoneChange
        let wanted = saveIDs.map(Change.saveRecord) + deleteIDs.map(Change.deleteRecord)
        let superseded = saveIDs.map(Change.deleteRecord) + deleteIDs.map(Change.saveRecord)
        engine.state.remove(pendingRecordZoneChanges: superseded)
        engine.state.add(pendingRecordZoneChanges: wanted)
    }

    /// Agrees on what each store now reports, so a record just applied is never echoed back.
    private func settle(_ applied: [Applied]) {
        guard !applied.isEmpty else { return }
        let snapshot = snapshot(of: Set(applied.map(\.kind)))
        for item in applied {
            ledger.didApply(
                item.name, kind: item.kind, key: item.key, body: item.body,
                localDigest: snapshot.locals[item.name]?.digest, systemFields: item.systemFields)
        }
        schedulePersist()
    }

    // MARK: - Remote changes

    private func handle(_ event: CKSyncEngine.Event, from engine: CKSyncEngine) {
        guard engine === self.engine else { return }
        switch event {
        case .stateUpdate(let update):
            ledger.engineState = try? JSONEncoder().encode(update.stateSerialization)
            schedulePersist()
        case .accountChange(let change):
            accountChanged(change.changeType)
        case .fetchedDatabaseChanges(let changes):
            zonesChanged(changes)
        case .fetchedRecordZoneChanges(let changes):
            apply(changes)
        case .sentDatabaseChanges(let sent):
            for failure in sent.failedZoneSaves { report(failure.error) }
        case .sentRecordZoneChanges(let sent):
            confirm(sent)
        case .willFetchChanges, .willSendChanges:
            state.isSyncing = true
        case .didFetchChanges:
            state.isSyncing = false
            state.lastError = nil
            ledger.lastFetch = .now
            publishStatus()
            schedulePersist()
        case .didSendChanges:
            state.isSyncing = false
            ledger.lastSend = .now
            publishStatus()
            schedulePersist()
        case .willFetchRecordZoneChanges, .didFetchRecordZoneChanges:
            break
        @unknown default:
            break
        }
    }

    private func apply(_ changes: CKSyncEngine.Event.FetchedRecordZoneChanges) {
        var applied: [Applied] = []
        for modification in changes.modifications {
            let record = modification.record
            if let device = CloudSyncRecords.device(from: record) {
                ledger.devices[device.id] = device
                if device.id == ledger.deviceID {
                    ledger.deviceSystemFields = CloudSyncRecords.systemFields(of: record)
                }
            } else if let item = CloudSyncRecords.item(from: record), kinds.contains(item.kind),
                let merged = merge(item, from: record)
            {
                applied.append(merged)
            }
        }
        for deletion in changes.deletions { removeRemotely(deletion.recordID) }
        settle(applied)
        retryHeld()
        publishStatus()
        schedulePersist()
    }

    /// The server's version lands unless this Mac's own unsent edit is the newer one.
    private func merge(_ item: CloudSyncRecords.Item, from record: CKRecord) -> Applied? {
        let name = record.recordID.recordName
        guard !ledger.pendingDeletes.contains(name) else { return nil }
        let systemFields = CloudSyncRecords.systemFields(of: record)
        let decision = SyncMergePolicy.decide(
            local: ledger.entries[name], serverEditedAt: item.editedAt,
            firstContact: ledger.firstContact)
        guard decision == .takeServer else {
            ledger.entries[name]?.systemFields = systemFields
            if let engine { queue(saves: [name], deletes: [], on: engine) }
            return nil
        }
        outgoing[name] = nil
        engine?.state.remove(pendingRecordZoneChanges: [.saveRecord(record.recordID)])
        guard bindings[item.kind]?.write(item.key, item.body) == true else {
            ledger.hold(
                name, kind: item.kind, key: item.key, body: item.body, systemFields: systemFields)
            return nil
        }
        return Applied(
            name: name, kind: item.kind, key: item.key, body: item.body, systemFields: systemFields)
    }

    /// A local edit not yet sent outlives a remote delete, and goes back up as a new record.
    private func removeRemotely(_ id: CKRecord.ID) {
        if let deviceID = CloudSyncRecords.deviceID(of: id) {
            ledger.devices[deviceID] = nil
            if deviceID == ledger.deviceID { ledger.deviceSystemFields = nil }
            return
        }
        let name = id.recordName
        guard let entry = ledger.entries[name], kinds.contains(entry.kind) else { return }
        if entry.pending != nil, !entry.isHeld {
            ledger.entries[name]?.systemFields = nil
            return
        }
        ledger.entries[name] = nil
        if !entry.isHeld { bindings[entry.kind]?.remove(entry.key) }
    }

    private func confirm(_ sent: CKSyncEngine.Event.SentRecordZoneChanges) {
        for record in sent.savedRecords {
            let name = record.recordID.recordName
            let systemFields = CloudSyncRecords.systemFields(of: record)
            if CloudSyncRecords.deviceID(of: record.recordID) != nil {
                ledger.deviceSystemFields = systemFields
            } else if let body = inFlight.removeValue(forKey: name) {
                ledger.didSend(name, body: body, systemFields: systemFields)
                if ledger.entries[name]?.pending == nil { outgoing[name] = nil }
            } else {
                ledger.entries[name]?.systemFields = systemFields
            }
        }
        for id in sent.deletedRecordIDs { ledger.pendingDeletes.remove(id.recordName) }
        for (id, error) in sent.failedRecordDeletes {
            if error.code == .unknownItem {
                ledger.pendingDeletes.remove(id.recordName)
            } else {
                report(error)
            }
        }
        for failure in sent.failedRecordSaves { recover(failure) }
        publishStatus()
        schedulePersist()
    }

    /// Transient errors the engine retries by itself; these three need a decision first.
    private func recover(_ failure: CKSyncEngine.Event.SentRecordZoneChanges.FailedRecordSave) {
        let id = failure.record.recordID
        let name = id.recordName
        inFlight[name] = nil
        let isDevice = CloudSyncRecords.deviceID(of: id) != nil
        switch failure.error.code {
        case .serverRecordChanged:
            guard let server = failure.error.serverRecord else { return }
            if isDevice {
                ledger.deviceSystemFields = CloudSyncRecords.systemFields(of: server)
                engine?.state.add(pendingRecordZoneChanges: [.saveRecord(id)])
            } else if let item = CloudSyncRecords.item(from: server), kinds.contains(item.kind) {
                settle(merge(item, from: server).map { [$0] } ?? [])
            }
        case .zoneNotFound, .unknownItem:
            if failure.error.code == .zoneNotFound {
                engine?.state.add(pendingDatabaseChanges: [.saveZone(Self.zone)])
            }
            if isDevice {
                ledger.deviceSystemFields = nil
            } else {
                ledger.entries[name]?.systemFields = nil
            }
            engine?.state.add(pendingRecordZoneChanges: [.saveRecord(id)])
        default:
            report(failure.error)
        }
    }

    private func zonesChanged(_ changes: CKSyncEngine.Event.FetchedDatabaseChanges) {
        guard let deletion = changes.deletions.first(where: { $0.zoneID == Self.zoneID }) else {
            return
        }
        switch deletion.reason {
        case .encryptedDataReset:
            resendEverything()
        case .deleted, .purged:
            stop(forgetting: true)
            onRemoteReset?()
        @unknown default:
            stop(forgetting: true)
            onRemoteReset?()
        }
    }

    /// The encryption keys were reset, which emptied the zone; this Mac's copy fills it again.
    private func resendEverything() {
        guard let engine else { return }
        for name in ledger.entries.keys {
            ledger.entries[name]?.agreed = nil
            ledger.entries[name]?.systemFields = nil
        }
        ledger.deviceSystemFields = nil
        engine.state.add(pendingDatabaseChanges: [.saveZone(Self.zone)])
        reconcile()
        engine.state.add(pendingRecordZoneChanges: [.saveRecord(deviceRecordID)])
    }

    private func accountChanged(_ change: CKSyncEngine.Event.AccountChange.ChangeType) {
        switch change {
        case .signIn:
            break
        case .signOut, .switchAccounts:
            ledger = SyncLedger(deviceID: ledger.deviceID)
        @unknown default:
            ledger = SyncLedger(deviceID: ledger.deviceID)
        }
        publishStatus()
        restart()
    }

    // MARK: - Records out

    private func nextBatch(
        _ context: CKSyncEngine.SendChangesContext, from engine: CKSyncEngine
    ) async -> CKSyncEngine.RecordZoneChangeBatch? {
        guard engine === self.engine else { return nil }
        let pending = engine.state.pendingRecordZoneChanges.filter {
            context.options.scope.contains($0)
        }
        guard !pending.isEmpty else { return nil }
        return await CKSyncEngine.RecordZoneChangeBatch(pendingChanges: pending) { [weak self] id in
            await self?.record(for: id, from: engine)
        }
    }

    private func record(for id: CKRecord.ID, from engine: CKSyncEngine) -> CKRecord? {
        guard engine === self.engine else { return nil }
        if id == deviceRecordID {
            let device = thisDevice()
            ledger.devices[device.id] = device
            return CloudSyncRecords.device(
                device, zoneID: Self.zoneID, systemFields: ledger.deviceSystemFields)
        }
        let name = id.recordName
        guard let body = outgoing[name], let entry = ledger.entries[name], !entry.isHeld else {
            engine.state.remove(pendingRecordZoneChanges: [.saveRecord(id)])
            return nil
        }
        inFlight[name] = body
        return CloudSyncRecords.item(
            id: id, systemFields: entry.systemFields, kind: entry.kind, key: entry.key, body: body,
            editedAt: entry.editedAt ?? .now, deviceID: ledger.deviceID)
    }

    // MARK: - This Mac

    private var deviceRecordID: CKRecord.ID {
        CloudSyncRecords.deviceRecordID(ledger.deviceID, zoneID: Self.zoneID)
    }

    private func thisDevice() -> SyncDevice {
        let computerName = SCDynamicStoreCopyComputerName(nil, nil) as String?
        let name = computerName ?? ProcessInfo.processInfo.hostName
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? ""
        return SyncDevice(id: ledger.deviceID, name: name, appVersion: version, lastSeen: .now)
    }

    private func publishDeviceIfStale() {
        let current = thisDevice()
        if let known = ledger.devices[current.id], !known.isStale(asOf: current.lastSeen),
            known.name == current.name, known.appVersion == current.appVersion
        {
            return
        }
        engine?.state.add(pendingRecordZoneChanges: [.saveRecord(deviceRecordID)])
    }

    private func observeWake() {
        let center = NSWorkspace.shared.notificationCenter
        let token = center.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                publishDeviceIfStale()
                await syncNow()
            }
        }
        wakeObserver = NotificationToken(token, center: center)
    }

    /// Covers signing in while no engine runs; a running engine reports account changes itself.
    private func observeAccount() {
        guard accountObserver == nil else { return }
        let center = NotificationCenter.default
        let token = center.addObserver(
            forName: .CKAccountChanged, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, engine == nil else { return }
                restart()
            }
        }
        accountObserver = NotificationToken(token, center: center)
    }

    // MARK: - State

    private func recordID(_ name: String) -> CKRecord.ID {
        CKRecord.ID(recordName: name, zoneID: Self.zoneID)
    }

    private func report(_ error: Error) {
        state.lastError = error.localizedDescription
    }

    private func publishStatus() {
        let this = ledger.deviceID
        let devices = ledger.devices.values.sorted {
            ($0.id == this ? 0 : 1, $0.name) < ($1.id == this ? 0 : 1, $1.name)
        }
        if state.devices != devices { state.devices = devices }
        if state.lastFetch != ledger.lastFetch { state.lastFetch = ledger.lastFetch }
        if state.lastSend != ledger.lastSend { state.lastSend = ledger.lastSend }
        let held = ledger.heldCount
        if state.heldCount != held { state.heldCount = held }
    }

    private func schedulePersist() {
        guard persistTask == nil else { return }
        persistTask = Task { [weak self] in
            try? await Task.sleep(for: Self.persistDelay)
            guard !Task.isCancelled else { return }
            self?.persist()
        }
    }

    /// Chained, so two writes in flight can never land out of order.
    private func persist() {
        persistTask = nil
        guard let data = try? Self.encodeLedger(ledger) else { return }
        let url = ledgerURL
        let previous = writeTask
        writeTask = Task.detached(priority: .utility) {
            await previous?.value
            try? data.write(to: url, options: .atomic)
        }
    }

    private static func encodeLedger(_ ledger: SyncLedger) throws -> Data {
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        return try encoder.encode(ledger)
    }

    private static func loadLedger(from url: URL) -> SyncLedger? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? PropertyListDecoder().decode(SyncLedger.self, from: data)
    }

    private static func kinds(for categories: Set<SyncCategory>) -> Set<SyncRecordKind> {
        Set(SyncRecordKind.allCases.filter { categories.contains($0.category) })
    }
}

extension CloudSyncManager: CKSyncEngineDelegate {
    nonisolated func handleEvent(_ event: CKSyncEngine.Event, syncEngine: CKSyncEngine) async {
        await handle(event, from: syncEngine)
    }

    nonisolated func nextRecordZoneChangeBatch(
        _ context: CKSyncEngine.SendChangesContext, syncEngine: CKSyncEngine
    ) async -> CKSyncEngine.RecordZoneChangeBatch? {
        await nextBatch(context, from: syncEngine)
    }
}
