import AppKit
import CommonCrypto
import LocalAuthentication
import Security

// Privacy plumbing for hidden tags: keychain secrets, the passcode, device
// auth, the encrypted vault disk image, and auto-lock triggers. TagStore owns
// the policy (what's hidden, when to lock); everything here is mechanism.

// MARK: - Keychain

/// Generic-password items in the login keychain, one account per secret.
enum Keychain {
    static let privacyService = "com.mike.overlap.privacy"
    /// Source-plugin credentials (account = "<plugin id>.<secret key>").
    static let sourcesService = "com.mike.overlap.sources"

    private static func query(_ account: String, service: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    static func read(_ account: String, service: String = privacyService) -> Data? {
        var q = query(account, service: service)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess else { return nil }
        return out as? Data
    }

    @discardableResult
    static func write(_ data: Data, account: String, service: String = privacyService) -> Bool {
        let q = query(account, service: service)
        let update = [kSecValueData as String: data]
        let status = SecItemUpdate(q as CFDictionary, update as CFDictionary)
        if status == errSecSuccess { return true }
        guard status == errSecItemNotFound else { return false }
        var add = q
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
    }

    static func delete(_ account: String, service: String = privacyService) {
        SecItemDelete(query(account, service: service) as CFDictionary)
    }
}

// MARK: - Passcode

/// The reveal passcode, stored as a PBKDF2-SHA256 hash in the keychain.
enum Passcode {
    private struct Record: Codable {
        let salt: Data
        let hash: Data
        let rounds: Int
    }

    private static let account = "passcode"
    private static let rounds = 310_000

    static var isSet: Bool { Keychain.read(account) != nil }

    static func set(_ code: String) {
        let salt = randomBytes(16)
        let record = Record(salt: salt, hash: derive(code, salt: salt, rounds: rounds), rounds: rounds)
        if let data = try? JSONEncoder().encode(record) {
            Keychain.write(data, account: account)
        }
    }

    static func remove() {
        Keychain.delete(account)
    }

    static func verify(_ code: String) -> Bool {
        guard let data = Keychain.read(account),
              let record = try? JSONDecoder().decode(Record.self, from: data) else { return false }
        return constantTimeEqual(derive(code, salt: record.salt, rounds: record.rounds), record.hash)
    }

    private static func derive(_ code: String, salt: Data, rounds: Int) -> Data {
        let password = Array(code.utf8).map { Int8(bitPattern: $0) }
        var out = [UInt8](repeating: 0, count: 32)
        salt.withUnsafeBytes { saltBuf in
            _ = CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2), password, password.count,
                                     saltBuf.bindMemory(to: UInt8.self).baseAddress, salt.count,
                                     CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256), UInt32(rounds),
                                     &out, out.count)
        }
        return Data(out)
    }

    private static func constantTimeEqual(_ a: Data, _ b: Data) -> Bool {
        guard a.count == b.count else { return false }
        var diff: UInt8 = 0
        for (x, y) in zip(a, b) {
            diff |= x ^ y
        }
        return diff == 0
    }
}

func randomBytes(_ count: Int) -> Data {
    var bytes = [UInt8](repeating: 0, count: count)
    _ = SecRandomCopyBytes(kSecRandomDefault, count, &bytes)
    return Data(bytes)
}

// MARK: - Private settings

/// Everything that names a hidden tag. Lives in the keychain so the
/// UserDefaults plist never lists hidden tag names.
struct PrivateSettings: Codable {
    var hiddenTags: [String] = []
    var tagDefaults: [String: Int] = [:]
    var knownTags: [String] = []
    /// Saved queries that name a hidden tag. Optional so settings written
    /// before it existed still decode.
    var savedQueries: [SavedQuery]?

    private static let account = "private-settings"

    static func load() -> PrivateSettings? {
        Keychain.read(account).flatMap { try? JSONDecoder().decode(PrivateSettings.self, from: $0) }
    }

