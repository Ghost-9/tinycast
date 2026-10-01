import Foundation

/// Installed extensions and their preferences; one installs here only from a registry enabled here.
@MainActor
enum ExtensionSyncBinding {
    private struct Record: Codable, Equatable {
        var title: String
        var preferences: [String: ExtensionStorage.StoredValue]
    }

    private typealias Values = [String: ExtensionStorage.StoredValue]

    static func make(extensions: ExtensionManager, settings: AppSettings) -> SyncBinding {
        let installs = Installs(extensions: extensions, settings: settings)
        return SyncBinding(
            kind: .installedExtension,
            observe: {
                _ = extensions.installed
                _ = extensions.hasScanned
                _ = settings.cloudSyncIncludesSecrets
            },
            read: {
                // Disabled or not yet scanned, the set is empty without anything being removed.
                guard extensions.isEnabled, extensions.hasScanned else { return nil }
                let withSecrets = settings.cloudSyncIncludesSecrets
                var records: [String: SyncPayload] = [:]
                for installed in extensions.installed {
                    let storage = extensions.storage
                    let record = Record(
                        title: installed.title,
                        preferences: preferences(of: installed, in: storage, passwords: false))
                    guard let body = SyncBinding.encode(record) else { continue }
                    let passwords =
                        withSecrets ? preferences(of: installed, in: storage, passwords: true) : [:]
                    records[installed.manifest.name] = SyncPayload(
                        body: body, secrets: passwords.isEmpty ? nil : SyncBinding.encode(passwords))
                }
                return records
            },
            write: { name, payload in
                guard let record = SyncBinding.decode(Record.self, from: payload.body) else {
                    return false
                }
                guard let installed = extensions.extensionNamed(name) else {
                    installs.request(name)
                    return false
                }
                var values = record.preferences
                if settings.cloudSyncIncludesSecrets,
                    let passwords = payload.secrets.flatMap({ SyncBinding.decode(Values.self, from: $0) })
                {
                    values.merge(passwords) { _, password in password }
                }
                apply(
                    values, to: installed, in: extensions.storage,
                    includingPasswords: settings.cloudSyncIncludesSecrets)
                return true
            },
            remove: { name in
                guard let installed = extensions.extensionNamed(name) else { return }
                await extensions.uninstall(installed)
            })
    }

    /// A path names something on this Mac alone, so it never travels.
    private static func isPortable(_ schema: ExtensionPreferenceSchema) -> Bool {
        switch schema.kind {
        case .appPicker, .file, .directory: false
        case .textfield, .checkbox, .dropdown, .password: true
        }
    }

    private static func schemas(of installed: InstalledExtension) -> [ExtensionPreferenceSchema] {
        installed.manifest.preferences + installed.manifest.commands.flatMap(\.preferences)
    }

    /// Passwords and everything else apart, since passwords travel only as secrets.
    private static func preferences(
        of installed: InstalledExtension, in storage: ExtensionStorage, passwords: Bool
    ) -> Values {
        var values: Values = [:]
        for schema in schemas(of: installed)
        where isPortable(schema) && (schema.kind == .password) == passwords {
            guard let value = storage.preference(extension: installed.manifest.name, key: schema.name)
            else { continue }
            values[schema.name] = ExtensionStorage.StoredValue(preference: value)
        }
        return values
    }

    /// A preference the record leaves out keeps its value here, so a narrower Mac clears nothing.
    private static func apply(
        _ values: Values, to installed: InstalledExtension, in storage: ExtensionStorage,
        includingPasswords: Bool
    ) {
        let name = installed.manifest.name
        for schema in schemas(of: installed)
        where isPortable(schema) && (includingPasswords || schema.kind != .password) {
            guard let value = values[schema.name]?.preferenceValue,
                storage.preference(extension: name, key: schema.name) != value
            else { continue }
            storage.setPreference(extension: name, key: schema.name, value: value)
        }
    }

    /// Installs run in the background: a source build can take minutes, and sync waits on nothing.
    @MainActor
    private final class Installs {
        private let extensions: ExtensionManager
        private let settings: AppSettings
        private var running: [String: Task<Void, Never>] = [:]
        /// Not retried this session: the registry lacked it, or the build failed.
        private var failed: Set<String> = []

        init(extensions: ExtensionManager, settings: AppSettings) {
            self.extensions = extensions
            self.settings = settings
        }

        isolated deinit {
            for task in running.values { task.cancel() }
        }

        func request(_ name: String) {
            guard settings.extensionsEnabled, running[name] == nil, !failed.contains(name) else {
                return
            }
            running[name] = Task { [weak self] in await self?.install(name) }
        }

        private func install(_ name: String) async {
            defer { running[name] = nil }
            let registries = settings.extensionRegistries.filter(\.isEnabled)
            let results = await ExtensionStoreClient().search(name, in: registries)
            let listing = results.lazy.flatMap(\.listings).first { $0.name == name }
            guard let listing, !Task.isCancelled else {
                failed.insert(name)
                return
            }
            do {
                try await extensions.install(
                    listing: listing, packageManager: settings.extensionPackageManager,
                    additionalSearchPaths: settings.extensionCustomSearchPaths,
                    onProgress: { _ in })
            } catch {
                failed.insert(name)
            }
        }
    }
}
