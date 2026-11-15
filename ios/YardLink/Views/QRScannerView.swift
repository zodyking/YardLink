import AVFoundation
import SwiftUI
import UIKit

/// Live camera that reports the first QR code it reads.
struct QRScannerView: UIViewControllerRepresentable {
    let onScan: (String) -> Void
    let onProblem: (String) -> Void

    func makeUIViewController(context: Context) -> ScannerController {
        let controller = ScannerController()
        controller.onScan = onScan
        controller.onProblem = onProblem
        return controller
    }

    func updateUIViewController(_ controller: ScannerController, context: Context) {}

    final class ScannerController: UIViewController, AVCaptureMetadataOutputObjectsDelegate {
        var onScan: ((String) -> Void)?
        var onProblem: ((String) -> Void)?

        private let session = AVCaptureSession()
        private var preview: AVCaptureVideoPreviewLayer?
        private var delivered = false
        private let queue = DispatchQueue(label: "yardlink.qr-scanner")

        override func viewDidLoad() {
            super.viewDidLoad()
            view.backgroundColor = .black

            switch AVCaptureDevice.authorizationStatus(for: .video) {
            case .authorized:
                configure()
            case .notDetermined:
                AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                    DispatchQueue.main.async {
                        if granted {
                            self?.configure()
                        } else {
                            self?.onProblem?("Yard Link needs the camera to scan your employer's code. Allow camera access in Settings, or enter the address instead.")
                        }
                    }
                }
            default:
                onProblem?("Yard Link needs the camera to scan your employer's code. Allow camera access in Settings, or enter the address instead.")
            }
        }

        private func configure() {
            guard let device = AVCaptureDevice.default(for: .video),
                  let input = try? AVCaptureDeviceInput(device: device),
                  session.canAddInput(input) else {
                onProblem?("The camera is not available on this device. Enter the address instead.")
                return
            }
            session.addInput(input)

            let output = AVCaptureMetadataOutput()
            guard session.canAddOutput(output) else {
                onProblem?("The camera could not start. Enter the address instead.")
                return
            }
            session.addOutput(output)
            output.setMetadataObjectsDelegate(self, queue: .main)
            output.metadataObjectTypes = [.qr]

            let layer = AVCaptureVideoPreviewLayer(session: session)
            layer.videoGravity = .resizeAspectFill
            layer.frame = view.bounds
            view.layer.addSublayer(layer)
            preview = layer

            queue.async { [session] in session.startRunning() }
        }

        override func viewDidLayoutSubviews() {
            super.viewDidLayoutSubviews()
            preview?.frame = view.bounds
        }

        override func viewWillDisappear(_ animated: Bool) {
            super.viewWillDisappear(animated)
            queue.async { [session] in
                if session.isRunning { session.stopRunning() }
            }
        }

        func metadataOutput(
            _ output: AVCaptureMetadataOutput,
            didOutput metadataObjects: [AVMetadataObject],
            from connection: AVCaptureConnection
        ) {
            guard !delivered,
                  let code = metadataObjects.first as? AVMetadataMachineReadableCodeObject,
                  code.type == .qr,
                  let text = code.stringValue else { return }
            delivered = true
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            onScan?(text)
        }
    }
}
