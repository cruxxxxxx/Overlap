import Foundation

/// Which left-column mode is active.
enum LibraryMode { case tags, queue, explore }

/// Which detail view is shown.
enum ViewStyle { case grid, clusters }

/// How included tags are combined.
///  - all:     item has every included tag (AND) — the default
///  - any:     item has at least one (OR)
///  - only:    item's tags are exactly the included set, nothing else ("Exact")
///  - regions: item's membership bitmask is one of the painted Venn regions
enum MatchMode { case all, any, only, regions }

/// A Venn set's effective role across the selected regions (.regions mode):
/// required in all of them, excluded from all of them, or mixed.
enum RegionRole { case required, excluded, mixed }

/// How the results grid is sorted.
enum SortKey: String, CaseIterable, Identifiable {
    case name = "Name"
    case type = "Type"
    case dateModified = "Date Modified"
    case dateCreated = "Date Created"
    case size = "Size"
    var id: String { rawValue }
}

/// Tri-state a tag can be in within the filter.
enum TriState: Int {
    case off = 0
    case include = 1
    case exclude = 2

    var next: TriState {
        switch self {
        case .off: return .include
        case .include: return .exclude
        case .exclude: return .off
        }
    }
}

/// A file shown in the results grid.
struct FileItem: Identifiable, Hashable {
    let url: URL
    let tags: [String]
    let tagSet: Set<String>
    let modDate: Date?
    let createdDate: Date?
    let size: Int64?

    var id: String { url.path }
    var name: String { url.lastPathComponent }
    var ext: String { url.pathExtension.lowercased() }

    init(url: URL, tags: [String],
         modDate: Date? = nil, createdDate: Date? = nil, size: Int64? = nil) {
        self.url = url
        self.tags = tags
        self.tagSet = Set(tags)
        self.modDate = modDate
        self.createdDate = createdDate
        self.size = size
    }

    /// Build from disk: tags + dates + size in one resource-values read.
    static func load(_ url: URL) -> FileItem {
        let vals = try? url.resourceValues(forKeys: [
            .tagNamesKey, .contentModificationDateKey, .creationDateKey, .fileSizeKey])
        return FileItem(
            url: url,
            tags: vals?.tagNames ?? [],
            modDate: vals?.contentModificationDate,
            createdDate: vals?.creationDate,
            size: vals?.fileSize.map(Int64.init))
    }
}

/// A node in the tag tree. `fullPath` is the complete tag string up to this
/// node (e.g. "cat/Fashion"); `name` is just this segment ("Fashion").
/// A node with children is a prefix (e.g. "cat") that filters as "cat/*".
final class TagNode: Identifiable {
    let fullPath: String
    let name: String
    var count: Int
    var children: [TagNode]

    init(fullPath: String, name: String, count: Int = 0, children: [TagNode] = []) {
        self.fullPath = fullPath
        self.name = name
        self.count = count
        self.children = children
    }

    var id: String { fullPath }
    var isLeaf: Bool { children.isEmpty }

    /// Build a forest of TagNodes from tag->count, splitting each tag on "/".
    static func buildTree(from counts: [String: Int]) -> [TagNode] {
        let root = TagNode(fullPath: "", name: "")
        for (tag, count) in counts {
            let segments = tag.split(separator: "/").map(String.init)
            var node = root
            var path = ""
            for seg in segments {
                path = path.isEmpty ? seg : path + "/" + seg
                if let existing = node.children.first(where: { $0.name == seg }) {
                    node = existing
                } else {
                    let child = TagNode(fullPath: path, name: seg)
                    node.children.append(child)
                    node = child
                }
            }
            // exact-tag count lands on the final node
            node.count += count
        }
        sortAndRollUp(root)
        return root.children
    }

    /// Sort children alphabetically and roll child counts up into parents so a
    /// prefix node shows the total of everything beneath it.
    @discardableResult
    private static func sortAndRollUp(_ node: TagNode) -> Int {
        node.children.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        var total = node.count
        for child in node.children {
            total += sortAndRollUp(child)
        }
        if !node.children.isEmpty {
            node.count = total
        }
        return total
    }
}
