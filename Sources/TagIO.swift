import Foundation
import AppKit

/// Finder's eight tag colors, by the index Finder stores next to each tag name.
enum TagColor: Int, CaseIterable, Identifiable {
    case none = 0, gray, green, purple, blue, yellow, red, orange

    var id: Int { rawValue }

    var name: String {
        switch self {
        case .none: return "None"
        case .gray: return "Gray"
        case .green: return "Green"
        case .purple: return "Purple"
        case .blue: return "Blue"
        case .yellow: return "Yellow"
        case .red: return "Red"
        case .orange: return "Orange"
        }
    }

    var nsColor: NSColor? {
        switch self {
        case .none: return nil
        case .gray: return .systemGray
        case .green: return .systemGreen
        case .purple: return .systemPurple
        case .blue: return .systemBlue
        case .yellow: return .systemYellow
        case .red: return .systemRed
        case .orange: return .systemOrange
        }
    }

    /// The colors offered in menus, in Finder's order.
    static let choices: [TagColor] = [.red, .orange, .yellow, .green, .blue, .purple, .gray]
}

/// Reads and writes macOS Finder tags. Tags live in the
/// `com.apple.metadata:_kMDItemUserTags` xattr as a plist array of
/// `"name\n<color index>"`. Written directly rather than through
/// `URLResourceKey.tagNamesKey`, which resets every tag's color to none.
enum TagIO {
    private static let attribute = "com.apple.metadata:_kMDItemUserTags"

    /// Each tag's color across the library, so a tag newly added to a file
    /// gets the color it has elsewhere. Kept current by the app.
    private static let knownColorsLock = NSLock()
    nonisolated(unsafe) private static var knownColors: [String: TagColor] = [:]

    static func rememberColors(_ colors: [String: TagColor]) {
        knownColorsLock.lock()
        knownColors = colors
        knownColorsLock.unlock()
    }

    private static func colorForNewTag(_ tag: String) -> TagColor? {
        knownColorsLock.lock()
        defer { knownColorsLock.unlock() }
        return knownColors[tag]
    }

    static func tags(of url: URL) -> [String] {
        entries(of: url).map(\.name)
    }

    /// Each tag with its color, in the file's order.
    static func entries(of url: URL) -> [(name: String, color: TagColor)] {
        let length = getxattr(url.path, attribute, nil, 0, 0, 0)
        guard length > 0 else {
            return []
        }
        var data = Data(count: length)
        let read = data.withUnsafeMutableBytes {
            getxattr(url.path, attribute, $0.baseAddress, length, 0, 0)
        }
        guard read > 0,
              let list = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String] else {
            return []
        }
        return list.map(parse)
    }

    static func color(of tag: String, on url: URL) -> TagColor? {
        entries(of: url).first { $0.name == tag }?.color
    }

    static func setTags(_ tags: [String], on url: URL) throws {
        let existing = Dictionary(entries(of: url).map { ($0.name, $0.color) }, uniquingKeysWith: { first, _ in first })
        var seen = Set<String>()
        let unique = tags.filter { seen.insert($0).inserted }
        try write(unique.map { ($0, existing[$0] ?? colorForNewTag($0) ?? .none) }, to: url)
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

    /// Rename a tag across a set of files (swap old->new where present),
    /// keeping its color.
    static func renameTag(_ old: String, to new: String, in urls: [URL]) {
        for url in urls {
            let current = entries(of: url)
            guard current.contains(where: { $0.name == old }) else { continue }
            var seen = Set<String>()
            let updated = current
                .map { ($0.name == old ? new : $0.name, $0.color) }
                .filter { seen.insert($0.0).inserted }
            try? write(updated, to: url)
        }
    }

    /// Recolor one tag on every file that has it. Returns each file's previous
    /// color so the change can be undone.
    @discardableResult
    static func setColor(_ color: TagColor, of tag: String, on urls: [URL]) -> [URL: TagColor] {
        var previous: [URL: TagColor] = [:]
        for url in urls {
            let current = entries(of: url)
            guard let old = current.first(where: { $0.name == tag })?.color else { continue }
            previous[url] = old
            guard old != color else { continue }
            try? write(current.map { ($0.name, $0.name == tag ? color : $0.color) }, to: url)
        }
        return previous
    }

    // MARK: - Encoding

    private static func parse(_ entry: String) -> (name: String, color: TagColor) {
        guard let newline = entry.lastIndex(of: "\n"),
              let index = Int(entry[entry.index(after: newline)...]) else {
            return (entry, .none)
        }
        return (String(entry[..<newline]), TagColor(rawValue: index) ?? .none)
    }

    private static func write(_ entries: [(String, TagColor)], to url: URL) throws {
        if entries.isEmpty {
            if removexattr(url.path, attribute, 0) != 0 && errno != ENOATTR {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            return
        }
        let list = entries.map { "\($0.0)\n\($0.1.rawValue)" }
        let data = try PropertyListSerialization.data(fromPropertyList: list, format: .binary, options: 0)
        let status = data.withUnsafeBytes {
            setxattr(url.path, attribute, $0.baseAddress, data.count, 0, 0)
        }
        if status != 0 {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }
}
