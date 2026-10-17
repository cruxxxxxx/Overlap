import Foundation

/// Stateless engine that runs discovered plugins on a set of targets and returns
/// merged tag suggestions. Each plugin is a child `Process`: request on stdin,
/// suggestions on stdout, killed if it overruns its timeout. Any per-plugin
/// failure is a silent no-op — one bad plugin never blocks the others or the app.
///
/// Published state (the current suggestions, running flag) lives on `TagStore`
/// so SwiftUI views observing the store refresh; this type just does the work.
enum SuggestionEngine {

    /// Discover applicable plugins, run them concurrently, merge the results.
    /// Runs off-main (call from a detached task).
    nonisolated static func run(files: [RequestFile], library: [LibraryItem],
                                knownTags: [String], kinds: Set<FileKind>,
                                disabledIDs: Set<String> = [],
                                pluginSettings: [String: [String: SettingValue]] = [:],
                                onProgress: (@Sendable (String) -> Void)? = nil) async -> [TagSuggestion] {
        // Search-only plugins (overlap-clip) never see suggest traffic: they'd
        // load a Core ML model on every selection click for nothing.
        let plugins = PluginRegistry.discover().filter { p in
            !disabledIDs.contains(p.id) && p.supports("suggest") && kinds.contains(where: p.handles)
        }
        guard !plugins.isEmpty else { return [] }
        let raws = await withTaskGroup(of: [RawSuggestion].self) { group -> [RawSuggestion] in
            for plugin in plugins {
                group.addTask {
                    let req = SuggestRequest(
                        files: files,
                        knownTags: plugin.manifest.wantsKnownTags ? knownTags : nil,
                        library: plugin.manifest.wantsLibrary ? library : nil,
                        settings: TagStore.effectiveSettings(for: plugin, stored: pluginSettings))
                    return invoke(plugin, request: req, onProgress: onProgress)
                }
            }
            var acc: [RawSuggestion] = []
            for await r in group { acc.append(contentsOf: r) }
            return acc
        }
        return merge(raws)
    }

    // MARK: - Process invocation

    /// Run one plugin to completion (or timeout) and return its clamped, path-
    /// validated suggestions. Returns `[]` on any failure.
    nonisolated private static func invoke(_ plugin: DiscoveredPlugin,
                                           request: SuggestRequest,
                                           onProgress: (@Sendable (String) -> Void)? = nil) -> [RawSuggestion] {
        guard let resp = runProcess(plugin, request: request,
                                    timeoutMs: plugin.manifest.timeoutMs,
                                    onProgress: onProgress) else { return [] }
        let valid = Set(request.files.map(\.path))
        return (resp.suggestions ?? [])
            .filter { valid.contains($0.path) && !$0.tag.isEmpty }
            .map { RawSuggestion(path: $0.path, tag: $0.tag,
                                 confidence: min(max($0.confidence, 0), 1),
                                 source: plugin.manifest.name, group: $0.group) }
    }

    /// The suggest/search shape of `PluginProcess.run`: a `SuggestRequest` in,
    /// a `SuggestResponse` out. Returns nil on any failure.
    nonisolated static func runProcess(_ plugin: DiscoveredPlugin,
                                       request: SuggestRequest,
                                       timeoutMs: Int,
                                       onProgress: (@Sendable (String) -> Void)? = nil) -> SuggestResponse? {
        PluginProcess.run(plugin, request: request, as: SuggestResponse.self,
                          timeoutMs: timeoutMs, onProgress: onProgress)
    }

    // MARK: - Merge / rank

    /// Group by tag, keep the max confidence, union the paths; sort by
    /// confidence desc then tag asc. Dedupes across plugins.
    nonisolated private static func merge(_ raws: [RawSuggestion]) -> [TagSuggestion] {
        var byTag: [String: TagSuggestion] = [:]
        for r in raws {
            if let e = byTag[r.tag] {
                byTag[r.tag] = TagSuggestion(
                    tag: r.tag,
                    confidence: max(e.confidence, r.confidence),
                    source: e.confidence >= r.confidence ? e.source : (r.source ?? e.source),
                    paths: e.paths.union([r.path]),
                    isGroup: e.isGroup || (r.group ?? false))
            } else {
                byTag[r.tag] = TagSuggestion(tag: r.tag, confidence: r.confidence,
                                             source: r.source ?? "plugin", paths: [r.path],
                                             isGroup: r.group ?? false)
            }
        }
        return byTag.values.sorted {
            $0.confidence > $1.confidence || ($0.confidence == $1.confidence && $0.tag < $1.tag)
        }
    }
}
