// Headless check of the source-plugin pipeline against scripts/fixtures/mocksource:
// pull (paging, text/link items, cross-collection dedupe, re-pull is a no-op)
// and push (upload, then connect-by-id for files the service already has).
//
// Top-level code must be compiled as main.swift, so copy it first:
//   (cd scripts/fixtures/mocksource && swiftc main.swift -o mocksource)
//   mkdir -p /tmp/ts && cp scripts/test-sources.swift /tmp/ts/main.swift
//   swiftc Sources/PluginContract.swift Sources/SourceContract.swift Sources/PluginProcess.swift \
//     Sources/FileOrigin.swift Sources/SourceEngine.swift Sources/TagIO.swift Sources/PluginRegistry.swift \
//     /tmp/ts/main.swift -o /tmp/test-sources && /tmp/test-sources
import Foundation

enum FileKind: String { case image }   // the app's real FileKind lives in Models.swift

var failures = 0
func check(_ ok: Bool, _ what: String) {
    print(ok ? "  ok   \(what)" : "  FAIL \(what)")
    if !ok {
        failures += 1
    }
}

let fm = FileManager.default
let repo = URL(fileURLWithPath: fm.currentDirectoryPath)
let pluginDir = repo.appendingPathComponent("scripts/fixtures/mocksource")
let manifest = try PluginCoder.decoder.decode(PluginManifest.self,
                                              from: Data(contentsOf: pluginDir.appendingPathComponent("manifest.json")))
let plugin = DiscoveredPlugin(manifest: manifest, dir: pluginDir,
                              execURL: pluginDir.appendingPathComponent(manifest.exec))

let work = fm.temporaryDirectory.appendingPathComponent("overlap-sources-\(UUID().uuidString)")
let remote = work.appendingPathComponent("remote")
let scope = work.appendingPathComponent("library")
setenv("MOCKSOURCE_ROOT", remote.path, 1)
defer {
    try? fm.removeItem(at: work)
}

func write(_ text: String, _ path: String) {
    let url = remote.appendingPathComponent(path)
    try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try? Data(text.utf8).write(to: url)
}
write("png-a", "Alpha/a.png")
write("png-shared", "Alpha/shared.png")
write("hello", "Alpha/note.txt")
write("https://example.com", "Alpha/site.url")
write("png-shared", "Beta/shared.png")
write("png-b", "Beta/b.png")
try fm.createDirectory(at: scope, withIntermediateDirectories: true)

let secrets = ["token": "t"]
let settings: [String: SettingValue] = ["pageSize": .number(2)]
let info = manifest.source!

func link(_ title: String) -> SourceLink {
    SourceLink(pluginID: plugin.id, collection: SourceCollection(id: title, title: title),
               destination: SourceEngine.defaultDestination(scope: scope, info: info, collectionTitle: title).path)
}

print("status / collections")
if case .success(let r) = await SourceEngine.call(plugin, SourceRequest(op: .status, secrets: secrets)) {
    check(r.account?.authenticated == true, "signed in with a token")
} else {
    check(false, "status answered")
}
if case .failure = await SourceEngine.call(plugin, SourceRequest(op: .collections)) {
    check(true, "no token → error surfaces")
} else {
    check(false, "no token → error surfaces")
}
if case .success(let r) = await SourceEngine.call(plugin, SourceRequest(op: .collections, secrets: secrets)) {
    check(r.collections?.map(\.id) == ["Alpha", "Beta"], "lists collections")
}

