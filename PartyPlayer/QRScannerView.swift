import SwiftUI
import AVFoundation

struct QRScannerView: UIViewControllerRepresentable {
    var onCode: (String) -> Void

    func makeUIViewController(context: Context) -> ScannerVC {
        let vc = ScannerVC()
        vc.onCode = onCode
        return vc
    }

    func updateUIViewController(_ uiViewController: ScannerVC, context: Context) {}

    final class ScannerVC: UIViewController, AVCaptureMetadataOutputObjectsDelegate {
        var onCode: ((String) -> Void)?

        private let session = AVCaptureSession()
        private let sessionQueue = DispatchQueue(label: "qr.session.queue")
        private var previewLayer: AVCaptureVideoPreviewLayer?
        private let permissionLabel: UILabel = {
            let lbl = UILabel()
            lbl.translatesAutoresizingMaskIntoConstraints = false
            lbl.textAlignment = .center
            lbl.textColor = .white
            lbl.numberOfLines = 0
            lbl.text = "Kamera-Zugriff benötigt. Bitte in den Einstellungen erlauben."
            lbl.isHidden = true
            return lbl
        }()

        override func viewDidLoad() {
            super.viewDidLoad()
            view.backgroundColor = .black

            view.addSubview(permissionLabel)
            NSLayoutConstraint.activate([
                permissionLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
                permissionLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
                permissionLabel.centerYAnchor.constraint(equalTo: view.centerYAnchor)
            ])

            let status = AVCaptureDevice.authorizationStatus(for: .video)
            switch status {
            case .authorized:
                configureSession()
            case .notDetermined:
                AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                    guard let self else { return }
                    DispatchQueue.main.async {
                        if granted {
                            self.configureSession()
                        } else {
                            self.showPermissionMessage()
                        }
                    }
                }
            default:
                showPermissionMessage()
            }
        }
        
        private func showPermissionMessage() {
            permissionLabel.isHidden = false
        }
        
        private func configureSession() {
            sessionQueue.async { [weak self] in
                guard let self else { return }

                self.session.beginConfiguration()

                guard let device = AVCaptureDevice.default(for: .video),
                      let input = try? AVCaptureDeviceInput(device: device),
                      self.session.canAddInput(input) else {
                    DispatchQueue.main.async { self.showPermissionMessage() }
                    self.session.commitConfiguration()
                    return
                }
                self.session.addInput(input)

                let output = AVCaptureMetadataOutput()
                guard self.session.canAddOutput(output) else {
                    DispatchQueue.main.async { self.showPermissionMessage() }
                    self.session.commitConfiguration()
                    return
                }
                self.session.addOutput(output)
                output.setMetadataObjectsDelegate(self, queue: .main)
                output.metadataObjectTypes = [.qr]

                self.session.commitConfiguration()

                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    let preview = AVCaptureVideoPreviewLayer(session: self.session)
                    preview.frame = self.view.layer.bounds
                    preview.videoGravity = .resizeAspectFill
                    self.view.layer.insertSublayer(preview, at: 0)
                    self.previewLayer = preview
                }
            }
        }

        override func viewWillAppear(_ animated: Bool) {
            super.viewWillAppear(animated)
            sessionQueue.async { [weak self] in
                guard let self else { return }
                if !self.session.isRunning {
                    self.session.startRunning()
                }
            }
        }

        override func viewWillDisappear(_ animated: Bool) {
            super.viewWillDisappear(animated)
            sessionQueue.async { [weak self] in
                guard let self else { return }
                if self.session.isRunning {
                    self.session.stopRunning()
                }
            }
        }
        
        nonisolated func metadataOutput(_ output: AVCaptureMetadataOutput,
                            didOutput metadataObjects: [AVMetadataObject],
                            from connection: AVCaptureConnection) {
            guard let obj = metadataObjects.first as? AVMetadataMachineReadableCodeObject,
                  obj.type == .qr,
                  let string = obj.stringValue else { return }

            // Hop back to the main actor explicitly to interact with UI
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.onCode?(string)
                self.dismiss(animated: true)
            }
        }
    }
}
