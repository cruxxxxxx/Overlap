import Foundation

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
        onProgress: (@Sendable (String) -> Void)? = nil
    ) -> Response? {
        guard let payload = try? PluginCoder.encoder.encode(request) else { return nil }
        guard let outData = runRaw(plugin, payload: payload, timeoutMs: timeoutMs,
                                   cancellable: cancellable, onProgress: onProgress) else { return nil }
        do {
            return try PluginCoder.decoder.decode(Response.self, from: outData)
        } catch {
            NSLog("[plugins] \(plugin.id): stdout is not a valid \(Response.self) — \(error)")
            return nil
        }
    }

    /// `cancellable`: kill the child when the calling task is cancelled. Off for
    /// suggest/search (an index warm-up should finish), on for source runs the
    /// user can stop.
    nonisolated private static func runRaw(_ plugin: DiscoveredPlugin, payload: Data, timeoutMs: Int,
                                           cancellable: Bool,
                                           onProgress: (@Sendable (String) -> Void)?) -> Data? {
        let proc = Process()
        proc.executableURL = plugin.execURL
        proc.currentDirectoryURL = plugin.dir
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
                    NSLog("[plugins] %@: %@", pluginID, line)
                    onProgress?(line)
                }
            }
        }

        do { try proc.run() } catch {
            errReader.readabilityHandler = nil
            NSLog("[plugins] \(plugin.id): failed to launch — \(error.localizedDescription)")
            return nil
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
