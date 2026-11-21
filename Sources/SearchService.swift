import Foundation

/// Runs `capabilities: ["search"]` plugins — the same child-process contract as
/// suggestions, but the request carries a free-text `query` and the response a
/// ranked `hits` list over the plugin's own persisted index. Two shapes:
///
///   - warm-up:  query nil,  library = every image in the corpus → plugin embeds
///               what's new, returns no hits.
///   - query:    query text, library []  → plugin ranks its index, returns hits.
///   - similar:  similarTo paths (plugins with `similar`) → hits ranked by
///               likeness to those images, which are left out.
///
/// Hits are NOT path-validated against `files` (there are none) — the whole
/// point is surfacing files the host didn't ask about.
enum SearchEngine {

    struct Outcome {
        var hits: [SearchHit] = []
        var indexedCount: Int?
        var ranPlugin = false          // false: no enabled search plugin installed
    }

    nonisolated static func searchPlugins(disabledIDs: Set<String>,
                                          capability: String = "search",
                                          partition: PluginPartition = .library) -> [DiscoveredPlugin] {
        PluginRegistry.discover().filter { p in
            !disabledIDs.contains(p.id) && p.supports(capability) && p.handles(.image)
                && (!partition.isVault || p.mayUseVault)
        }
    }

    struct ExploreOutcome {
        var result: ExploreResult?
        var indexedCount: Int?
        var ranPlugin = false
    }

    /// An Explore draw from the first enabled plugin that can do it. Vectors
    /// from different encoders don't compare, so it's never merged across plugins.
    nonisolated static func explore(_ query: ExploreQuery, disabledIDs: Set<String>,
                                    pluginSettings: [String: [String: SettingValue]],
                                    partition: PluginPartition = .library) async -> ExploreOutcome {
        guard let plugin = searchPlugins(disabledIDs: disabledIDs, capability: "explore",
                                         partition: partition).first else {
            return ExploreOutcome()
        }
        let request = SuggestRequest(files: [], knownTags: nil, library: nil,
                                     settings: TagStore.effectiveSettings(for: plugin, stored: pluginSettings),
                                     explore: query)
        let timeout = plugin.manifest.queryTimeoutMs ?? min(plugin.manifest.timeoutMs, 60_000)
        let response = SuggestionEngine.runProcess(plugin, request: request, timeoutMs: timeout,
                                                   partition: partition, onProgress: nil)
        return ExploreOutcome(result: response?.explore, indexedCount: response?.indexedCount, ranPlugin: true)
    }

    /// Runs off-main (call from a detached task).
    nonisolated static func run(query: String?, similarTo: [String]? = nil, library: [LibraryItem],
                                disabledIDs: Set<String> = [],
                                pluginSettings: [String: [String: SettingValue]] = [:],
                                partition: PluginPartition = .library,
                                onProgress: (@Sendable (String) -> Void)? = nil) async -> Outcome {
        // A hidden image as seed reaches only local plugins, whichever partition.
        let hiddenSeed = similarTo?.contains(where: VaultDisk.contains) ?? false
        let plugins = searchPlugins(disabledIDs: disabledIDs,
                                    capability: similarTo == nil ? "search" : "similar",
                                    partition: partition)
            .filter { !hiddenSeed || $0.mayUseVault }
        guard !plugins.isEmpty else { return Outcome() }

        let responses = await withTaskGroup(of: SuggestResponse?.self) { group -> [SuggestResponse] in
            for plugin in plugins {
                group.addTask {
                    let req = SuggestRequest(
                        files: [],
                        knownTags: nil,
                        library: plugin.manifest.wantsLibrary ? library : nil,
                        settings: TagStore.effectiveSettings(for: plugin, stored: pluginSettings),
                        query: query,
                        similarTo: similarTo)
                    // Indexing may legitimately run for an hour; a query that
                    // hangs must not pin the spinner that long.
                    let m = plugin.manifest
                    let timeout = query == nil && similarTo == nil ? m.timeoutMs : (m.queryTimeoutMs ?? min(m.timeoutMs, 60_000))
                    return SuggestionEngine.runProcess(plugin, request: req, timeoutMs: timeout,
                                                       partition: partition, onProgress: onProgress)
                }
            }
            var acc: [SuggestResponse] = []
            for await r in group { if let r { acc.append(r) } }
            return acc
        }

        // An enabled plugin that failed still "ran": the UI says the index
        // isn't ready, not that no plugin is installed.
        var outcome = combine(responses.map { Outcome(hits: $0.hits ?? [], indexedCount: $0.indexedCount, ranPlugin: true) })
        outcome.ranPlugin = true
        return outcome
    }

    /// One query over the library partition and, while it's open, the vault's.
    /// Each source image of a "similar" goes to both: a plugin embeds an image
    /// it hasn't indexed in memory only, so a hidden one leaves nothing behind.
    nonisolated static func run(query: String?, similarTo: [String]? = nil,
                                disabledIDs: Set<String>,
                                pluginSettings: [String: [String: SettingValue]],
                                vault: PluginPartition?) async -> Outcome {
        guard let vault else {
            // No vault partition: a hidden seed goes nowhere.
            let seeds = similarTo?.filter { !VaultDisk.contains($0) }
            if let seeds, seeds.isEmpty {
                return Outcome(ranPlugin: true)
            }
            return await run(query: query, similarTo: seeds, library: [],
                             disabledIDs: disabledIDs, pluginSettings: pluginSettings)
        }
        async let library = run(query: query, similarTo: similarTo, library: [],
                                disabledIDs: disabledIDs, pluginSettings: pluginSettings)
        async let hidden = run(query: query, similarTo: similarTo, library: [],
                               disabledIDs: disabledIDs, pluginSettings: pluginSettings, partition: vault)
        return combine([await library, await hidden])
    }

    /// Best score per path, summed index sizes. Scores from one encoder compare
    /// across partitions, which is what lets hidden hits interleave.
    nonisolated static func combine(_ outcomes: [Outcome]) -> Outcome {
        var outcome = Outcome(ranPlugin: outcomes.contains { $0.ranPlugin })
        var best: [String: Double] = [:]
        for part in outcomes {
            if let n = part.indexedCount { outcome.indexedCount = (outcome.indexedCount ?? 0) + n }
            for h in part.hits where !h.path.isEmpty {
                best[h.path] = max(best[h.path] ?? -.infinity, h.score)
            }
        }
        outcome.hits = best.map { SearchHit(path: $0.key, score: $0.value) }
            .sorted { $0.score > $1.score || ($0.score == $1.score && $0.path < $1.path) }
        return outcome
    }
}
