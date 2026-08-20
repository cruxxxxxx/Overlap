import SwiftUI
import Quartz

/// NSView that lives in the responder chain, captures the space bar to toggle
/// Quick Look, and serves the current selection to the shared preview panel.
final class QLKeyView: NSView, QLPreviewPanelDataSource, QLPreviewPanelDelegate {
    var urls: [URL] = []

    override var acceptsFirstResponder: Bool { true }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 49 { // space
            togglePanel()
        } else {
            super.keyDown(with: event)
        }
    }

    func togglePanel() {
        guard let panel = QLPreviewPanel.shared() else { return }
        if QLPreviewPanel.sharedPreviewPanelExists() && panel.isVisible {
            panel.orderOut(nil)
        } else {
            panel.makeKeyAndOrderFront(nil)
        }
    }

    // Responder chain hooks (informal QLPreviewPanelController protocol)
    override func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool { true }
    override func beginPreviewPanelControl(_ panel: QLPreviewPanel!) {
        panel.dataSource = self
        panel.delegate = self
    }
    override func endPreviewPanelControl(_ panel: QLPreviewPanel!) {}

    // Data source
    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int { urls.count }
    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> QLPreviewItem! {
        urls[index] as NSURL
    }
}

/// Bridges the QLKeyView into SwiftUI. Keeps its URL list in sync with the
/// current selection and grabs first-responder so the space bar works.
struct QuickLookCapture: NSViewRepresentable {
    var urls: [URL]

    func makeNSView(context: Context) -> QLKeyView {
        let v = QLKeyView()
        DispatchQueue.main.async { v.window?.makeFirstResponder(v) }
        return v
    }

    func updateNSView(_ nsView: QLKeyView, context: Context) {
        nsView.urls = urls
        if let panel = QLPreviewPanel.sharedPreviewPanelExists()
            ? QLPreviewPanel.shared() : nil, panel.isVisible {
            panel.reloadData()
        }
    }
}
