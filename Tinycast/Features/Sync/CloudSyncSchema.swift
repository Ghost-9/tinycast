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
                        ($0[keyPath: id].uuidString.lowercased(),
                            SettingsFileFormat.render(value: encode($0)))
                    })
            },
            write: { key, body in
                guard let json = SettingsFileFormat.parse(value: body), let record = decode(json),
                    record[keyPath: id].uuidString.lowercased() == key
                else { return false }
                // A name another record holds here is refused, which holds the record.
                return (try? upsert(record)) != nil
            },
            remove: { key in
                if let id = UUID(uuidString: key) { remove(id) }
            })
    }
}
