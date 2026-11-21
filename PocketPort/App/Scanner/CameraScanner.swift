import AVFoundation
import SwiftUI
import UIKit

struct CameraScanner: UIViewRepresentable {
    let scanned: (String) -> Void
    let unavailable: () -> Void

    final class Preview: UIView {
        var capture: Capture?

        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        var preview: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }

        override func layoutSubviews() {
            super.layoutSubviews()
            let angle: CGFloat
            switch window?.windowScene?.interfaceOrientation {
            case .landscapeLeft: angle = 0
            case .landscapeRight: angle = 180
            case .portraitUpsideDown: angle = 270
            default: angle = 90
            }
            capture?.rotatePreview(preview, to: angle)
        }
    }

    final class Capture: NSObject, AVCaptureMetadataOutputObjectsDelegate, @unchecked Sendable {
        private let session = AVCaptureSession()
        private let queue = DispatchQueue(label: "PocketPort.Camera")
        private var delivered = false
        @MainActor private var dismantled = false
        private let scanned: (String) -> Void
        private let unavailable: () -> Void

        init(scanned: @escaping (String) -> Void, unavailable: @escaping () -> Void) {
            self.scanned = scanned
            self.unavailable = unavailable
        }

        @MainActor
        func start(preview: Preview) {
            preview.preview.session = session
            queue.async {
                guard self.configure() else {
                    DispatchQueue.main.async {
                        if !self.dismantled { self.unavailable() }
                    }
                    return
                }
                self.session.startRunning()
            }
        }

        func rotatePreview(_ preview: AVCaptureVideoPreviewLayer, to angle: CGFloat) {
            queue.async {
                guard !self.delivered, let connection = preview.connection,
                      connection.videoRotationAngle != angle,
                      connection.isVideoRotationAngleSupported(angle) else { return }
                connection.videoRotationAngle = angle
            }
        }

        @MainActor
        func stop(detaching preview: Preview) {
            dismantled = true
            queue.async {
                self.delivered = true
                if self.session.isRunning { self.session.stopRunning() }
                self.removeInputsAndOutputs()

                // Detaching also changes the session's preview connection.
                DispatchQueue.main.async { preview.preview.session = nil }
            }
        }

        private func configure() -> Bool {
            guard let device = AVCaptureDevice.default(for: .video),
                  let input = try? AVCaptureDeviceInput(device: device) else { return false }
            let output = AVCaptureMetadataOutput()

            session.beginConfiguration()
            defer { session.commitConfiguration() }
            guard session.canAddInput(input) else { return false }
            session.addInput(input)
            guard session.canAddOutput(output) else { return false }
            session.addOutput(output)
            guard output.availableMetadataObjectTypes.contains(.qr) else { return false }
            output.setMetadataObjectsDelegate(self, queue: queue)
            output.metadataObjectTypes = [.qr]
            return true
        }

        private func removeInputsAndOutputs() {
            session.beginConfiguration()
            defer { session.commitConfiguration() }
            session.outputs.forEach { session.removeOutput($0) }
            session.inputs.forEach { session.removeInput($0) }
        }

        func metadataOutput(_ output: AVCaptureMetadataOutput, didOutput objects: [AVMetadataObject],
                            from connection: AVCaptureConnection) {
            guard !delivered, let value = objects.compactMap({ ($0 as? AVMetadataMachineReadableCodeObject)?.stringValue }).first else { return }
            delivered = true
            DispatchQueue.main.async {
                if !self.dismantled { self.scanned(value) }
            }
        }
    }

    func makeCoordinator() -> Capture { Capture(scanned: scanned, unavailable: unavailable) }
    func makeUIView(context: Context) -> Preview {
        let view = Preview()
        view.preview.videoGravity = .resizeAspectFill
        view.capture = context.coordinator
        context.coordinator.start(preview: view)
        return view
    }
    func updateUIView(_ uiView: Preview, context: Context) {}
    static func dismantleUIView(_ uiView: Preview, coordinator: Capture) {
        uiView.capture = nil
        coordinator.stop(detaching: uiView)
    }
}