print("pull")
let alpha = await SourceEngine.pull(link("Alpha"), plugin: plugin, scope: scope, secrets: secrets, settings: settings)
check(alpha.error == nil, "Alpha pulled without error (\(alpha.error ?? ""))")
check(alpha.added.count == 4, "4 files across 2 pages (got \(alpha.added.count))")
let names = Set(alpha.added.map(\.lastPathComponent))
check(names == ["a.png", "shared.png", "note.md", "site.webloc"], "image, text→.md, link→.webloc (\(names))")
let shared = alpha.added.first { $0.lastPathComponent == "shared.png" }!
check(shared.path.hasPrefix(scope.appendingPathComponent("Mock Source/Alpha").path), "lands in <scope>/<provider>/<collection>")
check(TagIO.tags(of: shared) == ["mock/Alpha"], "tagged mock/Alpha")
check(FileOrigin.records(of: shared).first?.remoteId == "shared.png", "origin xattr written")
let staged = (try? fm.contentsOfDirectory(atPath: SourceEngine.stagingRoot().path)) ?? []
check(staged.isEmpty, "staging cleaned (\(staged.count) leftover runs)")

let beta = await SourceEngine.pull(link("Beta"), plugin: plugin, scope: scope, secrets: secrets, settings: settings)
check(beta.added.map(\.lastPathComponent) == ["b.png"], "Beta adds only b.png")
check(beta.retagged.map { $0.resolvingSymlinksInPath().path } == [shared.resolvingSymlinksInPath().path],
      "shared.png reused, not duplicated")
check(Set(TagIO.tags(of: shared)) == ["mock/Alpha", "mock/Beta"], "shared.png carries both tags")
check(FileOrigin.records(of: shared).count == 2, "two origin records")

let again = await SourceEngine.pull(link("Alpha"), plugin: plugin, scope: scope, secrets: secrets, settings: settings)
check(again.added.isEmpty && again.retagged.isEmpty, "re-pull is a no-op")

print("push")
let local = scope.appendingPathComponent("mine.png")
try Data("png-mine".utf8).write(to: local)
let beta2 = SourceCollection(id: "Beta", title: "Beta")
let pushed = await SourceEngine.push([local, shared], to: beta2, plugin: plugin, secrets: secrets, settings: settings)
check(pushed.error == nil && pushed.pushed.count == 2, "pushed 2 (\(pushed.error ?? ""))")
check(fm.fileExists(atPath: remote.appendingPathComponent("Beta/mine.png").path), "new file uploaded")
check(fm.fileExists(atPath: remote.appendingPathComponent("Beta/.shared.png.connected").path),
      "known file connected by id, not re-uploaded")
check(TagIO.tags(of: local) == ["mock/Beta"], "pushed file gets the collection tag")
check(FileOrigin.remoteId(of: local, plugin: plugin.id) == "mine.png", "remote id written back")

print("browse + save picks")
write("png-c", "Beta/c.png")
if case .success(let r) = await SourceEngine.call(plugin, SourceRequest(op: .browse, secrets: secrets,
                                                                     collection: "Beta", scope: "collection")) {
    check(r.items?.contains { $0.remoteId == "c.png" && $0.file == nil } == true, "browse lists without downloading")
}
let picks = [
    SourceEngine.Pick(item: SourceItem(remoteId: "c.png", kind: "image"), collection: beta2),
    SourceEngine.Pick(item: SourceItem(remoteId: "a.png", kind: "image"),
                      collection: SourceCollection(id: "Gamma", title: "Gamma")),
]
let saved = await SourceEngine.save(picks, plugin: plugin, scope: scope, secrets: secrets, settings: settings)
check(saved.error == nil, "save ran (\(saved.error ?? ""))")
check(saved.added.map(\.lastPathComponent) == ["c.png"], "only the new pick downloads")
check(saved.added.first?.path.contains("Mock Source/Beta/") == true, "pick lands in its collection's folder")
let aFile = alpha.added.first { $0.lastPathComponent == "a.png" }!
check(TagIO.tags(of: aFile).contains("mock/Gamma"), "a pick already here just gains the tag")
check(saved.tags == ["mock/Beta", "mock/Gamma"], "outcome reports the tags used")

print(failures == 0 ? "\nall passed" : "\n\(failures) failed")
exit(failures == 0 ? 0 : 1)
