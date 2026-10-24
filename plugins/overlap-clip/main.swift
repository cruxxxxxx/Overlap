import Foundation
import CoreML
import Vision
import ImageIO
import Accelerate

// overlap-clip — semantic (text → image) search for Overlap.
//
// A `capabilities: ["search"]` plugin. Embeds every image the host hands it
// with a MobileCLIP image encoder into one persisted index, and answers a
// free-text `query` by encoding it with the matching text encoder and ranking
// the index by cosine. Same process contract as overlap-suggest: request on
// stdin, response on stdout, progress lines on stderr.
//
// Models are Apple's Core ML exports (huggingface.co/apple/coreml-mobileclip),
// downloaded on first use into the plugin cache — the app itself stays small.
//
// Three request shapes:
//   warm-up:  library = [every image], query = nil  → embed what's new, no hits
//   query:    library = [],            query = text → rank the index, return hits
//   similar:  similarTo = [paths]                    → rank the index by likeness to them
//   duplicates: duplicates = {threshold, paths?}     → pairs of near-identical images

// MARK: - Wire contract (hand-copied from Sources/PluginContract.swift)

struct RequestFile: Codable {
    let path: String; let kind: String
    let ext: String; let tags: [String]
    let size: Int64?; let modDate: Date?; let createdDate: Date?
}
struct LibraryItem: Codable {
    let path: String; let kind: String
    let tags: [String]; let modDate: Date?
}
enum SettingValue: Codable {
    case bool(Bool), number(Double), string(String)
    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let b = try? c.decode(Bool.self) { self = .bool(b); return }
        if let n = try? c.decode(Double.self) { self = .number(n); return }
        self = .string(try c.decode(String.self))
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .bool(let b): try c.encode(b)
        case .number(let n): try c.encode(n)
        case .string(let s): try c.encode(s)
        }
    }
    var boolValue: Bool? { if case .bool(let b) = self { return b }; return nil }
    var numberValue: Double? { if case .number(let n) = self { return n }; return nil }
    var stringValue: String? { if case .string(let s) = self { return s }; return nil }
}
struct SuggestRequest: Codable {
    let protocolVersion: Int?
    let files: [RequestFile]
    let knownTags: [String]?
    let library: [LibraryItem]?
    let settings: [String: SettingValue]?
    let query: String?
    let similarTo: [String]?
    let duplicates: DuplicatesQuery?
}
/// Near-duplicate scan: every pair of indexed images (restricted to `paths`
/// when given) at or above `threshold` cosine.
struct DuplicatesQuery: Codable {
    let threshold: Double
    let paths: [String]?
}
struct DuplicatePair: Codable { let a: String; let b: String; let score: Double }
struct RawSuggestion: Codable {
    let path: String; let tag: String
    let confidence: Double; let source: String?
}
struct SearchHit: Codable { let path: String; let score: Double }
struct SuggestResponse: Codable {
    let protocolVersion: Int
    let suggestions: [RawSuggestion]
    let hits: [SearchHit]
    let indexedCount: Int
    var pairs: [DuplicatePair]? = nil
}

// MARK: - Config

struct Config: Codable {
    var variant = "s2"          // mobileclip_{s0,s1,s2,blt}; switching re-embeds everything
    var maxResults = 300
    var minScore = 0.15         // CLIP cosine; good matches usually land 0.2–0.35
    var similarMinScore = 0.5   // image↔image cosine runs much higher than text↔image
    var maxFileMB = 25
    var batchSize = 32          // images per Core ML batch prediction
    var decodeMaxPixel = 320    // ImageIO thumbnail edge before the 256 crop

