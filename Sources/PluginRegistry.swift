import Foundation

/// Discovers suggestion plugins on disk. A plugin is a subdirectory containing a
/// `manifest.json` and the executable it names. Two roots are scanned: the user
/// dir (`~/Library/Application Support/Overlap/Plugins/`) and the app bundle's
/// built-in PlugIns dir (empty for now). Malformed or unsafe manifests are
/// skipped with a log line — never fatal.
enum PluginRegistry {

    /// `~/Library/Application Support/Overlap/Plugins/` — mirrors the App Support
    /// idiom used for the catalog cache (TagStore.cacheURL).
    static func userPluginsDir() -> URL? {
        guard let base = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return nil }
        return base.appendingPathComponent("Overlap/Plugins", isDirectory: true)
    }

    /// Discover every valid plugin across the known roots. Synchronous and cheap
    /// (a few small JSON reads); call it off-main from the service.
    static func discover() -> [DiscoveredPlugin] {
        let roots = [userPluginsDir(), Bundle.main.builtInPlugInsURL].compactMap { $0 }
        var found: [String: DiscoveredPlugin] = [:]   // id → plugin (user root wins, scanned first)
        for root in roots {
            for plugin in plugins(in: root) where found[plugin.id] == nil {
                found[plugin.id] = plugin
            }
        }
        return Array(found.values)
    }

    private static func plugins(in root: URL) -> [DiscoveredPlugin] {
        let fm = FileManager.default
        guard let subdirs = try? fm.contentsOfDirectory(
            at: root, includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]) else { return [] }

        return subdirs.compactMap { dir in
            // Plugins are often symlinked in (plugins/install.sh does); resolve
            // so the directory and containment checks see the real location.
            let real = dir.resolvingSymlinksInPath()
            guard (try? real.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
            else { return nil }
            let manifestURL = real.appendingPathComponent("manifest.json")
            guard let data = try? Data(contentsOf: manifestURL) else { return nil }
            guard let manifest = try? PluginCoder.decoder.decode(PluginManifest.self, from: data) else {
                NSLog("[plugins] skip \(dir.lastPathComponent): manifest.json won't decode")
                return nil
            }
            guard manifest.protocolVersion == PluginProtocol.version else {
                NSLog("[plugins] skip \(manifest.id): protocolVersion \(manifest.protocolVersion) ≠ \(PluginProtocol.version)")
                return nil
            }
            // Sanity guard: the exec must live under the plugin's own (resolved)
            // dir, so a manifest can't point `exec` at an arbitrary path.
            let execURL = real.appendingPathComponent(manifest.exec).standardizedFileURL
            guard execURL.resolvingSymlinksInPath().path.hasPrefix(real.path + "/") else {
                NSLog("[plugins] skip \(manifest.id): exec escapes the plugin dir")
                return nil
            }
            guard fm.isExecutableFile(atPath: execURL.path) else {
                NSLog("[plugins] skip \(manifest.id): exec missing or not executable at \(execURL.path)")
                return nil
            }
            return DiscoveredPlugin(manifest: manifest, dir: real, execURL: execURL)
        }
    }
}