    func save() {
        if let data = try? JSONEncoder().encode(self) {
            Keychain.write(data, account: Self.account)
        }
    }
}

// MARK: - Device auth

/// Touch ID, falling back to the macOS login password.
enum DeviceAuth {
    static var isAvailable: Bool {
        LAContext().canEvaluatePolicy(.deviceOwnerAuthentication, error: nil)
    }

    static var hasBiometrics: Bool {
        LAContext().canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil)
    }

    static func authenticate(reason: String) async -> Bool {
        (try? await LAContext().evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason)) ?? false
    }
}

// MARK: - Vault disk image

enum VaultError: LocalizedError {
    case hdiutil(String)
    case noSpace(String)

    var errorDescription: String? {
        switch self {
        case .hdiutil(let message):
            return message
        case .noSpace(let name):
            return "Not enough free disk space to move “\(name)” into the vault."
        }
    }
}

/// The encrypted vault: an AES-256 sparse bundle under Application Support,
/// attached (unbrowsable, unindexed) only while hidden tags are revealed.
/// Hidden files live under `Files/` at their original absolute path, so each
/// file's way home is encoded in where it sits.
///
/// The image grows on demand in 8 MB bands up to `virtualSize` (a ceiling, not
/// an allocation). It never shrinks by itself: `hdiutil compact` is
/// unimplemented for sparse bundles on current macOS. Space freed inside is
/// reused by later hides; `rebuild` reclaims it for real.
enum VaultDisk {
    private static let keyAccount = "vault-key"
    private static let virtualSize = "16t"

    /// Application Support/Overlap; `OVERLAP_VAULT_DIR` points a headless
    /// test at a scratch folder instead.
    static var baseDir: URL {
        if let dir = ProcessInfo.processInfo.environment["OVERLAP_VAULT_DIR"] {
            return URL(fileURLWithPath: dir, isDirectory: true)
        }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Overlap", isDirectory: true)
    }
    static var bundleURL: URL { baseDir.appendingPathComponent("Vault.sparsebundle") }
    static var mountURL: URL { baseDir.appendingPathComponent(".vault", isDirectory: true) }
    static var filesRoot: URL { mountURL.appendingPathComponent("Files", isDirectory: true) }

    static var exists: Bool { FileManager.default.fileExists(atPath: bundleURL.path) }

    static var isAttached: Bool {
        (try? mountURL.resourceValues(forKeys: [.isVolumeKey]).isVolume) == true
    }

    static func contains(_ path: String) -> Bool {
        path.hasPrefix(filesRoot.path + "/")
    }

    static func vaultURL(forOriginal url: URL) -> URL {
        filesRoot.appendingPathComponent(String(url.path.drop { $0 == "/" }))
    }

    static func originalURL(forVault url: URL) -> URL? {
        let path = url.path
        guard contains(path) else { return nil }
        return URL(fileURLWithPath: String(path.dropFirst(filesRoot.path.count)))
    }

    // Key

    static func storedKey() -> String? {
        Keychain.read(keyAccount).flatMap { String(data: $0, encoding: .utf8) }
    }

    @discardableResult
    static func storeKey(_ key: String) -> Bool {
        Keychain.write(Data(key.utf8), account: keyAccount)
    }

    static func deleteKey() {
        Keychain.delete(keyAccount)
    }

    /// A random key the user can write down: 30 Crockford base32 characters
    /// (150 bits) in dash-separated groups of five.
    static func generateKey() -> String {
        let alphabet = Array("0123456789ABCDEFGHJKMNPQRSTVWXYZ")
        let chars = randomBytes(30).map { alphabet[Int($0) % 32] }
        return grouped(chars)
    }

    /// Canonical form of a typed recovery key (case, spaces and dashes ignored).
    static func normalizeKey(_ input: String) -> String {
        grouped(Array(input.uppercased().filter { $0.isLetter || $0.isNumber }))
    }