    init() {}
    /// Tolerant decode: missing keys fall back to defaults so an old config.json
    /// keeps working after new fields appear.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        variant = try c.decodeIfPresent(String.self, forKey: .variant) ?? variant
        maxResults = try c.decodeIfPresent(Int.self, forKey: .maxResults) ?? maxResults
        minScore = try c.decodeIfPresent(Double.self, forKey: .minScore) ?? minScore
        similarMinScore = try c.decodeIfPresent(Double.self, forKey: .similarMinScore) ?? similarMinScore
        maxFileMB = try c.decodeIfPresent(Int.self, forKey: .maxFileMB) ?? maxFileMB
        batchSize = try c.decodeIfPresent(Int.self, forKey: .batchSize) ?? batchSize
        decodeMaxPixel = try c.decodeIfPresent(Int.self, forKey: .decodeMaxPixel) ?? decodeMaxPixel
    }
}

// MARK: - Paths

let cacheRoot: URL = {
    if let override = ProcessInfo.processInfo.environment["OVERLAP_PLUGIN_CACHE"] {
        return URL(fileURLWithPath: override, isDirectory: true)
    }
    return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Overlap/PluginCache", isDirectory: true)
}()
let cacheDir: URL = {
    let d = cacheRoot.appendingPathComponent("overlap-clip", isDirectory: true)
    try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
    return d
}()
let modelsDir = cacheDir.appendingPathComponent("models", isDirectory: true)
let metaURL = cacheDir.appendingPathComponent("meta.json")
let binURL = cacheDir.appendingPathComponent("clip.bin")
let configURL = cacheDir.appendingPathComponent("config.json")
let lockURL = cacheDir.appendingPathComponent("lock")

/// Where clip-vocab.json / clip-merges.txt live: next to the executable (the
/// plugin dir — the host also sets it as cwd; a symlinked install resolves to
/// the real dir either way).
let resourceDir: URL = {
    let exe = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
        .deletingLastPathComponent()
    if FileManager.default.fileExists(atPath: exe.appendingPathComponent("clip-vocab.json").path) {
        return exe
    }
    return URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
}()

var config: Config = {
    if let d = try? Data(contentsOf: configURL),
       let c = try? JSONDecoder().decode(Config.self, from: d) { return c }
    let c = Config()
    let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]
    if let d = try? enc.encode(c) { try? d.write(to: configURL) }
    return c
}()

/// Host-tuned settings override config.json which overrides built-in defaults.
func applyHostSettings(_ s: [String: SettingValue]?) {
    guard let s else { return }
    if let v = s["maxResults"]?.numberValue { config.maxResults = max(1, Int(v)) }
    if let v = s["minScore"]?.numberValue { config.minScore = v }
    if let v = s["similarMinScore"]?.numberValue { config.similarMinScore = v }
    if let v = s["maxFileMB"]?.numberValue { config.maxFileMB = max(1, Int(v)) }
}

func stderrLine(_ s: String) { FileHandle.standardError.write(Data((s + "\n").utf8)) }

// MARK: - Model download + compile

struct ModelSpec {
    let variant: String
    var imageName: String { "mobileclip_\(variant)_image" }
    var textName: String { "mobileclip_\(variant)_text" }
    var names: [String] { [imageName, textName] }
    static let repo = "https://huggingface.co/apple/coreml-mobileclip/resolve/main"
    static let packageFiles = ["Manifest.json", "Data/com.apple.CoreML/model.mlmodel",
                               "Data/com.apple.CoreML/weights/weight.bin"]
    /// Rough total bytes per variant, for a single overall progress percentage.
    var approxBytes: Int64 {
        switch variant {
        case "s0": return 110_000_000
        case "s1": return 175_000_000
        case "s2": return 199_000_000
        default:   return 310_000_000
        }
    }
    func compiled(_ name: String) -> URL { modelsDir.appendingPathComponent("\(name).mlmodelc") }
    var versionURL: URL { modelsDir.appendingPathComponent("VERSION") }
}

/// Synchronous file download with progress on stderr. One URLSession per file
/// keeps the delegate trivially simple; six files total.
final class Downloader: NSObject, URLSessionDownloadDelegate {
    private let done = DispatchSemaphore(value: 0)
    private let dest: URL
    private let progress: (Int64) -> Void
    private var failure: String?
    private var lastReported: Int64 = 0

