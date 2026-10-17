import SwiftUI
import AppKit

/// One thumbnail on a mood board, drawn at its on-screen size. Selection,
/// moving and taps belong to the canvas; the tile owns its image, the corner
/// resize handle, and a hover handle for dragging the file out to other apps.
struct BoardTile: View {
    let item: BoardItem
    let size: CGSize               // on-screen points (canvas frame × zoom)
    let selected: Bool
    let hideIfMissing: Bool        // locked with a vault: a missing file may be a hidden one
    let onResize: (_ translation: CGSize, _ ended: Bool) -> Void

    @State private var url: URL?
    @State private var image: NSImage?
    @State private var missing = false
    @State private var hovering = false

    /// Thumbnails come in a few fixed sizes so live resizing and zooming
    /// don't render (and cache) a new one at every point size.
    private var thumbnailBucket: CGFloat {
        let side = max(size.width, size.height)
        if side <= 128 {
            return 128
        } else if side <= 256 {
            return 256
        } else {
            return 512
        }
    }

    private var isHidden: Bool { missing && hideIfMissing }

    var body: some View {
        ZStack(alignment: .topLeading) {
            content
            if hovering, let url, !missing {
                dragOutHandle(url)
            }
        }
        .frame(width: size.width, height: size.height)
        .contentShape(Rectangle())
        .overlay(
            Rectangle().strokeBorder(selected ? Color.accentColor : .clear, lineWidth: 2)
        )
        .overlay(alignment: .bottomTrailing) {
            if selected {
                resizeHandle
            }
        }
        .shadow(color: .black.opacity(0.25), radius: selected ? 6 : 2, y: 1)
        .onHover { hovering = $0 }
        .opacity(isHidden ? 0 : 1)
        .allowsHitTesting(!isHidden)
        .task(id: item.path) {
            await resolveFile()
        }
        .task(id: "\(url?.path ?? "")|\(thumbnailBucket)") {
            await loadThumbnail()
        }
    }

    @ViewBuilder
    private var content: some View {
        if let image {
            Image(nsImage: image)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: size.width, height: size.height)
        } else if missing {
            VStack(spacing: 4) {
                Image(systemName: "questionmark.square.dashed")
                    .font(.system(size: min(size.width, size.height) * 0.2))
                Text(URL(fileURLWithPath: item.path).lastPathComponent)
                    .font(.caption2)
                    .lineLimit(2)
                    .truncationMode(.middle)
                    .multilineTextAlignment(.center)
            }
            .foregroundStyle(.secondary)
            .padding(6)
            .frame(width: size.width, height: size.height)
            .background(Color(nsColor: .quaternaryLabelColor))
            .help("File not found: \(item.path)")
        } else {
            Rectangle()
                .fill(Color(nsColor: .quaternaryLabelColor))
                .frame(width: size.width, height: size.height)
        }
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
            .help("Drag to resize · hold ⇧ to change the shape")
    }

    private func dragOutHandle(_ url: URL) -> some View {
        Image(systemName: "arrow.up.forward.square.fill")
            .font(.system(size: 16))
            .foregroundStyle(.white, Color.black.opacity(0.55))
            .padding(4)
            .onDrag { NSItemProvider(object: url as NSURL) }
            .help("Drag the file out to Finder or another app")
    }

    private func resolveFile() async {
        let path = item.path
        let resolved = await Task.detached(priority: .userInitiated) { () -> URL? in
            let url = VaultDisk.resolvedURL(forLogicalPath: path)
            return FileManager.default.fileExists(atPath: url.path) ? url : nil
        }.value
        url = resolved
        missing = resolved == nil
        if missing {
            image = nil
        }
    }

    private func loadThumbnail() async {
        guard let url else {
            return
        }
        // Keep the old image on screen until the sharper one arrives.
        if let fresh = await ThumbnailCache.shared.thumbnail(for: url, size: thumbnailBucket) {
            image = fresh
        }
    }
}
