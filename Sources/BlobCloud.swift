import SwiftUI

/// One node to render as a blob.
struct BlobItem: Identifiable, Equatable {
    let id: String
    let label: String
    var sublabel: String = ""      // e.g. group prefix ("type", "clothing")
    let count: Int
    let color: Color
    let drill: Bool
}

/// Stable tag colors from the top-level prefix (a whole group shares a hue).
enum TagPalette {
    static let colors: [Color] =
        [.blue, .purple, .pink, .orange, .green, .teal, .indigo, .mint, .red, .cyan]
    static func color(for path: String) -> Color {
        let key = path.split(separator: "/").first.map(String.init) ?? path
        var h = 5381
        for u in key.unicodeScalars { h = ((h << 5) &+ h) &+ Int(u.value) }
        return colors[abs(h) % colors.count]
    }
}

private struct PhysBlob: Identifiable {
    let id: String
    var item: BlobItem
    var pos: CGPoint
    var vel: CGVector
    var radius: CGFloat
    var phase: Double
    var squash: CGFloat
}

/// A juicy, physics-driven cloud of blobs sized by count. Blobs float, repel,
/// cluster toward center, spring in/out as the item set changes.
struct BlobCloud: View {
    let items: [BlobItem]
    var onTap: (BlobItem) -> Void

    @State private var blobs: [PhysBlob] = []
    @State private var canvas: CGSize = .init(width: 400, height: 500)
    @State private var time: Double = 0

    private let timer = Timer.publish(every: 1.0 / 60.0, on: .main, in: .common).autoconnect()
    private let dt: CGFloat = 1.0 / 60.0
    private var idSig: String { items.map(\.id).joined(separator: "|") }

    var body: some View {
        GeometryReader { geo in
            ZStack {
                ForEach(blobs) { b in
                    blobView(b)
                        .position(b.pos)
                        .transition(.scale.combined(with: .opacity))
                }
                if items.isEmpty {
                    Text("Nothing here").foregroundStyle(.tertiary)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
            .onAppear { canvas = geo.size; sync() }
            .onChange(of: geo.size) { canvas = $0 }
            .onChange(of: idSig) { _ in sync() }
            .onReceive(timer) { _ in step() }
            .animation(.spring(response: 0.5, dampingFraction: 0.65), value: idSig)
        }
    }

    private func blobView(_ b: PhysBlob) -> some View {
        let r = b.radius
        let color = b.item.color
        return ZStack {
            Circle()
                .fill(RadialGradient(
                    colors: [color.opacity(0.95), color.opacity(0.55)],
                    center: .init(x: 0.35, y: 0.3), startRadius: 2, endRadius: r * 1.4))
                .overlay(Circle().stroke(.white.opacity(0.25), lineWidth: 1))
                .overlay(Circle().fill(.white.opacity(0.35))
                    .frame(width: r * 0.34, height: r * 0.34)
                    .offset(x: -r * 0.32, y: -r * 0.34).blur(radius: 2))
                .shadow(color: color.opacity(0.35), radius: 5, y: 3)
            if r > 20 {
                VStack(spacing: 0) {
                    if !b.item.sublabel.isEmpty && r > 30 {
                        Text(b.item.sublabel.uppercased())
                            .font(.system(size: max(7, r * 0.17), weight: .bold))
                            .opacity(0.7).tracking(0.5)
                    }
                    Text(b.item.label)
                        .font(.system(size: max(9, r * 0.3), weight: .semibold))
                        .lineLimit(1).minimumScaleFactor(0.55)
                    if r > 32 {
                        Text("\(b.item.count)").font(.system(size: max(8, r * 0.22))).opacity(0.85)
                    }
                }
                .foregroundStyle(.white).frame(width: r * 1.7).shadow(radius: 1)
            }
            if b.item.drill {
                Image(systemName: "chevron.down.circle.fill")
                    .font(.system(size: max(9, r * 0.22)))
                    .foregroundStyle(.white.opacity(0.85))
                    .offset(y: r - r * 0.28)
            }
        }
        .frame(width: r * 2, height: r * 2)
        .scaleEffect(b.squash)
        .contentShape(Circle())
        // A drag gesture stays bound to the blob even as it drifts, so the
        // click still registers on a moving target (onTapGesture would miss).
        .gesture(DragGesture(minimumDistance: 0).onEnded { _ in tap(b) })
    }

    private func tap(_ b: PhysBlob) {
        if let i = blobs.firstIndex(where: { $0.id == b.id }) {
            withAnimation(.spring(response: 0.2, dampingFraction: 0.4)) { blobs[i].squash = 0.85 }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
                if let j = blobs.firstIndex(where: { $0.id == b.id }) {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.5)) { blobs[j].squash = 1 }
                }
            }
        }
        onTap(b.item)
    }

    private func sync() {
        let maxC = max(1, items.map { $0.count }.max() ?? 1)
        let existing = Dictionary(blobs.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let c = CGPoint(x: canvas.width / 2, y: canvas.height / 2)
        blobs = items.enumerated().map { i, it in
            let frac = sqrt(CGFloat(it.count) / CGFloat(maxC))
            let r = 20 + frac * 48
            if var b = existing[it.id] { b.radius = r; b.item = it; return b }
            // Spread new blobs on a golden-angle spiral so a widening level
            // doesn't stack them all at the center.
            let ang = Double(i) * 2.399963
            let spread = 30 + CGFloat(i % 8) * 26
            return PhysBlob(id: it.id, item: it,
                            pos: CGPoint(x: c.x + CGFloat(cos(ang)) * spread,
                                         y: c.y + CGFloat(sin(ang)) * spread),
                            vel: .zero, radius: r, phase: Double(i) * 0.6, squash: 1)
        }
    }

    private func step() {
        guard !blobs.isEmpty else { return }
        let center = CGPoint(x: canvas.width / 2, y: canvas.height / 2)
        for i in blobs.indices {
            var fx: CGFloat = (center.x - blobs[i].pos.x) * 0.45
            var fy: CGFloat = (center.y - blobs[i].pos.y) * 0.45
            for j in blobs.indices where j != i {
                let dx = blobs[i].pos.x - blobs[j].pos.x
                let dy = blobs[i].pos.y - blobs[j].pos.y
                var dist = sqrt(dx * dx + dy * dy)
                if dist < 0.01 { dist = 0.01 }
                let minDist = blobs[i].radius + blobs[j].radius + 7
                if dist < minDist {
                    let push = (minDist - dist) * 5.5
                    fx += dx / dist * push
                    fy += dy / dist * push
                }
            }
            fx += CGFloat(sin(time + blobs[i].phase)) * 1.4
            fy += CGFloat(cos(time * 1.1 + blobs[i].phase)) * 1.4
            blobs[i].vel.dx = (blobs[i].vel.dx + fx * dt) * 0.82
            blobs[i].vel.dy = (blobs[i].vel.dy + fy * dt) * 0.82
            blobs[i].pos.x += blobs[i].vel.dx * dt
            blobs[i].pos.y += blobs[i].vel.dy * dt
            let r = blobs[i].radius
            blobs[i].pos.x = min(max(blobs[i].pos.x, r), max(r, canvas.width - r))
            blobs[i].pos.y = min(max(blobs[i].pos.y, r), max(r, canvas.height - r))
        }
        time += Double(dt)
    }
}