    init(dest: URL, progress: @escaping (Int64) -> Void) {
        self.dest = dest; self.progress = progress
    }

    func run(_ url: URL) -> String? {
        let session = URLSession(configuration: .ephemeral, delegate: self, delegateQueue: nil)
        session.downloadTask(with: url).resume()
        done.wait()
        session.invalidateAndCancel()
        return failure
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
                    totalBytesExpectedToWrite: Int64) {
        progress(totalBytesWritten - lastReported)
        lastReported = totalBytesWritten
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didFinishDownloadingTo location: URL) {
        let status = (downloadTask.response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else { failure = "HTTP \(status)"; return }
        let fm = FileManager.default
        try? fm.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? fm.removeItem(at: dest)
        do { try fm.moveItem(at: location, to: dest) } catch { failure = error.localizedDescription }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error, failure == nil { failure = error.localizedDescription }
        done.signal()
    }
}

/// Make sure both compiled encoders exist for the configured variant. Downloads
/// + compiles on first use. Returns nil on success, else a human-readable reason.
func ensureModels(_ spec: ModelSpec) -> String? {
    let fm = FileManager.default
    let version = (try? String(contentsOf: spec.versionURL, encoding: .utf8))?
        .trimmingCharacters(in: .whitespacesAndNewlines)
    if version == spec.variant, spec.names.allSatisfy({ fm.fileExists(atPath: spec.compiled($0).path) }) {
        return nil
    }

    let downloadDir = modelsDir.appendingPathComponent("download", isDirectory: true)
    try? fm.removeItem(at: downloadDir)
    try? fm.createDirectory(at: downloadDir, withIntermediateDirectories: true)

    var received: Int64 = 0
    var lastPct = -1
    let mb = spec.approxBytes / 1_000_000
    for name in spec.names {
        let pkg = downloadDir.appendingPathComponent("\(name).mlpackage", isDirectory: true)
        for rel in ModelSpec.packageFiles {
            let url = URL(string: "\(ModelSpec.repo)/\(name).mlpackage/\(rel)")!
            let dl = Downloader(dest: pkg.appendingPathComponent(rel)) { delta in
                received += delta
                let pct = min(99, Int(received * 100 / max(1, spec.approxBytes)))
                if pct != lastPct {
                    lastPct = pct
                    stderrLine("Downloading CLIP model (\(spec.variant.uppercased()), ~\(mb) MB)… \(pct)%")
                }
            }
            if let err = dl.run(url) { return "download failed (\(rel)): \(err)" }
        }
    }

    stderrLine("Compiling CLIP model…")
    for name in spec.names {
        let pkg = downloadDir.appendingPathComponent("\(name).mlpackage", isDirectory: true)
        do {
            let tmp = try MLModel.compileModel(at: pkg)
            let dst = spec.compiled(name)
            try? fm.removeItem(at: dst)
            try fm.moveItem(at: tmp, to: dst)
        } catch {
            return "compile failed (\(name)): \(error.localizedDescription)"
        }
    }
    try? fm.removeItem(at: downloadDir)
    try? spec.variant.write(to: spec.versionURL, atomically: true, encoding: .utf8)
    return nil
}

// MARK: - Encoders

/// A loaded Core ML encoder with its feature names discovered from the model
/// description, so the exact export naming never matters.
struct ClipEncoder {
    let model: MLModel
    let inputName: String
    let outputName: String
    let imageConstraint: MLImageConstraint?

    static func load(_ url: URL, wantsImage: Bool) -> ClipEncoder? {
        let cfg = MLModelConfiguration()
        cfg.computeUnits = .all
        guard let model = try? MLModel(contentsOf: url, configuration: cfg) else { return nil }
        let desc = model.modelDescription
        let input = desc.inputDescriptionsByName.first { wantsImage ? $0.value.type == .image
                                                                    : $0.value.type == .multiArray }
        guard let input, let output = desc.outputDescriptionsByName.keys.sorted().first else { return nil }
        return ClipEncoder(model: model, inputName: input.key, outputName: output,
                       imageConstraint: input.value.imageConstraint)
    }

