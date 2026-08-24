import SwiftUI

/// The coach-mark layer: dims everything except the spotlight rect (four
/// hittable bands leave a real hole so the live control underneath stays
/// clickable), rings it, and shows a callout with step controls. The rect is
/// resolved from the target control's own frame anchor, so it's exact.
struct TutorialOverlay: View {
    @ObservedObject var tutorial: TutorialModel
    @EnvironmentObject var store: TagStore
    let size: CGSize
    let targetRect: CGRect?

    private var step: TutorialStep { tutorial.current }
    private let calloutWidth: CGFloat = 330
    private let calloutEstHeight: CGFloat = 200

    var body: some View {
        ZStack {
            if let r = targetRect {
                dimBands(around: r.insetBy(dx: -6, dy: -6))
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(Color.accentColor, lineWidth: 3)
                    .frame(width: r.width + 12, height: r.height + 12)
                    .position(x: r.midX, y: r.midY)
                    .shadow(color: .accentColor.opacity(0.6), radius: 8)
                    .allowsHitTesting(false)
            } else {
                Color.black.opacity(0.62)
            }
            callout
                .frame(width: calloutWidth)
                .fixedSize(horizontal: false, vertical: true)
                .position(calloutCenter)
        }
        .animation(.easeInOut(duration: 0.18), value: tutorial.index)
    }

    // MARK: Callout placement

    private var calloutCenter: CGPoint {
        guard let r = targetRect else {
            return CGPoint(x: size.width / 2, y: size.height / 2)
        }
        let w = calloutWidth, h = calloutEstHeight, gap: CGFloat = 18
        var cx = r.midX
        var cy: CGFloat
        if r.height > size.height * 0.5 {
            // Tall target (e.g. the sidebar list) → place beside it.
            cx = r.maxX + gap + w / 2
            cy = r.minY + h / 2
        } else if r.maxY + gap + h < size.height {
            cy = r.maxY + gap + h / 2          // below
        } else {
            cy = r.minY - gap - h / 2          // above
        }
        return CGPoint(x: min(max(cx, w / 2 + 10), size.width - w / 2 - 10),
                       y: min(max(cy, h / 2 + 10), size.height - h / 2 - 10))
    }

    /// Four dimmed, hittable rectangles surrounding the hole.
    @ViewBuilder
    private func dimBands(around r: CGRect) -> some View {
        let dim = Color.black.opacity(0.55)
        band(dim, CGRect(x: 0, y: 0, width: size.width, height: max(0, r.minY)))
        band(dim, CGRect(x: 0, y: r.maxY, width: size.width, height: max(0, size.height - r.maxY)))
        band(dim, CGRect(x: 0, y: r.minY, width: max(0, r.minX), height: r.height))
        band(dim, CGRect(x: r.maxX, y: r.minY, width: max(0, size.width - r.maxX), height: r.height))
    }

    private func band(_ color: Color, _ rect: CGRect) -> some View {
        color
            .frame(width: max(0, rect.width), height: max(0, rect.height))
            .position(x: rect.midX, y: rect.midY)
    }

    // MARK: Callout

    private var callout: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(tutorial.progress)
                .font(.caption2).foregroundStyle(.secondary)
            Text(step.title).font(.headline)
            Text(step.body).font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if step.kind == .action && !step.isDone(store) {
                Label("Do this to continue", systemImage: "hand.point.up.left")
                    .font(.caption).foregroundStyle(.tertiary)
            }

            Divider()
            controls
        }
        .padding(16)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.quaternary))
        .shadow(radius: 16, y: 4)
    }

    @ViewBuilder
    private var controls: some View {
        if tutorial.isLast {
            HStack {
                Button("Back") { tutorial.back(store) }
                Spacer()
                Button("Done") { tutorial.finish(store) }
                    .keyboardShortcut(.defaultAction)
            }
        } else {
            HStack(spacing: 8) {
                if tutorial.index > 0 {
                    Button("Back") { tutorial.back(store) }
                }
                Button("Skip tutorial") { tutorial.skip(store) }
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Next") { tutorial.next(store) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(step.kind == .action && !step.isDone(store))
            }
        }
    }
}
