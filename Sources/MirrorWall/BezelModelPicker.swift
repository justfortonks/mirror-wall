import AppKit
import MirrorCore
import SwiftUI

struct BezelModelPicker: View {
    @ObservedObject var slot: Slot
    var body: some View {
        Menu("Bezel Model") {
            Toggle("Automatic", isOn: Binding(get: { slot.config.bezelModel == nil }, set: { _ in slot.setBezelModel(nil) }))
            ForEach(Array(Set(BezelPreset.catalog.map(\.group))).sorted(), id: \.self) { group in
                Menu(group == "SE" ? "iPhone SE" : Int(group) != nil ? "iPhone \(group)" : group) {
                    ForEach(BezelPreset.catalog.filter { $0.group == group }) { preset in
                        Toggle(preset.title, isOn: Binding(
                            get: { slot.config.bezelModel == preset.id },
                            set: { _ in slot.setBezelModel(preset.id) }
                        ))
                    }
                }
            }
        }
    }
}

enum DemoLabelEditor {
    static func show(for slot: Slot) {
        // Let the menu close before presenting its editor.
        DispatchQueue.main.async {
            let alert = NSAlert()
            alert.messageText = "Demo label"
            alert.informativeText = "Shown on this Mac and the Stage. Leave blank to use the device name."
            let field = NSTextField(string: slot.config.displayAlias ?? "")
            field.frame = NSRect(x: 0, y: 0, width: 300, height: 24)
            field.placeholderString = "For example: Zebra — nurse workflow"
            alert.accessoryView = field
            alert.addButton(withTitle: "Save")
            alert.addButton(withTitle: "Cancel")
            alert.window.initialFirstResponder = field
            if alert.runModal() == .alertFirstButtonReturn { slot.setDisplayAlias(field.stringValue) }
        }
    }
}