    /// Read a prediction's embedding as Float32, whatever the array's dtype.
    func vector(from features: MLFeatureProvider) -> [Float]? {
        guard let arr = features.featureValue(for: outputName)?.multiArrayValue else { return nil }
        let n = arr.count
        var out = [Float](repeating: 0, count: n)
        switch arr.dataType {
        case .float32:
            let p = arr.dataPointer.assumingMemoryBound(to: Float.self)
            let stride = arr.strides.last?.intValue ?? 1
            for i in 0..<n { out[i] = p[i * stride] }
        case .double:
            let p = arr.dataPointer.assumingMemoryBound(to: Double.self)
            let stride = arr.strides.last?.intValue ?? 1
            for i in 0..<n { out[i] = Float(p[i * stride]) }
        default:
            for i in 0..<n { out[i] = arr[i].floatValue }
        }
        normalize(&out)
        return out
    }
}

func normalize(_ v: inout [Float]) {
    var n: Float = 0
    vDSP_svesq(v, 1, &n, vDSP_Length(v.count)); n = n.squareRoot()
    if n > 0 { var inv = 1 / n; vDSP_vsmul(v, 1, &inv, &v, 1, vDSP_Length(v.count)) }
}

/// Decode a bounded-size, orientation-corrected image once (ImageIO handles
/// HEIC/RAW/TIFF/… for free); Core ML crops + scales it to the model's input.
func downsampledImage(_ path: String, maxPixel: Int) -> CGImage? {
    guard let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL,
                                               [kCGImageSourceShouldCache: false] as CFDictionary)
    else { return nil }
    let opts: [CFString: Any] = [
        kCGImageSourceCreateThumbnailFromImageAlways: true,
        kCGImageSourceCreateThumbnailWithTransform: true,
        kCGImageSourceThumbnailMaxPixelSize: maxPixel,
        kCGImageSourceShouldCacheImmediately: true,
    ]
    return CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary)
}

func imageFeature(_ cg: CGImage, for enc: ClipEncoder) -> MLFeatureValue? {
    let w = enc.imageConstraint?.pixelsWide ?? 256
    let h = enc.imageConstraint?.pixelsHigh ?? 256
    let fmt = enc.imageConstraint?.pixelFormatType ?? kCVPixelFormatType_32BGRA
    return try? MLFeatureValue(cgImage: cg, pixelsWide: w, pixelsHigh: h, pixelFormatType: fmt,
                               options: [.cropAndScale: VNImageCropAndScaleOption.centerCrop.rawValue])
}

/// mtime fingerprint; host-supplied modDate avoids a stat on the hot path.
func signature(path: String, modDate: Date?) -> String {
    if let m = modDate { return "m:\(Int(m.timeIntervalSince1970))" }
    let mtime = (try? FileManager.default.attributesOfItem(atPath: path)[.modificationDate] as? Date)?
        .flatMap { $0 }?.timeIntervalSince1970 ?? -1
    return "s:\(Int(mtime))"
}

// MARK: - Persistent index

struct ImageRec: Codable {
    var sig: String
    var row: Int          // -1 = unreadable / skipped; never retried until the file changes
}
struct Meta: Codable {
    var schemaVersion = 1
    var model = ""        // variant the rows were embedded with
    var dim = 0
    var rows = 0          // rows physically in clip.bin (including dead ones)
    var images: [String: ImageRec] = [:]
}

var meta: Meta = {
    if let d = try? Data(contentsOf: metaURL), let m = try? JSONDecoder().decode(Meta.self, from: d) {
        return m
    }
    return Meta()
}()
func saveMeta() {
    if let d = try? JSONEncoder().encode(meta) { try? d.write(to: metaURL, options: .atomic) }
}
var liveCount: Int { meta.images.values.filter { $0.row >= 0 }.count }

