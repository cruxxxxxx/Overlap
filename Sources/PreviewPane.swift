import SwiftUI
import ImageIO

/// Large live preview of the selected image plus quick file insights.
struct PreviewPane: View {
    let item: FileItem?
    @State private var pixelSize: CGSize?
    @State private var exif: [(String, String)] = []

    var body: some View {
        Group {
            if let item {
                VStack(spacing: 8) {
                    AnimatedImageView(url: item.url)
                        .id(item.id)   // recreate so the preview follows selection
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    infoPanel(item)
                }
                .padding(10)
                .task(id: item.id) {
                    let url = item.url
                    let meta = await Task.detached { Self.metadata(of: url) }.value
                    pixelSize = meta.size
                    exif = meta.exif
                }
            } else {
                VStack(spacing: 8) {
                    Image(systemName: "photo").font(.system(size: 40)).foregroundStyle(.tertiary)
                    Text("Select an image").foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(Color(nsColor: .underPageBackgroundColor))
    }

    private func infoPanel(_ item: FileItem) -> some View {
        VStack(spacing: 6) {
            Text(item.name)
                .font(.callout).lineLimit(1).truncationMode(.middle)
            HStack(spacing: 18) {
                stat("Type", item.ext.isEmpty ? "—" : item.ext.uppercased())
                if let px = pixelSize {
                    stat("Resolution", "\(Int(px.width)) × \(Int(px.height))")
                }
                if let bytes = item.size {
                    stat("File Size", ByteCountFormatter.string(
                        fromByteCount: bytes, countStyle: .file))
                }
            }
            if let d = item.modDate {
                Text("Modified \(d.formatted(date: .abbreviated, time: .shortened))")
                    .font(.caption2).foregroundStyle(.tertiary)
            }
            if !exif.isEmpty {
                Divider().padding(.horizontal, 40)
                VStack(spacing: 2) {
                    ForEach(exif, id: \.0) { row in
                        HStack {
                            Text(row.0).foregroundStyle(.secondary)
                            Spacer()
                            Text(row.1)
                        }
                        .font(.caption2)
                    }
                }
                .padding(.horizontal, 20)
            }
        }
        .padding(.top, 2)
    }

    private func stat(_ label: String, _ value: String) -> some View {
        VStack(spacing: 1) {
            Text(value).font(.caption).monospacedDigit()
            Text(label).font(.caption2).foregroundStyle(.secondary)
        }
    }

    /// Read pixel dimensions + a few EXIF facts from the image header (no decode).
    nonisolated static func metadata(of url: URL) -> (size: CGSize?, exif: [(String, String)]) {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any]
        else { return (nil, []) }

        var size: CGSize?
        if let w = props[kCGImagePropertyPixelWidth] as? Double,
           let h = props[kCGImagePropertyPixelHeight] as? Double {
            size = CGSize(width: w, height: h)
        }

        var rows: [(String, String)] = []
        let tiff = props[kCGImagePropertyTIFFDictionary] as? [CFString: Any]
        let ex = props[kCGImagePropertyExifDictionary] as? [CFString: Any]

        if let make = tiff?[kCGImagePropertyTIFFMake] as? String {
            let model = tiff?[kCGImagePropertyTIFFModel] as? String ?? ""
            rows.append(("Camera", "\(make) \(model)".trimmingCharacters(in: .whitespaces)))
        }
        if let lens = ex?[kCGImagePropertyExifLensModel] as? String {
            rows.append(("Lens", lens))
        }
        if let taken = ex?[kCGImagePropertyExifDateTimeOriginal] as? String {
            rows.append(("Taken", taken))
        }
        var shot: [String] = []
        if let iso = (ex?[kCGImagePropertyExifISOSpeedRatings] as? [Int])?.first {
            shot.append("ISO \(iso)")
        }
        if let f = ex?[kCGImagePropertyExifFNumber] as? Double {
            shot.append(String(format: "f/%.1f", f))
        }
        if let fl = ex?[kCGImagePropertyExifFocalLength] as? Double {
            shot.append(String(format: "%.0fmm", fl))
        }
        if !shot.isEmpty { rows.append(("Exposure", shot.joined(separator: " · "))) }

        if let cm = props[kCGImagePropertyColorModel] as? String {
            let profile = props[kCGImagePropertyProfileName] as? String
            rows.append(("Color", profile.map { "\(cm) · \($0)" } ?? cm))
        }
        return (size, rows)
    }
}
