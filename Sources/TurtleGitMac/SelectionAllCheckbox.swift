import AppKit
import SwiftUI

struct SelectionAllCheckbox: NSViewRepresentable {
    let checked: Int
    let total: Int
    let change: (Bool) -> Void
    @Environment(\.isEnabled) private var enabled
    func makeCoordinator() -> Coordinator { Coordinator(change: change) }
    func makeNSView(context: Context) -> NSButton {
        let button = NSButton(checkboxWithTitle: "Select/deselect all", target: context.coordinator, action: #selector(Coordinator.clicked(_:)))
        button.allowsMixedState = true; return button
    }
    func updateNSView(_ button: NSButton, context: Context) {
        button.state = checked == 0 ? .off : checked == total ? .on : .mixed; button.isEnabled = enabled && total > 0
        context.coordinator.change = change; context.coordinator.selectOnClick = checked == 0
    }
    final class Coordinator: NSObject {
        var change: (Bool) -> Void
        var selectOnClick = true
        init(change: @escaping (Bool) -> Void) { self.change = change }
        @objc func clicked(_ sender: NSButton) { change(selectOnClick) }
    }
}

