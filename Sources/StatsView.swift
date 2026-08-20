import SwiftUI

/// A snapshot of the library: totals, type breakdown, and top tags.
struct StatsView: View {
    @EnvironmentObject var store: TagStore
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let s = store.libraryStats()
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Library Stats").font(.title2).bold()
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }

            HStack(spacing: 24) {
                metric("\(s.total)", "Files")
                metric(ByteCountFormatter.string(fromByteCount: s.totalSize, countStyle: .file), "Total Size")
                metric("\(s.tagCount)", "Tags")
                metric("\(s.untagged)", "Untagged")
            }

            HStack(alignment: .top, spacing: 28) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("By Type").font(.headline)
                    ForEach(s.byType.prefix(10), id: \.0) { row in
                        bar(label: row.0.uppercased(), value: row.1, max: s.byType.first?.1 ?? 1)
                    }
                }
                VStack(alignment: .leading, spacing: 6) {
                    Text("Top Tags").font(.headline)
                    ForEach(s.topTags, id: \.0) { row in
                        bar(label: row.0, value: row.1, max: s.topTags.first?.1 ?? 1)
                    }
                }
            }

            if let big = s.largest {
                Text("Largest: \(big.name) — \(ByteCountFormatter.string(fromByteCount: big.size ?? 0, countStyle: .file))")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(24)
        .frame(width: 560, height: 520)
    }

    private func metric(_ value: String, _ label: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value).font(.title3).bold().monospacedDigit()
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
    }

    private func bar(label: String, value: Int, max: Int) -> some View {
        HStack(spacing: 8) {
            Text(label).font(.caption).frame(width: 130, alignment: .leading)
                .lineLimit(1).truncationMode(.middle)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.accentColor.opacity(0.15))
                    Capsule().fill(Color.accentColor)
                        .frame(width: geo.size.width * CGFloat(value) / CGFloat(Swift.max(max, 1)))
                }
            }
            .frame(height: 12)
            Text("\(value)").font(.caption).monospacedDigit()
                .frame(width: 44, alignment: .trailing)
        }
    }
}