/// Advisory lock so a warm-up and a forced rebuild never append concurrently.
func withIndexLock<T>(_ body: () -> T) -> T {
    let fd = open(lockURL.path, O_CREAT | O_RDWR, 0o644)
    if fd >= 0 { flock(fd, LOCK_EX) }
    defer { if fd >= 0 { flock(fd, LOCK_UN); close(fd) } }
    return body()
}

/// Embed every library image whose signature changed (or that's new), append
/// the vectors to clip.bin, persist meta every batch so a killed run resumes.
func syncIndex(items: [LibraryItem], encoder: ClipEncoder, progress: (Int, Int) -> Void) {
    let fm = FileManager.default
    if meta.model != config.variant || meta.dim == 0 && meta.rows > 0 {
        // Variant switch: vectors aren't comparable across encoders. Start over.
        meta = Meta(); try? fm.removeItem(at: binURL)
    }
    meta.model = config.variant

    // Forget files that left the corpus AND the disk (a file merely outside
    // today's library list — e.g. a removed watched folder — keeps its row so
    // re-adding the folder costs nothing).
    let incoming = Set(items.map(\.path))
    var forgotten: [Int] = []
    for path in meta.images.keys where !incoming.contains(path) && !fm.fileExists(atPath: path) {
        if let row = meta.images.removeValue(forKey: path)?.row, row >= 0 { forgotten.append(row) }
    }
    zeroRows(forgotten, rowBytes: meta.dim * 4, in: binURL)

    let todo = items.filter { it in
        guard let rec = meta.images[it.path] else { return true }
        return rec.sig != signature(path: it.path, modDate: it.modDate)
    }
    guard !todo.isEmpty else { saveMeta(); return }

    if !fm.fileExists(atPath: binURL.path) { fm.createFile(atPath: binURL.path, contents: nil) }
    guard let fh = try? FileHandle(forUpdating: binURL) else { return }
    defer { try? fh.close() }

    let maxBytes = Int64(config.maxFileMB) * 1_048_576
    var done = 0
    let batch = max(1, config.batchSize)
    var start = 0
    while start < todo.count {
        let chunk = Array(todo[start..<min(start + batch, todo.count)])
        start += batch

        // Decode concurrently (ImageIO is the cost), predict as one batch.
        var features = [MLFeatureValue?](repeating: nil, count: chunk.count)
        features.withUnsafeMutableBufferPointer { buf in
            DispatchQueue.concurrentPerform(iterations: chunk.count) { i in
                let path = chunk[i].path
                let bytes = (try? fm.attributesOfItem(atPath: path)[.size] as? Int64).flatMap { $0 } ?? 0
                guard bytes <= maxBytes,
                      let cg = downsampledImage(path, maxPixel: config.decodeMaxPixel) else { return }
                buf[i] = imageFeature(cg, for: encoder)
            }
        }

        var vectors = [[Float]?](repeating: nil, count: chunk.count)
        let live = features.indices.filter { features[$0] != nil }
        if !live.isEmpty {
            let providers = live.compactMap { i -> MLFeatureProvider? in
                try? MLDictionaryFeatureProvider(dictionary: [encoder.inputName: features[i]!])
            }
            if let out = try? encoder.model.predictions(fromBatch: MLArrayBatchProvider(array: providers)) {
                for (k, i) in live.enumerated() { vectors[i] = encoder.vector(from: out.features(at: k)) }
            } else {
                // Batch failed (rare); salvage one at a time so a single bad
                // image can't sink its 31 neighbors.
                for i in live {
                    if let p = try? MLDictionaryFeatureProvider(dictionary: [encoder.inputName: features[i]!]),
                       let out = try? encoder.model.prediction(from: p) {
                        vectors[i] = encoder.vector(from: out)
                    }
                }
            }
        }

        for (i, it) in chunk.enumerated() {
            let sig = signature(path: it.path, modDate: it.modDate)
            if let vec = vectors[i] {
                if meta.dim == 0 { meta.dim = vec.count }
                if vec.count == meta.dim {
                    try? fh.seek(toOffset: UInt64(meta.rows * meta.dim * 4))
                    fh.write(vec.withUnsafeBytes { Data($0) })
                    meta.images[it.path] = ImageRec(sig: sig, row: meta.rows)
                    meta.rows += 1
                    continue
                }
            }
            meta.images[it.path] = ImageRec(sig: sig, row: -1)
        }
        done += chunk.count
        try? fh.synchronize()
        saveMeta()
        progress(done, todo.count)
    }
    compactIfNeeded()
}

