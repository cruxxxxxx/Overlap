import SwiftUI
import ImageIO

struct ThumbnailCell: View {
    let item: FileItem
    let size: CGFloat
    let selected: Bool

    @State private var image: NSImage?
    @State private var loaded = false

    private var isGIF: Bool { item.url.pathExtension.lowercased() == "gif" }

    var body: some View {
        VStack(spacing: 4) {
            ZStack {
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color(nsColor: .quaternaryLabelColor))
                if isGIF {
                    AnimatedImageView(url: item.url)
                        .frame(maxWidth: size, maxHeight: size)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                } else if let image {
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(maxWidth: size, maxHeight: size)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                } else if !loaded {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: item.kind.symbol)
                        .font(.system(size: size * 0.3))
                        .foregroundStyle(.tertiary)
                }
            }
            .frame(width: size, height: size)
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(selected ? Color.accentColor : .clear, lineWidth: 3)
            )

            Text(item.name)
                .font(.caption2)
                .lineLimit(1)
                .truncationMode(.middle)
                .foregroundStyle(.secondary)
                .frame(width: size)
        }
        .task(id: item.id) {
            guard !isGIF else { return }
            loaded = false
            image = await ThumbnailCache.shared.thumbnail(for: item.url, size: size)
            loaded = true
        }
    }
}

/// Plays an animated GIF (or any multi-frame image) via NSImageView.
struct AnimatedImageView: NSViewRepresentable {
    let url: URL

    func makeNSView(context: Context) -> NSImageView {
        let view = NSImageView()
        view.imageScaling = .scaleProportionallyUpOrDown
        view.animates = true
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        view.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        load(into: view)
        return view
    }

    func updateNSView(_ nsView: NSImageView, context: Context) {
        if nsView.image == nil { load(into: nsView) }
    }

    private func load(into view: NSImageView) {
        let url = self.url
        DispatchQueue.global(qos: .userInitiated).async {
            // NSImage(contentsOf:) fails on some JPEGs (CMYK / odd profiles);
            // fall back to an ImageIO decode that sniffs the actual contents.
            var img = NSImage(contentsOf: url)
            if img == nil,
               let src = CGImageSourceCreateWithURL(url as CFURL, nil),
               let cg = CGImageSourceCreateImageAtIndex(src, 0, nil) {
                img = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
            }
            // NSImage.size is DPI-derived and can be absurd (e.g. 4,000,000 pt);
            // pin it to the real pixel dimensions so NSImageView lays it out.
            if let img, let rep = img.representations.first, rep.pixelsWide > 0 {
                img.size = NSSize(width: rep.pixelsWide, height: rep.pixelsHigh)
            }
            DispatchQueue.main.async {
                view.image = img
                view.animates = true
            }
        }
    }
}
