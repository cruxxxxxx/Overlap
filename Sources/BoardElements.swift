import SwiftUI
import AppKit

/// Something on a board that isn't a file: a sticky note, a free text label,
/// or a titled box that groups whatever sits inside it.
struct BoardElement: Identifiable, Codable, Equatable {
    enum Kind: String, Codable {
        case note, label, box
    }

    var id = UUID()
    var kind: Kind
    var frame: CGRect
    var z: Int
    var text: String
    /// Note/box: fill tint. Label: text color. nil = the kind's default.
    var colorHex: String?
    var fontSize: Double?

    var defaultFontSize: Double {
        switch kind {
        case .note:
            return 14
        case .label:
            return 32
        case .box:
            return 15
        }
    }

    var effectiveFontSize: Double { fontSize ?? defaultFontSize }

    /// Text sizes offered in the context menu, per kind.
    var fontSizeChoices: [(name: String, size: Double)] {
        switch kind {
        case .note:
            return [("Small", 12), ("Medium", 14), ("Large", 18), ("Huge", 26)]
        case .label:
            return [("Small", 20), ("Medium", 32), ("Large", 48), ("Huge", 72)]
        case .box:
            return [("Small", 12), ("Medium", 15), ("Large", 20), ("Huge", 28)]
        }
    }

    static func make(_ kind: Kind, at center: CGPoint, z: Int) -> BoardElement {
        let size: CGSize
        let text: String
        switch kind {
        case .note:
            size = CGSize(width: 220, height: 140)
            text = ""
        case .label:
            size = CGSize(width: 320, height: 56)
            text = ""
        case .box:
            size = CGSize(width: 520, height: 380)
            text = "Section"
        }
        let origin = CGPoint(x: max(0, center.x - size.width / 2), y: max(0, center.y - size.height / 2))
        return BoardElement(kind: kind, frame: CGRect(origin: origin, size: size), z: z, text: text)
    }

    /// Height of a box's title bar in canvas units (the part that drags it).
    var boxHeaderHeight: CGFloat { CGFloat(effectiveFontSize) + 16 }
}

/// Address of anything on a board, file tile or element, for selection-wide
/// operations such as arranging.
enum BoardObjectKey: Hashable {
    case item(String)
    case element(UUID)
}

extension MoodBoard {
    var elementList: [BoardElement] { elements ?? [] }

    var maxElementZ: Int { elementList.map(\.z).max() ?? 0 }

    func frame(of key: BoardObjectKey) -> CGRect? {
        switch key {
        case .item(let path):
            return items.first { $0.path == path }?.frame
        case .element(let id):
            return elementList.first { $0.id == id }?.frame
        }
    }

    mutating func setFrame(_ frame: CGRect, for key: BoardObjectKey) {
        switch key {
        case .item(let path):
            if let i = items.firstIndex(where: { $0.path == path }) {
                items[i].frame = frame
            }
        case .element(let id):
            if let i = elements?.firstIndex(where: { $0.id == id }) {
                elements?[i].frame = frame
            }
        }
    }

    mutating func updateElement(_ id: UUID, _ change: (inout BoardElement) -> Void) {
        if let i = elements?.firstIndex(where: { $0.id == id }) {
            change(&elements![i])
        }
    }

    /// What a box carries when it's dragged: tiles whose center is inside it
    /// and notes, labels and smaller boxes wholly inside it.
    func contents(ofBox box: BoardElement) -> (paths: Set<String>, elements: Set<UUID>) {
        let paths = items
            .filter { box.frame.contains(CGPoint(x: $0.frame.midX, y: $0.frame.midY)) }
            .map(\.path)
        let inner = elementList
            .filter { $0.id != box.id && box.frame.contains($0.frame) }
            .map(\.id)
        return (Set(paths), Set(inner))
    }
}

