import SwiftUI

struct FilesSettingsView: View {
    private static let privacyPolicy = URL(string: "https://pranav108.github.io/pocket-port/privacy.html")!
    private static let termsOfUse = URL(string: "https://pranav108.github.io/pocket-port/terms.html")!

    @Binding var confirmBeforeDeleting: Bool
    let byteCount: Int64
    let isEmpty: Bool
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
                Section("About") {
                    NavigationLink("How It Works") {
                        HowItWorksView()
                    }
                    NavigationLink("Privacy Policy") {
                        privacyInfo
                    }
                    Link("Terms of Use", destination: Self.termsOfUse)
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

    private var privacyInfo: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("PocketPort transfers files directly from your Mac over local Wi-Fi and stores copies on this device. Camera access is used to scan share codes. Local Network access is used to reach your Mac. You can delete downloaded copies in PocketPort and choose where to send any copy you share.")
                Link("Read the full Privacy Policy", destination: Self.privacyPolicy)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(20)
        }
        .navigationTitle("Privacy Policy")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct HowItWorksView: View {
    private static let repository = URL(string: "https://github.com/Pranav108/pocket-port")!

    var body: some View {
        List {
            Section("On your Mac") {
                Text("Install the Mac helper using the instructions on GitHub. In Terminal, run `pocket-port` to share the only eligible file in your current folder.")
                Text("If there are several files to choose from, pass the filename or path, for example `pocket-port report.pdf`. Each command displays a QR code for one file.")
            }
            Section("On your iPhone") {
                Text("Connect your iPhone and Mac to the same trusted Wi-Fi. In Files, tap Scan and point your camera at the QR code in Terminal.")
                Text("Allow Camera and Local Network access when prompted. Keep Terminal open until the app says Saved offline. An unused code expires after three minutes.")
            }
            Section("After importing") {
                Text("Open saved Markdown, plain text, HTML, PDFs, and images from Files, even offline. Swipe a row to share or delete the downloaded copy.")
            }
            Section("Mac helper source") {
                Link(destination: Self.repository) {
                    Label("View on GitHub", systemImage: "arrow.up.right.square")
                }
                Text("Read the setup instructions, browse the source, or fork the repository to make your own changes.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("How It Works")
        .navigationBarTitleDisplayMode(.inline)
    }
}
