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
        return picker
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
