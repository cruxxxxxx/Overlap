import Foundation

/// Reads and writes macOS Finder tags via URL resource values. This handles the
/// `com.apple.metadata:_kMDItemUserTags` extended attribute (including color
/// indices) for us — no manual xattr/plist parsing.
enum TagIO {

    static func tags(of url: URL) -> [String] {
        (try? url.resourceValues(forKeys: [.tagNamesKey]).tagNames) ?? []
    }

    static func setTags(_ tags: [String], on url: URL) throws {
        // De-dupe while preserving order.
        var seen = Set<String>()
        let unique = tags.filter { seen.insert($0).inserted }
        try (url as NSURL).setResourceValue(unique, forKey: .tagNamesKey)
    }

    static func addTag(_ tag: String, to urls: [URL]) {
        for url in urls {
            var current = tags(of: url)
            guard !current.contains(tag) else { continue }
            current.append(tag)
            try? setTags(current, on: url)
        }
    }

    static func removeTag(_ tag: String, from urls: [URL]) {
        for url in urls {
            let current = tags(of: url)
            guard current.contains(tag) else { continue }
            try? setTags(current.filter { $0 != tag }, on: url)
        }
    }

    /// Rename a tag across a set of files (swap old->new where present).
    static func renameTag(_ old: String, to new: String, in urls: [URL]) {
        for url in urls {
            let current = tags(of: url)
            guard current.contains(old) else { continue }
            let updated = current.map { $0 == old ? new : $0 }
            try? setTags(updated, on: url)
        }
    }
}
