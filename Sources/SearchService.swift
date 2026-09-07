import Foundation

/// Runs `capabilities: ["search"]` plugins — the same child-process contract as
/// suggestions, but the request carries a free-text `query` and the response a
/// ranked `hits` list over the plugin's own persisted index. Two shapes:
///
///   - warm-up:  query nil,  library = every image in the corpus → plugin embeds
///               what's new, returns no hits.
///   - query:    query text, library []  → plugin ranks its index, returns hits.
///
/// Hits are NOT path-validated against `files` (there are none) — the whole
/// point is surfacing files the host didn't ask about.
enum SearchEngine {

    struct Outcome {
        var hits: [SearchHit] = []
        var indexedCount: Int?
        var ranPlugin = false          // false: no enabled search plugin installed
    }

    nonisolated static func searchPlugins(disabledIDs: Set<String>) -> [DiscoveredPlugin] {
        PluginRegistry.discover().filter { p in
            !disabledIDs.contains(p.id) && p.supports("search") && p.handles(.image)
        }
    }

    /// Runs off-main (call from a detached task).
    nonisolated static func run(query: String?, library: [LibraryItem],
                                disabledIDs: Set<String> = [],
                                pluginSettings: [String: [String: SettingValue]] = [:],
                                onProgress: (@Sendable (String) -> Void)? = nil) async -> Outcome {
        let plugins = searchPlugins(disabledIDs: disabledIDs)
        guard !plugins.isEmpty else { return Outcome() }

        let responses = await withTaskGroup(of: SuggestResponse?.self) { group -> [SuggestResponse] in
            for plugin in plugins {
                group.addTask {
                    let req = SuggestRequest(
                        files: [],
                        knownTags: nil,
                        library: plugin.manifest.wantsLibrary ? library : nil,
                        settings: TagStore.effectiveSettings(for: plugin, stored: pluginSettings),
                        query: query)
                    // Indexing may legitimately run for an hour; a query that
                    // hangs must not pin the spinner that long.
                    let m = plugin.manifest
                    let timeout = query == nil ? m.timeoutMs : (m.queryTimeoutMs ?? min(m.timeoutMs, 60_000))
                    return SuggestionEngine.runProcess(plugin, request: req, timeoutMs: timeout,
                                                       onProgress: onProgress)
                }
            }
            var acc: [SuggestResponse] = []
            for await r in group { if let r { acc.append(r) } }
            return acc
        }

        var outcome = Outcome(ranPlugin: true)
        var best: [String: Double] = [:]
        for resp in responses {
            if let n = resp.indexedCount { outcome.indexedCount = (outcome.indexedCount ?? 0) + n }
            for h in resp.hits ?? [] where !h.path.isEmpty {
                best[h.path] = max(best[h.path] ?? -.infinity, h.score)
            }
        }
        outcome.hits = best.map { SearchHit(path: $0.key, score: $0.value) }
            .sorted { $0.score > $1.score || ($0.score == $1.score && $0.path < $1.path) }
        return outcome
    }
}