/// Preset tints for notes, labels and boxes.
enum BoardColors {
    static let presets: [(name: String, hex: String)] = [
        ("Yellow", "#FFE27A"), ("Orange", "#FFB86B"), ("Pink", "#FF9EC4"),
        ("Purple", "#C3A6FF"), ("Blue", "#8EC5FF"), ("Green", "#9BE3A8"),
        ("Gray", "#C7C7CC"), ("Black", "#1C1C1E"), ("White", "#FFFFFF"),
    ]

    static let defaultNote = "#FFE27A"
    static let defaultBox = "#8EC5FF"

    static func color(_ hex: String?) -> Color? {
        guard let hex, let swatch = PalettePanel.parseHex(hex) else {
            return nil
        }
        return Color(nsColor: swatch.nsColor)
    }

    /// Readable text color on top of `hex`.
    static func textColor(on hex: String) -> Color {
        guard let swatch = PalettePanel.parseHex(hex) else {
            return .primary
        }
        return swatch.prefersDarkText ? .black : .white
    }
}

/// One element drawn at its on-screen size. Editing happens in place: the
/// canvas sets `editing`, and the view commits its draft when focus leaves.
struct BoardElementView: View {
    let element: BoardElement
    let size: CGSize               // on-screen points
    let zoom: CGFloat
    let selected: Bool
    let editing: Bool
    let onCommit: (String) -> Void
    let onResize: (_ translation: CGSize, _ ended: Bool) -> Void

    @State private var draft = ""
    @FocusState private var focused: Bool

    private var fontSize: CGFloat { CGFloat(element.effectiveFontSize) * zoom }

    var body: some View {
        content
            .frame(width: size.width, height: size.height, alignment: .topLeading)
            .overlay(alignment: .bottomTrailing) {
                if selected && !editing {
                    resizeHandle
                }
            }
            .onAppear {
                if editing {
                    draft = element.text
                    DispatchQueue.main.async {
                        focused = true
                    }
                }
            }
            .onChange(of: editing) { isEditing in
                if isEditing {
                    draft = element.text
                    DispatchQueue.main.async {
                        focused = true
                    }
                }
            }
            .onChange(of: focused) { isFocused in
                if !isFocused && editing {
                    onCommit(draft)
                }
            }
    }

    @ViewBuilder
    private var content: some View {
        switch element.kind {
        case .note:
            note
        case .label:
            label
        case .box:
            box
        }
    }

