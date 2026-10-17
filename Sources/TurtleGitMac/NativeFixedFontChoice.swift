import AppKit
import SwiftUI

/// Fixed-pitch font menu with each name rendered in its own face, replacing
/// SettingsTUDiff's owner-drawn CFontComboBox on macOS.
struct NativeFixedFontChoice: NSViewRepresentable {
    @Binding var value: String
    @Environment(\.isEnabled) private var enabled
    func makeCoordinator() -> Coordinator { Coordinator(value: $value) }
    func makeNSView(context: Context) -> NSPopUpButton {
        let button = OwnedButton(frame: .zero, pullsDown: false)
        button.coordinator = context.coordinator; context.coordinator.control = button
        button.target = context.coordinator; button.action = #selector(Coordinator.changed(_:))
        button.setAccessibilityLabel("Font")
        button.setContentHuggingPriority(.defaultLow, for: .horizontal)
        return button
    }
    func updateNSView(_ button: NSPopUpButton, context: Context) {
        guard !context.coordinator.retired else { return }
        button.isEnabled = enabled; context.coordinator.value = $value
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
    static func dismantleNSView(_ button: NSPopUpButton, coordinator: Coordinator) { coordinator.retire() }
    private final class OwnedButton: NSPopUpButton {
        weak var coordinator: Coordinator?
        override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); coordinator?.attach(window) }
    }
    @MainActor final class Coordinator: NSObject {
        var retired = false
        weak var control: NSPopUpButton?
        private var ownerObserver: NSObjectProtocol?
        private weak var owner: NSWindow?
        func attach(_ window: NSWindow?) {
            guard !retired, owner !== window else { return }
            if let ownerObserver { NotificationCenter.default.removeObserver(ownerObserver) }; ownerObserver = nil; owner = window
            if let window { ownerObserver = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { [weak self] _ in MainActor.assumeIsolated { self?.retire() } } }
        }
        func retire() { retired = true; control?.target = nil; control?.isEnabled = false; if let ownerObserver { NotificationCenter.default.removeObserver(ownerObserver) }; ownerObserver = nil }
        deinit { if let ownerObserver { NotificationCenter.default.removeObserver(ownerObserver) } }
        var value: Binding<String>
        var families: [String] = []
        init(value: Binding<String>) { self.value = value }
        @objc func changed(_ button: NSPopUpButton) {
            guard !retired, button.isEnabled, button.window != nil, let name = button.selectedItem?.representedObject as? String else { return }
            value.wrappedValue = name
        }
    }
}
