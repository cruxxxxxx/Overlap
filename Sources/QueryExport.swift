import AppKit

/// "Query export": materialize every current result into a real Finder folder
/// so upload dialogs, drag-and-drop targets, and other apps can consume a query
/// as if it were a folder. The folder is a snapshot, but it carries an
/// `.overlap-query.json` manifest describing the query that produced it.
///
/// Two ways to materialize a file:
///  - clone: `FileManager.copyItem`, which on APFS (same volume) is a
///    copy-on-write clone — instant, no disk until someone edits the copy,
///    Finder tags carried over. Across volumes it degrades to a real copy.
///    Viewing (Preview, Quick Look, browser uploads) never triggers a write.
///  - hard link: same inode as the original — edits and tags propagate both
///    ways, which some workflows want. Fails across volumes, on iCloud Drive
///    and on non-APFS/HFS+ volumes, so it falls back to a clone/copy per file.
enum ExportMode: String, CaseIterable {
    case clone = "Clone (copy-on-write)"
    case hardLink = "Hard link"

    var summary: String {
        switch self {
        case .clone:    return "Independent copies. Instant on APFS, no extra disk until edited."
        case .hardLink: return "Same file as the original. Edits and tags propagate. Falls back to a copy where links aren't possible."
        }
    }
}

/// Written as `.overlap-query.json` inside the export folder.
struct QueryExportManifest: Codable {
    var overlapQueryVersion = 1
    let created: Date
    let scope: String
    let query: String              // human-readable description
    let groups: [VennGroup]
    let excludes: [String]
    let kinds: [String]
    let exts: [String]
    let searchQuery: String?
    let mode: String
    let count: Int
}

enum QueryExporter {

    struct Outcome {
        var cloned = 0        // copyItem succeeded (clone or plain copy)
        var linked = 0        // linkItem succeeded
        var fellBack = 0      // hard link failed → copied instead
        var failed: [String] = []
        var total: Int { cloned + linked + failed.count }
    }

    /// A Finder-safe folder name from a query description: no path separators
    /// or colons, single spaces, bounded length.
    nonisolated static func folderName(for description: String) -> String {
        var s = description
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
            .replacingOccurrences(of: "\"", with: "")
            .replacingOccurrences(of: "“", with: "")
            .replacingOccurrences(of: "”", with: "")
        s = s.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        s = s.trimmingCharacters(in: CharacterSet(charactersIn: ". "))
        if s.count > 100 { s = String(s.prefix(100)).trimmingCharacters(in: .whitespaces) }
        return s.isEmpty ? "Overlap Export" : s
    }

    /// `dir/name`, suffixed " 2", " 3", … past any existing file.
    nonisolated static func uniqueDestination(for url: URL, in dir: URL, fm: FileManager) -> URL {
        var dest = dir.appendingPathComponent(url.lastPathComponent)
        var n = 2
        let base = url.deletingPathExtension().lastPathComponent
        let ext = url.pathExtension
        while fm.fileExists(atPath: dest.path) {
            dest = dir.appendingPathComponent(ext.isEmpty ? "\(base) \(n)" : "\(base) \(n).\(ext)")
            n += 1
        }
        return dest
    }

    /// Materialize `urls` into `folder` (created if needed). Off-main safe;
    /// `progress(done, total)` after each file.
    nonisolated static func materialize(_ urls: [URL], into folder: URL, mode: ExportMode,
                                        manifest: QueryExportManifest?,
                                        progress: (Int, Int) -> Void = { _, _ in }) -> Outcome {
        let fm = FileManager.default
        var outcome = Outcome()
        do {
            try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        } catch {
            outcome.failed = urls.map(\.lastPathComponent)
            return outcome
        }
        for (i, url) in urls.enumerated() {
            let dest = uniqueDestination(for: url, in: folder, fm: fm)
            switch mode {
            case .clone:
                do { try fm.copyItem(at: url, to: dest); outcome.cloned += 1 }
                catch { outcome.failed.append(url.lastPathComponent) }
            case .hardLink:
                if (try? fm.linkItem(at: url, to: dest)) != nil {
                    outcome.linked += 1
                } else if (try? fm.copyItem(at: url, to: dest)) != nil {
                    outcome.cloned += 1; outcome.fellBack += 1
                } else {
                    outcome.failed.append(url.lastPathComponent)
                }
            }
            progress(i + 1, urls.count)
        }
        if let manifest {
            let enc = JSONEncoder()
            enc.outputFormatting = [.prettyPrinted, .sortedKeys]
            enc.dateEncodingStrategy = .iso8601
            if let data = try? enc.encode(manifest) {
                try? data.write(to: folder.appendingPathComponent(".overlap-query.json"), options: .atomic)
            }
        }
        return outcome
    }

