import Foundation
import SwiftUI

extension Notification.Name {
    /// Posted by the Help-menu item to (re)start the tutorial.
    static let overlapStartTutorial = Notification.Name("overlapStartTutorial")
}

/// A control the coach-mark spotlight can target. Each is published as a frame
/// anchor by the matching view via `.tutorialAnchor(_:)`, so the ring lands
/// exactly on it and tracks window resizing. `.center` has no anchor (the whole
/// window dims and the callout centers).
enum TutorialTarget: Hashable {
    case modePicker, watchedFolders, applyButton, sidebar, grid, tagBar, center
}

/// Collects the frame of every tagged control, keyed by target.
struct TutorialAnchorKey: PreferenceKey {
    static var defaultValue: [TutorialTarget: Anchor<CGRect>] = [:]
    static func reduce(value: inout Value, nextValue: () -> Value) {
        value.merge(nextValue()) { _, new in new }
    }
}

extension View {
    /// Publish this view's frame so the tutorial can spotlight it. Purely
    /// additive — no effect unless the tutorial reads it.
    func tutorialAnchor(_ target: TutorialTarget) -> some View {
        anchorPreference(key: TutorialAnchorKey.self, value: .bounds) { [target: $0] }
    }
}

/// One coach-mark step.
struct TutorialStep: Identifiable {
    let id = UUID()
    let target: TutorialTarget
    let title: String
    let body: String
    /// `.info` steps advance on Next; `.action` steps require the user to do the
    /// thing (Next stays disabled until `isDone`, and we auto-advance too).
    enum Kind { case info, action }
    let kind: Kind
    var isDone: (TagStore) -> Bool = { _ in true }

    init(target: TutorialTarget, kind: Kind, title: String, body: String,
         isDone: @escaping (TagStore) -> Bool = { _ in true }) {
        self.target = target
        self.kind = kind
        self.title = title
        self.body = body
        self.isDone = isDone
    }
}

/// Drives the interactive tutorial: step state, first-boot gating, and a
/// throwaway practice library. All work goes through existing TagStore/TagIO
/// APIs so core code is untouched (aside from one-line anchors).
@MainActor
final class TutorialModel: ObservableObject {
    @Published private(set) var active = false
    @Published private(set) var index = 0

    private let seenKey = "hasSeenTutorial"
    var hasSeenTutorial: Bool { UserDefaults.standard.bool(forKey: seenKey) }

    /// A throwaway, self-owned library the tutorial runs against. It lives in an
    /// indexed location (Spotlight refuses /tmp & /var/folders, so the query
    /// step needs a real indexed dir) and is deleted when the tutorial ends.
    /// While active we point the app's scope + queue at it and never touch the
    /// user's real library; on exit we restore both.
    private var sandboxDir: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Documents/Overlap Tutorial", isDirectory: true)
    }
    private var savedScope: URL?
    private var savedFolders: [URL]?

    let steps: [TutorialStep] = [
        TutorialStep(
            target: .center, kind: .info,
            title: "Welcome to Overlap",
            body: "Overlap finds images by combining their tags. Let's queue, tag, and query a few sample images together — in a temporary practice library that's deleted when you're done. Your real photos aren't touched."),
        TutorialStep(
            target: .modePicker, kind: .action,
            title: "1 · The Queue",
            body: "Click “Queue” at the top of the sidebar. Freshly downloaded, untagged images collect here.",
            isDone: { $0.mode == .queue }),
        TutorialStep(
            target: .watchedFolders, kind: .info,
            title: "2 · Watched folder",
            body: "A practice folder was added here. Its sample images show in the grid, waiting to be tagged."),
        TutorialStep(
            target: .grid, kind: .action,
            title: "3 · Select images",
            body: "Click an image to select it. ⇧-click selects a range, ⌘-click adds one at a time.",
            isDone: { !$0.selection.isEmpty }),
        TutorialStep(
            target: .tagBar, kind: .action,
            title: "4 · Tag them",
            body: "Press T to focus the tag bar, type a tag like “Nature”, and press ⏎ to apply it to your selection.",
            isDone: { $0.taggedQueueCount > 0 }),
        TutorialStep(
            target: .applyButton, kind: .action,
            title: "5 · Apply to library",
            body: "Click “Apply → Library” to add your tagged images into the library.",
            isDone: { $0.taggedQueueCount == 0 }),
        TutorialStep(
            target: .sidebar, kind: .action,
            title: "6 · Query by tag",
            body: "Switch to “Tags”, then click a tag to filter by it. Click again to exclude it instead.",
            isDone: { !$0.querySets.isEmpty }),
        TutorialStep(
            target: .modePicker, kind: .info,
            title: "7 · Explore overlaps",
            body: "“Explore” shows tags as Venn diagrams — click the overlaps to find images that share tags."),
        TutorialStep(
            target: .center, kind: .info,
            title: "You're set!",
            body: "That's the whole loop: queue → tag → query. Click Done to close the practice library — its sample images are removed and your real library comes back."),
    ]

    var current: TutorialStep { steps[min(index, steps.count - 1)] }
    var isLast: Bool { index == steps.count - 1 }
    var progress: String { "Step \(index + 1) of \(steps.count)" }

    // MARK: Flow

    func start(_ store: TagStore) {
        index = 0
        installDemoData(store)   // must precede active so the sandbox is ready
        active = true
    }

    func next(_ store: TagStore) {
        guard index < steps.count - 1 else { finish(store); return }
        index += 1
    }

    func back(_ store: TagStore) {
        guard index > 0 else { return }
        index -= 1
    }

    func skip(_ store: TagStore) { finish(store) }

    func finish(_ store: TagStore) {
        teardownDemoData(store)
        active = false
        UserDefaults.standard.set(true, forKey: seenKey)
    }

    /// Called from the host's onChange hooks: advance if the current action step
    /// is satisfied.
    func advanceIfSatisfied(_ store: TagStore) {
        guard active, current.kind == .action, current.isDone(store) else { return }
        next(store)
    }

    // MARK: Demo data

    private static func bundledDemoURLs() -> [URL] {
        let all = Bundle.main.urls(forResourcesWithExtension: "png", subdirectory: nil) ?? []
        return all.filter { $0.lastPathComponent.hasPrefix("demo-") }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    /// Populate the sandbox with untagged demo images and point the app at it,
    /// remembering the real scope + queue folders to restore later. The swaps
    /// are in-memory only (setScope doesn't persist, and we set `queueFolders`
    /// directly rather than via addQueueFolder) so an interrupted tutorial never
    /// corrupts the user's saved config.
    private func installDemoData(_ store: TagStore) {
        let fm = FileManager.default
        try? fm.removeItem(at: sandboxDir)   // clear any leftover from a prior run
        try? fm.createDirectory(at: sandboxDir, withIntermediateDirectories: true)
        for src in Self.bundledDemoURLs() {
            try? fm.copyItem(at: src, to: sandboxDir.appendingPathComponent(src.lastPathComponent))
        }
        savedScope = store.scopeURL
        savedFolders = store.queueFolders
        store.queueFolders = [sandboxDir]    // transient — not persisted
        store.setScope(sandboxDir)           // isolate the catalog to the sandbox
        store.scanQueue()                    // surface the untagged demo images
    }

    /// Restore the user's real scope + queue folders and delete the sandbox.
    private func teardownDemoData(_ store: TagStore) {
        if let s = savedScope { store.setScope(s) }
        if let f = savedFolders { store.queueFolders = f }
        store.scanQueue()
        try? FileManager.default.removeItem(at: sandboxDir)
        savedScope = nil
        savedFolders = nil
    }
}
