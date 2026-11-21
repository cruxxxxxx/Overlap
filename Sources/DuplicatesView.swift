import SwiftUI
import Combine

/// The Duplicates window's state: one scan at a time, run on demand.
@MainActor
final class DuplicatesModel: ObservableObject {
    enum Scope: String, CaseIterable, Identifiable {
        case results = "Current Results"
        case library = "Whole Library"
        var id: String { rawValue }
    }

    @Published var scope: Scope = .results
    @Published var includeNear = true
    /// 0 = strict (near-identical only), 1 = loose (same shot, small edits).
    @Published var looseness = 0.4
    @Published private(set) var groups: [DuplicateGroup] = []
    @Published private(set) var scanning = false
    @Published private(set) var progress: String?
    @Published private(set) var scanned = false
    /// The file chosen to keep, per group (defaults to the suggested one).
    @Published var keepers: [String: String] = [:]
    private var notDuplicates: Set<String> = []
    private var token = UUID()
    private var revealSubscription: AnyCancellable?

    /// Bind to the store's lock state (idempotent; the window calls it on appear).
    func attach(to store: TagStore) {
        guard revealSubscription == nil else {
            return
        }
        revealSubscription = store.$revealed.removeDuplicates().sink { [weak self, weak store] revealed in
            guard let self else {
                return
            }
            if revealed {
                DispatchQueue.main.async {
                    self.notDuplicates = NotDuplicates.load(includingHidden: store?.revealed == true)
                }
            } else {
                self.dropHidden()
            }
        }
    }

    /// On lock: a scan in flight is void, and hidden files leave the window.
    private func dropHidden() {
        let hadHidden = groups.contains { $0.files.contains { VaultDisk.contains($0.id) } }
        if scanning {
            token = UUID()
            scanning = false
            progress = nil
        }
        groups.removeAll { group in group.files.contains { VaultDisk.contains($0.id) } }
        keepers = keepers.filter { group, _ in groups.contains { $0.id == group } }
        notDuplicates = notDuplicates.filter { !$0.components(separatedBy: "\n").contains(where: VaultDisk.contains) }
        if hadHidden && groups.isEmpty {
            scanned = false
        }
    }

    /// Cosine cutoff for the plugin: 0.98 strict … 0.90 loose.
    var threshold: Double { 0.98 - looseness * 0.08 }

    func scan(store: TagStore) {
        // Fresh: files may have moved into or out of the vault since.
        notDuplicates = NotDuplicates.load(includingHidden: store.revealed)
        let urls = store.duplicateCandidates(wholeLibrary: scope == .library)
        let near = includeNear && store.duplicatePluginsAvailable
        let libraryPaths = scope == .library ? nil : urls.map(\.path).filter { !VaultDisk.contains($0) }
        // Hidden images match only each other: their index is in the vault.
        let hiddenPaths = urls.map(\.path).filter(VaultDisk.contains)
        let vault = hiddenPaths.isEmpty ? nil : store.vaultPartition
        let vaultScope: [String]? = scope == .library ? nil : hiddenPaths
        let epoch = store.lockEpoch
        let threshold = threshold, excluded = notDuplicates
        let disabled = store.disabledPluginIDs, settings = store.pluginSettings
        let token = UUID()
        self.token = token
        scanning = true
        progress = "Looking for copies…"
        Task.detached(priority: .userInitiated) { [weak self] in
            let report: @Sendable (String) -> Void = { line in
                Task { @MainActor in
                    if self?.token == token {
                        self?.progress = line
                    }
                }
            }
            var pairs = DuplicateFinder.exactPairs(urls, onProgress: report)
            if near {
                report("Comparing images…")
                if libraryPaths?.isEmpty != true {
                    pairs += DuplicateFinder.nearPairs(threshold: threshold, paths: libraryPaths,
                                                       disabledIDs: disabled, pluginSettings: settings,
                                                       onProgress: report)
                }
                if let vault {
                    pairs += DuplicateFinder.nearPairs(threshold: threshold, paths: vaultScope,
                                                       disabledIDs: disabled, pluginSettings: settings,
                                                       partition: vault, onProgress: report)
                }
            }
            let groups = DuplicateFinder.groups(from: pairs, excluding: excluded)
            await MainActor.run {
                guard let self, self.token == token else {
                    return
                }
                // Locked meanwhile: nothing hidden may land in the window.
                guard store.lockEpoch == epoch, store.revealed || !groups.contains(where: { group in
                    group.files.contains { VaultDisk.contains($0.id) }
                }) else {
                    self.scanning = false
                    self.progress = nil
                    return
                }
                self.groups = groups
                self.keepers = [:]
                self.scanning = false
                self.progress = nil
                self.scanned = true
            }
        }
    }

