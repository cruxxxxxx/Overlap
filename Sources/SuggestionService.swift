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
                                knownTags: [String], kinds: Set<FileKind>) async -> [TagSuggestion] {
        let plugins = PluginRegistry.discover().filter { p in kinds.contains(where: p.handles) }
        guard !plugins.isEmpty else { return [] }
        let raws = await withTaskGroup(of: [RawSuggestion].self) { group -> [RawSuggestion] in
            for plugin in plugins {
                group.addTask {
                    let req = SuggestRequest(
                        files: files,
                        knownTags: plugin.manifest.wantsKnownTags ? knownTags : nil,
                        library: plugin.manifest.wantsLibrary ? library : nil)
                    return invoke(plugin, request: req)
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
                                           request: SuggestRequest) -> [RawSuggestion] {
        guard let payload = try? PluginCoder.encoder.encode(request) else { return [] }

        let proc = Process()
        proc.executableURL = plugin.execURL
        proc.currentDirectoryURL = plugin.dir
        let stdin = Pipe(), stdout = Pipe(), stderr = Pipe()
        proc.standardInput = stdin
        proc.standardOutput = stdout
        proc.standardError = stderr

        do { try proc.run() } catch {
            NSLog("[plugins] \(plugin.id): failed to launch — \(error.localizedDescription)")
            return []
        }

        // Feed stdin then close so the child sees EOF.
        stdin.fileHandleForWriting.write(payload)
        try? stdin.fileHandleForWriting.close()

        // Drain stdout on a background queue so a big write can't deadlock the pipe.
        var outData = Data()
        let readGroup = DispatchGroup()
        readGroup.enter()
        DispatchQueue.global().async {
            outData = stdout.fileHandleForReading.readDataToEndOfFile()
            readGroup.leave()
        }

        let deadline = DispatchTime.now() + .milliseconds(plugin.manifest.timeoutMs)
        if readGroup.wait(timeout: deadline) == .timedOut {
            proc.terminate()                            // SIGTERM
            usleep(50_000)
            if proc.isRunning { kill(proc.processIdentifier, SIGKILL) }
            NSLog("[plugins] \(plugin.id): timed out after \(plugin.manifest.timeoutMs)ms — killed")
            return []
        }
        proc.waitUntilExit()
        guard proc.terminationStatus == 0 else {
            NSLog("[plugins] \(plugin.id): exited \(proc.terminationStatus)")
            return []
        }
        guard let resp = try? PluginCoder.decoder.decode(SuggestResponse.self, from: outData) else {
            NSLog("[plugins] \(plugin.id): stdout is not a valid SuggestResponse")
            return []
        }
        let valid = Set(request.files.map(\.path))
        return resp.suggestions
            .filter { valid.contains($0.path) && !$0.tag.isEmpty }
            .map { RawSuggestion(path: $0.path, tag: $0.tag,
                                 confidence: min(max($0.confidence, 0), 1),
                                 source: plugin.manifest.name) }
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
                    paths: e.paths.union([r.path]))
            } else {
                byTag[r.tag] = TagSuggestion(tag: r.tag, confidence: r.confidence,
                                             source: r.source ?? "plugin", paths: [r.path])
            }
        }
        return byTag.values.sorted {
            $0.confidence > $1.confidence || ($0.confidence == $1.confidence && $0.tag < $1.tag)
        }
    }
}
