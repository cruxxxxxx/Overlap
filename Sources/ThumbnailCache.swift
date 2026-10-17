import AppKit
import AVFoundation
import QuickLookThumbnailing
import ImageIO

/// Async QuickLook thumbnail generator with an in-memory cache. Keyed by
/// path + modification time so edited files refresh.
final class ThumbnailCache: @unchecked Sendable {
    static let shared = ThumbnailCache()

    private let cache = NSCache<NSString, NSImage>()
    private let lock = NSLock()
    /// One generation per key: a cell scrolled away and back joins the request
    /// already running instead of queueing a duplicate behind it in QuickLook.
    private var inFlight: [NSString: Task<NSImage?, Never>] = [:]
    /// Keys of vault thumbnails, so a lock can drop exactly those.
    private var vaultKeys = Set<NSString>()
    private let decodeQueue = DispatchQueue(label: "overlap.thumbnail.decode", qos: .userInitiated,
                                            attributes: .concurrent)

    private init() {
        cache.countLimit = 2000
    }

    /// Drop everything, e.g. when the whole catalog changes.
    func removeAll() {
        cache.removeAllObjects()
        lock.withLock {
            vaultKeys.removeAll()
        }
    }

    /// Drop only vault thumbnails, on lock, so none outlives the reveal while
    /// the rest of the grid stays warm.
    func removeVaultThumbnails() {
        let keys = lock.withLock {
            let keys = vaultKeys
            vaultKeys.removeAll()
            return keys
        }
        for k in keys {
            cache.removeObject(forKey: k)
        }
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
        let task = lock.withLock { () -> Task<NSImage?, Never> in
            if let running = inFlight[k] {
                return running
            }
            // Unstructured on purpose: a cancelled cell must not cancel the
            // generation another cell (or its own return trip) is waiting on.
            let created = Task(priority: .userInitiated) { [self] in
                await generate(url: url, size: size)
            }
            inFlight[k] = created
            return created
        }
        let image = await task.value
        lock.withLock {
            inFlight[k] = nil
            if let image {
                cache.setObject(image, forKey: k)
                if VaultDisk.contains(url.path) {
                    vaultKeys.insert(k)
                }
            }
        }
        return image
    }

    private func generate(url: URL, size: CGFloat) async -> NSImage? {
        let scale = NSScreen.main?.backingScaleFactor ?? 2
        // Vault files never go through QuickLook: its thumbnail cache is a
        // plaintext file outside the vault. Render them in-process instead.
        if VaultDisk.contains(url.path) {
            if let image = await decodeOffPool(url: url, size: size * scale) {
                return image
            }
            return await videoThumbnail(url: url, size: size * scale)
        }
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
            return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
        }
        // QuickLook picks a renderer by extension and fails on mis-named files
        // (e.g. a JPEG saved as ".w807"). ImageIO sniffs the actual contents.
        return await decodeOffPool(url: url, size: size * scale)
    }

    /// ImageIO decodes block; keep them off Swift's small cooperative pool so a
    /// burst of big files can't stall every other async task in the app.
    private func decodeOffPool(url: URL, size: CGFloat) async -> NSImage? {
        await withCheckedContinuation { continuation in
            decodeQueue.async { [self] in
                continuation.resume(returning: imageIOThumbnail(url: url, size: size))
            }
        }
    }

    private func videoThumbnail(url: URL, size: CGFloat) async -> NSImage? {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: size, height: size)
        guard let cg = try? await generator.image(at: .zero).image else { return nil }
        return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
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
