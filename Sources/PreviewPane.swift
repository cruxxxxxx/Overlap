import SwiftUI

/// Large live preview of the selected file plus quick insights. The big view
/// and the type-specific info rows come from a `FilePreviewer` (image, video,
/// or the QuickLook catch-all), chosen per selection.
struct PreviewPane: View {
    let item: FileItem?
    @State private var typeRows: [(String, String)] = []

    var body: some View {
        Group {
            if let item {
                let provider = FilePreviewRegistry.provider(for: item)
                VStack(spacing: 8) {
                    provider.preview(item)
                        .id(item.id)   // recreate so the preview follows selection
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    infoPanel(item)
                }
                .padding(10)
                .task(id: item.id) { typeRows = await provider.info(item) }
            } else {
                VStack(spacing: 8) {
                    Image(systemName: "doc").font(.system(size: 40)).foregroundStyle(.tertiary)
                    Text("Select a file").foregroundStyle(.secondary)
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
                stat("Type", item.ext.isEmpty ? item.kind.label : item.ext.uppercased())
                if let bytes = item.size {
                    stat("File Size", ByteCountFormatter.string(
                        fromByteCount: bytes, countStyle: .file))
                }
            }
            if let d = item.modDate {
                Text("Modified \(d.formatted(date: .abbreviated, time: .shortened))")
                    .font(.caption2).foregroundStyle(.tertiary)
            }
            if !typeRows.isEmpty {
                Divider().padding(.horizontal, 40)
                VStack(spacing: 2) {
                    ForEach(typeRows, id: \.0) { row in
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
}
