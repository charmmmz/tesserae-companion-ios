@preconcurrency import AVFoundation
import SwiftUI

struct DeviceSetupQRScanner: UIViewControllerRepresentable {
    let onCode: @MainActor (String) -> Void
    let onError: @MainActor (String) -> Void

    func makeUIViewController(context: Context) -> DeviceSetupQRScannerController {
        let controller = DeviceSetupQRScannerController()
        controller.onCode = onCode
        controller.onError = onError
        return controller
    }

    func updateUIViewController(
        _ uiViewController: DeviceSetupQRScannerController,
        context: Context
    ) {}
}

@MainActor
final class DeviceSetupQRScannerController: UIViewController {
    var onCode: ((String) -> Void)?
    var onError: ((String) -> Void)?

    private let session = AVCaptureSession()
    private let metadataOutput = AVCaptureMetadataOutput()
    private var previewLayer: AVCaptureVideoPreviewLayer?
    private var didDeliverCode = false

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        configureOverlay()
        Task { await requestAccessAndStart() }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        previewLayer?.frame = view.bounds
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        if session.isRunning { session.stopRunning() }
    }

    private func requestAccessAndStart() async {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            configureCapture()
        case .notDetermined:
            if await AVCaptureDevice.requestAccess(for: .video) {
                configureCapture()
            } else {
                onError?(String(localized: "Camera access is required to scan the setup code."))
            }
        default:
            onError?(String(localized: "Allow camera access in Settings to scan the setup code."))
        }
    }

    private func configureCapture() {
        guard
            let camera = AVCaptureDevice.default(for: .video),
            let input = try? AVCaptureDeviceInput(device: camera),
            session.canAddInput(input),
            session.canAddOutput(metadataOutput)
        else {
            onError?(String(localized: "The camera could not be started."))
            return
        }
        session.beginConfiguration()
        session.addInput(input)
        session.addOutput(metadataOutput)
        metadataOutput.setMetadataObjectsDelegate(self, queue: .main)
        metadataOutput.metadataObjectTypes = [.qr]
        session.commitConfiguration()

        let layer = AVCaptureVideoPreviewLayer(session: session)
        layer.videoGravity = .resizeAspectFill
        layer.frame = view.bounds
        view.layer.insertSublayer(layer, at: 0)
        previewLayer = layer
        session.startRunning()
    }

    private func configureOverlay() {
        let label = UILabel()
        label.translatesAutoresizingMaskIntoConstraints = false
        label.text = String(localized: "Point the camera at the QR code on the display")
        label.textColor = .white
        label.font = .preferredFont(forTextStyle: .headline)
        label.textAlignment = .center
        label.numberOfLines = 0
        label.backgroundColor = UIColor.black.withAlphaComponent(0.58)
        label.layer.cornerRadius = 14
        label.layer.masksToBounds = true
        view.addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 24),
            label.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -24),
            label.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -24),
            label.heightAnchor.constraint(greaterThanOrEqualToConstant: 56),
        ])
    }
}

extension DeviceSetupQRScannerController: @preconcurrency AVCaptureMetadataOutputObjectsDelegate {
    func metadataOutput(
        _ output: AVCaptureMetadataOutput,
        didOutput metadataObjects: [AVMetadataObject],
        from connection: AVCaptureConnection
    ) {
        guard
            !didDeliverCode,
            let object = metadataObjects.first as? AVMetadataMachineReadableCodeObject,
            let value = object.stringValue,
            value.lowercased().hasPrefix("tesserae://setup?")
        else { return }
        didDeliverCode = true
        session.stopRunning()
        onCode?(value)
    }
}
