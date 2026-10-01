import Foundation

/// Where each record kind lives; exhaustive, so a new kind fails to build until it is bound.
@MainActor
enum CloudSyncSchema {
    static func bindings(core: AppCore) -> [SyncBinding] {
        SyncRecordKind.allCases.map { binding(for: $0, core: core) }
    }

    private static func binding(for kind: SyncRecordKind, core: AppCore) -> SyncBinding {
        let visibility = core.visibility
        typealias Format = WindowManagementFileFormat
        switch kind {
        case .setting:
            return settings(core)
        case .shortcut:
            return ShortcutSyncBinding.make(
                hotKeys: core.hotKeys,
                snippetsDirectory: { [settings = core.settings] in
                    AppPaths.contentFolder(settings.snippetsFolder, named: "Snippets")
                },
                isBindable: { [unowned core] action in core.canBindHotKey(action) })
        case .favorites:
            let favorites = core.favorites
            return wholeList(kind, read: { favorites.keys }, write: { favorites.replace(keys: $0) })
        case .alias:
            return aliases(core.aliases)
        case .hiddenItem:
            return hiddenItems(visibility)
        case .launcherKinds:
            return wholeList(
                kind, read: { visibility.disabledKinds.sorted() },
                write: {
                    visibility.replace(
                        hiddenItems: Array(visibility.hiddenItemKeys), disabledKinds: $0)
                })
        case .pinnedEmoji:
            let pinned = core.pinnedEmoji
            return wholeList(kind, read: { pinned.glyphs }, write: { pinned.replace($0) })
        case .customWindowSize:
            let sizes = core.customWindowSizes
            return records(
                kind, list: { sizes.sizes }, id: \.id,
                encode: { Format.json($0, shortcut: nil) },
                decode: { Format.customSizes(from: .array([$0]))?.records.first },
                upsert: { size in
                    if sizes.size(id: size.id) == nil {
                        try sizes.add(size)
                    } else {
                        try sizes.update(size)
                    }
                },
                remove: { _ = sizes.remove(id: $0) })
        case .windowLayout:
            let layouts = core.windowLayouts
            return records(
                kind, list: { layouts.layouts }, id: \.id,
                encode: { Format.json($0, shortcut: nil) },
                decode: { Format.layouts(from: .array([$0]))?.records.first },
                upsert: { layout in
                    if layouts.layout(id: layout.id) == nil {
                        try layouts.add(layout)
                    } else {
                        try layouts.update(layout)
                    }
                },
                remove: { _ = layouts.remove(id: $0) })
        case .room:
            let rooms = core.rooms
            return records(
                kind, list: { rooms.rooms }, id: \.id,
                encode: { Format.json($0, shortcut: nil) },
                decode: { Format.rooms(from: .array([$0]))?.records.first },
                upsert: { room in
                    if let learned = rooms.room(id: room.id) {
                        // What a room learns by being entered stays with the Mac that entered it.
                        try rooms.update(room.keepingRuntime(of: learned))
                    } else {
                        try rooms.add(room)
                    }
                },
                remove: { _ = rooms.remove(id: $0) })
        case .quicklink:
            let quicklinks = core.quicklinks
            return codable(
                kind, list: { quicklinks.isAvailable ? quicklinks.quicklinks : nil },
                find: quicklinks.quicklink(id:),
                add: { try quicklinks.add($0) }, update: { try quicklinks.update($0) },
                remove: { try? quicklinks.remove(id: $0) })
        case .customCommand:
            let commands = core.customCommands
            return codable(
                kind, list: { commands.commands }, find: commands.command(id:),
                add: { _ = try commands.add($0) }, update: { try commands.update($0) },
                remove: { _ = commands.remove(id: $0) })
        case .quickAction:
            let actions = core.customQuickActions
            return codable(
                kind, list: { actions.isAvailable ? actions.actions : nil }, find: actions.action(id:),
                add: { try actions.add($0) }, update: { try actions.update($0) },
                remove: { _ = try? actions.remove(id: $0) })
        case .aiConnection:
            return aiConnections(core)
        case .mcpServer:
            return mcpServers(core)
        case .snippet:
            return snippets(core.snippetsStore)
        case .note:
            return notes(core.notesStore)
        case .installedExtension:
            return ExtensionSyncBinding.make(extensions: core.extensions, settings: core.settings)
        }
    }

