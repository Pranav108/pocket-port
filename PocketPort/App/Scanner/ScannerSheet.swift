import AVFoundation
import SwiftUI

struct ScannerSheet: View {
    @ObservedObject var coordinator: ImportCoordinator
    let fixturesEnabled: Bool
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.openURL) private var openURL
    @State private var permission = AVCaptureDevice.authorizationStatus(for: .video)
    @State private var unavailable = false

    var body: some View {
        NavigationStack {
            Group {
                switch coordinator.phase {
                case .scanning:
                    scanner
                case .downloading:
                    progress("Downloading from your Mac…")
                case .saving:
                    progress("Saving offline…")
                case .committed:
                    progress("Opening file…")
                case .failed(let error):
                    failure(error)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .navigationTitle("Scan a code")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", role: .cancel) {
                        if case .committed = coordinator.phase { return }
                        coordinator.reset()
                        dismiss()
                    }
                    .disabled(isCommitted)
                }
            }
        }
        .interactiveDismissDisabled(locksInteractiveDismissal)
        .presentationDragIndicator(locksInteractiveDismissal ? .hidden : .visible)
        .task(id: scenePhase) {
            guard scenePhase == .active, !fixturesEnabled else { return }
            permission = AVCaptureDevice.authorizationStatus(for: .video)
            if permission == .notDetermined {
                _ = await AVCaptureDevice.requestAccess(for: .video)
                permission = AVCaptureDevice.authorizationStatus(for: .video)
            }
        }
    }

    private var isCommitted: Bool {
        if case .committed = coordinator.phase { return true }
        return false
    }

    private var locksInteractiveDismissal: Bool {
        switch coordinator.phase {
        case .downloading, .saving, .committed: return true
        case .scanning, .failed: return false
        }
    }

    @ViewBuilder private var scanner: some View {
        #if DEBUG
        if fixturesEnabled {
            VStack(spacing: 12) {
                ForEach(ScanFixture.allCases, id: \.self) { fixture in
                    Button(fixture.rawValue) { coordinator.scan(fixture.link.qrString) }
                        .pocketPortActionStyle()
                        .accessibilityIdentifier(fixture.rawValue)
                }
            }
        } else { camera }
        #else
        camera
        #endif
    }

    @ViewBuilder private var camera: some View {
        if unavailable || permission == .restricted {
            ContentUnavailableView("Camera unavailable", systemImage: "camera")
        } else if permission == .denied {
            ContentUnavailableView {
                Label("Camera access required", systemImage: "camera")
            } description: {
                Text("Allow Camera access to scan a PocketPort code.")
            } actions: {
                settings
            }
        } else if permission == .authorized && scenePhase == .active {
            cameraPreview
        } else {
            progress("Opening camera…")
        }
    }

    private var cameraPreview: some View {
        CameraScanner(scanned: { value in
            if scenePhase == .active { coordinator.scan(value) }
        }, unavailable: { unavailable = true })
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.black)
        .overlay {
            Image(systemName: "viewfinder")
                .font(.system(size: 152, weight: .ultraLight))
                .foregroundStyle(.white)
                .shadow(color: .black.opacity(0.45), radius: 6)
                .accessibilityHidden(true)
                .allowsHitTesting(false)
        }
        .overlay(alignment: .bottom) {
            Text("Point your camera at the QR code on your Mac.")
                .font(.subheadline.weight(.medium))
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .pocketPortGlass(in: RoundedRectangle(cornerRadius: 22))
                .padding(14)
        }
        .clipShape(RoundedRectangle(cornerRadius: 30))
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private func progress(_ message: LocalizedStringKey) -> some View {
        ProgressView(message)
            .padding(.horizontal, 24)
            .padding(.vertical, 18)
            .pocketPortGlass(in: RoundedRectangle(cornerRadius: 24))
            .padding(.horizontal, 20)
    }

    private func failure(_ error: ImportFailure) -> some View {
        ContentUnavailableView {
            Label("Couldn’t import file", systemImage: "exclamationmark.circle")
        } description: {
            Text(error.message)
        } actions: {
            VStack(spacing: 12) {
                if error == .transfer(.localNetworkDenied) { settings }
                if error.canRetry {
                    Button("Retry", systemImage: "arrow.clockwise") { coordinator.retry() }
                        .pocketPortActionStyle(prominent: error != .transfer(.localNetworkDenied))
                }
                Button("Continue scanning", systemImage: "qrcode.viewfinder") { coordinator.reset() }
                    .pocketPortActionStyle(prominent: !error.canRetry)
            }
        }
    }

    private var settings: some View {
        Button("Open Settings", systemImage: "gearshape") {
            if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
        }
        .pocketPortActionStyle(prominent: true)
    }
}