/// Overwrite rows of a flat Float32 blob with zeros, in place. A dead row is
/// still an embedding of its image; forgetting the path alone isn't enough.
func zeroRows(_ rows: [Int], rowBytes: Int, in url: URL) {
    guard !rows.isEmpty, rowBytes > 0, let fh = try? FileHandle(forUpdating: url) else { return }
    defer { try? fh.close() }
    let size = (try? fh.seekToEnd()) ?? 0
    let zeros = Data(count: rowBytes)
    for row in rows where row >= 0 && UInt64((row + 1) * rowBytes) <= size {
        try? fh.seek(toOffset: UInt64(row * rowBytes))
        fh.write(zeros)
    }
    try? fh.synchronize()
}

/// Rewrite clip.bin without dead rows once they're more than a fifth of it.
func compactIfNeeded() {
    let liveRows = meta.images.values.filter { $0.row >= 0 }.count
    guard meta.rows > 200, meta.rows - liveRows > meta.rows / 5, meta.dim > 0,
          let data = try? Data(contentsOf: binURL) else { return }
    let rowBytes = meta.dim * 4
    var out = Data(capacity: liveRows * rowBytes)
    var next = 0
    for (path, rec) in meta.images.sorted(by: { $0.value.row < $1.value.row }) where rec.row >= 0 {
        let lo = rec.row * rowBytes
        guard lo + rowBytes <= data.count else { meta.images[path]?.row = -1; continue }
        out.append(data[lo..<lo + rowBytes])
        meta.images[path]?.row = next
        next += 1
    }
    guard (try? out.write(to: binURL, options: .atomic)) != nil else { return }
    meta.rows = next
    saveMeta()
}

// MARK: - Query

func search(_ text: String, textEncoder: ClipEncoder) -> [SearchHit] {
    guard meta.dim > 0, meta.rows > 0 else { return [] }
    let tokenizer = CLIPTokenizer(resourceDir: resourceDir)
    let tokens = tokenizer.encode_full(text: text)
    guard let arr = try? MLMultiArray(shape: [1, NSNumber(value: tokens.count)], dataType: .int32) else { return [] }
    for (i, t) in tokens.enumerated() { arr[i] = NSNumber(value: Int32(t)) }
    guard let provider = try? MLDictionaryFeatureProvider(dictionary: [textEncoder.inputName: arr]),
          let out = try? textEncoder.model.prediction(from: provider),
          let q = textEncoder.vector(from: out), q.count == meta.dim else { return [] }
    return rank(q, minScore: config.minScore, excluding: [])
}

