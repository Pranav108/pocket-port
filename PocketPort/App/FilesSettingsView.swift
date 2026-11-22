import SwiftUI
import WebKit

struct FilesSettingsView: View {
    @Binding var confirmBeforeDeleting: Bool
    let byteCount: Int64
    let isEmpty: Bool
    @ObservedObject var direct: DirectReceivingModel
    let clearFiles: () async throws -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var confirmingClear = false
    @State private var clearing = false
    @State private var clearFailed = false

    var body: some View {
        NavigationStack {
            Form {
                Section("Files") {
                    Toggle("Confirm Before Deleting", isOn: $confirmBeforeDeleting)
                    LabeledContent("Downloaded Files", value: ByteCountFormatter.string(fromByteCount: byteCount, countStyle: .file))
                    Button("Clear Downloaded Files", role: .destructive) { confirmingClear = true }
                        .disabled(isEmpty || clearing)
                }
                Section("Local Wi-Fi") {
                    NavigationLink("Paired Computers") { PairedComputersView(model: direct) }
                }
                Section("About") {
                    NavigationLink("How It Works") {
                        HowItWorksView()
                    }
                    ForEach(LegalDocument.allCases) { document in
                        NavigationLink(document.rawValue) {
                            LegalDocumentView(document: document)
                        }
                    }
                    LabeledContent("Version", value: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—")
                }
            }
            .navigationTitle("Settings")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
            .alert("Clear downloaded files?", isPresented: $confirmingClear) {
                Button("Clear Downloads", role: .destructive, action: clear)
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This deletes every file saved in PocketPort on this iPhone.")
            }
            .alert("Couldn’t clear downloaded files", isPresented: $clearFailed) {
                Button("OK", role: .cancel) {}
            }
        }
        .presentationDragIndicator(.visible)
    }

    private func clear() {
        clearing = true
        Task {
            defer { clearing = false }
            do { try await clearFiles() }
            catch { clearFailed = true }
        }
    }
}

private enum LegalDocument: String, CaseIterable, Identifiable {
    case privacyPolicy = "Privacy Policy"
    case termsOfUse = "Terms of Use"

    var id: Self { self }

    var url: URL {
        let site = URL(string: "https://pranav108.github.io/pocket-port/")!
        return site.appendingPathComponent(self == .privacyPolicy ? "privacy.html" : "terms.html")
    }
}

private struct LegalDocumentView: View {
    private enum LoadState {
        case loading, loaded, failed
    }

    let document: LegalDocument
    @State private var loadState = LoadState.loading
    @State private var loadAttempt = 0

    var body: some View {
        LegalWebView(url: document.url) { success in
            loadState = success ? .loaded : .failed
        }
        .id(loadAttempt)
        .opacity(loadState == .loaded ? 1 : 0)
        .overlay {
            switch loadState {
            case .loading:
                ProgressView("Loading \(document.rawValue)…")
            case .failed:
                ContentUnavailableView {
                    Label("Page Unavailable", systemImage: "wifi.exclamationmark")
                } description: {
                    Text("Check your internet connection and try again.")
                } actions: {
                    Button("Try Again") {
                        loadState = .loading
                        loadAttempt += 1
                    }
                    .buttonStyle(.bordered)
                }
            case .loaded:
                EmptyView()
            }
        }
        .navigationTitle(document.rawValue)
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct LegalWebView: UIViewRepresentable {
    let url: URL
    let onLoad: (Bool) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onLoad: onLoad) }

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.load(URLRequest(url: url, timeoutInterval: 30))
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {}

    static func dismantleUIView(_ webView: WKWebView, coordinator: Coordinator) {
        webView.navigationDelegate = nil
        webView.stopLoading()
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        let onLoad: (Bool) -> Void

        init(onLoad: @escaping (Bool) -> Void) {
            self.onLoad = onLoad
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            onLoad(true)
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            reportFailure(error)
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            reportFailure(error)
        }

        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
            onLoad(false)
        }

        private func reportFailure(_ error: Error) {
            if (error as? URLError)?.code != .cancelled {
                onLoad(false)
            }
        }
    }
}

private struct HowItWorksView: View {
    private static let repository = URL(string: "https://github.com/Pranav108/pocket-port")!

    var body: some View {
        List {
            Section("Pair your devices") {
                Text("Connect your Mac and iPhone or iPad to the same trusted Wi-Fi. On the Mac, run `pocket-port pair` in Terminal.")
                Text("In PocketPort, open **Settings → Paired Computers → Add Computer**. Allow Local Network access if prompted, select your Mac, and enter the six-digit code from Terminal. The code expires after two minutes.")
                Text("Compare the Mac fingerprint on both screens and tap **Trust Computer** if it matches. Terminal confirms the pairing and shows the alias to use when sending.")
            }
            Section("Send to a paired device") {
                Text("Keep PocketPort open on the receiving device. From the folder containing the file, run this command with the alias shown in Terminal.")
                Text("pocket-port send README.md --to iphone")
                    .font(.system(.body, design: .monospaced))
                    .textSelection(.enabled)
                Text("Terminal shows **Saved on device** after the file has been saved in **Files**.")
                Text("Run `pocket-port devices` to see aliases and availability. Use `pocket-port default iphone` to set a default, then send with `pocket-port send README.md`. To send to more than one device, use `--to iphone,ipad` or `--to all`.")
                Text("To remove trust, tap a computer under **Paired Computers** and choose **Remove Computer**.")
            }
            Section("Troubleshoot a connection") {
                Text("If a device is offline, open PocketPort, check Wi-Fi and Local Network access, then tap **Retry Wi-Fi Receiver** in **Paired Computers**. Guest Wi-Fi may block connections between devices.")
                Text("If Terminal can’t confirm a send, retry with the same file and target. PocketPort can recognize a copy it already saved.")
            }
            Section("Share with a QR code") {
                Text("On your Mac, run `pocket-port report.pdf` using your file’s name or path. When there’s only one eligible file in the current folder, you can run `pocket-port` by itself.")
                Text("On your iPhone or iPad, tap **Scan** in **Files** and point the camera at the code in Terminal. Allow Camera and Local Network access if prompted. Keep Terminal open until you see **Saved offline**. The QR code expires after three minutes.")
            }
            Section("After importing") {
                Text("Open saved Markdown, plain text, HTML, PDFs, and images from Files, even offline. Swipe a row to share or delete the downloaded copy.")
            }
            Section("Mac helper source") {
                Link(destination: Self.repository) {
                    Label("View on GitHub", systemImage: "arrow.up.right.square")
                }
                Text("Find Mac helper installation instructions and the list of supported files.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("How It Works")
        .navigationBarTitleDisplayMode(.inline)
    }
}
