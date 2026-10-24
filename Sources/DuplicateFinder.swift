import Foundation
import CryptoKit
import ImageIO

/// One set of files that look like copies of each other, keeper first.
struct DuplicateGroup: Identifiable, Hashable {
    let id: String
    var files: [DuplicateFile]
    /// Lowest pair score that joined the group: 1 = byte-identical.
    var score: Double
    var identical: Bool
}

struct DuplicateFile: Identifiable, Hashable {
    var id: String { url.path }
    let url: URL
    let width: Int?
    let height: Int?
    let size: Int64
    let created: Date?

    var pixels: Int { (width ?? 0) * (height ?? 0) }

    static func load(_ url: URL) -> DuplicateFile {
        let values = try? url.resourceValues(forKeys: [.fileSizeKey, .creationDateKey])
        var width: Int?
        var height: Int?
        if let source = CGImageSourceCreateWithURL(url as CFURL, nil),
           let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] {
            width = props[kCGImagePropertyPixelWidth] as? Int
            height = props[kCGImagePropertyPixelHeight] as? Int
            if let orientation = props[kCGImagePropertyOrientation] as? Int, orientation >= 5 {
                swap(&width, &height)
            }
        }
        return DuplicateFile(url: url, width: width, height: height,
                             size: Int64(values?.fileSize ?? 0), created: values?.creationDate)
    }
}

/// Finds duplicates on demand; nothing is indexed. Exact copies by size then
/// SHA-256; near-duplicates from plugins with the `duplicates` capability.
enum DuplicateFinder {

    /// Pairs of byte-identical files. Only files whose sizes collide are read.
    nonisolated static func exactPairs(_ urls: [URL], onProgress: (String) -> Void) -> [DuplicatePair] {
        var bySize: [Int: [URL]] = [:]
        for url in urls {
            if let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize, size > 0 {
                bySize[size, default: []].append(url)
            }
        }
        let candidates = bySize.values.filter { $0.count > 1 }
        let total = candidates.reduce(0) { $0 + $1.count }
        var hashed = 0
        var pairs: [DuplicatePair] = []
        for sameSize in candidates {
            var byHash: [Data: [URL]] = [:]
            for url in sameSize {
                if let digest = sha256(of: url) {
                    byHash[digest, default: []].append(url)
                }
                hashed += 1
                if hashed % 50 == 0 {
                    onProgress("Comparing file contents… \(hashed)/\(total)")
                }
            }
            for copies in byHash.values where copies.count > 1 {
                for other in copies.dropFirst() {
                    pairs.append(DuplicatePair(a: copies[0].path, b: other.path, score: 1))
                }
            }
        }
        return pairs
    }

    private nonisolated static func sha256(of url: URL) -> Data? {
        guard let handle = try? FileHandle(forReadingFrom: url) else {
            return nil
        }
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try? handle.read(upToCount: 1 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return Data(hasher.finalize())
    }

    /// Near-duplicate pairs from every enabled `duplicates` plugin.
    nonisolated static func nearPairs(threshold: Double, paths: [String]?,
                                      disabledIDs: Set<String>,
                                      pluginSettings: [String: [String: SettingValue]],
                                      onProgress: @escaping @Sendable (String) -> Void) -> [DuplicatePair] {
        var pairs: [DuplicatePair] = []
        for plugin in SearchEngine.searchPlugins(disabledIDs: disabledIDs, capability: "duplicates") {
            let request = SuggestRequest(
                files: [], knownTags: nil, library: nil,
                settings: TagStore.effectiveSettings(for: plugin, stored: pluginSettings),
                duplicates: DuplicatesQuery(threshold: threshold, paths: paths))
            let timeout = plugin.manifest.queryTimeoutMs ?? 60_000
            let response = SuggestionEngine.runProcess(plugin, request: request, timeoutMs: timeout,
                                                       onProgress: onProgress)
            pairs += response?.pairs ?? []
        }
        return pairs
    }

    /// Union pairs into groups, skipping pairs the user marked as different.
    /// Each group's keeper (highest resolution, then oldest) comes first.
    nonisolated static func groups(from pairs: [DuplicatePair], excluding notDuplicates: Set<String>) -> [DuplicateGroup] {
        var parent: [String: String] = [:]
        func root(_ path: String) -> String {
            var node = path
            while let up = parent[node], up != node {
                node = up
            }
            return node
        }
        var lowest: [String: Double] = [:]
        var identicalOnly: [String: Bool] = [:]
        let fm = FileManager.default
        let kept = pairs.filter { pair in
            pair.a != pair.b && !notDuplicates.contains(NotDuplicates.key(pair.a, pair.b))
                && fm.fileExists(atPath: pair.a) && fm.fileExists(atPath: pair.b)
        }
        for pair in kept {
            parent[pair.a] = parent[pair.a] ?? pair.a
            parent[pair.b] = parent[pair.b] ?? pair.b
            let ra = root(pair.a), rb = root(pair.b)
            if ra != rb {
                parent[rb] = ra
            }
        }
        var members: [String: [String]] = [:]
        for path in parent.keys {
            members[root(path), default: []].append(path)
        }
        for pair in kept {
            let r = root(pair.a)
            lowest[r] = min(lowest[r] ?? 1, pair.score)
            identicalOnly[r] = (identicalOnly[r] ?? true) && pair.score >= 1
        }
        return members.map { r, paths in
            let files = paths.map { DuplicateFile.load(URL(fileURLWithPath: $0)) }
            return DuplicateGroup(id: r, files: suggestedOrder(files), score: lowest[r] ?? 1,
                                  identical: identicalOnly[r] ?? false)
        }
        .sorted { $0.files.count != $1.files.count ? $0.files.count > $1.files.count : $0.score > $1.score }
    }

    /// Highest resolution first, then oldest, then the shortest path.
    nonisolated static func suggestedOrder(_ files: [DuplicateFile]) -> [DuplicateFile] {
        files.sorted { a, b in
            if a.pixels != b.pixels {
                return a.pixels > b.pixels
            }
            let da = a.created ?? .distantFuture, db = b.created ?? .distantFuture
            if da != db {
                return da < db
            }
            return a.url.path.count < b.url.path.count
        }
    }
}

/// Pairs the user said aren't duplicates, kept in
/// `~/Library/Application Support/Overlap/not-duplicates.json`.
enum NotDuplicates {
    nonisolated static func key(_ a: String, _ b: String) -> String {
        a < b ? a + "\n" + b : b + "\n" + a
    }

    private static var fileURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Overlap/not-duplicates.json")
    }

    static func load() -> Set<String> {
        guard let data = try? Data(contentsOf: fileURL),
              let pairs = try? JSONDecoder().decode([[String]].self, from: data) else {
            return []
        }
        return Set(pairs.filter { $0.count == 2 }.map { key($0[0], $0[1]) })
    }

    static func add(_ paths: [String], to current: inout Set<String>) {
        for (i, a) in paths.enumerated() {
            for b in paths[(i + 1)...] {
                current.insert(key(a, b))
            }
        }
        // Drop pairs whose files are gone, so the list doesn't grow forever.
        let fm = FileManager.default
        let pairs = current.map { $0.components(separatedBy: "\n") }
            .filter { $0.count == 2 && fm.fileExists(atPath: $0[0]) && fm.fileExists(atPath: $0[1]) }
            .sorted { $0[0] < $1[0] }
        current = Set(pairs.map { key($0[0], $0[1]) })
        try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(pairs) {
            try? data.write(to: fileURL, options: .atomic)
        }
    }
}