    /// The settings.json bindings, so a setting has one spelling whichever way it travels.
    private static func settings(_ core: AppCore) -> SyncBinding {
        let windowManagement = WindowManagementSettingsFile(
            sizes: core.customWindowSizes, layouts: core.windowLayouts, rooms: core.rooms,
            hotKeys: core.hotKeys)
        let all = SettingsFileSchema.bindings(
            settings: core.settings, ai: core.aiSettings, quickActions: core.quickActionSettings,
            windowManagement: windowManagement)
        let synced = Dictionary(
            uniqueKeysWithValues: all.filter { SyncSettingsCoverage.syncs($0.key) }.map {
                ($0.key.rawValue, $0)
            })
        return SyncBinding(
            kind: .setting,
            read: { synced.mapValues { SettingsFileFormat.render(value: $0.read()) } },
            write: { key, body in
                guard let binding = synced[key], let value = SettingsFileFormat.parse(value: body)
                else { return false }
                return binding.write(value).isEmpty
            },
            remove: { _ in },
            isAvailable: { synced[$0] != nil })
    }

    /// The files in the snippets folder, written straight to it; the store's watcher reloads.
    private static func snippets(_ store: SnippetsStore) -> SyncBinding {
        let reader = FolderSyncReader()
        return SyncBinding(
            kind: .snippet,
            observe: {
                _ = store.snippets
                _ = store.snippetsDirectory
            },
            read: { await reader.read(store.snippetsDirectory) },
            write: { name, payload in
                await FolderSyncReader.write(payload.body, named: name, in: store.snippetsDirectory)
            },
            remove: { name in await FolderSyncReader.trash(named: name, in: store.snippetsDirectory) },
            scope: { store.snippetsDirectory.path },
            keepCopy: { name, body in
                await FolderSyncReader.writeCopy(body, of: name, in: store.snippetsDirectory)
            })
    }

    /// Notes go through their store, which never lets another Mac's version replace a draft.
    private static func notes(_ store: NotesStore) -> SyncBinding {
        let reader = FolderSyncReader()
        func keepCopy(of name: String, _ body: Data) async -> Bool {
            guard let source = String(data: body, encoding: .utf8) else { return false }
            let title = (SyncFileName.conflictCopy(of: name) as NSString).deletingPathExtension
            return await store.importNotes([.init(title: title, source: source)]) == 1
        }
        return SyncBinding(
            kind: .note,
            observe: {
                _ = store.summaries
                _ = store.notesDirectory
            },
            read: { await reader.read(store.notesDirectory) },
            write: { name, payload in
                guard SyncFileName.isValid(name),
                    let source = String(data: payload.body, encoding: .utf8)
                else { return false }
                switch await store.acceptRemote(source, for: NoteID(rawValue: name)) {
                case .replaced: return true
                case .keptDraft: return await keepCopy(of: name, payload.body)
                case .failed: return false
                }
            },
            remove: { name in
                let id = NoteID(rawValue: name)
                guard SyncFileName.isValid(name), store.activeID != id || !store.isDirty else {
                    return
                }
                if store.summaries.contains(where: { $0.id == id }) {
                    _ = await store.trash(id)
                } else {
                    await FolderSyncReader.trash(named: name, in: store.notesDirectory)
                }
            },
            scope: { store.notesDirectory.path },
            keepCopy: keepCopy)
    }