    func keeper(of group: DuplicateGroup) -> DuplicateFile {
        group.files.first { $0.id == keepers[group.id] } ?? group.files[0]
    }

    func keep(_ group: DuplicateGroup, store: TagStore, trashOthers: Bool) {
        let keeper = keeper(of: group)
        let others = group.files.filter { $0.id != keeper.id }.map(\.url)
        store.resolveDuplicates(keeper: keeper.url, others: others, trashOthers: trashOthers)
        remove(group)
    }

    func keepSuggestedInAll(store: TagStore) {
        for group in groups {
            keep(group, store: store, trashOthers: true)
        }
    }

    func markNotDuplicates(_ group: DuplicateGroup, store: TagStore) {
        NotDuplicates.add(group.files.map(\.id), to: &notDuplicates, includingHidden: store.revealed)
        remove(group)
    }

    private func remove(_ group: DuplicateGroup) {
        groups.removeAll { $0.id == group.id }
        keepers.removeValue(forKey: group.id)
    }
}

struct DuplicatesView: View {
    @EnvironmentObject var store: TagStore
    @StateObject private var model = DuplicatesModel()
    @State private var confirmingAll = false

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            content
        }
        .frame(minWidth: 640, minHeight: 420)
        .onAppear { model.attach(to: store) }
    }

    /// Files "Keep Suggested in All" would remove, and how many are hidden.
    private var removalCounts: (all: Int, hidden: Int) {
        let others = model.groups.flatMap { $0.files.dropFirst() }
        return (others.count, others.filter { VaultDisk.contains($0.id) }.count)
    }

    private var toolbar: some View {
        HStack(spacing: 12) {
            Picker("", selection: $model.scope) {
                ForEach(DuplicatesModel.Scope.allCases) { scope in
                    Text(scope.rawValue).tag(scope)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            if store.duplicatePluginsAvailable {
                Toggle("Similar images", isOn: $model.includeNear)
                    .help("Also find resized, recompressed or lightly edited copies")
                if model.includeNear {
                    HStack(spacing: 4) {
                        Text("Strict").font(.caption).foregroundStyle(.secondary)
                        Slider(value: $model.looseness, in: 0...1).frame(width: 110)
                        Text("Loose").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            Spacer()
            if model.scanning {
                ProgressView().controlSize(.small)
                Text(model.progress ?? "").font(.caption).foregroundStyle(.secondary).lineLimit(1)
            } else if model.groups.count > 1 {
                Button("Keep Suggested in All…") { confirmingAll = true }
            }
            Button(model.scanned ? "Scan Again" : "Find Duplicates") { model.scan(store: store) }
                .keyboardShortcut(.defaultAction)
                .disabled(model.scanning)
        }
        .padding(10)
        .confirmationDialog("Keep the suggested file in all \(model.groups.count) groups?",
                            isPresented: $confirmingAll) {
            Button("Keep Suggested and Move Others to Trash", role: .destructive) {
                model.keepSuggestedInAll(store: store)
            }
        } message: {
            let counts = removalCounts
            Text("\(counts.all) files move to the Trash"
                 + (counts.hidden > 0 ? " (\(counts.hidden) hidden, to the vault's own trash, emptied when you lock)" : "")
                 + ". Their tags are added to the file that's kept, except hidden tags onto a file outside the vault."
                 + " Edit ▸ Undo in the main window reverses each group.")
        }
    }

    @ViewBuilder
    private var content: some View {
        if model.groups.isEmpty {
            VStack(spacing: 8) {
                Image(systemName: "square.on.square").font(.system(size: 40)).foregroundStyle(.tertiary)
                Text(model.scanning ? "Scanning…" : (model.scanned ? "No duplicate files found" : "Find duplicate files"))
                    .foregroundStyle(.secondary)
                Text("Separate files with the same contents, or images that look the same (resized, recompressed, re-saved)")
                    .font(.caption).foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
                Text(model.scope == .results ? "\(store.results.count) files in the current results"
                                             : "Every tagged and queued file")
                    .font(.caption).foregroundStyle(.tertiary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(model.groups) { group in
                        DuplicateGroupRow(group: group, model: model)
                        Divider()
                    }
                }
            }
        }
    }
}

private struct DuplicateGroupRow: View {
    @EnvironmentObject var store: TagStore
    let group: DuplicateGroup
    @ObservedObject var model: DuplicatesModel

    private var folderSummary: String {
        let folders = Set(group.files.map { $0.url.deletingLastPathComponent().path })
        return folders.count == 1 ? "same folder" : "in \(folders.count) folders"
    }

    var body: some View {
        let keeper = model.keeper(of: group)
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label(group.identical ? "\(group.files.count) identical files"
                                      : "\(group.files.count) files that look \(Int((group.score * 100).rounded()))% alike",
                      systemImage: group.identical ? "doc.on.doc" : "photo.on.rectangle")
                    .font(.headline)
                Text(folderSummary).foregroundStyle(.secondary)
                Spacer()
                Button("Not Duplicates") { model.markNotDuplicates(group, store: store) }
                    .help("Don't show these together again")
                Button("Merge Tags Only") { model.keep(group, store: store, trashOthers: false) }
                    .help("Add every file's tags to the one marked Keep, and keep all files")
                Button("Keep Selected") { model.keep(group, store: store, trashOthers: true) }
                    .help(group.files.contains { VaultDisk.contains($0.id) }
                          ? "Move the others to the Trash after adding their tags to this one (hidden tags only if it's hidden too). Hidden files go to the vault's trash, emptied when you lock."
                          : "Move the others to the Trash after adding their tags to this one")
            }
            ScrollView(.horizontal) {
                HStack(alignment: .top, spacing: 12) {
                    ForEach(group.files) { file in
                        DuplicateCard(file: file, isKeeper: file.id == keeper.id)
                            .onTapGesture { model.keepers[group.id] = file.id }
                    }
                }
            }
        }
        .padding(12)
    }
}

private struct DuplicateCard: View {
    let file: DuplicateFile
    let isKeeper: Bool
    @State private var thumbnail: NSImage?

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            ZStack(alignment: .topLeading) {
                Group {
                    if let thumbnail {
                        Image(nsImage: thumbnail).resizable().scaledToFit()
                    } else {
                        Color.secondary.opacity(0.15)
                    }
                }
                .frame(width: 170, height: 130)
                if isKeeper {
                    Text("Keep")
                        .font(.caption.bold())
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(Capsule().fill(Color.accentColor))
                        .foregroundStyle(.white)
                        .padding(4)
                }
            }
            .overlay(RoundedRectangle(cornerRadius: 4)
                .stroke(isKeeper ? Color.accentColor : .clear, lineWidth: 2))
            Text(file.url.lastPathComponent).font(.caption).lineLimit(1).truncationMode(.middle)
            Text(details).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            HStack(spacing: 3) {
                if isHidden {
                    Image(systemName: "lock.fill").help("Hidden file, in the vault")
                }
                Text(folder.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                    .lineLimit(1).truncationMode(.head)
            }
            .font(.caption2).foregroundStyle(.tertiary)
            let tags = TagIO.tags(of: file.url)
            if !tags.isEmpty {
                Text(tags.joined(separator: ", ")).font(.caption2).foregroundStyle(.secondary).lineLimit(2)
            }
        }
        .frame(width: 170)
        .contentShape(Rectangle())
        .contextMenu {
            Button("Reveal in Finder") {
                if HiddenExposure.confirm([file.url], question: "Reveal %@ in Finder?", button: "Reveal") {
                    NSWorkspace.shared.activateFileViewerSelecting([file.url])
                }
            }
            Button("Quick Look") { QuickLookOpener.open([file.url]) }
        }
        .help("Click to keep this one")
        .task(id: file.id) {
            thumbnail = await ThumbnailCache.shared.thumbnail(for: file.url, size: 340)
        }
    }

    private var isHidden: Bool { VaultDisk.contains(file.id) }

    /// Where the file lives, or for a hidden one where it lived before hiding.
    private var folder: String {
        (VaultDisk.originalURL(forVault: file.url) ?? file.url).deletingLastPathComponent().path
    }

    private var details: String {
        var parts: [String] = []
        if let w = file.width, let h = file.height {
            parts.append("\(w)×\(h)")
        }
        parts.append(ByteCountFormatter.string(fromByteCount: file.size, countStyle: .file))
        if let created = file.created {
            parts.append(created.formatted(date: .abbreviated, time: .omitted))
        }
        return parts.joined(separator: " · ")
    }
}