    private static func grouped(_ chars: [Character]) -> String {
        stride(from: 0, to: chars.count, by: 5)
            .map { String(chars[$0..<min($0 + 5, chars.count)]) }
            .joined(separator: "-")
    }

    // Lifecycle (blocking — call off the main thread)

    static func create(key: String) throws {
        try FileManager.default.createDirectory(at: baseDir, withIntermediateDirectories: true)
        try create(at: bundleURL, key: key)
    }

    private static func create(at url: URL, key: String) throws {
        try hdiutil(["create", "-size", virtualSize, "-type", "SPARSEBUNDLE", "-fs", "APFS",
                     "-encryption", "AES-256", "-stdinpass", "-volname", "Overlap Vault", url.path],
                    password: key)
    }

    static func attach(key: String) throws {
        guard !isAttached else { return }
        try attach(bundleURL, at: mountURL, key: key)
        try FileManager.default.createDirectory(at: filesRoot, withIntermediateDirectories: true)
    }

    private static func attach(_ bundle: URL, at mount: URL, key: String) throws {
        try FileManager.default.createDirectory(at: mount, withIntermediateDirectories: true)
        try hdiutil(["attach", "-stdinpass", "-nobrowse", "-noautoopen", "-owners", "on",
                     "-mountpoint", mount.path, bundle.path], password: key)
    }

    /// Detach, forcing it if something (a Quick Look panel, an editor) still
    /// holds a file open. Locking must win.
    static func detach() {
        detach(mountURL)
    }

    private static func detach(_ mount: URL) {
        guard (try? mount.resourceValues(forKeys: [.isVolumeKey]).isVolume) == true else { return }
        if (try? hdiutil(["detach", mount.path])) == nil {
            _ = try? hdiutil(["detach", "-force", mount.path])
        }
    }

    /// Delete the image and its key. The caller has already moved files out.
    static func destroy() {
        detach()
        try? FileManager.default.removeItem(at: bundleURL)
        try? FileManager.default.removeItem(at: mountURL)
        deleteKey()
    }

    /// Every regular file inside the attached vault, minus the bookkeeping
    /// files Finder drops in folders it shows. Those never went in through
    /// Overlap, and moving `Files/Users/.DS_Store` "back" targets /Users.
    static func scanFiles() -> [URL] {
        let en = FileManager.default.enumerator(at: filesRoot, includingPropertiesForKeys: [.isRegularFileKey],
                                                options: [.skipsPackageDescendants])
        var urls: [URL] = []
        while let url = en?.nextObject() as? URL {
            if isFinderBookkeeping(url) {
                continue
            }
            if (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true {
                urls.append(url)
            }
        }
        return urls
    }

    private static func isFinderBookkeeping(_ url: URL) -> Bool {
        let name = url.lastPathComponent
        return name == ".DS_Store" || name == ".localized" || name.hasPrefix("._")
    }

    // Space

    struct Usage {
        let onDisk: Int64
        let inUse: Int64
        var reclaimable: Int64 { max(0, onDisk - inUse) }
    }

    /// Bundle size on the host disk vs bytes the vault's files actually use.
    static func usage() -> Usage {
        Usage(onDisk: allocatedSize(of: bundleURL), inUse: allocatedSize(of: filesRoot))
    }

    private static func allocatedSize(of dir: URL) -> Int64 {
        let keys: [URLResourceKey] = [.totalFileAllocatedSizeKey]
        let en = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: keys)
        var total: Int64 = 0
        while let url = en?.nextObject() as? URL {
            total += Int64((try? url.resourceValues(forKeys: Set(keys)).totalFileAllocatedSize) ?? 0)
        }
        return total
    }

