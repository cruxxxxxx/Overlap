import SwiftUI

/// Detail-pane cluster browser: the tag tree as juicy blobs. Tap a parent to
/// drill into its subtags; tap a leaf to jump to its images in the grid.
struct ClusterView: View {
    @EnvironmentObject var store: TagStore
    @State private var stack: [TagNode] = []

    private var current: [TagNode] { stack.last?.children ?? store.tagTree }

    private var items: [BlobItem] {
        current.map {
            BlobItem(id: $0.fullPath, label: $0.name, count: $0.count,
                     color: TagPalette.color(for: $0.fullPath), drill: !$0.children.isEmpty)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            breadcrumb
            Divider()
            BlobCloud(items: items) { tapped(id: $0.id) }
                .id(items.map(\.id).joined(separator: "|"))
                .background(Color(nsColor: .underPageBackgroundColor))
        }
    }

    private var breadcrumb: some View {
        HStack(spacing: 6) {
            crumb("All", active: stack.isEmpty) { stack = [] }
            ForEach(Array(stack.enumerated()), id: \.element.id) { idx, node in
                Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary)
                crumb(node.name, active: idx == stack.count - 1) { stack = Array(stack.prefix(idx + 1)) }
            }
            Spacer()
            Text("\(current.count) tags").font(.caption).foregroundStyle(.secondary)
        }
        .padding(8)
    }

    private func crumb(_ label: String, active: Bool, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label).font(.callout).fontWeight(active ? .semibold : .regular)
                .foregroundStyle(active ? Color.primary : Color.secondary)
        }
        .buttonStyle(.plain)
    }

    private func tapped(id: String) {
        guard let node = current.first(where: { $0.fullPath == id }) else { return }
        if node.children.isEmpty {
            store.focusTag(node.fullPath)
        } else {
            stack.append(node)
        }
    }
}
