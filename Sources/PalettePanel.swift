import SwiftUI
import AppKit

/// Right-hand panel of a board window: the dominant colors of the selected
/// image, and the board's own palette, built from those colors, the screen
/// eyedropper, or pasted hex codes. Everything in it is meant to leave the app:
/// click copies hex, swatches drag out as text, and the palette exports.
struct PalettePanel: View {
    let boardID: UUID
    let selectedPath: String?
    @EnvironmentObject var boards: BoardStore
    private var undoManager: UndoManager { boards.undoManager(for: boardID) }

    @State private var extracted: [ExtractedColor] = []
    @State private var extracting = false
    @State private var copiedKey: String?
    @State private var hexEntry = ""
    @State private var notice: String?

    private var palette: [PaletteSwatch] { boards.board(boardID)?.palette ?? [] }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    imageSection
                    Divider()
                    paletteSection
                }
                .padding(12)
            }
            Divider()
            footer
        }
        .frame(width: 250)
        .background(Color(nsColor: .windowBackgroundColor))
        .task(id: selectedPath) {
            await extractColors()
        }
    }

    // MARK: - Image colors

    private var imageSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Image Colors").font(.headline)
                Spacer()
                if !extracted.isEmpty {
                    Button("Add All") { addAll(extracted.map(\.swatch)) }
                        .buttonStyle(.link)
                        .font(.caption)
                }
            }
            if selectedPath == nil {
                Text("Select one image to see its colors.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if extracting {
                ProgressView().controlSize(.small)
            } else if extracted.isEmpty {
                Text("No colors found in this file.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                proportionStrip
                swatchGrid(extracted.map(\.swatch), keyPrefix: "image") { swatch in
                    add(swatch)
                } menu: { swatch in
                    Button("Add to Palette") { add(swatch) }
                    copyButtons(swatch)
                }
                Text("Click a color to add it to the palette.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    /// How much of the image each color covers.
    private var proportionStrip: some View {
        GeometryReader { geo in
            HStack(spacing: 0) {
                ForEach(extracted) { color in
                    Rectangle()
                        .fill(Color(nsColor: color.swatch.nsColor))
                        .frame(width: geo.size.width * color.share / totalShare)
                        .help("\(color.swatch.hex) · \(Int((color.share * 100).rounded()))%")
                        .onTapGesture { add(color.swatch) }
                }
            }
        }
        .frame(height: 22)
        .clipShape(RoundedRectangle(cornerRadius: 5))
    }

    private var totalShare: Double {
        max(extracted.reduce(0) { $0 + $1.share }, 0.0001)
    }

    // MARK: - Palette

    private var paletteSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Palette").font(.headline)
                Text("\(palette.count)")
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                Spacer()
                Button { sampleScreen() } label: {
                    Image(systemName: "eyedropper")
                }
                .buttonStyle(.borderless)
                .help("Pick a color from anywhere on screen")
            }
            if palette.isEmpty {
                Text("Click image colors above, use the eyedropper, or paste a hex code.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                swatchGrid(palette, keyPrefix: "palette") { swatch in
                    copy(swatch.hex, key: "palette-\(swatch.id)")
                } menu: { swatch in
                    copyButtons(swatch)
                    Divider()
                    Button("Move Earlier") { move(swatch, by: -1) }
                        .disabled(palette.first?.id == swatch.id)
                    Button("Move Later") { move(swatch, by: 1) }
                        .disabled(palette.last?.id == swatch.id)
                    Divider()
                    Button("Remove", role: .destructive) { remove(swatch) }
                }
                Text("Click copies hex · drag out as text · right-click for more")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            TextField("Add hex, e.g. #3A7BD5", text: $hexEntry)
                .textFieldStyle(.roundedBorder)
                .font(.callout.monospaced())
                .onSubmit { addHexEntry() }
            if let notice {
                Text(notice)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var footer: some View {
        HStack {
            Menu {
                Button("Copy as HEX List") { copy(PaletteExport.hexList(palette), key: nil) }
                Button("Copy as CSS Variables") { copy(PaletteExport.css(palette), key: nil) }
                Divider()
                Button("Export Adobe Swatches (.ase)…") {
                    PaletteExport.saveASE(palette, suggestedName: boardName)
                }
                Button("Save to macOS Colors Panel") { saveToColorPanel() }
            } label: {
                Label("Export", systemImage: "square.and.arrow.up")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            Spacer()
            Button(role: .destructive) { clearPalette() } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .help("Clear the palette")
        }
        .disabled(palette.isEmpty)
        .padding(10)
    }

    // MARK: - Swatches

    private func swatchGrid<MenuContent: View>(_ swatches: [PaletteSwatch], keyPrefix: String,
                                         onTap: @escaping (PaletteSwatch) -> Void,
                                         @ViewBuilder menu: @escaping (PaletteSwatch) -> MenuContent) -> some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 52), spacing: 6)], spacing: 6) {
            ForEach(swatches) { swatch in
                swatchTile(swatch, copied: copiedKey == "\(keyPrefix)-\(swatch.id)")
                    .onTapGesture { onTap(swatch) }
                    .onDrag { NSItemProvider(object: swatch.hex as NSString) }
                    .contextMenu { menu(swatch) }
                    .help(swatch.hex)
            }
        }
    }

    private func swatchTile(_ swatch: PaletteSwatch, copied: Bool) -> some View {
        RoundedRectangle(cornerRadius: 6)
            .fill(Color(nsColor: swatch.nsColor))
            .frame(height: 44)
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.primary.opacity(0.12)))
            .overlay(alignment: .bottomLeading) {
                Text(copied ? "Copied" : swatch.hex)
                    .font(.system(size: 9, weight: .medium, design: .monospaced))
                    .foregroundStyle(swatch.prefersDarkText ? Color.black : Color.white)
                    .padding(4)
            }
    }

    @ViewBuilder
    private func copyButtons(_ swatch: PaletteSwatch) -> some View {
        Button("Copy HEX  \(swatch.hex)") { copy(swatch.hex, key: nil) }
        Button("Copy RGB  \(swatch.rgbText)") { copy(swatch.rgbText, key: nil) }
    }

    // MARK: - Actions

    private var boardName: String {
        QueryExporter.folderName(for: boards.board(boardID)?.name ?? "Palette")
    }

    private func extractColors() async {
        extracted = []
        guard let selectedPath else {
            return
        }
        extracting = true
        defer { extracting = false }
        let url = VaultDisk.resolvedURL(forLogicalPath: selectedPath)
        guard let image = await ThumbnailCache.shared.thumbnail(for: url, size: 256),
              let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            return
        }
        let colors = await Task.detached(priority: .userInitiated) {
            PaletteExtractor.dominantColors(in: cgImage)
        }.value
        guard !Task.isCancelled else {
            return
        }
        extracted = colors
    }

    private func add(_ swatch: PaletteSwatch) {
        addAll([swatch])
    }

    private func addAll(_ swatches: [PaletteSwatch]) {
        var seen = palette
        let fresh = swatches.filter { candidate in
            guard !seen.contains(where: { $0.matches(candidate) }) else {
                return false
            }
            seen.append(candidate)
            return true
        }
        guard !fresh.isEmpty else {
            show("Already in the palette.")
            return
        }
        let added = fresh.map { PaletteSwatch(red: $0.red, green: $0.green, blue: $0.blue) }
        boards.mutate(boardID, undo: undoManager, actionName: "Add Color") { board in
            board.palette = (board.palette ?? []) + added
        }
    }

    private func remove(_ swatch: PaletteSwatch) {
        boards.mutate(boardID, undo: undoManager, actionName: "Remove Color") { board in
            board.palette?.removeAll { $0.id == swatch.id }
        }
    }

    private func move(_ swatch: PaletteSwatch, by offset: Int) {
        boards.mutate(boardID, undo: undoManager, actionName: "Move Color") { board in
            guard var colors = board.palette,
                  let i = colors.firstIndex(where: { $0.id == swatch.id }),
                  colors.indices.contains(i + offset) else {
                return
            }
            colors.swapAt(i, i + offset)
            board.palette = colors
        }
    }

    private func clearPalette() {
        boards.mutate(boardID, undo: undoManager, actionName: "Clear Palette") { board in
            board.palette = []
        }
    }

    /// The system eyedropper: samples any pixel on any screen, other apps included.
    private func sampleScreen() {
        NSColorSampler().show { color in
            guard let color, let swatch = PaletteSwatch(color) else {
                return
            }
            DispatchQueue.main.async {
                add(swatch)
            }
        }
    }

    private func addHexEntry() {
        guard let swatch = Self.parseHex(hexEntry) else {
            show("Not a hex color. Try #3A7BD5 or 3A7BD5.")
            return
        }
        add(swatch)
        hexEntry = ""
        NSApp.keyWindow?.makeFirstResponder(nil)   // back to the canvas keys
    }

    /// `#RGB`, `#RRGGBB`, with or without `#`.
    static func parseHex(_ text: String) -> PaletteSwatch? {
        var hex = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if hex.hasPrefix("#") {
            hex.removeFirst()
        }
        if hex.count == 3 {
            hex = hex.map { "\($0)\($0)" }.joined()
        }
        guard hex.count == 6, let value = UInt32(hex, radix: 16) else {
            return nil
        }
        return PaletteSwatch(red: Double((value >> 16) & 0xFF) / 255,
                             green: Double((value >> 8) & 0xFF) / 255,
                             blue: Double(value & 0xFF) / 255)
    }

    private func copy(_ text: String, key: String?) {
        PaletteExport.copy(text)
        if let key {
            copiedKey = key
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                if copiedKey == key {
                    copiedKey = nil
                }
            }
        } else {
            show("Copied.")
        }
    }

    private func saveToColorPanel() {
        if let name = PaletteExport.saveToColorPanel(palette, name: boardName) {
            show("Saved as “\(name)” — find it under Color Palettes in any app's color panel.")
        } else {
            show("Couldn't save to ~/Library/Colors.")
        }
    }

    private func show(_ message: String) {
        notice = message
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) {
            if notice == message {
                notice = nil
            }
        }
    }
}
