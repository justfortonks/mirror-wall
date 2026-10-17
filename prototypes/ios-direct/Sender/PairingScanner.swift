import SwiftUI
import VisionKit
import AVFoundation
import IOSDirectShared

struct PairingScannerSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var authorized = false
    @State private var error: String?
    let scanned: (String) -> Void
    var body: some View {
        NavigationStack {
            Group {
                if let error { Text(error).padding() }
                else if authorized { PairingScanner(scanned: { payload in scanned(payload); dismiss() }, failed: { error = $0 }) }
                else { ProgressView("Requesting camera access") }
            }.navigationTitle("Scan pairing code")
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
        }.task {
            guard DataScannerViewController.isSupported else { error = "Code scanning is unavailable on this phone"; return }
            authorized = await AVCaptureDevice.requestAccess(for: .video)
            if !authorized { error = "Allow camera access in Settings to scan the code shown on your Mac" }
        }
    }
}

private struct PairingScanner: UIViewControllerRepresentable {
    let scanned: (String) -> Void
    let failed: (String) -> Void
    func makeCoordinator() -> Coordinator { Coordinator(scanned: scanned, failed: failed) }
    func makeUIViewController(context: Context) -> DataScannerViewController {
        let scanner = DataScannerViewController(recognizedDataTypes: [.barcode(symbologies: [.qr])],
            qualityLevel: .balanced, recognizesMultipleItems: false, isGuidanceEnabled: true, isHighlightingEnabled: true)
        scanner.delegate = context.coordinator
        do { try scanner.startScanning() } catch { DispatchQueue.main.async { failed("Camera scanner unavailable; try again") } }
        return scanner
    }
    func updateUIViewController(_ controller: DataScannerViewController, context: Context) {}
    static func dismantleUIViewController(_ controller: DataScannerViewController, coordinator: Coordinator) { controller.stopScanning() }
    final class Coordinator: NSObject, DataScannerViewControllerDelegate {
        private var used = false
        let scanned: (String) -> Void, failed: (String) -> Void
        init(scanned: @escaping (String) -> Void, failed: @escaping (String) -> Void) { self.scanned = scanned; self.failed = failed }
        func dataScanner(_ scanner: DataScannerViewController, didAdd addedItems: [RecognizedItem], allItems: [RecognizedItem]) {
            guard !used else { return }
            for item in addedItems {
                if case .barcode(let code) = item, let payload = code.payloadStringValue {
                    used = true; scanner.stopScanning(); scanned(payload); return
                }
            }
        }
        func dataScanner(_ scanner: DataScannerViewController, becameUnavailableWithError error: DataScannerViewController.ScanningUnavailable) {
            failed("Camera scanner unavailable; try again")
        }
    }
}
