import SwiftUI
import AVKit
import Quartz
import ImageIO

/// A pluggable preview for one kind of file. Add a conformer to teach Overlap a
/// richer preview for a new type; `GenericPreviewer` (QuickLook) is the
/// catch-all so anything is at least viewable.
protocol FilePreviewer {
    func handles(_ item: FileItem) -> Bool
    @MainActor func preview(_ item: FileItem) -> AnyView
    /// Type-specific info rows (resolution, duration, …) — may be async.
    func info(_ item: FileItem) async -> [(String, String)]
}

extension FilePreviewer {
    func info(_ item: FileItem) async -> [(String, String)] { [] }
}

enum FilePreviewRegistry {
    /// Ordered; first `handles` wins. Generic is last (matches everything).
    static let providers: [FilePreviewer] =
        [ImagePreviewer(), AVPreviewer(), GenericPreviewer()]

    static func provider(for item: FileItem) -> FilePreviewer {
        providers.first { $0.handles(item) } ?? GenericPreviewer()
    }
}

// MARK: - Image

struct ImagePreviewer: FilePreviewer {
    func handles(_ item: FileItem) -> Bool { item.kind == .image }

    func preview(_ item: FileItem) -> AnyView {
        AnyView(AnimatedImageView(url: item.url))
    }

    func info(_ item: FileItem) async -> [(String, String)] {
        let url = item.url
        return await Task.detached { Self.metadata(of: url) }.value
    }

    /// Resolution + a few EXIF facts from the image header (no full decode).
    nonisolated static func metadata(of url: URL) -> [(String, String)] {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any]
        else { return [] }

        var rows: [(String, String)] = []
        if let w = props[kCGImagePropertyPixelWidth] as? Double,
           let h = props[kCGImagePropertyPixelHeight] as? Double {
            rows.append(("Resolution", "\(Int(w)) × \(Int(h))"))
        }
        let tiff = props[kCGImagePropertyTIFFDictionary] as? [CFString: Any]
        let ex = props[kCGImagePropertyExifDictionary] as? [CFString: Any]
        if let make = tiff?[kCGImagePropertyTIFFMake] as? String {
            let model = tiff?[kCGImagePropertyTIFFModel] as? String ?? ""
            rows.append(("Camera", "\(make) \(model)".trimmingCharacters(in: .whitespaces)))
        }
        if let lens = ex?[kCGImagePropertyExifLensModel] as? String { rows.append(("Lens", lens)) }
        if let taken = ex?[kCGImagePropertyExifDateTimeOriginal] as? String { rows.append(("Taken", taken)) }
        var shot: [String] = []
        if let iso = (ex?[kCGImagePropertyExifISOSpeedRatings] as? [Int])?.first { shot.append("ISO \(iso)") }
        if let f = ex?[kCGImagePropertyExifFNumber] as? Double { shot.append(String(format: "f/%.1f", f)) }
        if let fl = ex?[kCGImagePropertyExifFocalLength] as? Double { shot.append(String(format: "%.0fmm", fl)) }
        if !shot.isEmpty { rows.append(("Exposure", shot.joined(separator: " · "))) }
        if let cm = props[kCGImagePropertyColorModel] as? String {
            let profile = props[kCGImagePropertyProfileName] as? String
            rows.append(("Color", profile.map { "\(cm) · \($0)" } ?? cm))
        }
        return rows
    }
}

// MARK: - Video / Audio

struct AVPreviewer: FilePreviewer {
    func handles(_ item: FileItem) -> Bool { item.kind == .video || item.kind == .audio }

    func preview(_ item: FileItem) -> AnyView {
        AnyView(AVPlayerViewRep(url: item.url))
    }

    func info(_ item: FileItem) async -> [(String, String)] {
        let asset = AVURLAsset(url: item.url)
        var rows: [(String, String)] = []
        if let dur = try? await asset.load(.duration) {
            let secs = CMTimeGetSeconds(dur)
            if secs.isFinite && secs > 0 { rows.append(("Duration", Self.clock(secs))) }
        }
        if let track = try? await asset.loadTracks(withMediaType: .video).first,
           let size = try? await track.load(.naturalSize) {
            rows.append(("Dimensions", "\(Int(abs(size.width))) × \(Int(abs(size.height)))"))
        }
        return rows
    }

    private static func clock(_ seconds: Double) -> String {
        let s = Int(seconds.rounded())
        let m = s / 60, r = s % 60
        return String(format: "%d:%02d", m, r)
    }
}

/// AppKit `AVPlayerView` wrapper. Used instead of SwiftUI's `VideoPlayer`,
/// whose `_AVKit_SwiftUI` generic-metadata path crashes at runtime here.
struct AVPlayerViewRep: NSViewRepresentable {
    let url: URL

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.controlsStyle = .inline
        configure(view, context.coordinator)
        return view
    }

    func updateNSView(_ view: AVPlayerView, context: Context) {
        if context.coordinator.url != url { configure(view, context.coordinator) }
    }

    /// Muted, autoplaying, looping. `AVPlayerLooper` must be retained, so it
    /// lives on the coordinator.
    private func configure(_ view: AVPlayerView, _ coord: Coordinator) {
        let queue = AVQueuePlayer()
        queue.isMuted = true
        coord.looper = AVPlayerLooper(player: queue, templateItem: AVPlayerItem(url: url))
        coord.url = url
        view.player = queue
        queue.play()
    }

    final class Coordinator {
        var looper: AVPlayerLooper?
        var url: URL?
    }
}

// MARK: - Generic (QuickLook)

struct GenericPreviewer: FilePreviewer {
    func handles(_ item: FileItem) -> Bool { true }

    func preview(_ item: FileItem) -> AnyView {
        AnyView(QuickLookPreview(url: item.url))
    }
}

/// Embeds the system QuickLook view — renders PDFs, text, code, and virtually
/// anything with a Quick Look plugin.
struct QuickLookPreview: NSViewRepresentable {
    let url: URL

    func makeNSView(context: Context) -> QLPreviewView {
        let view = QLPreviewView(frame: .zero, style: .normal) ?? QLPreviewView()
        view.previewItem = url as NSURL
        return view
    }

    func updateNSView(_ view: QLPreviewView, context: Context) {
        if (view.previewItem as? URL) != url { view.previewItem = url as NSURL }
    }
}
