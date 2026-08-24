import SwiftUI

/// Wraps the app's root content, layering the tutorial overlay on top and
/// hosting all tutorial behavior (first-boot start, Help-menu trigger, and the
/// state-change hooks that auto-advance action steps). Keeps OverlapApp/
/// ContentView edits to a single line.
struct TutorialHost<Content: View>: View {
    @EnvironmentObject var store: TagStore
    @StateObject private var tutorial = TutorialModel()
    let content: Content

    init(@ViewBuilder content: () -> Content) { self.content = content() }

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            content
                .overlayPreferenceValue(TutorialAnchorKey.self) { anchors in
                    GeometryReader { proxy in
                        if tutorial.active {
                            TutorialOverlay(tutorial: tutorial, size: proxy.size,
                                            targetRect: resolvedRect(tutorial.current.target,
                                                                     anchors, proxy))
                                .environmentObject(store)
                        }
                    }
                }

            if !tutorial.active { helpButton }
        }
        .animation(.easeInOut(duration: 0.2), value: tutorial.active)
        .onAppear {
            if !tutorial.hasSeenTutorial { tutorial.start(store) }
        }
        .onReceive(NotificationCenter.default.publisher(for: .overlapStartTutorial)) { _ in
            tutorial.start(store)
        }
        // Auto-advance hooks: any state an action step waits on.
        .onChange(of: store.mode) { _ in tutorial.advanceIfSatisfied(store) }
        .onChange(of: store.selection) { _ in tutorial.advanceIfSatisfied(store) }
        .onChange(of: store.taggedQueueCount) { _ in tutorial.advanceIfSatisfied(store) }
        .onChange(of: store.queueItems) { _ in tutorial.advanceIfSatisfied(store) }
        .onChange(of: store.querySets) { _ in tutorial.advanceIfSatisfied(store) }
    }

    /// Resolve a target to a rect. Detail targets use their own frame anchors.
    /// Sidebar targets can't (NavigationSplitView doesn't bubble the sidebar's
    /// preferences to this overlay), so they fall back to the whole sidebar
    /// column — its exact width taken from the grid anchor's left edge — which
    /// keeps the control clickable instead of full-dimming the window.
    private func resolvedRect(_ target: TutorialTarget,
                              _ anchors: [TutorialTarget: Anchor<CGRect>],
                              _ proxy: GeometryProxy) -> CGRect? {
        if target == .center { return nil }
        if let a = anchors[target] { return proxy[a] }
        switch target {
        case .modePicker, .watchedFolders, .applyButton, .sidebar:
            let gridMinX = anchors[.grid].map { proxy[$0].minX }
            let width = gridMinX ?? max(240, proxy.size.width * 0.22)
            return CGRect(x: 0, y: 0, width: width, height: proxy.size.height)
        default:
            return nil
        }
    }

    private var helpButton: some View {
        Button {
            tutorial.start(store)
        } label: {
            Image(systemName: "questionmark.circle.fill")
                .font(.system(size: 26))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.secondary)
                .padding(14)
        }
        .buttonStyle(.plain)
        .help("Show the Overlap tutorial")
    }
}
