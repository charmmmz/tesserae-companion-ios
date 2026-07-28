import SwiftUI
import VisionKit

struct PairingScannerView: View {
    @Environment(\.dismiss) private var dismiss
    let onCode: (String) -> Void
    @State private var scannerError: String?

    var body: some View {
        NavigationStack {
            Group {
                if DataScannerViewController.isSupported {
                    ZStack {
                        PairingDataScanner(
                            onCode: onCode,
                            onError: { scannerError = $0 }
                        )
                        VStack {
                            Spacer()
                            Label(
                                "Point the camera at the pairing QR shown by Tesserae.",
                                systemImage: "qrcode.viewfinder"
                            )
                            .font(.callout.weight(.medium))
                            .multilineTextAlignment(.center)
                            .padding()
                            .background(.regularMaterial, in: .rect(cornerRadius: 16))
                            .padding()
                        }
                    }
                } else {
                    ContentUnavailableView(
                        "QR Scanner Unavailable",
                        systemImage: "camera.fill",
                        description: Text(
                            "Enter the Tesserae server address and pairing code manually."
                        )
                    )
                }
            }
            .navigationTitle("Scan Pairing QR")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .alert(
                "Camera Unavailable",
                isPresented: Binding(
                    get: { scannerError != nil },
                    set: { if !$0 { scannerError = nil } }
                )
            ) {
                Button("OK", role: .cancel) { scannerError = nil }
            } message: {
                Text(scannerError ?? "")
            }
        }
    }
}

private struct PairingDataScanner: UIViewControllerRepresentable {
    let onCode: (String) -> Void
    let onError: (String) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onCode: onCode, onError: onError)
    }

    func makeUIViewController(context: Context) -> DataScannerViewController {
        let scanner = DataScannerViewController(
            recognizedDataTypes: [.barcode(symbologies: [.qr])],
            qualityLevel: .balanced,
            recognizesMultipleItems: false,
            isHighFrameRateTrackingEnabled: true,
            isPinchToZoomEnabled: true,
            isGuidanceEnabled: true,
            isHighlightingEnabled: true
        )
        scanner.delegate = context.coordinator
        Task { @MainActor in
            do {
                try scanner.startScanning()
            } catch {
                onError(error.localizedDescription)
            }
        }
        return scanner
    }

    func updateUIViewController(
        _ uiViewController: DataScannerViewController,
        context: Context
    ) {}

    static func dismantleUIViewController(
        _ uiViewController: DataScannerViewController,
        coordinator: Coordinator
    ) {
        uiViewController.stopScanning()
    }

    @MainActor
    final class Coordinator: NSObject, DataScannerViewControllerDelegate {
        private let onCode: (String) -> Void
        private let onError: (String) -> Void
        private var delivered = false

        init(
            onCode: @escaping (String) -> Void,
            onError: @escaping (String) -> Void
        ) {
            self.onCode = onCode
            self.onError = onError
        }

        func dataScanner(
            _ dataScanner: DataScannerViewController,
            didAdd addedItems: [RecognizedItem],
            allItems: [RecognizedItem]
        ) {
            guard !delivered else { return }
            for item in addedItems {
                guard
                    case let .barcode(barcode) = item,
                    let value = barcode.payloadStringValue
                else {
                    continue
                }
                delivered = true
                dataScanner.stopScanning()
                onCode(value)
                return
            }
        }

        func dataScanner(
            _ dataScanner: DataScannerViewController,
            becameUnavailableWithError error: DataScannerViewController.ScanningUnavailable
        ) {
            onError(String(describing: error))
        }
    }
}
