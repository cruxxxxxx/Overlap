import Foundation

/// Where a file came from on an external service, written on the file itself
/// (extended attribute `com.overlap.origin`) so it survives moves, renames and
/// the vault, and no index has to remember it. A file can belong to several
/// remote collections, so the attribute holds a list.
struct OriginRecord: Codable, Hashable {
    let plugin: String
    let remoteId: String
    let collection: String
    var url: String? = nil
    var updatedAt: Date? = nil
}

enum FileOrigin {
    private static let attribute = "com.overlap.origin"
    private static let whereFroms = "com.apple.metadata:kMDItemWhereFroms"

    static func records(of url: URL) -> [OriginRecord] {
        guard let data = readAttribute(attribute, of: url) else {
            return []
        }
        return (try? PluginCoder.decoder.decode([OriginRecord].self, from: data)) ?? []
    }

    /// The remote id this file has on `plugin`, from any collection.
    static func remoteId(of url: URL, plugin: String) -> String? {
        records(of: url).first { $0.plugin == plugin }?.remoteId
    }

    /// Add (or refresh) one record. Same plugin + collection replaces the old one.
    static func add(_ record: OriginRecord, to url: URL) {
        var all = records(of: url).filter {
            !($0.plugin == record.plugin && $0.collection == record.collection)
        }
        all.append(record)
        if let data = try? PluginCoder.encoder.encode(all) {
            writeAttribute(attribute, data: data, to: url)
        }
    }

    /// Finder's "Where from". Only set when the file has none, so a browser's
    /// original download URL is never replaced.
    static func setWhereFrom(_ links: [String], on url: URL) {
        let links = links.filter { !$0.isEmpty }
        guard !links.isEmpty, readAttribute(whereFroms, of: url) == nil,
              let data = try? PropertyListSerialization.data(fromPropertyList: links,
                                                             format: .binary, options: 0) else {
            return
        }
        writeAttribute(whereFroms, data: data, to: url)
    }

    private static func readAttribute(_ name: String, of url: URL) -> Data? {
        url.withUnsafeFileSystemRepresentation { path -> Data? in
            guard let path else {
                return nil
            }
            let size = getxattr(path, name, nil, 0, 0, 0)
            guard size > 0 else {
                return nil
            }
            var data = Data(count: size)
            let read = data.withUnsafeMutableBytes { getxattr(path, name, $0.baseAddress, size, 0, 0) }
            return read == size ? data : nil
        }
    }

    private static func writeAttribute(_ name: String, data: Data, to url: URL) {
        url.withUnsafeFileSystemRepresentation { path in
            guard let path else {
                return
            }
            _ = data.withUnsafeBytes { setxattr(path, name, $0.baseAddress, data.count, 0, 0) }
        }
    }
}
