import Foundation

/// The iCloud Sync pane's actions. `AppCore` owns the manager they drive.
@MainActor
final class CloudSyncCoordinator {
    private let settings: AppSettings
    private unowned let core: AppCore

    init(settings: AppSettings, core: AppCore) {
        self.settings = settings
        self.core = core
    }

    func setEnabled(_ enabled: Bool) {
        if enabled {
            core.startCloudSync()
        } else {
            core.stopCloudSync()
        }
    }

    /// A category that runs code here asks first, as switching on extensions does.
    func setCategory(_ category: SyncCategory, enabled: Bool) async {
        guard enabled else {
            settings.cloudSyncCategories.remove(category)
            return
        }
        if let consent = category.descriptor.consent {
            let confirmed = await core.confirm(
                title: "Sync \(category.descriptor.label)?",
                message: consent + " Turn this on only if you trust every Mac on this iCloud account.",
                symbol: "exclamationmark.icloud", confirmTitle: "Sync", confirmRole: .standard)
            guard confirmed else { return }
        }
        settings.cloudSyncCategories.insert(category)
    }

    func syncNow() async {
        await core.cloudSyncManager?.syncNow()
    }

    /// Nil turns sync back off: the question was dismissed before anything was exchanged.
    func chooseFirstContact() async -> SyncFirstContact? {
        let choice = await core.choose(
            title: "Tinycast is already in iCloud",
            message:
                "Another Mac already syncs Tinycast. Where both Macs have a value, choose which "
                + "one to keep. Everything else is merged, and nothing is deleted.",
            symbol: "icloud",
            options: [
                DialogAction(title: "Use iCloud’s"),
                DialogAction(title: "Keep This Mac’s"),
                DialogAction(title: "Cancel", role: .cancel)
            ],
            defaultIndex: 0)
        switch choice {
        case 0: return .preferICloud
        case 1: return .preferThisMac
        default:
            core.stopCloudSync()
            return nil
        }
    }

    func removeDevice(_ device: SyncDevice) async {
        let confirmed = await core.confirm(
            title: "Remove “\(device.name)”?",
            message: "If that Mac still syncs, it appears here again the next time it connects.",
            symbol: "desktopcomputer", confirmTitle: "Remove")
        guard confirmed else { return }
        core.cloudSyncManager?.removeDevice(id: device.id)
    }

    func deleteICloudData() async {
        let confirmed = await core.confirm(
            title: "Delete Tinycast’s data from iCloud?",
            message:
                "Sync turns off on every Mac. Each Mac keeps everything it has now; only the copy "
                + "in iCloud is deleted.",
            symbol: "icloud.slash", confirmTitle: "Delete")
        guard confirmed, let manager = core.cloudSyncManager else { return }
        guard await manager.deleteAllData() else {
            core.showMessage("Couldn’t delete Tinycast’s data from iCloud", tone: .danger)
            return
        }
        core.stopCloudSync()
        core.showMessage("Deleted Tinycast’s data from iCloud")
    }

    /// Another Mac deleted the iCloud data; the manager has already stopped.
    func remoteReset() {
        core.stopCloudSync()
        core.showMessage("Sync is off: another Mac deleted Tinycast’s iCloud data", tone: .danger)
    }
}
