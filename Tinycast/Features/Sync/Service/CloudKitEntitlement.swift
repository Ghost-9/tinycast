import Security

/// Read before the first `CKContainer` exists: naming a container the build isn't signed for traps.
enum CloudKitEntitlement {
    static func allows(container identifier: String) -> Bool {
        guard let task = SecTaskCreateFromSelf(nil),
            let value = SecTaskCopyValueForEntitlement(
                task, "com.apple.developer.icloud-container-identifiers" as CFString, nil)
        else { return false }
        return (value as? [String])?.contains(identifier) == true
    }
}
