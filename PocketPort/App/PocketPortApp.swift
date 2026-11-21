import SwiftUI
import struct PocketPortProtocol.ShareLink
import struct PocketPortProtocol.ShareMetadata

@main
struct PocketPortApp: App {
    @StateObject private var coordinator: ImportCoordinator
    @StateObject private var wifi: WiFiAvailability
    private let fixturesEnabled: Bool

    init() {
        #if DEBUG
        let args = ProcessInfo.processInfo.arguments
        if let index = args.firstIndex(of: "--pocketport-ui-test"), args.indices.contains(index + 1) {
            let key = ShareMetadata.digest(of: Data(args[index + 1].utf8))
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ui-" + key)
            _coordinator = StateObject(wrappedValue: ImportCoordinator(store: ImportStore(root: directory), transfer: FixtureTransport()))
            _wifi = StateObject(wrappedValue: WiFiAvailability(testOverride: !args.contains("--pocketport-ui-test-no-wifi")))
            fixturesEnabled = true
            return
        }
        #endif
        _coordinator = StateObject(wrappedValue: ImportCoordinator(store: ImportStore(), transfer: TransferClient()))
        _wifi = StateObject(wrappedValue: WiFiAvailability())
        fixturesEnabled = false
    }

    var body: some Scene {
        WindowGroup {
            ImportedFilesView(coordinator: coordinator, wifi: wifi, fixturesEnabled: fixturesEnabled)
                .tint(.teal)
                .modifier(LaunchTransition())
        }
    }
}

private struct LaunchTransition: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var showingArtwork = true

    func body(content: Content) -> some View {
        content.overlay {
            if showingArtwork {
                ZStack {
                    Color("LaunchBackground")
                    Image("LaunchArtwork")
                }
                    .ignoresSafeArea()
                    .accessibilityHidden(true)
                    .allowsHitTesting(false)
                    .transition(.opacity)
                    .task {
                        guard !reduceMotion else {
                            showingArtwork = false
                            return
                        }

                        // Let the first scene frame settle before fading the launch artwork.
                        try? await Task.sleep(for: .milliseconds(240))
                        guard !Task.isCancelled else { return }
                        withAnimation(.easeInOut(duration: 0.32)) {
                            showingArtwork = false
                        }
                    }
            }
        }
    }
}

#if DEBUG
enum ScanFixture: String, CaseIterable {
    case a = "fixture-project-a", b = "fixture-project-b", interrupted = "fixture-interrupted"

    var link: ShareLink {
        let index = Self.allCases.firstIndex(of: self)! + 1
        return try! ShareLink(host: "fixture.local", port: 8080,
                              shareID: UUID(uuidString: "00000000-0000-4000-8000-00000000000" + String(index))!,
                              token: ShareLink.generateToken(), expiresAtUnixSeconds: Int64(Date().timeIntervalSince1970) + 180)
    }
}

struct FixtureTransport: ShareTransferring {
    func download(_ link: ShareLink) async throws -> DownloadedFile {
        guard link.shareID != ScanFixture.interrupted.link.shareID else { throw TransferError.incomplete }
        let project = link.shareID == ScanFixture.a.link.shareID ? "Project A" : "Project B"
        let content = """
        # \(project) plan

        ## Milestones

        - [x] Outline the project
        - [ ] Ship the prototype
          - Review the **offline** workflow

        | Phase | Owner |
        | --- | --- |
        | Prototype | Team |

        > Keep a local copy.

        ```swift
        let message = "Saved offline"
        ```

        See [the guide](https://example.com/guide).
        """
        let data = Data(content.utf8)
        return try DownloadedFile(data: data, metadata: ShareMetadata(filename: "PLAN.md", project: project, sha256: ShareMetadata.digest(of: data)))
    }
    func acknowledge(_ link: ShareLink) async throws {}
}
#endif
