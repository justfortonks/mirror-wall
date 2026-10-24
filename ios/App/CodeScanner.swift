import AVFoundation
import SwiftUI
import VisionKit

/// The camera, looking for a QR code: Mirror Wall's Connect with QR Code (⌘K). Calls back once
/// with the first code's text.
struct CodeScanner: UIViewControllerRepresentable {
    let onCode: (String) -> Void

    /// Whether this iPhone can scan at all (it needs an A12 or newer and a camera).
    static var isSupported: Bool { DataScannerViewController.isSupported }

    /// Asks for the camera first, so the scanner opens to a live picture: starting the scanner
    /// while iOS's camera prompt is up fails, and doesn't recover once the person allows it.
    static func requestCamera() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: return true
        case .notDetermined: return await AVCaptureDevice.requestAccess(for: .video)
        default: return false
        }
    }

    func makeUIViewController(context: Context) -> DataScannerViewController {
        let scanner = DataScannerViewController(
            recognizedDataTypes: [.barcode(symbologies: [.qr])],
            qualityLevel: .balanced,
            recognizesMultipleItems: false,
            isHighFrameRateTrackingEnabled: false,
            isHighlightingEnabled: true
        )
        scanner.delegate = context.coordinator
        return scanner
    }

    /// Starts the camera once the scanner is on screen (starting it before that does nothing).
    func updateUIViewController(_ controller: DataScannerViewController, context: Context) {
        guard !controller.isScanning else { return }
        DispatchQueue.main.async {
            do { try controller.startScanning() } catch {
                Shared.log("Scanner didn't start: \(error.localizedDescription)", from: "app")
            }
        }
    }

    static func dismantleUIViewController(_ controller: DataScannerViewController, coordinator: Coordinator) {
        controller.stopScanning()
    }

    func makeCoordinator() -> Coordinator { Coordinator(onCode: onCode) }

    final class Coordinator: NSObject, DataScannerViewControllerDelegate {
        let onCode: (String) -> Void
        private var done = false

        init(onCode: @escaping (String) -> Void) { self.onCode = onCode }

        func dataScanner(_ scanner: DataScannerViewController, didAdd items: [RecognizedItem], allItems: [RecognizedItem]) {
            guard !done else { return }
            for item in items {
                if case .barcode(let barcode) = item, let text = barcode.payloadStringValue {
                    done = true
                    scanner.stopScanning()
                    onCode(text)
                    return
                }
            }
        }
    }
}
