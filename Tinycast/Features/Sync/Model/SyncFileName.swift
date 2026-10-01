import Foundation

/// A file a folder-backed kind syncs, named by its file name alone.
enum SyncFileName {
    /// Only a visible `.md` file directly in the folder, so a key from another Mac never leaves it.
    static func isValid(_ name: String) -> Bool {
        let file = name as NSString
        return !name.hasPrefix(".") && !name.contains("/") && name.utf8.count <= 255
            && file.pathExtension.lowercased() == "md" && !file.deletingPathExtension.isEmpty
    }

    /// Where the other side of a conflict is kept, beside the file it disagreed with.
    static func conflictCopy(of name: String, attempt: Int = 1) -> String {
        let base = (name as NSString).deletingPathExtension
        let suffix = attempt == 1 ? " (conflicted copy)" : " (conflicted copy \(attempt))"
        return base + suffix + ".md"
    }
}