    /// A connection, and its API key while keys sync; a key never arriving keeps the one here.
    private static func aiConnections(_ core: AppCore) -> SyncBinding {
        let ai = core.aiSettings
        let settings = core.settings
        let keys = KeychainSecretStore.aiAPIKeys
        return SyncBinding(
            kind: .aiConnection,
            observe: {
                _ = ai.connections
                _ = settings.cloudSyncIncludesSecrets
            },
            read: {
                let connections = ai.connections
                let apiKeys: [UUID: String] =
                    settings.cloudSyncIncludesSecrets
                    ? await Task.detached(priority: .utility) {
                        var found: [UUID: String] = [:]
                        for connection in connections {
                            found[connection.id] = try? keys.secret(for: connection.id)
                        }
                        return found
                    }.value : [:]
                var records: [String: SyncPayload] = [:]
                for connection in connections {
                    guard let body = SyncBinding.encode(connection) else { continue }
                    records[key(connection.id)] = SyncPayload(
                        body: body, secrets: apiKeys[connection.id].map { Data($0.utf8) })
                }
                return records
            },
            write: { name, payload in
                guard let connection = SyncBinding.decode(AIConnection.self, from: payload.body),
                    key(connection.id) == name
                else { return false }
                if ai.connection(id: connection.id) != connection { ai.save(connection) }
                guard settings.cloudSyncIncludesSecrets,
                    let apiKey = payload.secrets.flatMap({ String(data: $0, encoding: .utf8) })
                else { return true }
                let id = connection.id
                return await Task.detached(priority: .utility) {
                    guard (try? keys.secret(for: id)) != apiKey else { return true }
                    return (try? keys.setSecret(apiKey, for: id)) != nil
                }.value
            },
            remove: { name in
                guard let id = UUID(uuidString: name) else { return }
                ai.removeConnection(id: id)
                await Task.detached(priority: .utility) { try? keys.removeSecret(for: id) }.value
            })
    }

    /// A server, with its header and variables while secrets sync; trust never leaves its Mac.
    private static func mcpServers(_ core: AppCore) -> SyncBinding {
        struct Shared: Codable {
            var headerValue: String
            var environment: [String: String]
        }
        let store = core.mcpSettings
        let settings = core.settings
        let secretStore = MCPSecretStore()
        return SyncBinding(
            kind: .mcpServer,
            observe: {
                _ = store.servers
                _ = settings.cloudSyncIncludesSecrets
            },
            read: {
                let servers = store.servers
                let secrets: [UUID: MCPSecretStore.Secrets] =
                    settings.cloudSyncIncludesSecrets
                    ? await Task.detached(priority: .utility) {
                        Dictionary(
                            uniqueKeysWithValues: servers.map { ($0.id, secretStore.secrets(for: $0.id)) })
                    }.value : [:]
                var records: [String: SyncPayload] = [:]
                for server in servers {
                    var shared = server
                    shared.trust = .ask
                    guard let body = SyncBinding.encode(shared) else { continue }
                    let secret = secrets[server.id].flatMap {
                        SyncBinding.encode(
                            Shared(headerValue: $0.headerValue, environment: $0.environment))
                    }
                    records[key(server.id)] = SyncPayload(body: body, secrets: secret)
                }
                return records
            },
            write: { [unowned core] name, payload in
                guard var server = SyncBinding.decode(MCPServer.self, from: payload.body),
                    key(server.id) == name
                else { return false }
                let existing = store.server(id: server.id)
                server.trust = existing?.trust ?? .ask
                let id = server.id
                let stored = await Task.detached(priority: .utility) {
                    secretStore.secrets(for: id)
                }.value
                var secrets = stored
                if settings.cloudSyncIncludesSecrets,
                    let shared = payload.secrets.flatMap({ SyncBinding.decode(Shared.self, from: $0) })
                {
                    secrets.headerValue = shared.headerValue
                    secrets.environment = shared.environment
                }
                // Saving reconnects the server, so an unchanged record must not touch it.
                guard existing != server || secrets != stored else { return true }
                return (try? core.mcpCoordinator.save(server, secrets: secrets)) != nil
            },
            remove: { [unowned core] name in
                guard let id = UUID(uuidString: name), store.server(id: id) != nil else { return }
                try? core.mcpCoordinator.remove(id)
            })
    }

