import AppKit
import SwiftUI
import TurtleGitCore

/// Observe the public AppKit table underlying a SwiftUI Table without replacing
/// its selection, accessibility, checkbox or context-menu implementations.
struct CommitFileInteraction: NSViewRepresentable {
    let entries: [StatusEntry]
    @Binding var focusedPath: String?
    let enabled: Bool
    let delete: ([StatusEntry], StatusEntry, Bool) -> Void

    func makeNSView(context: Context) -> Probe { Probe() }
    func updateNSView(_ view: Probe, context: Context) {
        view.entries = entries; view.focusedPath = $focusedPath
        view.enabled = enabled; view.delete = delete
    }
    static func dismantleNSView(_ view: Probe, coordinator: ()) { view.stopObserving() }

    final class Probe: NSView {
        var entries: [StatusEntry] = []
        var focusedPath: Binding<String?>?
        var enabled = false
        var delete: ([StatusEntry], StatusEntry, Bool) -> Void = { _, _, _ in }
        private var monitor: Any?
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow(); stopObserving()
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .keyDown]) { [weak self] event in
                guard let self else { return event }
                return self.observe(event)
            }
        }
        func stopObserving() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
        }
        deinit { stopObserving() }
        private func table(containing view: NSView?) -> NSTableView? {
            var current = view
            while let candidate = current {
                if let table = candidate as? NSTableView { return table }
                current = candidate.superview
            }
            return nil
        }
        private func contains(_ table: NSTableView) -> Bool {
            let area = convert(bounds, to: nil)
            return area.intersects(table.convert(table.visibleRect, to: nil))
        }
        private func observe(_ event: NSEvent) -> NSEvent? {
            guard let window, event.window === window else { return event }
            if event.type != .keyDown {
                let point = convert(event.locationInWindow, from: nil)
                guard bounds.contains(point),
                      let content = window.contentView,
                      let table = table(containing: content.hitTest(content.convert(event.locationInWindow, from: nil))) else { return event }
                let row = table.row(at: table.convert(event.locationInWindow, from: nil))
                guard entries.indices.contains(row) else { return event }
                // Right-clicking a selected row preserves the selection mark;
                // Shift extends the range from the existing mark.
                let preserve = event.type == .rightMouseDown && table.selectedRowIndexes.contains(row)
                    || event.modifierFlags.contains(.shift)
                if !preserve || focusedPath?.wrappedValue == nil { focusedPath?.wrappedValue = entries[row].path }
                return event
            }
            guard let table = window.firstResponder as? NSTableView, contains(table) else { return event }
            let flags = event.modifierFlags.intersection([.command, .control, .option, .shift])
            if event.keyCode == 51 || event.keyCode == 117 {
                guard enabled else { return event }
                let selected = table.selectedRowIndexes.compactMap { entries.indices.contains($0) ? entries[$0] : nil }
                let mark = entries.first { $0.path == focusedPath?.wrappedValue } ?? (selected.count == 1 ? selected.first : nil)
                guard !selected.isEmpty, let mark, mark.canDeleteWithKeyboard else { return event }
                delete(selected, mark, flags.contains(.shift))
                return nil
            }
            // AppKit applies arrow/Home/End selection after the local monitor.
            // A non-range keyboard move starts a new selection mark.
            if [123, 124, 125, 126, 115, 119].contains(event.keyCode), !flags.contains(.shift) {
                DispatchQueue.main.async { [weak self, weak table] in
                    guard let self, let table, table.selectedRowIndexes.count == 1,
                          self.entries.indices.contains(table.selectedRow) else { return }
                    self.focusedPath?.wrappedValue = self.entries[table.selectedRow].path
                }
            }
            return event
        }
    }
}
