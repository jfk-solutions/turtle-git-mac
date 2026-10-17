import AppKit
import SwiftUI

// Editable 6–30 presets shared by the upstream Blame and UDiff settings.
struct NativeFontSizeChoice: NSViewRepresentable {
    @Binding var value: String
    @Environment(\.isEnabled) private var enabled
    func makeCoordinator() -> Coordinator { Coordinator(value: $value) }
    func makeNSView(context: Context) -> NSComboBox {
        let combo = OwnedCombo()
        combo.coordinator = context.coordinator; context.coordinator.control = combo
        combo.addItems(withObjectValues: stride(from: 6, through: 30, by: 2).map(String.init))
        combo.delegate = context.coordinator
        combo.setAccessibilityLabel("Font size")
        return combo
    }
    func updateNSView(_ combo: NSComboBox, context: Context) {
        guard !context.coordinator.retired else { return }
        combo.isEnabled = enabled; context.coordinator.value = $value
        if combo.stringValue != value { combo.stringValue = value }
    }
    static func dismantleNSView(_ combo: NSComboBox, coordinator: Coordinator) { coordinator.retire() }
    private final class OwnedCombo: NSComboBox {
        weak var coordinator: Coordinator?
        override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); coordinator?.attach(window) }
    }
    final class Coordinator: NSObject, NSComboBoxDelegate {
        var retired = false
        weak var control: NSComboBox?
        private var ownerObserver: NSObjectProtocol?
        private weak var owner: NSWindow?
        func attach(_ window: NSWindow?) {
            guard !retired, owner !== window else { return }
            if let ownerObserver { NotificationCenter.default.removeObserver(ownerObserver) }; ownerObserver = nil; owner = window
            if let window { ownerObserver = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { [weak self] _ in MainActor.assumeIsolated { self?.retire() } } }
        }
        func retire() { retired = true; control?.delegate = nil; control?.isEnabled = false; if let ownerObserver { NotificationCenter.default.removeObserver(ownerObserver) }; ownerObserver = nil }
        deinit { if let ownerObserver { NotificationCenter.default.removeObserver(ownerObserver) } }
        var value: Binding<String>
        init(value: Binding<String>) { self.value = value }
        func controlTextDidChange(_ notification: Notification) {
            guard !retired, let combo = notification.object as? NSComboBox, combo.isEnabled, combo.window != nil else { return }
            value.wrappedValue = combo.stringValue
        }
        func comboBoxSelectionDidChange(_ notification: Notification) {
            guard !retired, let combo = notification.object as? NSComboBox, combo.isEnabled, combo.window != nil,
                  let selected = combo.objectValueOfSelectedItem as? String else { return }
            value.wrappedValue = selected
        }
    }
}
