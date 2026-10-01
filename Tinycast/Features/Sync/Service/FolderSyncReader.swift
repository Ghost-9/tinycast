import Foundation

/// The Markdown files directly in one folder, each re-read only when its date or size moves.
@MainActor
final class FolderSyncReader {
    private struct File: Sendable {
        let modified: Date
        let size: Int
        let body: Data
    }

    private var folder: URL?
    private var files: [String: File] = [:]

    func read(_ folder: URL) async -> [String: SyncPayload] {
        let known = folder == self.folder ? files : [:]
        let scanned = await Task.detached(priority: .utility) {
            Self.scan(folder, known: known)
        }.value
        self.folder = folder
        files = scanned
        return scanned.mapValues { SyncPayload(body: $0.body) }
    }

    /// Atomic, and only ever inside `folder`: a name that could leave it is refused.
    nonisolated static func write(_ body: Data, named name: String, in folder: URL) async -> Bool {
        guard SyncFileName.isValid(name) else { return false }
        return await Task.detached(priority: .utility) {
            do {
                try FileManager.default.createDirectory(
                    at: folder, withIntermediateDirectories: true)
                try body.write(to: folder.appending(path: name), options: .atomic)
                return true
            } catch {
                return false
            }
        }.value
    }

    /// Beside `name`, under the first conflicted-copy name still free.
    nonisolated static func writeCopy(_ body: Data, of name: String, in folder: URL) async -> Bool {
        let free = await Task.detached(priority: .utility) {
            (1...99).lazy.map { SyncFileName.conflictCopy(of: name, attempt: $0) }.first {
                !FileManager.default.fileExists(atPath: folder.appending(path: $0).path)
            }
        }.value
        guard let free else { return false }
        return await write(body, named: free, in: folder)
    }

    /// To the Trash rather than gone, so a delete made on another Mac stays recoverable here.
    nonisolated static func trash(named name: String, in folder: URL) async {
        guard SyncFileName.isValid(name) else { return }
        await Task.detached(priority: .utility) {
            try? FileManager.default.trashItem(
                at: folder.appending(path: name), resultingItemURL: nil)
        }.value
    }

    /// A link is skipped like a hidden file: writing it back would replace the link with a copy.
    private nonisolated static func scan(_ folder: URL, known: [String: File]) -> [String: File] {
        let keys: Set<URLResourceKey> = [
            .isRegularFileKey, .isSymbolicLinkKey, .contentModificationDateKey, .fileSizeKey
        ]
        guard
            let urls = try? FileManager.default.contentsOfDirectory(
                at: folder, includingPropertiesForKeys: Array(keys), options: [.skipsHiddenFiles])
        else { return [:] }
        var files: [String: File] = [:]
        for url in urls {
            let name = url.lastPathComponent
            guard SyncFileName.isValid(name), let values = try? url.resourceValues(forKeys: keys),
                values.isRegularFile == true, values.isSymbolicLink != true
            else { continue }
            let modified = values.contentModificationDate ?? .distantPast
            let size = values.fileSize ?? 0
            if let file = known[name], file.modified == modified, file.size == size {
                files[name] = file
            } else if let body = try? Data(contentsOf: url) {
                files[name] = File(modified: modified, size: size, body: body)
            }
        }
        return files
    }
}
