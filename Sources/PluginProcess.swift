import Foundation

/// Where a plugin keeps what it learns about files (paths, tags, OCR text,
/// embeddings). `.library` is the usual cache in Application Support; `.vault`
/// is a cache root inside the attached encrypted vault, for hidden files only.
/// Config and downloaded models are file-free, so they always stay in the
/// library cache (`OVERLAP_PLUGIN_SHARED_CACHE`) and both partitions share them.
enum PluginPartition: Sendable {
    case library
    /// A cache root inside `volume`, the vault's mount point. `epoch` is the
    /// `VaultRuns` epoch it was handed out in; any close voids it.
    case vault(URL, volume: URL, epoch: Int)

    /// The library cache root; `OVERLAP_PLUGIN_CACHE` redirects it for tests.
    static var libraryRoot: URL {
        if let dir = ProcessInfo.processInfo.environment["OVERLAP_PLUGIN_CACHE"] {
            return URL(fileURLWithPath: dir, isDirectory: true)
        }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Overlap/PluginCache", isDirectory: true)
    }

    /// The child's environment, or nil unless a vault root really sits on the
    /// mounted vault: once detached, the mount point is a plain folder on the
    /// host disk. `OVERLAP_PLUGIN_CACHE_STRICT` and `_VOLUME` make the plugin
    /// check the same before it writes anything.
    func environment() -> [String: String]? {
        var env = ProcessInfo.processInfo.environment
        env["OVERLAP_PLUGIN_SHARED_CACHE"] = Self.libraryRoot.path
        switch self {
        case .library:
            env["OVERLAP_PLUGIN_CACHE"] = Self.libraryRoot.path
            env.removeValue(forKey: "OVERLAP_PLUGIN_CACHE_STRICT")
        case .vault(let root, let volume, _):
            guard Self.isMounted(volume), Self.device(of: root) == Self.device(of: volume) else {
                return nil
            }
            env["OVERLAP_PLUGIN_CACHE"] = root.path
            env["OVERLAP_PLUGIN_CACHE_STRICT"] = "1"
            env["OVERLAP_PLUGIN_CACHE_VOLUME"] = volume.path
        }
        return env
    }

    /// A mount point sits on a different device than its parent folder.
    static func isMounted(_ volume: URL) -> Bool {
        guard let own = device(of: volume), let parent = device(of: volume.deletingLastPathComponent()) else {
            return false
        }
        return own != parent
    }

    static func device(of url: URL) -> dev_t? {
        var info = stat()
        return stat(url.path, &info) == 0 ? info.st_dev : nil
    }

    var isVault: Bool {
        if case .vault = self {
            return true
        }
        return false
    }
}

/// The plugin process lifecycle shared by every capability (suggest, search,
/// source): request JSON on stdin, stderr lines streamed as progress, stdout
/// decoded as the response, SIGTERM→SIGKILL past `timeoutMs`. Returns nil on
/// any failure; callers apply their own semantics to the response.
enum PluginProcess {

    nonisolated static func run<Request: Encodable, Response: Decodable>(
        _ plugin: DiscoveredPlugin,
        request: Request,
        as responseType: Response.Type,
        timeoutMs: Int,
        cancellable: Bool = false,
        partition: PluginPartition = .library,
        onProgress: (@Sendable (String) -> Void)? = nil
    ) -> Response? {
        guard let payload = try? PluginCoder.encoder.encode(request) else { return nil }
        guard let outData = runRaw(plugin, payload: payload, timeoutMs: timeoutMs,
                                   cancellable: cancellable, partition: partition,
                                   onProgress: onProgress) else { return nil }
        do {
            return try PluginCoder.decoder.decode(Response.self, from: outData)
        } catch {
            // A decoding error can quote the payload; not for a vault run.
            NSLog("[plugins] \(plugin.id): stdout is not a valid \(Response.self)\(partition.isVault ? "" : " — \(error)")")
            return nil
        }
    }

