import Foundation
import SwiftUI
import UniformTypeIdentifiers

/// Which left-column mode is active.
enum LibraryMode { case tags, queue, explore }

/// One section of the queue's "group by suggestions" view: a suggested tag and
/// the (currently visible) files it covers. `suggestion == nil` is the trailing
/// leftover section — visible queue files no plugin suggested anything for.
struct SuggestionSection: Identifiable {
    let suggestion: TagSuggestion?
    let items: [FileItem]
    var id: String { suggestion?.tag ?? "·ungrouped" }
}

/// How a diagram's included sets combine when no regions are painted.
///  - all:  item has every set (AND) — the default
///  - any:  item has at least one (OR)
///  - only: item's tags are exactly the sets, nothing else ("Exact",
///          meaningful only when the query has a single diagram)
enum MatchMode: String, Codable { case all, any, only }

/// How a diagram joins the previous one (ignored on the first diagram).
/// The query evaluates as sum-of-products: OR starts a new clause, AND binds
/// diagrams within a clause — `D1 AND D2 OR D3` = (D1 ∧ D2) ∨ D3.
enum GroupOp: String, Codable { case and = "AND", or = "OR" }

/// One Venn diagram: an ordered list of sets and (optionally) painted regions.
/// Painted regions override `mode`.
struct VennGroup: Identifiable, Equatable, Codable {
    let id: UUID
    var sets: [String]
    var regions: Set<Int>     // membership bitmasks over `sets`; empty = use mode
    var mode: MatchMode
    var op: GroupOp           // how this diagram joins the previous one

    init(id: UUID = UUID(), sets: [String] = [], regions: Set<Int> = [],
         mode: MatchMode = .all, op: GroupOp = .and) {
        self.id = id
        self.sets = sets
        self.regions = regions
        self.mode = mode
        self.op = op
    }
}

/// A named snapshot of a full query — its diagrams (sets + painted regions +
/// mode + join op) plus global excludes — so a Venn setup can be reused without
/// rebuilding it. Type filters are session-only and intentionally not saved.
struct SavedQuery: Identifiable, Codable {
    var id: UUID = UUID()
    var name: String
    var groups: [VennGroup]
    var excludes: [String]
}

/// A Venn set's effective role across a diagram's painted regions:
/// required in all of them, excluded from all of them, or mixed.
enum RegionRole { case required, excluded, mixed }

/// Stable tag colors.
enum TagPalette {
    static let colors: [Color] =
        [.blue, .purple, .pink, .orange, .green, .teal, .indigo, .mint, .red, .cyan]

    private static func hash(_ s: String) -> Int {
        var h = 5381
        for u in s.unicodeScalars { h = ((h << 5) &+ h) &+ Int(u.value) }
        return abs(h)
    }

    /// Grouped hue: keyed by the top-level prefix (all `cat/…` share a color).
    /// Used where tags from many groups mix (map, chips).
    static func color(for path: String) -> Color {
        let key = path.split(separator: "/").first.map(String.init) ?? path
        return colors[hash(key) % colors.count]
    }

    /// Distinct hue per full tag — used inside a Venn diagram, where telling
    /// the circles apart matters more than family grouping.
    static func setColor(for path: String) -> Color {
        colors[hash(path) % colors.count]
    }
}

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

/// Broad content category, derived from the file's UTType. Drives the type
/// filter and the fallback thumbnail icon. Overlap is type-agnostic: it tags
/// and queries any file, and this just groups them.
enum FileKind: String, CaseIterable, Identifiable {
    case image, video, audio, pdf, text, archive, folder, other
    var id: String { rawValue }

    var label: String {
        switch self {
        case .image: return "Images"
        case .video: return "Videos"
        case .audio: return "Audio"
        case .pdf: return "PDFs"
        case .text: return "Text"
        case .archive: return "Archives"
        case .folder: return "Folders"
        case .other: return "Other"
        }
    }

    var symbol: String {
        switch self {
        case .image: return "photo"
        case .video: return "film"
        case .audio: return "music.note"
        case .pdf: return "doc.richtext"
        case .text: return "doc.text"
        case .archive: return "doc.zipper"
        case .folder: return "folder"
        case .other: return "doc"
        }
    }

    /// Classify by UTType conformance, preferring a real content type and
    /// falling back to the extension.
    static func of(contentType: UTType?, ext: String) -> FileKind {
        guard let ut = contentType ?? UTType(filenameExtension: ext.lowercased()) else {
            return .other
        }
        if ut.conforms(to: .folder) { return .folder }
        if ut.conforms(to: .image) { return .image }
        if ut.conforms(to: .movie) || ut.conforms(to: .video) { return .video }
        if ut.conforms(to: .audio) { return .audio }
        if ut.conforms(to: .pdf) { return .pdf }
        if ut.conforms(to: .archive) { return .archive }
        if ut.conforms(to: .text) || ut.conforms(to: .sourceCode) { return .text }
        return .other
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
    let kind: FileKind

    var id: String { url.path }
    var name: String { url.lastPathComponent }
    var ext: String { url.pathExtension.lowercased() }

    init(url: URL, tags: [String],
         modDate: Date? = nil, createdDate: Date? = nil, size: Int64? = nil,
         contentType: UTType? = nil) {
        self.url = url
        self.tags = tags
        self.tagSet = Set(tags)
        self.modDate = modDate
        self.createdDate = createdDate
        self.size = size
        self.kind = FileKind.of(contentType: contentType, ext: url.pathExtension)
    }

    /// Fast path for the on-disk cache: kind is already known, so skip the
    /// UTType lookup (matters when rebuilding thousands of items on launch).
    init(url: URL, tags: [String], modDate: Date?, createdDate: Date?,
         size: Int64?, kind: FileKind) {
        self.url = url
        self.tags = tags
        self.tagSet = Set(tags)
        self.modDate = modDate
        self.createdDate = createdDate
        self.size = size
        self.kind = kind
    }

    /// Build from disk: tags + dates + size + content type in one read.
    static func load(_ url: URL) -> FileItem {
        let vals = try? url.resourceValues(forKeys: [
            .tagNamesKey, .contentModificationDateKey, .creationDateKey,
            .fileSizeKey, .contentTypeKey])
        return FileItem(
            url: url,
            tags: vals?.tagNames ?? [],
            modDate: vals?.contentModificationDate,
            createdDate: vals?.creationDate,
            size: vals?.fileSize.map(Int64.init),
            contentType: vals?.contentType)
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
