import SwiftUI
import WebKit

struct MermaidDiagramView: View {
    let blockID: Int
    let source: String
    @Environment(\.colorScheme) private var colorScheme

    private struct Identity: Hashable {
        let blockID: Int
        let colorScheme: ColorScheme
    }

    var body: some View {
        MermaidDiagramCard(source: source, dark: colorScheme == .dark)
            .id(Identity(blockID: blockID, colorScheme: colorScheme))
    }
}

private struct MermaidDiagramCard: View {
    let source: String
    let dark: Bool
    @State private var phase = Phase.loading

    private enum Phase {
        case loading
        case ready(CGFloat)
        case failed
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if source.utf8.count > 50_000 {
                Text("This Mermaid diagram is too large to render.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                MarkdownCodeBlock(source: source)
            } else if case .failed = phase {
                Text("Couldn’t render this Mermaid diagram.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                MarkdownCodeBlock(source: source)
            } else {
                diagram
                    .task {
                        try? await Task.sleep(for: .seconds(12))
                        if !Task.isCancelled, case .loading = phase { phase = .failed }
                    }
                DisclosureGroup("Diagram source") {
                    MarkdownCodeBlock(source: source)
                }
                .font(.footnote)
            }
        }
    }

    private var diagram: some View {
        let height: CGFloat
        let isLoading: Bool
        switch phase {
        case .ready(let renderedHeight):
            height = min(max(renderedHeight, 100), 640)
            isLoading = false
        default:
            height = 112
            isLoading = true
        }

        return MermaidWebView(source: source, dark: dark) { size in
            phase = size.map(Phase.ready) ?? .failed
        }
        .frame(height: height)
        .opacity(isLoading ? 0 : 1)
        .accessibilityHidden(isLoading)
        .accessibilityIdentifier("mermaid-diagram")
        .overlay {
            if isLoading { ProgressView("Rendering diagram") }
        }
        .background(.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

private struct MermaidWebView: UIViewRepresentable {
    private static let dataStore = WKWebsiteDataStore.nonPersistent()

    let source: String
    let dark: Bool
    let onRender: (CGFloat?) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(source: source, dark: dark, onRender: onRender)
    }

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = Self.dataStore
        configuration.setURLSchemeHandler(MermaidResources(), forURLScheme: MermaidResources.scheme)

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.isOpaque = false
        webView.backgroundColor = .clear
        webView.scrollView.backgroundColor = .clear
        webView.scrollView.contentInsetAdjustmentBehavior = .never
        webView.navigationDelegate = context.coordinator
        webView.load(URLRequest(url: MermaidResources.page))
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {}

    static func dismantleUIView(_ webView: WKWebView, coordinator: Coordinator) {
        coordinator.active = false
        webView.navigationDelegate = nil
        webView.stopLoading()
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        let source: String
        let dark: Bool
        let onRender: (CGFloat?) -> Void
        var active = true

        init(source: String, dark: Bool, onRender: @escaping (CGFloat?) -> Void) {
            self.source = source
            self.dark = dark
            self.onRender = onRender
        }

        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                     decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            decisionHandler(action.targetFrame?.isMainFrame == true &&
                            action.request.url == MermaidResources.page ? .allow : .cancel)
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            webView.callAsyncJavaScript("return await renderDiagram(source, dark);",
                arguments: ["source": source, "dark": dark], in: nil, in: .page) { [weak self] result in
                guard let self, self.active else { return }
                let height = (try? result.get() as? NSNumber)?.doubleValue
                guard let height, height.isFinite, height > 0 else {
                    self.onRender(nil)
                    return
                }
                self.onRender(CGFloat(height))
            }
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            if active { onRender(nil) }
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            if active { onRender(nil) }
        }

        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
            if active { onRender(nil) }
        }
    }
}

private final class MermaidResources: NSObject, WKURLSchemeHandler {
    static let scheme = "pocketport-mermaid"
    static let page = URL(string: "\(scheme)://local/index.html")!

    func webView(_ webView: WKWebView, start task: WKURLSchemeTask) {
        guard let url = task.request.url, url.host == Self.page.host,
              let asset = Self.assets[url.path] else {
            task.didFailWithError(URLError(.resourceUnavailable))
            return
        }

        let response = URLResponse(url: url, mimeType: asset.type,
                                   expectedContentLength: asset.data.count, textEncodingName: "utf-8")
        task.didReceive(response)
        task.didReceive(asset.data)
        task.didFinish()
    }

    func webView(_ webView: WKWebView, stop task: WKURLSchemeTask) {}

    private static let assets: [String: (type: String, data: Data)] = {
        let files = ["index.html": "text/html", "mermaid.min.js": "application/javascript",
                     "renderer.js": "application/javascript"]
        var assets: [String: (String, Data)] = [:]
        for (name, type) in files {
            if let url = Bundle.main.url(forResource: name, withExtension: nil, subdirectory: "Mermaid"),
               let data = try? Data(contentsOf: url, options: .mappedIfSafe) {
                assets["/" + name] = (type, data)
            }
        }
        return assets
    }()
}