    /// `cancellable`: kill the child when the calling task is cancelled. Off for
    /// suggest/search (an index warm-up should finish), on for source runs the
    /// user can stop.
    nonisolated private static func runRaw(_ plugin: DiscoveredPlugin, payload: Data, timeoutMs: Int,
                                           cancellable: Bool, partition: PluginPartition,
                                           onProgress: (@Sendable (String) -> Void)?) -> Data? {
        if partition.isVault && !plugin.mayUseVault {
            return nil
        }
        guard let environment = partition.environment() else {
            NSLog("[plugins] \(plugin.id): vault partition unavailable — not launched")
            return nil
        }
        let proc = Process()
        proc.executableURL = plugin.execURL
        proc.currentDirectoryURL = plugin.dir
        proc.environment = environment
        let stdin = Pipe(), stdout = Pipe(), stderr = Pipe()
        proc.standardInput = stdin
        proc.standardOutput = stdout
        proc.standardError = stderr

        // Stream stderr as progress: a plugin may emit human-readable status lines
        // (e.g. "Building suggestion index… 300/4000") while it works; the last
        // line is surfaced in the UI. Draining also prevents a chatty plugin from
        // blocking on a full stderr pipe.
        // Every line also goes to the system log (Console, filter "[plugins]").
        let errReader = stderr.fileHandleForReading
        let pluginID = plugin.id
        let quiet = partition.isVault
        var buf = Data()
        errReader.readabilityHandler = { h in
            let chunk = h.availableData
            guard !chunk.isEmpty else { return }
            buf.append(chunk)
            while let nl = buf.firstIndex(of: 0x0A) {
                let lineData = buf.subdata(in: buf.startIndex..<nl)
                buf.removeSubrange(buf.startIndex...nl)
                if let line = String(data: lineData, encoding: .utf8)?
                    .trimmingCharacters(in: .whitespaces), !line.isEmpty {
                    // The unified log isn't in the vault: a run on hidden
                    // files stays out of it, whatever the plugin prints.
                    if !quiet {
                        NSLog("[plugins] %@: %@", pluginID, line)
                    }
                    onProgress?(line)
                }
            }
        }

        do {
            if partition.isVault {
                guard case .vault(_, _, let epoch) = partition, try VaultRuns.launch(proc, epoch: epoch) else {
                    errReader.readabilityHandler = nil
                    return nil   // the vault is closing
                }
            } else {
                try proc.run()
            }
        } catch {
            errReader.readabilityHandler = nil
            NSLog("[plugins] \(plugin.id): failed to launch — \(error.localizedDescription)")
            return nil
        }
        defer {
            if partition.isVault {
                VaultRuns.remove(proc)
            }
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

        let deadline = DispatchTime.now() + .milliseconds(timeoutMs)
        var finished = false
        var cancelled = false
        while !finished {
            let slice = min(deadline, DispatchTime.now() + .milliseconds(250))
            finished = readGroup.wait(timeout: slice) == .success
            if finished || DispatchTime.now() >= deadline {
                break
            }
            if cancellable && Task.isCancelled {
                cancelled = true
                break
            }
        }
        if !finished {
            proc.terminate()                            // SIGTERM
            usleep(50_000)
            if proc.isRunning {
                kill(proc.processIdentifier, SIGKILL)
            }
            errReader.readabilityHandler = nil
            NSLog("[plugins] \(plugin.id): \(cancelled ? "cancelled" : "timed out after \(timeoutMs)ms") — killed")
            return nil
        }
        proc.waitUntilExit()
        errReader.readabilityHandler = nil
        guard proc.terminationStatus == 0 else {
            NSLog("[plugins] \(plugin.id): exited \(proc.terminationStatus)")
            return nil
        }
        return outData
    }
}

/// Plugin processes working in the vault partition. Closing kills them and
/// refuses new ones until the vault opens again, so none can be running, or
/// start, while it detaches.
enum VaultRuns {
    /// Guards the state below; waited on while a launch is between its check
    /// and its registration, so a close never misses a process.
    private static let state = NSCondition()
    nonisolated(unsafe) private static var running: [ObjectIdentifier: Process] = [:]
    nonisolated(unsafe) private static var launching = 0
    nonisolated(unsafe) private static var closed = false
    nonisolated(unsafe) private static var epoch = 0

    private static func withState<T>(_ body: () throws -> T) rethrows -> T {
        state.lock()
        defer { state.unlock() }
        return try body()
    }

    /// The current epoch, for a new vault partition.
    static var currentEpoch: Int { withState { epoch } }

    /// Start `process` unless closed, or closed since its partition was handed
    /// out. The spawn itself runs outside the lock (it can take a while for a
    /// freshly built binary); a close that comes meanwhile waits for it.
    static func launch(_ process: Process, epoch partitionEpoch: Int) throws -> Bool {
        let allowed = withState { () -> Bool in
            guard !closed, partitionEpoch == epoch else { return false }
            launching += 1
            return true
        }
        guard allowed else { return false }
        var launched = false
        defer {
            withState {
                launching -= 1
                if launched {
                    running[ObjectIdentifier(process)] = process
                }
                state.broadcast()
            }
        }
        try process.run()
        launched = true
        return true
    }

    static func reopen() {
        withState {
            closed = false
        }
    }

    static func remove(_ process: Process) {
        withState {
            _ = running.removeValue(forKey: ObjectIdentifier(process))
        }
    }

    /// Refuse new vault runs and void every partition handed out so far.
    /// Returns the runs to kill. Cheap; safe on the main thread.
    @discardableResult
    static func close() -> [Process] {
        withState {
            closed = true
            epoch += 1
            while launching > 0 {
                state.wait()
            }
            return Array(running.values)
        }
    }

    /// SIGKILL these runs and wait for each to exit. Blocking.
    static func kill(_ processes: [Process]) {
        for process in processes where process.isRunning {
            Darwin.kill(process.processIdentifier, SIGKILL)
        }
        for process in processes {
            process.waitUntilExit()
        }
    }

    static func closeAndKill() {
        kill(close())
    }
}
