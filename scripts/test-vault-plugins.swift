// End-to-end check of the vault plugin partition: hidden files' plugin index
// lives only inside the (here throwaway) encrypted vault, queries span both
// partitions, a lock kills vault runs and leaves the mount point empty.
// Uses the installed plugins and the real CLIP models (read through a symlink);
// never touches the real vault, keychain or plugin cache.
//
//   SP=$(mktemp -d); mkdir -p $SP/h $SP/libcache/overlap-clip $SP/vaultbase
//   ln -s "$HOME/Library/Application Support/Overlap/PluginCache/overlap-clip/models" $SP/libcache/overlap-clip/models
//   cp scripts/test-vault-plugins.swift $SP/h/main.swift
//   swiftc Sources/PluginContract.swift Sources/SourceContract.swift Sources/PluginProcess.swift \
//     Sources/PluginRegistry.swift Sources/SuggestionService.swift Sources/SearchService.swift \
//     Sources/PrivacyVault.swift Sources/Models.swift Sources/DuplicateFinder.swift $SP/h/main.swift -o $SP/h/t
//   SCRATCH=$SP IMAGES=$PWD/Resources/TutorialImages OVERLAP_PLUGIN_CACHE=$SP/libcache \
//     OVERLAP_VAULT_DIR=$SP/vaultbase OVERLAP_NOT_DUPLICATES=$SP/not-duplicates.json $SP/h/t
import Foundation
import CryptoKit

enum TagStore {
    static func effectiveSettings(for plugin: DiscoveredPlugin, stored: [String: [String: SettingValue]]) -> [String: SettingValue]? { nil }
}

var failures = 0
func check(_ ok: Bool, _ what: String) {
    print(ok ? "  ok   \(what)" : "  FAIL \(what)")
    if !ok { failures += 1 }
}

let fm = FileManager.default
let env = ProcessInfo.processInfo.environment
guard let scratchPath = env["SCRATCH"], let imagesPath = env["IMAGES"] else {
    print("set SCRATCH and IMAGES (see the header)")
    exit(2)
}
let scratch = URL(fileURLWithPath: scratchPath).resolvingSymlinksInPath()
let images = URL(fileURLWithPath: imagesPath)

// This test creates and DELETES a vault image and writes plugin caches. Both
// must be redirected into the scratch folder, or it would hit the real ones.
func insideScratch(_ variable: String) -> Bool {
    guard let value = env[variable] else { return false }
    let path = URL(fileURLWithPath: value).resolvingSymlinksInPath().path
    return path.hasPrefix(scratch.path + "/")
}
guard insideScratch("OVERLAP_VAULT_DIR"), insideScratch("OVERLAP_PLUGIN_CACHE"),
      insideScratch("OVERLAP_NOT_DUPLICATES"),
      VaultDisk.bundleURL.resolvingSymlinksInPath().path.hasPrefix(scratch.path + "/") else {
    print("refusing to run: OVERLAP_VAULT_DIR, OVERLAP_PLUGIN_CACHE and OVERLAP_NOT_DUPLICATES must point inside SCRATCH")
    exit(2)
}
let libDir = scratch.appendingPathComponent("lib")
let libCache = PluginPartition.libraryRoot
let key = "TEST0-TEST1-TEST2-TEST3-TEST4-TEST5"
let marker = "SECRETMARKER"
let hiddenTag = "zz-hidden-nature"

func item(_ url: URL, _ tags: [String]) -> LibraryItem {
    let mod = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
    return LibraryItem(path: url.path, kind: "image", tags: tags, modDate: mod)
}

/// Every file under `dir` whose bytes contain `needle`.
func filesContaining(_ needle: String, under dir: URL) -> [String] {
    let en = fm.enumerator(at: dir, includingPropertiesForKeys: nil)
    var hits: [String] = []
    while let url = en?.nextObject() as? URL {
        if url.pathExtension == "mlmodelc" || url.path.contains(".mlmodelc/") || url.path.contains("/models") { continue }
        if let data = try? Data(contentsOf: url), data.range(of: Data(needle.utf8)) != nil {
            hits.append(url.path)
        }
    }
    return hits
}

