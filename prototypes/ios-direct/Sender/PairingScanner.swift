import SwiftUI
import VisionKit
import AVFoundation
import IOSDirectShared

/// Presentation identity belongs to this object, independent of metrics and the
/// changing children of the Radio/Stream forms. Consume a scan after dismissal.
@MainActor
final class PairingScanPresentation: ObservableObject {
    struct Request: Identifiable { let id = UUID(); let rid: UUID? }
    @Published var request: Request?
    private var result: (String, UUID?)?
    func present(rid: UUID?) { guard request == nil else { return }; result = nil; request = Request(rid: rid) }
    func scanned(_ payload: String, request: Request) {
        guard self.request?.id == request.id, result == nil else { return }
        result = (payload, request.rid); self.request = nil
    }
    func dismissed(_ consume: (String, UUID?) -> Void) {
        let scanned = result; result = nil
        if let scanned { consume(scanned.0, scanned.1) }
    }
}

/// Attach once to a stable screen root, never to a Group or a receiver row.
struct PairingScannerPresenter: ViewModifier {
    @ObservedObject var presentation: PairingScanPresentation
    let scanned: (String, UUID?) -> Void
    func body(content: Content) -> some View {
        content.sheet(item: $presentation.request, onDismiss: { presentation.dismissed(scanned) }) { request in
            PairingScannerSheet(scanned: { presentation.scanned($0, request: request) },
                                cancel: { presentation.request = nil })
        }
    }
}

private struct PairingScannerSheet: UIViewControllerRepresentable {
    let scanned: (String) -> Void
    let cancel: () -> Void
    func makeUIViewController(context: Context) -> UINavigationController {
        UINavigationController(rootViewController: ScannerController(scanned: scanned, cancel: cancel))
    }
    func updateUIViewController(_ controller: UINavigationController, context: Context) {}
}

/// The camera starts only once the sheet is visible and stops on disappearance.
/// Permission changes and SwiftUI updates never replace the camera controller.
private final class ScannerController: UIViewController, DataScannerViewControllerDelegate {
    private let scanned: (String) -> Void, cancel: () -> Void
    private var scanner: DataScannerViewController?
    private var visible = false, requesting = false, used = false
    init(scanned: @escaping (String) -> Void, cancel: @escaping () -> Void) {
        self.scanned = scanned; self.cancel = cancel; super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func viewDidLoad() {
        super.viewDidLoad(); title = "Scan pairing code"; view.backgroundColor = .systemBackground
        navigationItem.leftBarButtonItem = UIBarButtonItem(title: "Cancel", style: .plain, target: self, action: #selector(cancelTapped))
        showMessage("Requesting camera access…")
    }
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated); visible = true
        guard !requesting else { return }; requesting = true
        guard DataScannerViewController.isSupported else { showMessage("Code scanning is unavailable on this phone"); return }
        AVCaptureDevice.requestAccess(for: .video) { [weak self] allowed in
            DispatchQueue.main.async {
                guard let self, self.visible else { return }
                guard allowed else { self.showMessage("Allow camera access in Settings to scan the code shown on your Mac"); return }
                self.startCamera()
            }
        }
    }
    override func viewWillDisappear(_ animated: Bool) {
        visible = false; scanner?.stopScanning(); requesting = false; super.viewWillDisappear(animated)
    }
    private func startCamera() {
        guard visible, !used else { return }
        if scanner == nil {
            let camera = DataScannerViewController(recognizedDataTypes: [.barcode(symbologies: [.qr])],
                qualityLevel: .balanced, recognizesMultipleItems: false, isGuidanceEnabled: true, isHighlightingEnabled: true)
            camera.delegate = self
            view.subviews.forEach { $0.removeFromSuperview() }
            addChild(camera); view.addSubview(camera.view); camera.view.frame = view.bounds
            camera.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]; camera.didMove(toParent: self); scanner = camera
        }
        do { try scanner?.startScanning() } catch { showMessage("Camera scanner unavailable; cancel and try again") }
    }
    private func showMessage(_ message: String) {
        let label = UILabel(); label.text = message; label.numberOfLines = 0; label.textAlignment = .center
        label.frame = view.bounds.insetBy(dx: 24, dy: 24); label.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(label)
    }
    @objc private func cancelTapped() { cancel() }
    func dataScanner(_ scanner: DataScannerViewController, didAdd addedItems: [RecognizedItem], allItems: [RecognizedItem]) {
        guard !used else { return }
        for item in addedItems {
            if case .barcode(let code) = item, let payload = code.payloadStringValue {
                used = true; scanned(payload); return
            }
        }
    }
    func dataScanner(_ scanner: DataScannerViewController, becameUnavailableWithError error: DataScannerViewController.ScanningUnavailable) {
        showMessage("Camera scanner unavailable; cancel and try again")
    }
}
