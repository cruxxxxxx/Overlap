import Foundation

/// The wire contract between Overlap and out-of-process suggestion plugins.
///
/// A plugin is any standalone executable discovered under the Plugins dir with a
/// `manifest.json`. Overlap writes a `SuggestRequest` (JSON) to the plugin's
/// stdin and reads a `SuggestResponse` (JSON) from its stdout. Nothing here is
/// shared as a library — the contract IS the JSON, so plugins can be written in
/// any language. Bump `PluginProtocol.version` on a breaking change.
enum PluginProtocol { static let version = 1 }

// MARK: - Request (host → plugin stdin)

struct SuggestRequest: Codable {
    var protocolVersion = PluginProtocol.version
    var files: [RequestFile]          // the targets to suggest tags FOR
    var knownTags: [String]?          // sent only when manifest.wantsKnownTags
    var library: [LibraryItem]?       // sent only when manifest.wantsLibrary
    var settings: [String: SettingValue]?  // merged values for manifest.settings keys
}

// MARK: - Plugin-declared settings (rendered by the host's Plugin Settings UI)

/// A JSON scalar setting value — bool, number, or string. Tolerant decode so any
/// language's JSON maps cleanly.
enum SettingValue: Codable, Hashable {
    case bool(Bool), number(Double), string(String)

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let b = try? c.decode(Bool.self) { self = .bool(b); return }
        if let n = try? c.decode(Double.self) { self = .number(n); return }
        self = .string(try c.decode(String.self))
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .bool(let b): try c.encode(b)
        case .number(let n): try c.encode(n)
        case .string(let s): try c.encode(s)
        }
    }

    var boolValue: Bool? { if case .bool(let b) = self { return b }; return nil }
    var numberValue: Double? { if case .number(let n) = self { return n }; return nil }
    var stringValue: String? { if case .string(let s) = self { return s }; return nil }
}

/// One tunable a plugin exposes. The host renders bool → toggle, number → slider
/// (min/max/step), choice → picker; groups by `section`; and injects the merged
/// values into every request's `settings`.
struct PluginSetting: Codable {
    let key: String
    let type: String                 // "bool" | "number" | "choice"
    let label: String
    var help: String? = nil
    var section: String? = nil
    var min: Double? = nil
    var max: Double? = nil
    var step: Double? = nil
    var choices: [Choice]? = nil
    let defaultValue: SettingValue

    struct Choice: Codable { let value: String; let label: String }

    enum CodingKeys: String, CodingKey {
        case key, type, label, help, section, min, max, step, choices
        case defaultValue = "default"
    }
}

struct RequestFile: Codable {
    let path: String
    let kind: String                  // FileKind.rawValue
    let ext: String
    let tags: [String]
    let size: Int64?
    let modDate: Date?
    let createdDate: Date?
}

/// One already-tagged file in the corpus — a plugin's training / neighbor set.
/// Clustering plugins embed these (reading pixels from `path` themselves) and
/// suggest the tags of the nearest matches; `modDate` lets them cache by file.
struct LibraryItem: Codable {
    let path: String
    let kind: String
    let tags: [String]
    let modDate: Date?
}

// MARK: - Response (plugin stdout → host)

struct SuggestResponse: Codable {
    let protocolVersion: Int?
    let suggestions: [RawSuggestion]
}

struct RawSuggestion: Codable {
    let path: String                  // must match a request file path, else dropped
    let tag: String
    let confidence: Double            // 0…1, clamped host-side
    let source: String?               // optional; host overrides with the plugin name
    var group: Bool? = nil            // true: a cluster handle to name, not a tag to apply
}

// MARK: - Merged result the UI consumes

struct TagSuggestion: Identifiable, Hashable {
    let tag: String
    let confidence: Double
    let source: String                // plugin display name
    let paths: Set<String>            // which selected files it applies to
    var isGroup: Bool = false         // true: a cluster handle — select its members and
                                      // name them, rather than applying `tag` literally
    var id: String { tag }
}

// MARK: - Manifest

struct PluginManifest: Codable {
    let name: String
    let id: String
    let version: String
    var protocolVersion = 1
    let exec: String                  // executable path, relative to the manifest dir
    var handles: [String] = ["*"]     // FileKind rawValues, or ["*"] for all kinds
    var batch = true                  // true: one call for all targets; false: per-file
    var wantsKnownTags = false
    var wantsLibrary = false          // receive the full tagged corpus
    var timeoutMs = 5000
    var settings: [PluginSetting]? = nil   // tunables the host renders + injects
}

/// A manifest paired with its resolved on-disk location.
struct DiscoveredPlugin: Identifiable {
    let manifest: PluginManifest
    let dir: URL
    let execURL: URL
    var id: String { manifest.id }

    func handles(_ kind: FileKind) -> Bool {
        manifest.handles.contains("*") || manifest.handles.contains(kind.rawValue)
    }
}

// MARK: - Shared JSON coders (ISO-8601 dates so any language can parse)

enum PluginCoder {
    static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        return e
    }()
    static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()
}
