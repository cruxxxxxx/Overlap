import Foundation
import ImageIO

/// Automatic placement for mood-board tiles: a masonry pack (each tile drops
/// into the shortest column) at a fixed column width, heights from each
/// file's aspect ratio.
enum BoardLayout {
    static let columnWidth: CGFloat = 240
    static let gap: CGFloat = 16
    static let margin: CGFloat = 40

    /// Roughly 4:3 overall for `count` tiles, capped so a big board stays scrollable.
    static func columns(for count: Int) -> Int {
        max(1, min(12, Int((Double(count) * 1.3).squareRoot().rounded(.up))))
    }

    /// One frame per aspect ratio (width / height), in input order.
    static func masonry(_ aspects: [CGFloat], origin: CGPoint, columns: Int) -> [CGRect] {
        let columnCount = max(1, columns)
        var columnBottoms = Array(repeating: origin.y, count: columnCount)
        var frames: [CGRect] = []
        frames.reserveCapacity(aspects.count)
        for aspect in aspects {
            let column = columnBottoms.indices.min { columnBottoms[$0] < columnBottoms[$1] } ?? 0
            let height = (columnWidth / max(aspect, 0.1)).rounded()
            let x = origin.x + CGFloat(column) * (columnWidth + gap)
            frames.append(CGRect(x: x, y: columnBottoms[column], width: columnWidth, height: height))
            columnBottoms[column] += height + gap
        }
        return frames
    }

    /// Re-pack existing tiles in reading order (top-to-bottom, left-to-right),
    /// keeping each tile's own aspect ratio.
    static func tidy(_ items: [BoardItem]) -> [BoardItem] {
        let ordered = items.sorted {
            if abs($0.frame.minY - $1.frame.minY) > 1 {
                return $0.frame.minY < $1.frame.minY
            } else {
                return $0.frame.minX < $1.frame.minX
            }
        }
        let aspects = ordered.map { $0.frame.width / max($0.frame.height, 1) }
        let frames = masonry(aspects, origin: CGPoint(x: margin, y: margin),
                             columns: columns(for: ordered.count))
        return zip(ordered, frames).map { item, frame in
            var moved = item
            moved.frame = frame
            return moved
        }
    }

    /// Width / height for each path, read from image headers off-main. Files
    /// ImageIO can't size (video, PDF, documents) get a square.
    static func aspectRatios(_ paths: [String]) async -> [CGFloat] {
        await Task.detached(priority: .userInitiated) {
            paths.map { aspectRatio(atLogicalPath: $0) }
        }.value
    }

    private static func aspectRatio(atLogicalPath path: String) -> CGFloat {
        let url = VaultDisk.resolvedURL(forLogicalPath: path)
        let options = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithURL(url as CFURL, options),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, options) as? [CFString: Any],
              let width = props[kCGImagePropertyPixelWidth] as? CGFloat,
              let height = props[kCGImagePropertyPixelHeight] as? CGFloat,
              width > 0, height > 0 else {
            return 1
        }
        // EXIF orientations 5–8 are rotated a quarter turn.
        let orientation = props[kCGImagePropertyOrientation] as? Int ?? 1
        if orientation >= 5 {
            return height / width
        } else {
            return width / height
        }
    }
}
