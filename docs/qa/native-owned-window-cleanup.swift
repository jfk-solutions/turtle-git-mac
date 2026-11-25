// SPDX-License-Identifier: GPL-2.0-or-later
import AppKit

/// Receiver-only cleanup. AppKit-managed release-on-close auxiliaries are hidden
/// and detached; the caller's ARC-owned windows retain their normal close route.
/// Callers remain responsible for awaiting their actual feature/sheet drainage.
@MainActor enum NativeOwnedWindowCleanup {
    static func close(_ windows: [NSWindow],
                      returnCode: NSApplication.ModalResponse = .cancel,
                      closeControllers: Bool = false,
                      clearContentViewControllers: Bool = false) {
        var targets = [NSWindow](), seen = Set<ObjectIdentifier>()
        func append(_ window: NSWindow) {
            if seen.insert(ObjectIdentifier(window)).inserted { targets.append(window) }
        }
        windows.forEach(append)
        var pairs = [(NSWindow, NSWindow)](), sheets = Set<ObjectIdentifier>()
        func pair(_ parent: NSWindow, _ sheet: NSWindow) {
            if sheets.insert(ObjectIdentifier(sheet)).inserted { pairs.append((parent, sheet)) }
        }
        var index = 0
        while index < targets.count {
            let window = targets[index]; index += 1
            if let parent = window.sheetParent { pair(parent, window) }
            if let sheet = window.attachedSheet { append(sheet); pair(window, sheet) }
        }
        for (parent, sheet) in pairs {
            // A half-detached pair already has its native end request in flight.
            if sheet.sheetParent === parent && parent.attachedSheet === sheet {
                parent.endSheet(sheet, returnCode: returnCode)
            }
        }
        for window in targets {
            let arcOwned = !window.isReleasedWhenClosed
            if arcOwned {
                window.makeFirstResponder(nil); window.endEditing(for: nil)
                if clearContentViewControllers { window.contentViewController = nil }
            }
            window.orderOut(nil)
            guard arcOwned else { continue }
            if closeControllers, let controller = window.windowController { controller.close() }
            else { window.close() }
        }
    }
}