    private static func aliases(_ store: AliasStore) -> SyncBinding {
        SyncBinding(
            kind: .alias,
            read: { store.aliases.compactMapValues { SyncBinding.encode($0) } },
            write: { key, body in
                guard let alias = SyncBinding.decode(String.self, from: body) else { return false }
                store.setAlias(alias, for: key)
                return store.alias(for: key) == alias
            },
            remove: { store.removeKeys([$0]) })
    }

    /// One record per hidden item, so two Macs hiding different things both keep theirs.
    private static func hiddenItems(_ store: VisibilityStore) -> SyncBinding {
        let hidden = Data("true".utf8)
        return SyncBinding(
            kind: .hiddenItem,
            read: { Dictionary(uniqueKeysWithValues: store.hiddenItemKeys.map { ($0, hidden) }) },
            write: { key, _ in
                guard !store.hiddenItemKeys.contains(key) else { return true }
                store.replace(
                    hiddenItems: Array(store.hiddenItemKeys) + [key],
                    disabledKinds: Array(store.disabledKinds))
                return true
            },
            remove: { store.removeItemKeys([$0]) })
    }

    /// An ordered list syncs whole: merging two orders item by item produces neither.
    private static func wholeList<Value: Codable & Equatable>(
        _ kind: SyncRecordKind, read: @escaping () -> Value, write: @escaping (Value) -> Void
    ) -> SyncBinding {
        let key = SyncRecordKind.wholeListKey
        return SyncBinding(
            kind: kind,
            read: { SyncBinding.encode(read()).map { [key: $0] } ?? [:] },
            write: { _, body in
                guard let value = SyncBinding.decode(Value.self, from: body) else { return false }
                if read() != value { write(value) }
                return true
            },
            remove: { _ in })
    }

    /// Items keyed by id; an unchanged one is left alone, and one the store refuses is held.
    private static func codable<Record: Codable & Equatable & Identifiable>(
        _ kind: SyncRecordKind, list: @escaping () -> [Record]?,
        find: @escaping (UUID) -> Record?, add: @escaping (Record) throws -> Void,
        update: @escaping (Record) throws -> Void, remove: @escaping (UUID) -> Void
    ) -> SyncBinding where Record.ID == UUID {
        SyncBinding(
            kind: kind,
            read: {
                list().map { items in
                    Dictionary(
                        uniqueKeysWithValues: items.compactMap { item in
                            SyncBinding.encode(item).map { (key(item.id), $0) }
                        })
                }
            },
            write: { name, body in
                guard let record = SyncBinding.decode(Record.self, from: body),
                    key(record.id) == name
                else { return false }
                guard let existing = find(record.id) else { return (try? add(record)) != nil }
                return existing == record || (try? update(record)) != nil
            },
            remove: { name in
                if let id = UUID(uuidString: name) { remove(id) }
            })
    }

    private static func key(_ id: UUID) -> String { id.uuidString.lowercased() }

    /// Records in settings.json's own spelling, which already leaves out what is machine-local.
    private static func records<Record>(
        _ kind: SyncRecordKind, list: @escaping () -> [Record], id: KeyPath<Record, UUID>,
        encode: @escaping (Record) -> SettingsFileJSON,
        decode: @escaping (SettingsFileJSON) -> Record?,
        upsert: @escaping (Record) throws -> Void,
        remove: @escaping (UUID) -> Void
    ) -> SyncBinding {
        SyncBinding(
            kind: kind,
            read: {
                Dictionary(
                    uniqueKeysWithValues: list().map {
                        (key($0[keyPath: id]), SettingsFileFormat.render(value: encode($0)))
                    })
            },
            write: { key, body in
                guard let json = SettingsFileFormat.parse(value: body), let record = decode(json),
                    Self.key(record[keyPath: id]) == key
                else { return false }
                // A name another record holds here is refused, which holds the record.
                return (try? upsert(record)) != nil
            },
            remove: { key in
                if let id = UUID(uuidString: key) { remove(id) }
            })
    }
}
