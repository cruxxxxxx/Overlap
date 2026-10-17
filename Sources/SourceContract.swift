import Foundation

// Wire contract for `capabilities: ["source"]` plugins: external image and
// web services that Overlap pulls files from and pushes files to.
// The host only knows *collections* (an album, a board) and *items* (a remote
// thing that becomes a local file). Every network call, credential and rate
// limit stays inside the plugin. Same process model as suggest/search.

// MARK: - Manifest

/// How the host presents a source provider (manifest `source`).
struct SourceInfo: Codable, Hashable {
    let displayName: String           // the service's name: menu titles, the library folder name
    var collectionNoun: String? = nil // what the service calls a collection ("board", "album")
    let tagPrefix: String             // "<prefix>/<Collection Title>" is the tag pulled files get
    var canPush: Bool? = nil
    var canCreateCollection: Bool? = nil
    var canEditCollection: Bool? = nil   // rename, describe, change visibility
    var visibilities: [SourceVisibility]? = nil   // choices for a collection, in the service's words

    var noun: String { collectionNoun ?? "collection" }

    func visibility(_ id: String?) -> SourceVisibility? {
        visibilities?.first { $0.id == id }
    }

    func visibilityLabel(_ id: String?) -> String? {
        guard let id else {
            return nil
        }
        return visibility(id)?.label ?? id.capitalized
    }

    /// Others can see what's in it. An id the manifest doesn't describe
    /// counts as shared, so the host warns rather than assumes privacy.
    func isShared(_ id: String?) -> Bool {
        guard let id else {
            return false
        }
        return (visibility(id)?.audience ?? 1) > 0
    }

    /// Who would newly see a collection moved from `old` to `new`.
    func widens(from old: String?, to new: String?) -> Bool {
        let from = visibility(old)?.audience ?? 0
        let to = visibility(new)?.audience ?? (new == nil ? 0 : 1)
        return to > from
    }

    var mostPrivate: SourceVisibility? {
        visibilities?.min { $0.audience < $1.audience }
    }
}

/// One visibility a service offers. `audience` orders them: 0 = only you
/// (and collaborators); higher = more people can see the collection.
struct SourceVisibility: Codable, Hashable, Identifiable {
    let id: String
    let label: String
    var help: String? = nil
    let audience: Int
}

/// One credential a plugin needs (manifest `secrets`). The host keeps the value
/// in the keychain and sends it only to the plugin that declared it.
struct PluginSecret: Codable, Hashable {
    let key: String
    let label: String
    var help: String? = nil
    var url: String? = nil            // where the user creates it
}

// MARK: - Request (host → plugin stdin)

enum SourceOp: String, Codable {
    case status, collections, resolve, pull, push, createCollection, updateCollection
    case browse    // a page of a scope (feed, search, one collection…) with previews, no downloads
    case fetch     // download chosen items by remote id
    case related   // collections connected to an item, or the owner's other collections
}

/// A place to browse, offered by the plugin for this account (e.g. search only
/// on paid tiers). `collection` is implicit: opening one collection.
struct BrowseScope: Codable, Hashable, Identifiable {
    let id: String
    let label: String
    var takesQuery: Bool? = nil
    var symbol: String? = nil         // SF Symbol name
}

struct SourceRequest: Codable {
    var protocolVersion = PluginProtocol.version
    let op: SourceOp
    var settings: [String: SettingValue]? = nil
    var secrets: [String: String]? = nil
    var collection: String? = nil     // pull / push / resolve: a collection id, slug or URL
    var cursor: String? = nil         // pull: opaque paging cursor from the last page
    var since: Date? = nil            // pull: last successful sync, a hint only
    var stagingDir: String? = nil     // pull: the plugin writes downloads here
    var knownIds: [String]? = nil     // pull: already local — list them, but don't download
    var items: [SourcePushItem]? = nil   // push
    var title: String? = nil          // createCollection / updateCollection
    var visibility: String? = nil     // createCollection / updateCollection
    var description: String? = nil    // createCollection / updateCollection
    var scope: String? = nil          // browse: a BrowseScope id, or "collection"
    var query: String? = nil          // browse: search text
    var remoteIds: [String]? = nil    // fetch
    var remoteId: String? = nil       // related: an item; nil + collection = owner's collections
}

/// One local file to push. `remoteId` set = the file already exists remotely
/// (from an earlier pull or push), so connect it rather than upload again.
struct SourcePushItem: Codable {
    let path: String
    let title: String
    var remoteId: String? = nil
}

// MARK: - Response (plugin stdout → host)

/// Every field is optional: each op fills only its own.
struct SourceResponse: Codable {
    var protocolVersion: Int? = nil
    var account: SourceAccount? = nil         // status
    var collections: [SourceCollection]? = nil   // collections / resolve / createCollection
    var items: [SourceItem]? = nil            // pull
    var nextCursor: String? = nil             // pull: nil = last page
    var pushed: [SourcePushResult]? = nil     // push
    var retryAfter: Double? = nil             // rate-limited: wait this many seconds, call again
    var error: String? = nil
}

struct SourceAccount: Codable, Hashable {
    var name: String? = nil
    var url: String? = nil
    let authenticated: Bool
    var canWrite: Bool? = nil
    var browseScopes: [BrowseScope]? = nil
}

struct SourceCollection: Codable, Hashable, Identifiable {
    let id: String
    let title: String
    var url: String? = nil
    var count: Int? = nil
    var updatedAt: Date? = nil
    var writable: Bool? = nil
    var visibility: String? = nil     // "public" | "closed" | "private" | provider-defined
    var owner: String? = nil
    var description: String? = nil
    var previewURL: String? = nil
}

struct SourceItem: Codable, Hashable {
    let remoteId: String
    let kind: String                  // "image" | "file" | "text" | "link" | "embed"
    var title: String? = nil
    var description: String? = nil
    var url: String? = nil            // the item's page on the service
    var sourceURL: String? = nil      // where it originally came from
    var file: String? = nil           // downloaded bytes, a path inside stagingDir
    var filename: String? = nil       // preferred local name
    var text: String? = nil           // text items
    var updatedAt: Date? = nil
    var labels: [String]? = nil
    var previewURL: String? = nil     // browse: a thumbnail the host may load directly
    var author: String? = nil
    var via: SourceCollection? = nil  // browse: the collection it was seen in (feed, search)
}

struct SourcePushResult: Codable, Hashable {
    let path: String
    var remoteId: String? = nil
    var url: String? = nil
    var error: String? = nil
}

extension DiscoveredPlugin {
    var isSource: Bool { supports("source") && manifest.source != nil }
}
