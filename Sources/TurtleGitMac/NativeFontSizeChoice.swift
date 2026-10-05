import AppKit
import SwiftUI

// Editable 6–30 presets shared by the upstream Blame and UDiff settings.
struct NativeFontSizeChoice: NSViewRepresentable {
    @Binding var value: String
    func makeCoordinator() -> Coordinator { Coordinator(value: $value) }
    func makeNSView(context: Context) -> NSComboBox {
        let combo = NSComboBox()
        combo.addItems(withObjectValues: stride(from: 6, through: 30, by: 2).map(String.init))
        combo.delegate = context.coordinator
        combo.setAccessibilityLabel("Font size")
        return combo
    }
    func updateNSView(_ combo: NSComboBox, context: Context) {
        context.coordinator.value = $value
        if combo.stringValue != value { combo.stringValue = value }
    }
    final class Coordinator: NSObject, NSComboBoxDelegate {
        var value: Binding<String>
        init(value: Binding<String>) { self.value = value }
        func controlTextDidChange(_ notification: Notification) {
            guard let combo = notification.object as? NSComboBox else { return }
            value.wrappedValue = combo.stringValue
        }
        func comboBoxSelectionDidChange(_ notification: Notification) {
            guard let combo = notification.object as? NSComboBox,
                  let selected = combo.objectValueOfSelectedItem as? String else { return }
            value.wrappedValue = selected
        }
    }
}
