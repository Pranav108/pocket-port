import SwiftUI
import WebKit

struct LocalHTMLPreview: View {
    let data: Data
    @State private var loaded = false
    @State private var failed = false

    var body: some View {
        if failed {
            ContentUnavailableView("Couldn’t preview this HTML file", systemImage: "doc.badge.exclamationmark")
        } else {
            HTMLWebView(data: data) { success in
                loaded = success
                failed = !success
            }
            .overlay {
                if !loaded { ProgressView("Opening HTML") }
            }
        }
    }
}

private struct HTMLWebView: UIViewRepresentable {
    let data: Data
    let onLoad: (Bool) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onLoad: onLoad) }

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        configuration.setURLSchemeHandler(HTMLDocument(data: data), forURLScheme: HTMLDocument.scheme)

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.load(URLRequest(url: HTMLDocument.url))
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {}

    static func dismantleUIView(_ webView: WKWebView, coordinator: Coordinator) {
        webView.navigationDelegate = nil
        webView.stopLoading()
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        let onLoad: (Bool) -> Void
        private var started = false

        init(onLoad: @escaping (Bool) -> Void) {
            self.onLoad = onLoad
        }

        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                     decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            guard action.targetFrame?.isMainFrame == true,
                  let url = action.request.url else {
                decisionHandler(.cancel)
                return
            }
            if !started, url == HTMLDocument.url {
                started = true
                decisionHandler(.allow)
            } else if action.navigationType == .linkActivated, url.fragment != nil,
                      url.absoluteString.hasPrefix(HTMLDocument.url.absoluteString + "#") {
                decisionHandler(.allow)
            } else {
                decisionHandler(.cancel)
            }
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            onLoad(true)
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            if (error as? URLError)?.code != .cancelled { onLoad(false) }
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            if (error as? URLError)?.code != .cancelled { onLoad(false) }
        }

        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
            onLoad(false)
        }
    }
}

private final class HTMLDocument: NSObject, WKURLSchemeHandler {
    static let scheme = "pocketport-html"
    static let url = URL(string: "\(scheme)://document/index.html")!
    private let data: Data

    init(data: Data) {
        self.data = data
    }

    func webView(_ webView: WKWebView, start task: WKURLSchemeTask) {
        // The renderer can fetch this document only. Its stored file URL never crosses into WebKit.
        guard task.request.url == Self.url,
              let response = HTTPURLResponse(url: Self.url, statusCode: 200, httpVersion: "HTTP/1.1",
                headerFields: [
                    "Content-Type": "text/html; charset=utf-8",
                    "Content-Security-Policy": "default-src 'none'; style-src 'unsafe-inline'; img-src data:; font-src data:; base-uri 'none'; form-action 'none'; sandbox",
                    "X-DNS-Prefetch-Control": "off"
                ]) else {
            task.didFailWithError(URLError(.resourceUnavailable))
            return
        }
        task.didReceive(response)
        task.didReceive(data)
        task.didFinish()
    }

    func webView(_ webView: WKWebView, stop task: WKURLSchemeTask) {}
}