    private var note: some View {
        let fillHex = element.colorHex ?? BoardColors.defaultNote
        return ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 4 * zoom)
                .fill(BoardColors.color(fillHex) ?? .yellow)
                .shadow(color: .black.opacity(0.2), radius: 3, y: 1)
            if editing {
                TextEditor(text: $draft)
                    .focused($focused)
                    .font(.system(size: fontSize))
                    .scrollContentBackground(.hidden)
                    .foregroundStyle(BoardColors.textColor(on: fillHex))
                    .padding(8 * zoom)
            } else {
                Text(element.text.isEmpty ? "Double-click to write" : element.text)
                    .font(.system(size: fontSize))
                    .foregroundStyle(BoardColors.textColor(on: fillHex)
                        .opacity(element.text.isEmpty ? 0.45 : 1))
                    .padding(12 * zoom)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
        }
        .overlay(selectionOutline(cornerRadius: 4 * zoom))
        .contentShape(Rectangle())
    }

    private var label: some View {
        let textColor = BoardColors.color(element.colorHex) ?? .primary
        return Group {
            if editing {
                TextField("Label", text: $draft, axis: .vertical)
                    .focused($focused)
                    .textFieldStyle(.plain)
                    .font(.system(size: fontSize, weight: .bold))
                    .foregroundStyle(textColor)
                    .onSubmit { focused = false }
            } else {
                Text(element.text.isEmpty ? "Label" : element.text)
                    .font(.system(size: fontSize, weight: .bold))
                    .foregroundStyle(textColor.opacity(element.text.isEmpty ? 0.4 : 1))
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
        }
        .padding(4 * zoom)
        .overlay(selectionOutline(cornerRadius: 3))
        .contentShape(Rectangle())
    }

    /// A box only answers clicks on its title bar, so the inside stays free
    /// for selecting and dragging the tiles it holds.
    private var box: some View {
        let tintHex = element.colorHex ?? BoardColors.defaultBox
        let tint = BoardColors.color(tintHex) ?? .blue
        let header = element.boxHeaderHeight * zoom
        return ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 10 * zoom)
                .fill(tint.opacity(0.14))
                .overlay(RoundedRectangle(cornerRadius: 10 * zoom)
                    .strokeBorder(selected ? Color.accentColor : tint.opacity(0.6),
                                  lineWidth: selected ? 2 : 1))
                .allowsHitTesting(false)
            Group {
                if editing {
                    TextField("Title", text: $draft)
                        .focused($focused)
                        .textFieldStyle(.plain)
                        .onSubmit { focused = false }
                } else {
                    Text(element.text.isEmpty ? "Untitled" : element.text)
                        .lineLimit(1)
                }
            }
            .font(.system(size: fontSize, weight: .semibold))
            .foregroundStyle(tint.opacity(0.95))
            .padding(.horizontal, 10 * zoom)
            .frame(width: size.width, height: header, alignment: .leading)
            .background(tint.opacity(0.22))
            .clipShape(UnevenRoundedCorners(radius: 10 * zoom))
            .contentShape(Rectangle())
        }
    }

    private func selectionOutline(cornerRadius: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: cornerRadius)
            .strokeBorder(selected ? Color.accentColor : .clear, lineWidth: 2)
    }

    private var resizeHandle: some View {
        Circle()
            .fill(Color.accentColor)
            .overlay(Circle().strokeBorder(.white, lineWidth: 1.5))
            .frame(width: 12, height: 12)
            .offset(x: 5, y: 5)
            .gesture(
                DragGesture(minimumDistance: 1, coordinateSpace: .named(BoardCanvas.space))
                    .onChanged { onResize($0.translation, false) }
                    .onEnded { onResize($0.translation, true) }
            )
            .help("Drag to resize")
    }
}

/// Rounded top corners only (macOS 13 has no UnevenRoundedRectangle).
struct UnevenRoundedCorners: Shape {
    let radius: CGFloat

    func path(in rect: CGRect) -> Path {
        let r = min(radius, rect.height, rect.width / 2)
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.minY + r))
        path.addArc(center: CGPoint(x: rect.minX + r, y: rect.minY + r), radius: r,
                    startAngle: .degrees(180), endAngle: .degrees(270), clockwise: false)
        path.addLine(to: CGPoint(x: rect.maxX - r, y: rect.minY))
        path.addArc(center: CGPoint(x: rect.maxX - r, y: rect.minY + r), radius: r,
                    startAngle: .degrees(270), endAngle: .degrees(0), clockwise: false)
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        path.closeSubpath()
        return path
    }
}

/// Selection-wide layout commands. Pure frame math: tiles keep their aspect
/// ratio when resized, elements don't need to.
enum BoardArrange {
    enum Action {
        case alignLeft, alignCenterX, alignRight, alignTop, alignCenterY, alignBottom
        case distributeHorizontally, distributeVertically
        case matchWidth, matchHeight
        case grid
    }

    static let gridStep: CGFloat = 20