/// Images like the given ones: their vectors (stored, or embedded now for a
/// file the index hasn't seen) averaged into one query.
func similar(to paths: [String], imageEncoder: () -> ClipEncoder?) -> [SearchHit] {
    guard meta.dim > 0, meta.rows > 0 else { return [] }
    var sum = [Float](repeating: 0, count: meta.dim)
    var used = 0
    var encoder: ClipEncoder?
    for path in paths {
        var vector = storedVector(path)
        if vector == nil {
            if encoder == nil {
                encoder = imageEncoder()
            }
            if let encoder, let cg = downsampledImage(path, maxPixel: config.decodeMaxPixel),
               let feature = imageFeature(cg, for: encoder),
               let provider = try? MLDictionaryFeatureProvider(dictionary: [encoder.inputName: feature]),
               let out = try? encoder.model.prediction(from: provider) {
                vector = encoder.vector(from: out)
            }
        }
        guard let vector, vector.count == meta.dim else { continue }
        vDSP_vadd(sum, 1, vector, 1, &sum, 1, vDSP_Length(meta.dim))
        used += 1
    }
    guard used > 0 else { return [] }
    normalize(&sum)
    return rank(sum, minScore: config.similarMinScore, excluding: Set(paths))
}

func storedVector(_ path: String) -> [Float]? {
    guard let row = meta.images[path]?.row, row >= 0,
          let fh = try? FileHandle(forReadingFrom: binURL) else { return nil }
    defer { try? fh.close() }
    let rowBytes = meta.dim * 4
    try? fh.seek(toOffset: UInt64(row * rowBytes))
    guard let data = try? fh.read(upToCount: rowBytes), data.count == rowBytes else { return nil }
    return data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
}

/// Cosine against every stored row (vectors are normalized), best first.
func rank(_ q: [Float], minScore: Double, excluding: Set<String>) -> [SearchHit] {
    guard let fh = try? FileHandle(forReadingFrom: binURL) else { return [] }
    defer { try? fh.close() }
    let size = Int(lseek(fh.fileDescriptor, 0, SEEK_END))
    guard size > 0, let raw = mmap(nil, size, PROT_READ, MAP_PRIVATE, fh.fileDescriptor, 0),
          raw != MAP_FAILED else { return [] }
    defer { munmap(raw, size) }
    let base = UnsafePointer(raw.assumingMemoryBound(to: Float.self))
    let dim = meta.dim
    let rowBytes = dim * 4

    var scored: [SearchHit] = []
    scored.reserveCapacity(meta.images.count)
    q.withUnsafeBufferPointer { qp in
        for (path, rec) in meta.images where rec.row >= 0 && (rec.row + 1) * rowBytes <= size
            && !excluding.contains(path) {
            var d: Float = 0
            vDSP_dotpr(qp.baseAddress!, 1, base.advanced(by: rec.row * dim), 1, &d, vDSP_Length(dim))
            if Double(d) >= minScore { scored.append(SearchHit(path: path, score: Double(d))) }
        }
    }
    scored.sort { $0.score > $1.score }
    return Array(scored.prefix(config.maxResults))
}

// MARK: - Near duplicates

let maxDuplicatePairs = 50_000

