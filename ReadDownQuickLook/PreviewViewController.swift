import Cocoa
import QuickLookUI
import WebKit

class PreviewViewController: NSViewController, QLPreviewingController, WKNavigationDelegate {

    private var webView: WKWebView!

    override func loadView() {
        let config = WKWebViewConfiguration()
        config.preferences.isElementFullscreenEnabled = false
        let pagePrefs = WKWebpagePreferences()
        pagePrefs.allowsContentJavaScript = true
        config.defaultWebpagePreferences = pagePrefs

        webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = self
        // Readdown previews are always dark, like the main app. The extension
        // runs in its own process with no app delegate, and the template's dark
        // palette comes from `prefers-color-scheme` — which WebKit resolves from
        // the view's appearance — so pin the appearance on the web view itself.
        webView.appearance = NSAppearance(named: .darkAqua)
        // Do NOT use `setValue(false, forKey: "drawsBackground")` here — that is a
        // private, undocumented KVC key on WKWebView. If a macOS release removes or
        // renames it, `setValue` throws NSUnknownKeyException inside loadView(),
        // which Swift can't catch — the extension crashes before producing a view
        // and Quick Look shows an endless spinner (GitHub issue #5). The HTML
        // template paints its own opaque background and carries a `color-scheme`
        // meta tag, so no background manipulation is needed — the main app's
        // WebView renders the same content without it.
        self.view = webView
    }

    func webView(_ webView: WKWebView,
                 decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        if navigationAction.navigationType == .linkActivated {
            decisionHandler(.cancel)
            return
        }
        decisionHandler(.allow)
    }

    func preparePreviewOfFile(at url: URL, completionHandler handler: @escaping (Error?) -> Void) {
        do {
            let markdown = try TextFileDecoder.decode(Data(contentsOf: url))
            let result = MarkdownRenderer.render(markdown)
            let html = HTMLTemplate.wrap(body: result.html, hasMermaid: result.hasMermaid, hasMath: result.hasMath, compact: true, isDark: true)
            webView.loadHTMLString(html, baseURL: url.deletingLastPathComponent())
            handler(nil)
        } catch {
            handler(error)
        }
    }
}