    static func apply(_ action: Action, to frames: [BoardObjectKey: CGRect]) -> [BoardObjectKey: CGRect] {
        guard frames.count >= 2, let bounds = frames.values.reduce(nil as CGRect?, { ($0 ?? $1).union($1) }) else {
            return frames
        }
        var out = frames
        switch action {
        case .alignLeft:
            mapOrigins(&out) { f in CGPoint(x: bounds.minX, y: f.minY) }
        case .alignCenterX:
            mapOrigins(&out) { f in CGPoint(x: bounds.midX - f.width / 2, y: f.minY) }
        case .alignRight:
            mapOrigins(&out) { f in CGPoint(x: bounds.maxX - f.width, y: f.minY) }
        case .alignTop:
            mapOrigins(&out) { f in CGPoint(x: f.minX, y: bounds.minY) }
        case .alignCenterY:
            mapOrigins(&out) { f in CGPoint(x: f.minX, y: bounds.midY - f.height / 2) }
        case .alignBottom:
            mapOrigins(&out) { f in CGPoint(x: f.minX, y: bounds.maxY - f.height) }
        case .distributeHorizontally:
            distribute(&out, horizontal: true, bounds: bounds)
        case .distributeVertically:
            distribute(&out, horizontal: false, bounds: bounds)
        case .matchWidth:
            let width = frames.values.map(\.width).max() ?? 0
            for (key, f) in frames {
                out[key] = resized(f, key: key, width: width, height: nil)
            }
        case .matchHeight:
            let height = frames.values.map(\.height).max() ?? 0
            for (key, f) in frames {
                out[key] = resized(f, key: key, width: nil, height: height)
            }
        case .grid:
            out = grid(frames, origin: bounds.origin)
        }
        return out
    }

    private static func mapOrigins(_ frames: inout [BoardObjectKey: CGRect], _ origin: (CGRect) -> CGPoint) {
        for (key, f) in frames {
            frames[key] = CGRect(origin: origin(f), size: f.size)
        }
    }

    /// Equal gaps between neighbours, first and last staying put.
    private static func distribute(_ frames: inout [BoardObjectKey: CGRect], horizontal: Bool, bounds: CGRect) {
        let ordered = frames.sorted { horizontal ? $0.value.minX < $1.value.minX : $0.value.minY < $1.value.minY }
        let total = ordered.reduce(0) { $0 + (horizontal ? $1.value.width : $1.value.height) }
        let span = horizontal ? bounds.width : bounds.height
        let gap = (span - total) / CGFloat(max(ordered.count - 1, 1))
        var cursor = horizontal ? bounds.minX : bounds.minY
        for (key, f) in ordered {
            if horizontal {
                frames[key] = CGRect(x: cursor, y: f.minY, width: f.width, height: f.height)
                cursor += f.width + gap
            } else {
                frames[key] = CGRect(x: f.minX, y: cursor, width: f.width, height: f.height)
                cursor += f.height + gap
            }
        }
    }

    private static func resized(_ f: CGRect, key: BoardObjectKey, width: CGFloat?, height: CGFloat?) -> CGRect {
        let aspect = f.width / max(f.height, 1)
        var size = f.size
        if let width {
            size.width = width
            if case .item = key {
                size.height = width / aspect
            }
        }
        if let height {
            size.height = height
            if case .item = key {
                size.width = height * aspect
            }
        }
        return CGRect(origin: f.origin, size: size)
    }

    /// Reading order into rows; each column as wide as its widest cell.
    private static func grid(_ frames: [BoardObjectKey: CGRect], origin: CGPoint) -> [BoardObjectKey: CGRect] {
        let ordered = frames.sorted {
            abs($0.value.minY - $1.value.minY) > 1 ? $0.value.minY < $1.value.minY : $0.value.minX < $1.value.minX
        }
        let columns = max(1, Int(Double(ordered.count).squareRoot().rounded(.up)))
        let gap = BoardLayout.gap
        var columnWidths = Array(repeating: CGFloat(0), count: columns)
        for (i, entry) in ordered.enumerated() {
            columnWidths[i % columns] = max(columnWidths[i % columns], entry.value.width)
        }
        var out: [BoardObjectKey: CGRect] = [:]
        var y = origin.y
        for rowStart in stride(from: 0, to: ordered.count, by: columns) {
            let row = ordered[rowStart..<min(rowStart + columns, ordered.count)]
            var x = origin.x
            for (offset, entry) in row.enumerated() {
                out[entry.key] = CGRect(origin: CGPoint(x: x, y: y), size: entry.value.size)
                x += columnWidths[offset] + gap
            }
            y += (row.map(\.value.height).max() ?? 0) + gap
        }
        return out
    }

    static func snap(_ value: CGFloat) -> CGFloat {
        (value / gridStep).rounded() * gridStep
    }
}