func digest(_ url: URL) -> String {
    guard let data = try? Data(contentsOf: url) else { return "missing" }
    return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

// ---------------------------------------------------------------- setup
print("setup")
try? fm.removeItem(at: VaultDisk.bundleURL)
try fm.createDirectory(at: libDir, withIntermediateDirectories: true)
try VaultDisk.create(key: key)
try VaultDisk.attach(key: key)
check(VaultDisk.isAttached, "scratch vault attached at \(VaultDisk.mountURL.path)")
check(fm.fileExists(atPath: VaultDisk.pluginCacheRoot.path), "attach creates AppData/PluginCache")

let libraryNames = ["city", "desert", "night", "snow", "sunset"]
let hiddenNames = ["flower", "forest", "ocean"]
var libItems: [LibraryItem] = []
for name in libraryNames {
    let dst = libDir.appendingPathComponent("demo-\(name).png")
    try? fm.removeItem(at: dst)
    try fm.copyItem(at: images.appendingPathComponent("demo-\(name).png"), to: dst)
    libItems.append(item(dst, ["landscape"]))
}
var hiddenItems: [LibraryItem] = []
for name in hiddenNames {
    let original = libDir.appendingPathComponent("\(marker)-\(name).png")
    let dst = VaultDisk.vaultURL(forOriginal: original)
    try fm.createDirectory(at: dst.deletingLastPathComponent(), withIntermediateDirectories: true)
    try fm.copyItem(at: images.appendingPathComponent("demo-\(name).png"), to: dst)
    hiddenItems.append(item(dst, [hiddenTag]))
}
/// Fresh each time: a partition handed out before a close never launches after it.
var vault: PluginPartition { VaultDisk.pluginPartition }
let plugins = PluginRegistry.discover().map(\.id).sorted()
check(plugins.contains("com.overlap.clip"), "plugins discovered: \(plugins)")

// ---------------------------------------------------------------- warm-ups
print("warm-up")
_ = await SuggestionEngine.run(files: [], library: libItems, knownTags: ["landscape"], kinds: [.image])
let libSearch = await SearchEngine.run(query: nil, library: libItems)
check(libSearch.indexedCount == libraryNames.count, "library index holds \(libSearch.indexedCount ?? -1) images")
_ = await SuggestionEngine.run(files: [], library: hiddenItems, knownTags: ["landscape", hiddenTag],
                               kinds: [.image], partition: vault)
let vaultSearch = await SearchEngine.run(query: nil, library: hiddenItems, partition: vault)
check(vaultSearch.indexedCount == hiddenNames.count, "vault index holds \(vaultSearch.indexedCount ?? -1) images")

async let syncA = SuggestionEngine.sync(library: hiddenItems, knownTags: [hiddenTag], kinds: [.image],
                                        disabledIDs: [], pluginSettings: [:], partition: vault)
async let syncB = SuggestionEngine.sync(library: hiddenItems.reversed(), knownTags: [hiddenTag], kinds: [.image],
                                        disabledIDs: [], pluginSettings: [:], partition: vault)
let bothSynced = await (syncA, syncB)
let suggestMeta = VaultDisk.pluginCacheRoot.appendingPathComponent("overlap-suggest/meta.json")
check(bothSynced == (true, true), "two suggest runs on one index both finish (they take turns)")
check((try? JSONSerialization.jsonObject(with: Data(contentsOf: suggestMeta))) != nil, "…and leave a readable meta.json")

// ---------------------------------------------------------------- where the data went
print("isolation")
let vaultClip = VaultDisk.pluginCacheRoot.appendingPathComponent("overlap-clip")
let vaultSuggest = VaultDisk.pluginCacheRoot.appendingPathComponent("overlap-suggest")
check(fm.fileExists(atPath: vaultClip.appendingPathComponent("clip.bin").path), "CLIP vectors for hidden files sit in the vault")
check(fm.fileExists(atPath: vaultSuggest.appendingPathComponent("meta.json").path), "suggest index for hidden files sits in the vault")
check(!filesContaining(marker, under: VaultDisk.pluginCacheRoot).isEmpty, "vault index names the hidden files")
check(filesContaining(marker, under: libCache).isEmpty, "library cache never names a hidden file")
check(filesContaining(hiddenTag, under: libCache).isEmpty, "library cache never names a hidden tag")
check(!fm.fileExists(atPath: vaultClip.appendingPathComponent("models").path), "no model copy in the vault")
check(!fm.fileExists(atPath: vaultClip.appendingPathComponent("config.json").path), "config stays shared, out of the vault")
check(fm.fileExists(atPath: libCache.appendingPathComponent("overlap-clip/config.json").path), "shared config in the library cache")
let realCache = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Overlap/PluginCache")
check(filesContaining(marker, under: realCache).isEmpty, "real plugin cache untouched by the test")

// ---------------------------------------------------------------- queries
print("queries")
let flower = hiddenItems[0].path
let both = await SearchEngine.run(query: "a flower", disabledIDs: [], pluginSettings: [:], vault: vault)
check(both.hits.first?.path == flower, "text search ranks the hidden flower first: \(both.hits.first.map { URL(fileURLWithPath: $0.path).lastPathComponent } ?? "none")")
check(both.indexedCount == libraryNames.count + hiddenNames.count, "combined count spans both partitions")
let lockedSearch = await SearchEngine.run(query: "a flower", disabledIDs: [], pluginSettings: [:], vault: nil)
let seedWithoutVault = await SearchEngine.run(query: nil, similarTo: [flower], disabledIDs: [], pluginSettings: [:], vault: nil)
check(seedWithoutVault.hits.isEmpty && seedWithoutVault.ranPlugin, "without the vault partition a hidden seed reaches no plugin")
let failing = await SearchEngine.run(query: "a flower", library: [], disabledIDs: [], partition: .vault(VaultDisk.pluginCacheRoot, volume: scratch, epoch: VaultRuns.currentEpoch))
check(failing.ranPlugin && failing.indexedCount == nil, "a plugin run that fails still counts as ran (index not ready, not 'no plugin')")
check(!lockedSearch.hits.contains { $0.path.contains(marker) }, "without the vault partition no hidden hit appears")

let libBin = libCache.appendingPathComponent("overlap-clip/clip.bin")
let libMeta = libCache.appendingPathComponent("overlap-clip/meta.json")
let before = (digest(libBin), digest(libMeta))
let similar = await SearchEngine.run(query: nil, similarTo: [flower], disabledIDs: [], pluginSettings: [:], vault: vault)
check(!similar.hits.isEmpty, "Find Similar from a hidden image returns \(similar.hits.count) hits")
check(similar.hits.contains { !$0.path.contains(marker) }, "…including library files")
check((digest(libBin), digest(libMeta)) == before, "the library index didn't keep the hidden source")
check(filesContaining(marker, under: libCache).isEmpty, "library cache still clean after Find Similar")

let exploreQuery = ExploreQuery(tastes: [], avoid: [], exclude: [], roots: [VaultDisk.filesRoot.path],
                                perTaste: 0, random: 20, within: nil)
let hiddenExplore = await SearchEngine.explore(exploreQuery, disabledIDs: [], pluginSettings: [:], partition: vault)
let hiddenPaths = hiddenExplore.result?.candidates.map(\.path) ?? []
check(hiddenPaths.count == hiddenNames.count && hiddenPaths.allSatisfy(VaultDisk.contains), "hidden Explore draws only vault files (\(hiddenPaths.count))")
let libExplore = await SearchEngine.explore(ExploreQuery(tastes: [], avoid: [], exclude: [], roots: [libDir.path],
                                                         perTaste: 0, random: 20, within: nil),
                                            disabledIDs: [], pluginSettings: [:])
check((libExplore.result?.candidates ?? []).allSatisfy { !VaultDisk.contains($0.path) }, "library Explore never sees a vault file")
check(hiddenExplore.result?.model == libExplore.result?.model, "both partitions use the same encoder (\(libExplore.result?.model ?? "?"))")

let target = RequestFile(path: hiddenItems[1].path, kind: "image", ext: "png", tags: [], size: nil, modDate: nil, createdDate: nil)
let suggestions = await SuggestionEngine.run(files: [target], library: [], knownTags: [hiddenTag], kinds: [.image],
                                             partition: vault)
print("       hidden suggestions: \(suggestions.map { "\($0.tag) \(String(format: "%.2f", $0.confidence))" })")
check(filesContaining(marker, under: libCache).isEmpty, "library cache still clean after a hidden suggest")

// ---------------------------------------------------------------- lock while indexing
print("lock mid-index")
var bulk: [LibraryItem] = []
let bulkDir = VaultDisk.vaultURL(forOriginal: libDir.appendingPathComponent("bulk"))
try fm.createDirectory(at: bulkDir, withIntermediateDirectories: true)
for i in 0..<600 {
    let dst = bulkDir.appendingPathComponent("\(marker)-bulk-\(i).png")
    try fm.copyItem(at: images.appendingPathComponent("demo-\(hiddenNames[i % 3]).png"), to: dst)
    bulk.append(item(dst, [hiddenTag]))
}
let started = Date()
let indexing = Task.detached {
    await SearchEngine.run(query: nil, library: hiddenItems + bulk, partition: vault)
}
try await Task.sleep(nanoseconds: 1_500_000_000)
VaultDisk.detach()   // kills vault runs, detaches, scrubs
let killed = await indexing.value
let elapsed = Date().timeIntervalSince(started)
check(killed.indexedCount == nil, "the vault warm-up was killed, not finished (\(String(format: "%.1f", elapsed))s)")
check(!VaultDisk.isAttached, "vault detached")
let leftovers = (try? fm.contentsOfDirectory(atPath: VaultDisk.mountURL.path)) ?? []
check(leftovers.isEmpty, "mount point is empty after detach: \(leftovers)")

// ---------------------------------------------------------------- closed vault
print("closed vault")
check(vault.environment() == nil, "no environment for a closed vault partition")
let closed = await SearchEngine.run(query: "a flower", library: [], partition: vault)
check(closed.hits.isEmpty && closed.indexedCount == nil, "a query on the closed partition launches nothing")
check(((try? fm.contentsOfDirectory(atPath: VaultDisk.mountURL.path)) ?? []).isEmpty, "…and creates nothing in the mount point")

let clipExec = PluginRegistry.discover().first { $0.id == "com.overlap.clip" }!.execURL
let strict = Process()
strict.executableURL = clipExec
var strictEnv = env
strictEnv["OVERLAP_PLUGIN_CACHE"] = VaultDisk.pluginCacheRoot.path
strictEnv["OVERLAP_PLUGIN_CACHE_STRICT"] = "1"
strictEnv["OVERLAP_PLUGIN_CACHE_VOLUME"] = VaultDisk.mountURL.path
strict.environment = strictEnv
let strictIn = Pipe()
strict.standardInput = strictIn
strict.standardOutput = FileHandle.nullDevice
strict.standardError = FileHandle.nullDevice
try strict.run()
try? strictIn.fileHandleForWriting.close()
strict.waitUntilExit()
check(strict.terminationStatus == 2, "a plugin told STRICT refuses a missing root (exit \(strict.terminationStatus))")
check(!fm.fileExists(atPath: VaultDisk.pluginCacheRoot.path), "…without recreating it on the host disk")

// A plain folder where the vault root should be (something recreated it on the host disk).
try fm.createDirectory(at: VaultDisk.pluginCacheRoot, withIntermediateDirectories: true)
check(vault.environment() == nil, "a plain folder at the mount point is not taken for the vault")
let fake = await SearchEngine.run(query: nil, library: hiddenItems, partition: vault)
check(fake.indexedCount == nil, "…so nothing is indexed into it")
let fakeRun = Process()
fakeRun.executableURL = clipExec
fakeRun.environment = strictEnv
let fakeIn = Pipe()
fakeRun.standardInput = fakeIn
fakeRun.standardOutput = FileHandle.nullDevice
fakeRun.standardError = FileHandle.nullDevice
try fakeRun.run()
try? fakeIn.fileHandleForWriting.close()
fakeRun.waitUntilExit()
check(fakeRun.terminationStatus == 2, "a STRICT plugin refuses a root that isn't on the mounted vault")
check(((try? fm.contentsOfDirectory(atPath: VaultDisk.pluginCacheRoot.path)) ?? []).isEmpty, "…and writes nothing into it")
try fm.removeItem(at: VaultDisk.appDataRoot)

// ---------------------------------------------------------------- reopen, gates
print("reopen + gates")
try VaultDisk.attach(key: key)
let reopened = await SearchEngine.run(query: "a flower", disabledIDs: [], pluginSettings: [:], vault: vault)
check(reopened.hits.first?.path == flower, "hidden index survives lock/unlock")

let installed = PluginRegistry.discover()
check(installed.filter(\.mayUseVault).map(\.id).sorted() == ["com.overlap.clip", "com.overlap.suggest"],
      "only the local plugins may use the vault")
let clipPlugin = installed.first { $0.id == "com.overlap.clip" }!
var unmarked = try JSONSerialization.jsonObject(with: Data(contentsOf: clipPlugin.dir.appendingPathComponent("manifest.json"))) as! [String: Any]
unmarked.removeValue(forKey: "local")
let unmarkedManifest = try PluginCoder.decoder.decode(PluginManifest.self, from: JSONSerialization.data(withJSONObject: unmarked))
let notLocal = DiscoveredPlugin(manifest: unmarkedManifest, dir: clipPlugin.dir, execURL: clipPlugin.execURL)
let flowerQuery = SuggestRequest(files: [], knownTags: nil, library: nil, settings: nil, query: "a flower")
check(SuggestionEngine.runProcess(notLocal, request: flowerQuery, timeoutMs: 60_000, partition: vault) == nil,
      "a plugin not marked local is never run in the vault")
check(SuggestionEngine.runProcess(clipPlugin, request: flowerQuery, timeoutMs: 60_000, partition: vault)?.hits?.isEmpty == false,
      "…while the local one is")

let handedOut = vault
VaultRuns.closeAndKill()
check(SuggestionEngine.runProcess(clipPlugin, request: flowerQuery, timeoutMs: 60_000, partition: vault) == nil,
      "a closed gate refuses vault launches while still attached")
VaultRuns.reopen()
check(SuggestionEngine.runProcess(clipPlugin, request: flowerQuery, timeoutMs: 60_000, partition: handedOut) == nil,
      "a partition handed out before the close stays void after reopening")
check(SuggestionEngine.runProcess(clipPlugin, request: flowerQuery, timeoutMs: 60_000, partition: vault) != nil,
      "…and reopening lets them through")

// ---------------------------------------------------------------- duplicates, vault trash
print("duplicates + trash")
let flowerCopy = VaultDisk.filesRoot.appendingPathComponent(String(libDir.path.dropFirst()))
    .appendingPathComponent("\(marker)-flower-copy.png")
try? fm.removeItem(at: flowerCopy)
try fm.copyItem(at: URL(fileURLWithPath: flower), to: flowerCopy)
let cityCopy = libDir.appendingPathComponent("demo-city-copy.png")
try? fm.removeItem(at: cityCopy)
try fm.copyItem(at: libDir.appendingPathComponent("demo-city.png"), to: cityCopy)
let withCopies = hiddenItems + [item(flowerCopy, [hiddenTag])]
_ = await SearchEngine.run(query: nil, library: withCopies, partition: vault)
_ = await SearchEngine.run(query: nil, library: libItems + [item(cityCopy, ["landscape"])])

let exact = DuplicateFinder.exactPairs((withCopies + libItems).map { URL(fileURLWithPath: $0.path) } + [cityCopy]) { _ in }
check(exact.count == 2, "exact copies found across library and vault (\(exact.count) pairs)")
let hiddenNear = DuplicateFinder.nearPairs(threshold: 0.95, paths: nil, disabledIDs: [], pluginSettings: [:],
                                           partition: vault) { _ in }
check(hiddenNear.contains { Set([$0.a, $0.b]) == Set([flower, flowerCopy.path]) },
      "near duplicates of hidden images come from the vault index")
check(hiddenNear.allSatisfy { VaultDisk.contains($0.a) && VaultDisk.contains($0.b) }, "…and only name vault files")
let libraryNear = DuplicateFinder.nearPairs(threshold: 0.95, paths: nil, disabledIDs: [], pluginSettings: [:]) { _ in }
check(libraryNear.contains { Set([$0.a, $0.b]) == Set([libItems[0].path, cityCopy.path]) }, "library near duplicates as before")
check(!libraryNear.contains { VaultDisk.contains($0.a) || VaultDisk.contains($0.b) }, "…never naming a vault file")

let plainList = URL(fileURLWithPath: env["OVERLAP_NOT_DUPLICATES"]!)
var notDups = NotDuplicates.load(includingHidden: true)
NotDuplicates.add([flower, flowerCopy.path], to: &notDups, includingHidden: true)
NotDuplicates.add([libItems[0].path, cityCopy.path], to: &notDups, includingHidden: true)
let plainText = (try? String(contentsOf: plainList, encoding: .utf8)) ?? ""
check(!plainText.contains(marker), "a hidden not-duplicates pair never reaches the plain list")
check(plainText.contains("demo-city-copy"), "library pairs still go to the plain list")
check(!filesContaining(marker, under: VaultDisk.appDataRoot).filter { $0.hasSuffix("not-duplicates.json") }.isEmpty,
      "hidden pairs are kept in the vault")
check(NotDuplicates.load(includingHidden: true).count == 2, "both lists load while revealed")
// Locked while a vault job keeps it mounted: the model holds no hidden pairs.
var lockedView = NotDuplicates.load(includingHidden: false)
check(lockedView.count == 1, "locked: hidden pairs don't load even though mounted")
NotDuplicates.add([libItems[1].path, libItems[2].path], to: &lockedView, includingHidden: false)
check(NotDuplicates.load(includingHidden: true).count == 3, "…and a library mark then leaves the hidden list intact")

// A file in a marked pair gets hidden: its pair follows it into the vault.
let snowOriginal = libItems[1].path
let snowInVault = VaultDisk.vaultURL(forOriginal: URL(fileURLWithPath: snowOriginal))
try fm.createDirectory(at: snowInVault.deletingLastPathComponent(), withIntermediateDirectories: true)
try fm.moveItem(at: URL(fileURLWithPath: snowOriginal), to: snowInVault)
NotDuplicates.remap([snowOriginal: snowInVault.path])
let afterHide = (try? String(contentsOf: plainList, encoding: .utf8)) ?? ""
check(!afterHide.contains("demo-snow"), "hiding a file takes its old path out of the plain list")
check(NotDuplicates.load(includingHidden: true).contains(NotDuplicates.key(snowInVault.path, libItems[2].path)),
      "…and the pair is kept, under the vault path")
try fm.moveItem(at: snowInVault, to: URL(fileURLWithPath: snowOriginal))
NotDuplicates.remap([snowInVault.path: snowOriginal])
check(NotDuplicates.load(includingHidden: false).contains(NotDuplicates.key(snowOriginal, libItems[2].path)),
      "unhiding brings the pair back to the plain list")

let trashed = try VaultDisk.trash(flowerCopy)
check(!fm.fileExists(atPath: flowerCopy.path) && fm.fileExists(atPath: trashed.path), "a hidden file goes to the vault trash")
check(trashed.path.hasPrefix(VaultDisk.trashRoot.path + "/") && !VaultDisk.contains(trashed.path),
      "…outside the hidden files")
check(!VaultDisk.scanFiles().contains { $0.path == trashed.path }, "…so it no longer lists as hidden")
check((try? VaultDisk.trash(cityCopy)) == nil, "the vault trash refuses a library file")
try VaultDisk.attach(key: key)   // what every move does while revealed
check(fm.fileExists(atPath: trashed.path), "an attach while already attached keeps the trash (Undo)")
VaultDisk.detach()
check(NotDuplicates.load(includingHidden: true).count == 2, "locked: only the library pairs load")
try VaultDisk.attach(key: key)
check(!fm.fileExists(atPath: VaultDisk.trashRoot.path), "lock emptied the vault trash")
let oceanTrashed = try VaultDisk.trash(URL(fileURLWithPath: hiddenItems[2].path))
try VaultDisk.rebuild(key: key)
check(fm.fileExists(atPath: oceanTrashed.path), "Reclaim Space keeps the trash (Undo still works)")
try fm.moveItem(at: oceanTrashed, to: URL(fileURLWithPath: hiddenItems[2].path))
// A crash leaves the trash on the image (no detach ran): the next real unlock
// empties it. Simulated: detach by hand, without the lock's own emptying.
_ = try VaultDisk.trash(URL(fileURLWithPath: hiddenItems[2].path))
_ = try? Process.run(URL(fileURLWithPath: "/usr/bin/hdiutil"), arguments: ["detach", VaultDisk.mountURL.path]).waitUntilExit()
check(!VaultDisk.isAttached, "simulated crash: vault detached with a full trash")
try VaultDisk.attach(key: key)
check(!fm.fileExists(atPath: VaultDisk.trashRoot.path), "unlock empties a trash a crash left behind")
try fm.copyItem(at: images.appendingPathComponent("demo-ocean.png"), to: URL(fileURLWithPath: hiddenItems[2].path))
_ = await SearchEngine.run(query: nil, library: hiddenItems, partition: vault)   // forget the trashed copy

// ---------------------------------------------------------------- rebuild
print("rebuild")
let usage = VaultDisk.usage()
check(usage.inUse > 0, "usage counts files + AppData (\(usage.inUse) bytes)")
try VaultDisk.rebuild(key: key)
check(fm.fileExists(atPath: vaultClip.appendingPathComponent("clip.bin").path), "rebuild carries the hidden index over")
let rebuilt = await SearchEngine.run(query: "a flower", disabledIDs: [], pluginSettings: [:], vault: vault)
check(rebuilt.hits.first?.path == flower, "search works after rebuild")

try Data("{}".utf8).write(to: VaultDisk.exploreProfileURL)
VaultDisk.clearAppData(keepingExplore: true)
check(((try? fm.contentsOfDirectory(atPath: VaultDisk.pluginCacheRoot.path)) ?? ["?"]).isEmpty, "clearAppData empties the hidden index")
check(fm.fileExists(atPath: VaultDisk.exploreProfileURL.path), "…keeping the Explore profile when asked")
VaultDisk.clearAppData(keepingExplore: false)
check(!fm.fileExists(atPath: VaultDisk.exploreProfileURL.path), "…or not")

VaultDisk.detach()
try? fm.removeItem(at: VaultDisk.bundleURL)
print(failures == 0 ? "ALL PASSED" : "\(failures) FAILED")
exit(failures == 0 ? 0 : 1)