    /// Save panel asking where the folder goes and how files are materialized.
    /// Returns nil on cancel. Main thread only.
    @MainActor
    static func askDestination(suggestedName: String, count: Int) -> (folder: URL, mode: ExportMode)? {
        let panel = NSSavePanel()
        panel.title = "Export Results as Folder"
        panel.message = "Creates a folder holding all \(count) current results."
        panel.prompt = "Export"
        panel.nameFieldLabel = "Folder name:"
        panel.nameFieldStringValue = suggestedName
        panel.canCreateDirectories = true
        panel.showsTagField = false

        // Accessory: mode picker + one-line explanation.
        let popup = NSPopUpButton(frame: .zero, pullsDown: false)
        popup.addItems(withTitles: ExportMode.allCases.map(\.rawValue))
        let explain = NSTextField(wrappingLabelWithString: ExportMode.clone.summary)
        explain.textColor = .secondaryLabelColor
        explain.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        explain.preferredMaxLayoutWidth = 360
        let handler = PopupHandler { idx in
            explain.stringValue = ExportMode.allCases[idx].summary
        }
        popup.target = handler
        popup.action = #selector(PopupHandler.changed(_:))
        let label = NSTextField(labelWithString: "Files:")
        let row = NSStackView(views: [label, popup])
        row.orientation = .horizontal
        let stack = NSStackView(views: [row, explain])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        stack.edgeInsets = NSEdgeInsets(top: 8, left: 20, bottom: 8, right: 20)
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.widthAnchor.constraint(equalToConstant: 420).isActive = true
        panel.accessoryView = stack
        let response = withExtendedLifetime(handler) { panel.runModal() }
        guard response == .OK, let url = panel.url else { return nil }
        let mode = ExportMode.allCases[max(0, popup.indexOfSelectedItem)]
        return (url, mode)
    }

    /// After the work: reveal the folder; explain anything that didn't go to plan.
    @MainActor
    static func finish(_ outcome: Outcome, folder: URL, mode: ExportMode) {
        NSWorkspace.shared.activateFileViewerSelecting([folder])
        var notes: [String] = []
        if mode == .hardLink && outcome.fellBack > 0 {
            notes.append("\(outcome.fellBack) file\(outcome.fellBack == 1 ? "" : "s") couldn't be hard-linked (different volume, iCloud Drive, or a non-APFS disk) and were copied instead.")
        }
        if !outcome.failed.isEmpty {
            let shown = outcome.failed.prefix(5).joined(separator: "\n")
            notes.append("\(outcome.failed.count) file\(outcome.failed.count == 1 ? "" : "s") failed:\n\(shown)\(outcome.failed.count > 5 ? "\n…" : "")")
        }
        guard !notes.isEmpty else { return }
        let alert = NSAlert()
        alert.messageText = "Exported \(outcome.cloned + outcome.linked) of \(outcome.total)"
        alert.informativeText = notes.joined(separator: "\n\n")
        alert.alertStyle = outcome.failed.isEmpty ? .informational : .warning
        alert.runModal()
    }

    /// Target/action shim for the accessory popup (NSSavePanel is AppKit).
    private final class PopupHandler: NSObject {
        let onChange: (Int) -> Void
        init(onChange: @escaping (Int) -> Void) { self.onChange = onChange }
        @objc func changed(_ sender: NSPopUpButton) { onChange(sender.indexOfSelectedItem) }
    }
}
