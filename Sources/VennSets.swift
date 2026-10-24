import Foundation

/// A Venn circle. Most are tags; the rest are encoded in the set's string
/// with an `@kind:` prefix, so diagrams, regions and saved queries need no
/// new fields:
///
///   @type:image   @ext:png   @year:2024   @search:girl with spiral hair
///   @similar:/path/a.jpg\n/path/b.jpg
enum QuerySet: Hashable {
    case tag(String)
    case kind(FileKind)
    case ext(String)
    case year(Int)
    case search(String)
    case similar([String])

    private static let marker = "@"

    init(_ raw: String) {
        guard raw.hasPrefix(Self.marker), let colon = raw.firstIndex(of: ":") else {
            self = .tag(raw)
            return
        }
        let name = raw[raw.index(after: raw.startIndex)..<colon]
        let value = String(raw[raw.index(after: colon)...])
        switch name {
        case "type":
            self = FileKind(rawValue: value).map(QuerySet.kind) ?? .tag(raw)
        case "ext":
            self = .ext(value.lowercased())
        case "year":
            self = Int(value).map(QuerySet.year) ?? .tag(raw)
        case "search":
            self = .search(value)
        case "similar":
            self = .similar(value.components(separatedBy: "\n").filter { !$0.isEmpty })
        default:
            self = .tag(raw)
        }
    }

    var raw: String {
        switch self {
        case .tag(let tag):
            return tag
        case .kind(let kind):
            return "@type:\(kind.rawValue)"
        case .ext(let ext):
            return "@ext:\(ext)"
        case .year(let year):
            return "@year:\(year)"
        case .search(let text):
            return "@search:\(text)"
        case .similar(let paths):
            return "@similar:" + paths.joined(separator: "\n")
        }
    }

    var isTag: Bool {
        if case .tag = self {
            return true
        }
        return false
    }

    /// Membership comes from a plugin run, not from the file itself.
    var needsPlugin: Bool {
        switch self {
        case .search, .similar:
            return true
        default:
            return false
        }
    }

    /// Full name, for chips and descriptions.
    var displayName: String {
        switch self {
        case .tag(let tag):
            return tag
        case .kind(let kind):
            return kind.label
        case .ext(let ext):
            return ".\(ext)"
        case .year(let year):
            return "From \(year)"
        case .search(let text):
            return "“\(text)”"
        case .similar(let paths):
            if paths.count == 1, let path = paths.first {
                return "Like \(URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent)"
            }
            return "Like \(paths.count) images"
        }
    }

    /// Short name, for labels inside a diagram.
    var shortName: String {
        switch self {
        case .tag(let tag):
            return tag.split(separator: "/").last.map(String.init) ?? tag
        case .year(let year):
            return String(year)
        default:
            return displayName
        }
    }

    var symbol: String? {
        switch self {
        case .tag:
            return nil
        case .kind:
            return "doc"
        case .ext:
            return "textformat"
        case .year:
            return "calendar"
        case .search:
            return "sparkle.magnifyingglass"
        case .similar:
            return "photo.stack"
        }
    }

    static func displayName(_ raw: String) -> String {
        QuerySet(raw).displayName
    }

    static func shortName(_ raw: String) -> String {
        QuerySet(raw).shortName
    }
}

extension FileItem {
    /// The year a file is filed under: when it was made, else last changed.
    var year: Int? {
        (createdDate ?? modDate).map { Calendar.current.component(.year, from: $0) }
    }
}
