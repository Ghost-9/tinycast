import Foundation

/// Shortcuts as records keyed by `defaultsKey`; a snippet's key names its file, never its path.
@MainActor
enum ShortcutSyncBinding {
    /// `isBindable` is false for an action whose app, item or file this Mac doesn't have.
    static func make(
        hotKeys: HotKeyManager, snippetsDirectory: @escaping () -> URL,
        isBindable: @escaping (HotKeyAction) -> Bool
    ) -> SyncBinding {
        func key(for action: HotKeyAction) -> String? {
            guard case .snippet(let path) = action else { return action.defaultsKey }
            let folder = snippetsDirectory().standardizedFileURL.path + "/"
            guard path.hasPrefix(folder) else { return nil }
            return HotKeyAction.snippet(id: String(path.dropFirst(folder.count))).defaultsKey
        }
        func action(for key: String) -> HotKeyAction? {
            guard let action = HotKeyAction(defaultsKey: key) else { return nil }
            guard case .snippet(let name) = action else { return action }
            return .snippet(id: snippetsDirectory().appending(path: name).standardizedFileURL.path)
        }
        return SyncBinding(
            kind: .shortcut,
            read: {
                var records: [String: Data] = [:]
                for (action, binding) in hotKeys.allBindings {
                    guard let key = key(for: action), let body = SyncBinding.encode(binding) else {
                        continue
                    }
                    records[key] = body
                }
                return records
            },
            write: { key, body in
                guard let action = action(for: key), isBindable(action),
                    let binding = SyncBinding.decode(HotKeyBinding.self, from: body)
                else { return false }
                guard hotKeys.binding(for: action) != binding else { return true }
                // Held, not forced: a chord another action holds here would never register.
                guard hotKeys.conflictOwner(of: binding, excluding: action) == nil else {
                    return false
                }
                hotKeys.setBinding(binding, for: action)
                return true
            },
            remove: { key in
                guard let action = action(for: key), hotKeys.binding(for: action) != nil else {
                    return
                }
                if hotKeys.recordingAction == action { hotKeys.recordingAction = nil }
                hotKeys.setBinding(nil, for: action)
            },
            isAvailable: { key in action(for: key).map(isBindable) ?? false })
    }
}