    /// Reclaim freed space: copy the vault's files into a fresh image and swap
    /// it in. Needs free space for the files in use; leaves the new vault attached.
    static func rebuild(key: String) throws {
        let fm = FileManager.default
        let freshURL = baseDir.appendingPathComponent("Vault-rebuild.sparsebundle")
        let freshMount = baseDir.appendingPathComponent(".vault-rebuild", isDirectory: true)
        try? fm.removeItem(at: freshURL)
        try create(at: freshURL, key: key)
        do {
            try attach(freshURL, at: freshMount, key: key)
            // ditto keeps extended attributes, so Finder tags survive the copy.
            try run("/usr/bin/ditto", [filesRoot.path, freshMount.appendingPathComponent("Files").path])
        } catch {
            detach(freshMount)
            try? fm.removeItem(at: freshURL)
            throw error
        }
        detach(freshMount)
        detach()
        try fm.removeItem(at: bundleURL)
        try fm.moveItem(at: freshURL, to: bundleURL)
        try? fm.removeItem(at: freshMount)
        try attach(key: key)
    }

    // Process plumbing

    /// Run hdiutil. The password goes in on stdin (NUL-terminated, as
    /// `-stdinpass` expects) and never appears in argv.
    @discardableResult
    private static func hdiutil(_ args: [String], password: String? = nil) throws -> Data {
        try run("/usr/bin/hdiutil", args, stdin: password.map { Data(($0 + "\0").utf8) })
    }

    @discardableResult
    private static func run(_ tool: String, _ args: [String], stdin: Data? = nil) throws -> Data {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = args
        let input = Pipe(), output = Pipe(), errors = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = errors
        try process.run()
        if let stdin {
            input.fileHandleForWriting.write(stdin)
        }
        try? input.fileHandleForWriting.close()
        let out = output.fileHandleForReading.readDataToEndOfFile()
        let err = errors.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let message = String(data: err, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            throw VaultError.hdiutil(message.isEmpty ? "\(tool) failed" : message)
        }
        return out
    }
}

// MARK: - QuickLook cache

/// The system thumbnail cache (ThumbnailsAgent) keeps plaintext thumbnails of
/// anything QuickLook rendered, vault files included, outside the vault.
enum QuickLookCache {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var sawVaultFile = false

    /// Note a URL handed to QuickLook. Only vault files make a reset necessary.
    static func noteHandoff(_ url: URL) {
        if VaultDisk.contains(url.path) {
            lock.withLock {
                sawVaultFile = true
            }
        }
    }

    /// Reset only when a vault file actually went through QuickLook since the
    /// last reset. The reset is system-wide: every thumbnail in Overlap and
    /// Finder re-renders from source afterwards, so it must not run on every lock.
    static func resetIfVaultFilesPreviewed() {
        let needed = lock.withLock {
            let needed = sawVaultFile
            sawVaultFile = false
            return needed
        }
        if needed {
            reset()
        }
    }

    /// Empty it. Instant; Finder regenerates thumbnails lazily.
    static func reset() {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/qlmanage")
        process.arguments = ["-r", "cache"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try? process.run()
        process.waitUntilExit()
    }
}

// MARK: - Moving files in and out

struct VaultMoveOutcome {
    var movedIn: [(from: URL, to: URL)] = []
    var movedOut: [(from: URL, to: URL)] = []
    var failed: [String] = []
    var error: String?
}

enum VaultMover {
    /// Attach if needed, then move `incoming` files into the vault and
    /// `outgoing` vault files back to their original paths. Blocking.
    static func run(key: String, into incoming: [URL], outOf outgoing: [URL],
                    progress: (Int) -> Void) -> VaultMoveOutcome {
        var outcome = VaultMoveOutcome()
        do {
            try VaultDisk.attach(key: key)
        } catch {
            outcome.error = error.localizedDescription
            return outcome
        }
        var done = 0
        for url in incoming {
            do {
                try ensureSpace(for: url)
                let dest = try move(url, to: VaultDisk.vaultURL(forOriginal: url))
                outcome.movedIn.append((url, dest))
            } catch {
                outcome.failed.append(url.path)
                outcome.error = error.localizedDescription
            }
            done += 1
            progress(done)
        }
        scrubFinderRecords(for: outcome.movedIn.map(\.from))
        for url in outgoing {
            guard let original = VaultDisk.originalURL(forVault: url) else { continue }
            do {
                let dest = try move(url, to: original)
                outcome.movedOut.append((url, dest))
            } catch {
                outcome.failed.append(url.path)
                outcome.error = error.localizedDescription
            }
            done += 1
            progress(done)
        }
        return outcome
    }

