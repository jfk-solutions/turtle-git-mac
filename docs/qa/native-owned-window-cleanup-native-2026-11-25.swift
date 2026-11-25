// SPDX-License-Identifier: GPL-2.0-or-later
import AppKit

@MainActor private final class CleanupWindow: NSWindow {
    var closeCalls = 0
    override func close() { closeCalls += 1; super.close() }
}
@MainActor private final class CleanupController: NSWindowController {
    var closeCalls = 0
    override func close() { closeCalls += 1; super.close() }
}
@main struct NativeOwnedWindowCleanupVerification {
    struct Failure: Error { let message: String }
    @MainActor static func require(_ value: Bool, _ message: String) throws {
        if !value { throw Failure(message: message) }
    }
    @MainActor private static func window() -> CleanupWindow {
        let window = CleanupWindow(contentRect: .init(x: -24000, y: -24000, width: 320, height: 180),
                                   styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.alphaValue = 0
        window.orderFront(nil); return window
    }
    @MainActor static func main() async throws {
        NSApp.setActivationPolicy(.prohibited)
        let auxiliary = window(), content = NSViewController()
        content.view = NSView(frame: .zero); auxiliary.contentViewController = content
        auxiliary.isReleasedWhenClosed = true
        // This one explicitly constructed fixture remains ours to dispose after
        // verifying that generic cleanup does not change an auxiliary's policy.
        defer { auxiliary.isReleasedWhenClosed = false; auxiliary.close() }
        NativeOwnedWindowCleanup.close([auxiliary, auxiliary], closeControllers: true, clearContentViewControllers: true)
        try require(auxiliary.closeCalls == 0 && auxiliary.isReleasedWhenClosed && !auxiliary.isVisible,
                    "Generic cleanup closed or changed the release policy of an auxiliary")
        try require(auxiliary.contentViewController === content, "Generic cleanup mutated auxiliary content ownership")

        let owner = window(), controller = CleanupController(window: owner)
        defer { if owner.closeCalls == 0 { controller.close() } }
        NativeOwnedWindowCleanup.close([owner, owner], closeControllers: true)
        try require(controller.closeCalls == 1 && owner.closeCalls == 1 && !owner.isVisible,
                    "Duplicate windows repeated controller closure or lost the owned close route")

        let direct = window(), directController = CleanupController(window: direct), directContent = NSViewController()
        directContent.view = NSView(frame: .zero); direct.contentViewController = directContent
        defer { if direct.closeCalls == 0 { directController.close() } }
        NativeOwnedWindowCleanup.close([direct], clearContentViewControllers: true)
        try require(direct.closeCalls == 1 && directController.closeCalls == 0 && direct.contentViewController == nil,
                    "Window closure changed controller dispatch or retained requested content")

        let parent = window(), sheet = window()
        defer {
            if let linked = sheet.sheetParent { linked.endSheet(sheet, returnCode: .cancel) }
            if parent.closeCalls == 0 { parent.close() }
            if sheet.closeCalls == 0 { sheet.close() }
        }
        var responses = [NSApplication.ModalResponse]()
        parent.beginSheet(sheet) { response in MainActor.assumeIsolated { responses.append(response) } }
        try require(parent.attachedSheet === sheet && sheet.sheetParent === parent, "Native sheet did not attach")
        NativeOwnedWindowCleanup.close([parent, parent, sheet], returnCode: .abort)
        for _ in 0..<500 {
            if responses.count == 1 && parent.attachedSheet == nil && sheet.sheetParent == nil { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        try require(responses == [.abort] && parent.attachedSheet == nil && sheet.sheetParent == nil,
                    "Cleanup lost the original sheet response or actual paired detachment")
        try require(parent.closeCalls == 1 && sheet.closeCalls == 1 && !parent.isVisible && !sheet.isVisible,
                    "Sheet discovery or duplicate targets repeated closure")
        try require(!NSApp.isActive && NSApp.windows.allSatisfy { !$0.isVisible && $0.attachedSheet == nil && $0.sheetParent == nil },
                    "Private cleanup left active/visible windows or linked sheets")
        print("PASS: native owned-window cleanup preserves auxiliary release/content, unique controller/window routes and actual paired-sheet response/drain; no user app or window targeted")
    }
}
