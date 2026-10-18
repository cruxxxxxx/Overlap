import SwiftUI
import WebKit

extension OriginRecord {
    var sourceLink: URL? { source.flatMap(URL.init(string:)) }

    var openLabel: String { embed != nil ? "Open Video" : "Open Link" }
}

/// Plays a service's embedded player (an iframe) in the preview pane. Kept
/// isolated: no cookies or storage persist, and any link that would leave the
/// player opens in the default browser instead.
struct EmbedPlayer: NSViewRepresentable {
    let html: String
    /// The page the player is embedded from, sent as its referrer.
    let pageURL: URL?

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.mediaTypesRequiringUserActionForPlayback = .all
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.navigationDelegate = context.coordinator
        view.uiDelegate = context.coordinator
        view.setValue(false, forKey: "drawsBackground")
        load(into: view)
        return view
    }

    func updateNSView(_ view: WKWebView, context: Context) {
        if context.coordinator.loadedHTML != html {
            load(into: view)
        }
    }

    private func load(into view: WKWebView) {
        (view.navigationDelegate as? Coordinator)?.loadedHTML = html
        guard let player = Self.playerURL(in: html) else {
            view.loadHTMLString("", baseURL: nil)
            return
        }
        // Only the player's address is kept from the service's HTML: the page
        // is ours, with no script of its own, and the frame is sandboxed.
        let page = """
        <!doctype html><html><head>
        <meta http-equiv="Content-Security-Policy" content="default-src 'none'; style-src 'unsafe-inline'; frame-src https:">
        <style>html,body{margin:0;height:100%;background:transparent;overflow:hidden}
        iframe{position:absolute;inset:0;width:100%;height:100%;border:0}</style>
        </head><body><iframe src="\(player.absoluteString.htmlEscaped)"
        sandbox="allow-scripts allow-same-origin allow-presentation allow-popups"
        allow="fullscreen; encrypted-media; picture-in-picture" allowfullscreen></iframe></body></html>
        """
        let base = pageURL.flatMap { URL(string: "/", relativeTo: $0)?.absoluteURL }
        view.loadHTMLString(page, baseURL: base)
    }

    /// The first iframe's `src`, when it's an https address.
    static func playerURL(in html: String) -> URL? {
        guard let iframe = html.range(of: "<iframe", options: .caseInsensitive),
              let srcRange = html.range(of: #"src\s*=\s*["']([^"']+)["']"#, options: .regularExpression,
                                        range: iframe.upperBound..<html.endIndex) else {
            return nil
        }
        let attribute = String(html[srcRange])
        guard let open = attribute.firstIndex(where: { $0 == "\"" || $0 == "'" }) else {
            return nil
        }
        let value = attribute[attribute.index(after: open)..<attribute.index(before: attribute.endIndex)]
            .replacingOccurrences(of: "&amp;", with: "&")
        guard let url = URL(string: value), url.scheme?.lowercased() == "https" else {
            return nil
        }
        return url
    }

    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
        var loadedHTML: String?

        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                     decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            // The player's own frames load freely; a click that would replace
            // the whole pane goes to the browser.
            if action.targetFrame?.isMainFrame == true, action.navigationType == .linkActivated,
               let url = action.request.url {
                NSWorkspace.shared.open(url)
                decisionHandler(.cancel)
                return
            }
            decisionHandler(.allow)
        }

        func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                     for action: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
            if let url = action.request.url {
                NSWorkspace.shared.open(url)
            }
            return nil
        }
    }
}

private extension String {
    var htmlEscaped: String {
        replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }
}
