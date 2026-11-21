import SwiftUI

/// The Explore page's bar: the next batch and what the feed is drawn from.
struct ExploreBar: View {
    @EnvironmentObject var store: TagStore
    @EnvironmentObject var boards: BoardStore
    @EnvironmentObject var explore: ExploreModel
    @Environment(\.openWindow) private var openWindow
    @ObservedObject private var keys = ExploreKeyBindings.shared
    @Binding var thumbSize: CGFloat

    var body: some View {
        HStack(spacing: 10) {
            ExploreToggle()
            if store.vaultPartition != nil || store.exploreInVault {
                Picker("Explore", selection: Binding(
                    get: { store.exploreInVault },
                    set: { store.setExploreInVault($0) })) {
                    Text("Library").tag(false)
                    Text("Hidden").tag(true)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                .help("Explore the hidden files, with a taste profile kept in the vault")
            }
            if explore.showingLiked {
                Button { explore.leaveLiked() } label: {
                    Image(systemName: "chevron.left")
                }
                .help("Back to the batch")
                Text("Liked").font(.headline)
            } else {
                Text(summary).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            if explore.loading {
                ProgressView().controlSize(.small)
            }
            if !store.exploreFilterSignature.isEmpty {
                Button("All Tags") { store.clearQueryEntirely() }
                    .help("Draw from the whole library again")
            }
            if explore.lastLess != nil {
                Button("Undo Less") { explore.undoLess() }
            }
            Button("New Board") { makeBoard() }
                .disabled(store.results.isEmpty)
                .help("Put these images on a mood board")
            if !explore.showingLiked {
                SurpriseDial()
                Divider().frame(height: 16)
            }
            Slider(value: $thumbSize, in: 90...280).frame(width: 110)
            if !explore.showingLiked {
                Button("Next Batch") { explore.next() }
                    .help("Add a batch to the feed and jump to it (\(keys.label(.nextBatch))). \(keys.label(.like)) likes the selection, \(keys.label(.less)) asks for less like it, \(keys.label(.nextImage)) steps to the next image.")
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .onAppear { explore.enter() }
        .onChange(of: store.selection) { explore.noteSelection($0) }
        .onChange(of: store.scopeURL) { _ in explore.enter() }
        .onChange(of: store.exploreAvailable) { _ in explore.enter() }
        .onChange(of: store.searchIndexing) { _ in explore.enter() }
        .onChange(of: store.isIndexing) { _ in explore.enter() }
        .onChange(of: store.exploreFilterSignature) { _ in explore.filterChanged() }
    }

    private var summary: String {
        store.exploreFilterSignature.isEmpty ? batchSummary : batchSummary + " · filtered"
    }

    private var batchSummary: String {
        let batches = "\(explore.batches.count) \(explore.batches.count == 1 ? "batch" : "batches")"
        if explore.focusedTaste != nil {
            return "\(batches) · from one taste"
        }
        if explore.isColdStart {
            return "\(batches) · random picks. Like what catches your eye."
        }
        let count = explore.profile.drawnTastes.count
        return "\(batches) · from \(count) \(count == 1 ? "taste" : "tastes"), plus a few surprises"
    }

    private func makeBoard() {
        let name = explore.showingLiked ? "Liked" : "Explore \(Date().formatted(date: .abbreviated, time: .omitted))"
        Task { @MainActor in
            if let id = await boards.createFromResults(store, name: name) {
                openWindow(id: "board", value: id)
            }
        }
    }
}

/// Explore on and off, at the start of the results bar: the same library and
/// query, shown as batches steered by what you like.
struct ExploreToggle: View {
    @EnvironmentObject var store: TagStore

    var body: some View {
        let on = store.mode == .explore
        Button {
            if on {
                store.showTagsTab()
            } else {
                store.setMode(.explore)
            }
        } label: {
            Label("Explore", systemImage: "sparkles")
        }
        .buttonStyle(.bordered)
        .tint(on ? Color.accentColor : nil)
        .background(on ? Color.accentColor.opacity(0.25) : .clear, in: RoundedRectangle(cornerRadius: 6))
        .help(on ? "Stop exploring and list the results (⌘3)" : "Explore: batches of the library, steered by what you like (⌘3)")
    }
}

/// Familiar ↔ surprising: how far batches stray from what you like.
struct SurpriseDial: View {
    @EnvironmentObject var explore: ExploreModel

    var body: some View {
        HStack(spacing: 4) {
            Text("Familiar").font(.caption).foregroundStyle(.secondary)
            Slider(value: $explore.surprise, in: 0...1)
                .frame(width: 90)
            Text("Surprising").font(.caption).foregroundStyle(.secondary)
        }
        .help("How far batches stray from your tastes: more random picks, more variety between picks, tastes shared more evenly. Applies from the next batch.")
        .contextMenu {
            Button("Reset to Default") { explore.surprise = ExploreBatch.Mix.standard.surprise }
        }
    }
}

struct ExploreLikeButton: View {
    @EnvironmentObject var explore: ExploreModel
    @ObservedObject private var keys = ExploreKeyBindings.shared
    let url: URL

    var body: some View {
        let liked = explore.isLiked(url)
        Button { explore.toggleLike([url]) } label: {
            Image(systemName: liked ? "heart.fill" : "heart")
                .foregroundStyle(liked ? Color.pink : Color.white)
                .shadow(color: .black.opacity(0.6), radius: 2)
                .padding(6)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("\(liked ? "Unlike" : "Like") (\(keys.label(.like)))")
    }
}

struct ExploreEmptyState: View {
    @EnvironmentObject var store: TagStore
    @EnvironmentObject var explore: ExploreModel
    @ObservedObject private var keys = ExploreKeyBindings.shared

    var body: some View {
        if explore.loading {
            ProgressView()
        } else {
            switch explore.status {
            case .noPlugin:
                message("sparkles", "Explore needs the CLIP plugin",
                        "Enable Overlap CLIP Search in the Plugins menu")
            case .noIndex:
                message("sparkles", "Search index not built yet",
                        store.searchIndexing ? (store.searchProgress ?? "Indexing images for search…")
                                             : "Plugins ▸ Rebuild Search Index")
            case .noMatches:
                message("tag", "No images match these tags", "Change them in the sidebar")
            case .exhausted:
                message("photo.on.rectangle", "No images to show", "Add images under the library folder")
            case .ok:
                message("heart", explore.showingLiked ? "Nothing liked yet" : "Nothing left in this batch",
                        explore.showingLiked ? "Press \(keys.label(.like)) on an image you like" : "Press \(keys.label(.nextBatch)) for the next one")
            }
        }
    }

    private func message(_ symbol: String, _ title: String, _ detail: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: symbol).font(.system(size: 40)).foregroundStyle(.tertiary)
            Text(title).foregroundStyle(.secondary)
            Text(detail).font(.caption).foregroundStyle(.tertiary)
        }
    }
}

/// Explore's sidebar sections, above the usual ones: what the profile has
/// learned, in pictures.
struct TasteSections: View {
    @EnvironmentObject var explore: ExploreModel

    var body: some View {
        Section {
            Button { explore.showLiked() } label: {
                HStack {
                    Label("Liked", systemImage: "heart")
                    Spacer()
                    Text("\(explore.likedEvents.count)").foregroundStyle(.secondary).monospacedDigit()
                }
            }
            .buttonStyle(.plain)
        }
        Section("Tastes") {
            if explore.profile.tastes.isEmpty {
                Text("Like a few images and your tastes appear here. Everything stays on this Mac.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            ForEach(explore.profile.drawnTastes) { taste in
                TasteRow(taste: taste,
                         share: taste.weight / max(explore.profile.tastes.first?.weight ?? 1, 0.001),
                         focused: explore.focusedTaste == taste.id)
            }
            let waiting = explore.profile.tastes.count - explore.profile.drawnTastes.count
            if waiting > 0 {
                Text("\(waiting) more forming. Like more of one to bring it up.")
                    .font(.caption).foregroundStyle(.tertiary)
            }
        }
    }
}

/// Explore's line under the sidebar: how much it has learned, and a reset.
struct TasteFooter: View {
    @EnvironmentObject var explore: ExploreModel

    var body: some View {
        Divider()
        HStack {
            Text("\(explore.events.count) signals").font(.caption).foregroundStyle(.tertiary)
            Spacer()
            Button("Reset…") { confirmReset() }
                .buttonStyle(.plain).font(.caption).foregroundStyle(.secondary)
                .disabled(explore.events.isEmpty)
        }
        .padding(8)
    }

    private func confirmReset() {
        let alert = NSAlert()
        alert.messageText = "Reset your taste profile?"
        alert.informativeText = "This forgets every like and everything Explore has learned. Your images and tags aren't touched."
        alert.addButton(withTitle: "Reset")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn {
            explore.reset()
        }
    }
}

private struct TasteRow: View {
    @EnvironmentObject var explore: ExploreModel
    let taste: TasteCentroid
    let share: Float
    let focused: Bool
    @State private var image: NSImage?

    var body: some View {
        HStack(spacing: 8) {
            ZStack {
                RoundedRectangle(cornerRadius: 4).fill(Color(nsColor: .quaternaryLabelColor))
                if let image {
                    Image(nsImage: image).resizable().scaledToFill()
                }
            }
            .frame(width: 44, height: 44)
            .clipShape(RoundedRectangle(cornerRadius: 4))
            VStack(alignment: .leading, spacing: 4) {
                Text("\(taste.eventIDs.count) \(taste.eventIDs.count == 1 ? "signal" : "signals")")
                    .font(.caption)
                ProgressView(value: Double(share)).controlSize(.small)
            }
            Spacer(minLength: 0)
            if focused {
                Image(systemName: "scope").foregroundStyle(Color.accentColor)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { explore.focus(on: taste.id) }
        .help("Click to draw batches only from this taste")
        .contextMenu {
            Button("Forget This Taste") { explore.forget(taste) }
        }
        .task(id: taste.exemplar) {
            image = await ThumbnailCache.shared.thumbnail(for: URL(fileURLWithPath: taste.exemplar), size: 88)
        }
    }
}