/// All pairs at or above the threshold, via blocked matrix products of the
/// stored (normalized) vectors. 20k images ≈ 200M dot products: a few seconds.
func duplicatePairs(_ q: DuplicatesQuery) -> [DuplicatePair] {
    guard meta.dim > 0, meta.rows > 0, let fh = try? FileHandle(forReadingFrom: binURL) else { return [] }
    defer { try? fh.close() }
    let size = Int(lseek(fh.fileDescriptor, 0, SEEK_END))
    guard size > 0, let raw = mmap(nil, size, PROT_READ, MAP_PRIVATE, fh.fileDescriptor, 0),
          raw != MAP_FAILED else { return [] }
    defer { munmap(raw, size) }
    let stored = UnsafePointer(raw.assumingMemoryBound(to: Float.self))
    let dim = meta.dim

    let wanted = q.paths.map(Set.init)
    let entries = meta.images
        .filter { $0.value.row >= 0 && ($0.value.row + 1) * dim * 4 <= size && wanted?.contains($0.key) != false }
        .sorted { $0.key < $1.key }
    let n = entries.count
    guard n > 1 else { return [] }
    var matrix = [Float](repeating: 0, count: n * dim)
    for (i, entry) in entries.enumerated() {
        matrix.withUnsafeMutableBufferPointer { m in
            m.baseAddress!.advanced(by: i * dim).update(from: stored.advanced(by: entry.value.row * dim), count: dim)
        }
    }

    let threshold = Float(q.threshold)
    let block = 512
    var pairs: [DuplicatePair] = []
    var scores = [Float](repeating: 0, count: block * block)
    let blocks = (n + block - 1) / block
    var done = 0
    let total = blocks * (blocks + 1) / 2
    matrix.withUnsafeBufferPointer { m in
        let base = m.baseAddress!
        outer: for bi in 0..<blocks {
            let i0 = bi * block, rows = min(block, n - i0)
            for bj in bi..<blocks {
                let j0 = bj * block, cols = min(block, n - j0)
                // scores (rows×cols) = A_i · A_jᵀ
                cblas_sgemm(CblasRowMajor, CblasNoTrans, CblasTrans, Int32(rows), Int32(cols), Int32(dim),
                            1, base.advanced(by: i0 * dim), Int32(dim),
                            base.advanced(by: j0 * dim), Int32(dim), 0, &scores, Int32(cols))
                for r in 0..<rows {
                    let start = bi == bj ? r + 1 : 0
                    for c in stride(from: start, to: cols, by: 1) where scores[r * cols + c] >= threshold {
                        pairs.append(DuplicatePair(a: entries[i0 + r].key, b: entries[j0 + c].key,
                                                   score: Double(scores[r * cols + c])))
                    }
                }
                done += 1
                if done % 20 == 0 {
                    stderrLine("Comparing images… \(done * 100 / total)%")
                }
                if pairs.count >= maxDuplicatePairs {
                    stderrLine("Stopped at \(maxDuplicatePairs) pairs; raise the threshold")
                    break outer
                }
            }
        }
    }
    return pairs.sorted { $0.score > $1.score }
}

// MARK: - Main

let input = FileHandle.standardInput.readDataToEndOfFile()
let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
guard let req = try? decoder.decode(SuggestRequest.self, from: input) else {
    stderrLine("overlap-clip: bad request JSON")
    exit(1)
}
applyHostSettings(req.settings)

let library = req.library ?? []
let query = req.query?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
let similarTo = req.similarTo ?? []
var hits: [SearchHit] = []
var pairs: [DuplicatePair]?
if let dup = req.duplicates {
    pairs = duplicatePairs(dup)   // read-only, like search: no lock (a warm-up may hold it for minutes)
}

if !library.isEmpty || !query.isEmpty || !similarTo.isEmpty {
    let spec = ModelSpec(variant: config.variant)
    if let reason = ensureModels(spec) {
        stderrLine("CLIP model unavailable: \(reason)")
    } else {
        if !library.isEmpty {
            if let enc = ClipEncoder.load(spec.compiled(spec.imageName), wantsImage: true) {
                withIndexLock {
                    syncIndex(items: library, encoder: enc) { done, total in
                        stderrLine("Indexing images for search… \(done)/\(total)")
                    }
                }
            } else {
                stderrLine("CLIP image encoder failed to load")
            }
        }
        if !query.isEmpty {
            if let enc = ClipEncoder.load(spec.compiled(spec.textName), wantsImage: false) {
                hits = search(query, textEncoder: enc)
            } else {
                stderrLine("CLIP text encoder failed to load")
            }
        } else if !similarTo.isEmpty {
            hits = similar(to: similarTo) {
                ClipEncoder.load(spec.compiled(spec.imageName), wantsImage: true)
            }
        }
    }
}

let resp = SuggestResponse(protocolVersion: 1, suggestions: [], hits: hits, indexedCount: liveCount,
                           pairs: pairs)
let encoder = JSONEncoder()
FileHandle.standardOutput.write((try? encoder.encode(resp))
    ?? Data("{\"protocolVersion\":1,\"suggestions\":[],\"hits\":[],\"indexedCount\":0}".utf8))
