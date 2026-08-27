import SwiftUI

/// Auto-advancing preview over the current results — any file type, rendered by
/// the same `FilePreviewer` registry as the preview pane. Arrow keys step
/// (which also restarts the timer), Esc closes. Two options: seconds per item
/// and shuffle.
struct SlideshowView: View {
    @EnvironmentObject var store: TagStore
    @Environment(\.dismiss) private var dismiss

    let items: [FileItem]
    let startAt: Int

    @AppStorage("slideshowInterval") private var interval: Double = 4
    @AppStorage("slideshowShuffle") private var shuffle = false
    @State private var order: [Int] = []
    @State private var pos = 0

    private var current: FileItem? {
        order.indices.contains(pos) ? items[order[pos]] : nil
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if let item = current {
                FilePreviewRegistry.provider(for: item).preview(item)
                    .id(item.id)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(24)
            }

            VStack {
                controls
                Spacer()
            }
            hotkeys
        }
        .frame(minWidth: 700, minHeight: 500)
        .onAppear { buildOrder(start: startAt) }
        .onChange(of: shuffle) { _ in buildOrder(start: 0) }
        .task(id: "\(interval)-\(pos)-\(order.count)") {
            guard order.count > 1 else { return }
            try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
            if !Task.isCancelled { advance(1) }
        }
    }

    private func buildOrder(start: Int) {
        let all = Array(items.indices)
        if shuffle {
            order = all.shuffled()
            pos = 0
        } else {
            order = all
            pos = max(0, min(start, items.count - 1))
        }
    }

    private func advance(_ by: Int) {
        guard order.count > 1 else { return }
        pos = (pos + by + order.count) % order.count
    }

    private var controls: some View {
        HStack(spacing: 12) {
            Spacer()
            Button { shuffle.toggle() } label: {
                Image(systemName: shuffle ? "shuffle.circle.fill" : "shuffle")
            }
            .help("Shuffle")
            Menu {
                ForEach([2.0, 3, 4, 6, 10], id: \.self) { s in
                    Button {
                        interval = s
                    } label: {
                        HStack { Text("\(Int(s))s"); if interval == s { Image(systemName: "checkmark") } }
                    }
                }
            } label: {
                Label("\(Int(interval))s", systemImage: "timer")
            }
            .menuStyle(.borderlessButton).fixedSize()
            .help("Seconds per item")
            Button { dismiss() } label: { Image(systemName: "xmark") }
                .help("Close (Esc)")
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 14).padding(.vertical, 8)
        .background(.ultraThinMaterial, in: Capsule())
        .padding(12)
    }

    /// Invisible buttons carrying the keyboard shortcuts.
    private var hotkeys: some View {
        ZStack {
            Button("") { advance(-1) }.keyboardShortcut(.leftArrow, modifiers: [])
            Button("") { advance(1) }.keyboardShortcut(.rightArrow, modifiers: [])
            Button("") { dismiss() }.keyboardShortcut(.cancelAction)
        }
        .opacity(0)
    }
}