    /// Finder's .DS_Store keeps the names of files that sat in a folder. Drop it
    /// when it names a file that just moved into the vault; Finder rebuilds it
    /// (only that folder's view settings reset).
    private static func scrubFinderRecords(for moved: [URL]) {
        let byFolder = Dictionary(grouping: moved) { $0.deletingLastPathComponent() }
        for (folder, files) in byFolder {
            let store = folder.appendingPathComponent(".DS_Store")
            guard let data = try? Data(contentsOf: store) else { continue }
            let namesMovedFile = files.contains { file in
                guard let name = file.lastPathComponent.data(using: .utf16BigEndian) else { return false }
                return data.range(of: name) != nil
            }
            if namesMovedFile {
                try? FileManager.default.removeItem(at: store)
            }
        }
    }

    /// Move, creating the parent folder and never overwriting ("name 2.ext").
    private static func move(_ source: URL, to target: URL) throws -> URL {
        let fm = FileManager.default
        let dir = target.deletingLastPathComponent()
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        var dest = target
        let base = target.deletingPathExtension().lastPathComponent
        let ext = target.pathExtension
        var n = 2
        while fm.fileExists(atPath: dest.path) {
            dest = dir.appendingPathComponent(ext.isEmpty ? "\(base) \(n)" : "\(base) \(n).\(ext)")
            n += 1
        }
        try fm.moveItem(at: source, to: dest)
        return dest
    }

    /// Moving into the image copies the bytes; keep a margin on the host disk.
    private static func ensureSpace(for url: URL) throws {
        let margin: Int64 = 256 * 1_048_576
        let size = Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        let free = (try? VaultDisk.baseDir.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
            .volumeAvailableCapacityForImportantUsage) ?? Int64.max
        if free < size + margin {
            throw VaultError.noSpace(url.lastPathComponent)
        }
    }
}

// MARK: - Auto-lock

/// Locks on sleep, screen lock, fast user switch, and (optionally) after the
/// app has been in the background for `idleMinutes`. Detaches on quit.
@MainActor
final class AutoLock {
    var idleMinutes: Int
    private let onLock: @MainActor () -> Void
    private var tokens: [(NotificationCenter, NSObjectProtocol)] = []
    private var idleTimer: Timer?

    init(idleMinutes: Int, onLock: @escaping @MainActor () -> Void) {
        self.idleMinutes = idleMinutes
        self.onLock = onLock
        let workspace = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.willSleepNotification, NSWorkspace.screensDidSleepNotification,
                     NSWorkspace.sessionDidResignActiveNotification] {
            observe(workspace, name) { $0.onLock() }
        }
        observe(DistributedNotificationCenter.default(), Notification.Name("com.apple.screenIsLocked")) {
            $0.onLock()
        }
        observe(NotificationCenter.default, NSApplication.didResignActiveNotification) {
            $0.startIdleTimer()
        }
        observe(NotificationCenter.default, NSApplication.didBecomeActiveNotification) {
            $0.idleTimer?.invalidate()
        }
        observe(NotificationCenter.default, NSApplication.willTerminateNotification) { _ in
            VaultDisk.detach()
        }
    }

    private func observe(_ center: NotificationCenter, _ name: Notification.Name,
                         _ handler: @escaping @MainActor (AutoLock) -> Void) {
        let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                if let self {
                    handler(self)
                }
            }
        }
        tokens.append((center, token))
    }

    private func startIdleTimer() {
        idleTimer?.invalidate()
        guard idleMinutes > 0 else {
            return
        }
        idleTimer = Timer.scheduledTimer(withTimeInterval: TimeInterval(idleMinutes * 60),
                                         repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.onLock()
            }
        }
    }
}
