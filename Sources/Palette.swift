import Foundation
import AppKit
import CoreGraphics

/// One color in a board's palette, stored as sRGB components (0…1).
struct PaletteSwatch: Identifiable, Codable, Hashable {
    var id = UUID()
    var red: Double
    var green: Double
    var blue: Double

    init(red: Double, green: Double, blue: Double) {
        self.red = red
        self.green = green
        self.blue = blue
    }

    /// From any NSColor (eyedropper, color panel), converted to sRGB.
    init?(_ color: NSColor) {
        guard let srgb = color.usingColorSpace(.sRGB) else {
            return nil
        }
        self.init(red: Double(srgb.redComponent), green: Double(srgb.greenComponent),
                  blue: Double(srgb.blueComponent))
    }

    var nsColor: NSColor {
        NSColor(srgbRed: red, green: green, blue: blue, alpha: 1)
    }

    var hex: String {
        String(format: "#%02X%02X%02X", byte(red), byte(green), byte(blue))
    }

    var rgbText: String {
        "rgb(\(byte(red)), \(byte(green)), \(byte(blue)))"
    }

    /// Black or white, whichever reads better on top of this color.
    var prefersDarkText: Bool {
        0.2126 * red + 0.7152 * green + 0.0722 * blue > 0.55
    }

    /// Same color regardless of id — used to skip duplicates.
    func matches(_ other: PaletteSwatch) -> Bool {
        hex == other.hex
    }

    private func byte(_ value: Double) -> Int {
        Int((min(max(value, 0), 1) * 255).rounded())
    }
}

/// A dominant color found in an image, with the share of pixels it covers.
struct ExtractedColor: Identifiable {
    let swatch: PaletteSwatch
    let share: Double
    var id: String { swatch.hex }
}

/// Dominant colors of an image: pixels are bucketed into a coarse histogram,
/// then clustered with weighted k-means (farthest-point seeding, so the result
/// is deterministic and keeps small but distinct accents).
enum PaletteExtractor {
    static func dominantColors(in image: CGImage, count: Int = 6) -> [ExtractedColor] {
        let bins = histogram(of: image)
        guard !bins.isEmpty else {
            return []
        }
        var centers = seeds(bins, count: count + 2)
        var assignment = Array(repeating: 0, count: bins.count)
        for _ in 0..<12 {
            for (i, bin) in bins.enumerated() {
                assignment[i] = nearest(bin.color, in: centers)
            }
            var sums = Array(repeating: SIMD3<Double>(repeating: 0), count: centers.count)
            var weights = Array(repeating: 0.0, count: centers.count)
            for (i, bin) in bins.enumerated() {
                sums[assignment[i]] += bin.color * bin.weight
                weights[assignment[i]] += bin.weight
            }
            for c in centers.indices where weights[c] > 0 {
                centers[c] = sums[c] / weights[c]
            }
        }
        var clusters: [(color: SIMD3<Double>, weight: Double)] = centers.indices.map { c in
            (centers[c], bins.indices.filter { assignment[$0] == c }.reduce(0) { $0 + bins[$1].weight })
        }
        clusters = mergeNearDuplicates(clusters)
        let total = clusters.reduce(0) { $0 + $1.weight }
        return clusters
            .filter { $0.weight / total >= 0.01 }
            .sorted { $0.weight > $1.weight }
            .prefix(count)
            .map { cluster in
                ExtractedColor(swatch: PaletteSwatch(red: cluster.color.x, green: cluster.color.y,
                                                     blue: cluster.color.z),
                               share: cluster.weight / total)
            }
    }

    private struct Bin {
        let color: SIMD3<Double>
        let weight: Double
    }

