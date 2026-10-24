import ReplayKit
import SwiftUI

/// Apple's Start Broadcast button, aimed at Mirror Wall Cast's own extension. iOS only lets a
/// person start a whole-screen broadcast from this button (or Control Center), so the app's
/// "Start sharing" button is this one, made invisible and laid over the styled label: a tap on
/// the label is a tap on Apple's button, which opens iOS's Start Broadcast sheet.
struct BroadcastPicker: UIViewRepresentable {
    static let extensionID = "com.justfortonks.mirrorwall.cast.broadcast"

    func makeUIView(context: Context) -> FillingPicker {
        let picker = FillingPicker(frame: .zero)
        picker.preferredExtension = Self.extensionID
        picker.showsMicrophoneButton = false
        picker.alpha = 0.02 // invisible, still tappable
        Self.current = picker
        return picker
    }

    /// The picker on screen, so a scan or a tapped slot can open iOS's Start Broadcast sheet
    /// straight away, as the Android app goes straight to its own sharing prompt.
    private static weak var current: FillingPicker?

    /// Opens iOS's Start Broadcast sheet, as a tap on the button would. Waits a moment for the
    /// picker to be on screen when the ready card has only just appeared.
    @MainActor static func open() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
            guard let picker = current, picker.window != nil else { return }
            for case let button as UIButton in picker.subviews {
                button.sendActions(for: .touchUpInside)
            }
        }
    }

    func updateUIView(_ picker: FillingPicker, context: Context) {}

    /// The picker's own button sized to the whole view, so the full label is the tap target.
    final class FillingPicker: RPSystemBroadcastPickerView {
        override func layoutSubviews() {
            super.layoutSubviews()
            for case let button as UIButton in subviews { button.frame = bounds }
        }
    }
}
