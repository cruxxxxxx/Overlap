import AppKit
import QuickLookThumbnailing
import ImageIO

/// Async QuickLook thumbnail generator with an in-memory cache. Keyed by
/// path + modification time so edited files refresh.
final class ThumbnailCache: @unchecked Sendable {
    static let shared = ThumbnailCache()

    private let cache = NSCache<NSString, NSImage>()

    private init() {
        cache.countLimit = 2000
    }

    private func key(for url: URL, size: CGFloat) -> NSString {
        let mtime = (try? url.resourceValues(forKeys: [.contentModificationDateKey])
            .contentModificationDate)?.timeIntervalSince1970 ?? 0
        return "\(url.path)|\(Int(mtime))|\(Int(size))" as NSString
    }

    func thumbnail(for url: URL, size: CGFloat) async -> NSImage? {
        let k = key(for: url, size: size)
        if let hit = cache.object(forKey: k) {
            return hit
        }
        let scale = NSScreen.main?.backingScaleFactor ?? 2
        let request = QLThumbnailGenerator.Request(
            fileAt: url,
            size: CGSize(width: size, height: size),
            scale: scale,
            representationTypes: .thumbnail
        )
        if let rep = try? await QLThumbnailGenerator.shared
            .generateBestRepresentation(for: request) {
            let cg = rep.cgImage
            // Preserve the real pixel aspect ratio (don't force a square).
            let image = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
            cache.setObject(image, forKey: k)
            return image
        }
        // QuickLook picks a renderer by extension and fails on mis-named files
        // (e.g. a JPEG saved as ".w807"). ImageIO sniffs the actual contents.
        if let image = imageIOThumbnail(url: url, size: size * scale) {
            cache.setObject(image, forKey: k)
            return image
        }
        return nil
    }

    private func imageIOThumbnail(url: URL, size: CGFloat) -> NSImage? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: max(32, size),
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, options as CFDictionary)
        else { return nil }
        return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
    }
}