    /// Draw the image small in sRGB and count opaque pixels per 5-bit-per-channel bin.
    private static func histogram(of image: CGImage) -> [Bin] {
        let side = 64
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8,
                                      bytesPerRow: side * 4, space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            return []
        }
        context.interpolationQuality = .medium
        context.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))
        guard let data = context.data else {
            return []
        }
        let pixels = data.bindMemory(to: UInt8.self, capacity: side * side * 4)
        var sums: [Int: (SIMD3<Double>, Double)] = [:]
        for p in 0..<(side * side) {
            let alpha = Double(pixels[p * 4 + 3])
            guard alpha >= 128 else {
                continue
            }
            let r = Double(pixels[p * 4]) / alpha
            let g = Double(pixels[p * 4 + 1]) / alpha
            let b = Double(pixels[p * 4 + 2]) / alpha
            let key = (Int(r * 31) << 10) | (Int(g * 31) << 5) | Int(b * 31)
            let entry = sums[key] ?? (SIMD3(repeating: 0), 0)
            sums[key] = (entry.0 + SIMD3(r, g, b), entry.1 + 1)
        }
        return sums.values.map { Bin(color: $0.0 / $0.1, weight: $0.1) }
    }

    /// Most common bin first, then repeatedly the bin farthest from every seed
    /// so far, weighted by how common it is.
    private static func seeds(_ bins: [Bin], count: Int) -> [SIMD3<Double>] {
        guard let first = bins.max(by: { $0.weight < $1.weight }) else {
            return []
        }
        var seeds = [first.color]
        while seeds.count < min(count, bins.count) {
            let next = bins.max { a, b in
                score(a, seeds) < score(b, seeds)
            }
            guard let next, score(next, seeds) > 0 else {
                break
            }
            seeds.append(next.color)
        }
        return seeds
    }

    private static func score(_ bin: Bin, _ seeds: [SIMD3<Double>]) -> Double {
        let nearestDistance = seeds.map { distance(bin.color, $0) }.min() ?? 0
        return nearestDistance * bin.weight.squareRoot()
    }

    private static func nearest(_ color: SIMD3<Double>, in centers: [SIMD3<Double>]) -> Int {
        centers.indices.min { distance(color, centers[$0]) < distance(color, centers[$1]) } ?? 0
    }

    private static func distance(_ a: SIMD3<Double>, _ b: SIMD3<Double>) -> Double {
        let d = a - b
        return (d * d).sum().squareRoot()
    }

    private static func mergeNearDuplicates(_ clusters: [(color: SIMD3<Double>, weight: Double)])
        -> [(color: SIMD3<Double>, weight: Double)] {
        var merged: [(color: SIMD3<Double>, weight: Double)] = []
        for cluster in clusters.sorted(by: { $0.weight > $1.weight }) where cluster.weight > 0 {
            if let i = merged.firstIndex(where: { distance($0.color, cluster.color) < 0.07 }) {
                let w = merged[i].weight + cluster.weight
                merged[i] = ((merged[i].color * merged[i].weight + cluster.color * cluster.weight) / w, w)
            } else {
                merged.append(cluster)
            }
        }
        return merged
    }
}

/// Getting a palette out of Overlap: text for code and chat, Adobe swatch
/// exchange files, and named color lists for every Mac app's color panel.
enum PaletteExport {
    static func hexList(_ swatches: [PaletteSwatch]) -> String {
        swatches.map(\.hex).joined(separator: "\n")
    }

    static func css(_ swatches: [PaletteSwatch]) -> String {
        let lines = swatches.enumerated().map { i, s in "  --color-\(i + 1): \(s.hex.lowercased());" }
        return ":root {\n" + lines.joined(separator: "\n") + "\n}"
    }

    static func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    /// Adobe Swatch Exchange (.ase), readable by Photoshop, Illustrator,
    /// InDesign, Affinity, Procreate and others. Big-endian throughout.
    static func ase(_ swatches: [PaletteSwatch]) -> Data {
        var data = Data("ASEF".utf8)
        data.appendBigEndian(UInt16(1))
        data.appendBigEndian(UInt16(0))
        data.appendBigEndian(UInt32(swatches.count))
        for swatch in swatches {
            let name = Array(swatch.hex.utf16) + [0]
            var block = Data()
            block.appendBigEndian(UInt16(name.count))
            for unit in name {
                block.appendBigEndian(unit)
            }
            block.append(contentsOf: Array("RGB ".utf8))
            for component in [swatch.red, swatch.green, swatch.blue] {
                block.appendBigEndian(Float32(component).bitPattern)
            }
            block.appendBigEndian(UInt16(2))   // normal (not global or spot)
            data.appendBigEndian(UInt16(0x0001))   // color entry
            data.appendBigEndian(UInt32(block.count))
            data.append(block)
        }
        return data
    }

    @MainActor
    static func saveASE(_ swatches: [PaletteSwatch], suggestedName: String) {
        let panel = NSSavePanel()
        panel.title = "Export Adobe Swatches"
        panel.nameFieldStringValue = suggestedName + ".ase"
        guard panel.runModal() == .OK, let url = panel.url else {
            return
        }
        try? ase(swatches).write(to: url, options: .atomic)
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    /// Save as a named list in ~/Library/Colors: it then shows under
    /// "Color Palettes" in the color panel of every Mac app.
    /// Returns the list's name, or nil on failure.
    @discardableResult
    static func saveToColorPanel(_ swatches: [PaletteSwatch], name: String) -> String? {
        let listName = QueryExporter.folderName(for: name)
        let list = NSColorList(name: listName)
        for (i, swatch) in swatches.enumerated() {
            list.insertColor(swatch.nsColor, key: "\(i + 1) \(swatch.hex)", at: i)
        }
        let dir = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Colors", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(listName + ".clr")
        do {
            try list.write(to: url)
            return listName
        } catch {
            return nil
        }
    }
}

private extension Data {
    mutating func appendBigEndian<T: FixedWidthInteger>(_ value: T) {
        Swift.withUnsafeBytes(of: value.bigEndian) { append(contentsOf: $0) }
    }
}
