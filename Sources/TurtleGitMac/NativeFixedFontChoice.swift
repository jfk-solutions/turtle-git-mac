import AppKit
import SwiftUI

/// Fixed-pitch font menu with each name rendered in its own face, replacing
/// SettingsTUDiff's owner-drawn CFontComboBox on macOS.
struct NativeFixedFontChoice: NSViewRepresentable {
    @Binding var value: String
    func makeCoordinator() -> Coordinator { Coordinator(value: $value) }
    func makeNSView(context: Context) -> NSPopUpButton {
        let button = NSPopUpButton(frame: .zero, pullsDown: false)
        button.target = context.coordinator; button.action = #selector(Coordinator.changed(_:))
        button.setAccessibilityLabel("Font")
        button.setContentHuggingPriority(.defaultLow, for: .horizontal)
        return button
    }
    func updateNSView(_ button: NSPopUpButton, context: Context) {
        context.coordinator.value = $value
        let manager = NSFontManager.shared
        let families = Array(Set(manager.availableFontFamilies.filter {
            manager.font(withFamily: $0, traits: [], weight: 5, size: 12)?.isFixedPitch == true
        } + [value])).sorted()
        if context.coordinator.families != families {
            context.coordinator.families = families
            button.removeAllItems()
            for name in families {
                button.addItem(withTitle: name)
                let item = button.lastItem!
                item.representedObject = name
                let font = manager.font(withFamily: name, traits: [], weight: 5, size: 12)
                    ?? NSFont(name: name, size: 12) ?? NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
                item.attributedTitle = NSAttributedString(string: name, attributes: [.font: font])
            }
        }
        button.selectItem(withTitle: value)
    }
    @MainActor final class Coordinator: NSObject {
        var value: Binding<String>
        var families: [String] = []
        init(value: Binding<String>) { self.value = value }
        @objc func changed(_ button: NSPopUpButton) {
            guard let name = button.selectedItem?.representedObject as? String else { return }
            value.wrappedValue = name
        }
    }
}
