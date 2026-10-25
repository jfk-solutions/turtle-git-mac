// SPDX-License-Identifier: GPL-2.0-or-later
import AppKit
import ScreenCaptureKit
import TurtleGitCore

private final class MergeOpenSourceScopes: RepositoryBookmarkProvider {
    var acquired: [Data] = [], released: [Data] = []
    func create(for url: URL) throws -> Data { Data(url.path.utf8) }
    func resolve(_ data: Data) throws -> ResolvedBookmark { .init(url:FileTransferPaths.fileURL(String(decoding:data,as:UTF8.self)),stale:false) }
    func startAccessing(_ url: URL) -> Bool { acquired.append(Data(url.path.utf8)); return true }
    func stopAccessing(_ url: URL) { released.append(Data(url.path.utf8)) }
}

struct MergeOpenSourceVerification {
    struct Failure: Error { let message: String }
    @MainActor static func require(_ yes: Bool, _ message: String) throws { if !yes { throw Failure(message: message) } }
    @MainActor static func wait(_ yes: () -> Bool) async throws {
        for _ in 0..<2000 { if yes() { return }; try await Task.sleep(nanoseconds: 10_000_000) }
        throw Failure(message: "Open source timeout")
    }
    @MainActor static func views(_ root: NSView?) -> [NSView] { guard let root else { return [] }; return [root] + root.subviews.flatMap { views($0) } }
    @MainActor static func capture(_ window: NSWindow, into folder: URL) async throws {
        guard #available(macOS 14.4, *) else { throw Failure(message: "Capture requires macOS 14.4") }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for (name, suffix) in [(NSAppearance.Name.aqua, "light"), (.darkAqua, "dark")] {
            window.appearance = NSAppearance(named: name); window.alphaValue = 1; window.orderFront(nil); window.contentView?.layoutSubtreeIfNeeded()
            try await Task.sleep(nanoseconds: 250_000_000)
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
            guard let own = content.windows.first(where: { $0.windowID == CGWindowID(window.windowNumber) }) else { throw Failure(message: "Capture owner missing") }
            let options = SCStreamConfiguration(); options.width = Int(window.frame.width*2); options.height = Int(window.frame.height*2); options.showsCursor = false
            let image = try await SCScreenshotManager.captureImage(contentFilter: SCContentFilter(desktopIndependentWindow: own), configuration: options)
            guard let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else { throw Failure(message: "Capture PNG missing") }
            try data.write(to: folder.appendingPathComponent("merge-open-source-" + suffix + ".png"))
        }
        window.orderOut(nil); window.alphaValue = 0
    }
    @MainActor static func verify() async throws {
        let fm = FileManager.default, root = fm.temporaryDirectory.appendingPathComponent("TurtleGitOpenSource-" + UUID().uuidString)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        let base = root.appendingPathComponent("base.txt"), mine = root.appendingPathComponent("mine.txt"), patch = root.appendingPathComponent("changes.patch")
        for (file, text) in [(base, "base\n"), (mine, "mine\n"), (patch, "--- a/base.txt\n+++ b/base.txt\n@@ -1 +1 @@\n-base\n+mine\n")] { try Data(text.utf8).write(to: file) }
        let original = try [base, mine, patch].map { try Data(contentsOf: $0) }
        let suite = "TurtleGit.OpenSource." + UUID().uuidString, prefs = UserDefaults(suiteName: suite)!
        let board = NSPasteboard(name: NSPasteboard.Name("TurtleGit.OpenSource." + UUID().uuidString))
        var owners: [MergeOpenWindowController] = []
        defer { owners.forEach { $0.close() }; board.releaseGlobally(); prefs.removePersistentDomain(forName: suite); try? fm.removeItem(at: root) }
        func opener() -> MergeOpenWindowController {
            let owner = MergeOpenWindowController(preferences: prefs, pasteboard: board); owner.window?.alphaValue = 0; owners.append(owner); return owner
        }
        let owner = opener(); owner.setMode(.merging); owner.base.stringValue = base.path; owner.mine.stringValue = mine.path
        var reply: ((NSApplication.ModalResponse) -> Void)?, panel: NSOpenPanel?, selected = mine, leaseCalls = 0
        let scopes = MergeOpenSourceScopes()
        weak var latestLease: RepositoryAccessLease?
        owner.presentPicker = { chooser, _, completion in panel = chooser; reply = completion }
        owner.selectedPath = { _ in selected }
        owner.makeLease = { url in
            leaseCalls += 1
            let lease = RepositoryAccessLease(url:url,provider:scopes); latestLease = lease; return lease
        }
        owner.browse(.base)
        try await wait { reply != nil }
        try require(owner.busy && MergeOpenWindowController.activeChoices == 1 && !owner.ok.isEnabled && !owner.apply.isEnabled, "Chooser gates missing")
        try require(panel?.canChooseFiles == true && panel?.canChooseDirectories == false && panel?.allowsMultipleSelection == false && panel?.directoryURL?.path == root.path, "Source file chooser settings/seed differ")
        owner.browse(.mine); owner.accept(); owner.setMode(.applyUnifiedDiff)
        try require(owner.mode == .merging && MergeOpenWindowController.activeChoices == 1, "Competing request accepted")
        // An externally edited form invalidates the pending response; duplicate callbacks drain only once.
        owner.mine.stringValue = base.path; reply?(.OK); reply?(.OK)
        try await wait { !owner.busy && MergeOpenWindowController.activeChoices == 0 }
        try require(owner.base.stringValue == base.path && leaseCalls == 0 && scopes.acquired.isEmpty, "Changed form consumed an obsolete choice")
        owner.mine.stringValue = mine.path; reply = nil; owner.browse(.base); try await wait { reply != nil }
        selected = root; reply?(.OK); try await wait { !owner.busy }
        try require(leaseCalls == 1 && scopes.acquired == [Data(root.path.utf8)] && scopes.released == scopes.acquired && latestLease == nil && owner.base.stringValue == base.path && owner.status.stringValue == "Select an existing regular file.", "Wrong-type file selection was accepted, changed its field or retained its temporary grant")
        reply = nil; owner.browse(.base); try await wait { reply != nil }; selected = mine; reply?(.OK)
        try await wait { !owner.busy }; try require(owner.base.stringValue == mine.path && leaseCalls == 2 && scopes.released.count == 1 && latestLease != nil && owner.status.stringValue.isEmpty, "Valid file did not replace captured slot and retain only its own grant")
        weak var acceptedLease = latestLease
        owner.setMode(.applyUnifiedDiff); owner.directory.stringValue = root.path
        reply = nil; owner.browse(.directory); try await wait { reply != nil }
        try require(panel?.canChooseDirectories == true && panel?.canChooseFiles == false && panel?.directoryURL?.path == root.path, "Directory picker settings/seed differ")
        selected = mine; reply?(.OK); try await wait { !owner.busy }
        try require(owner.directory.stringValue == root.path && leaseCalls == 3 && scopes.released.count == 2 && latestLease == nil && acceptedLease != nil && owner.status.stringValue == "Select an existing directory.", "Wrong-type directory selection was accepted or retained, or discarded the earlier valid grant")
        owner.diff.stringValue = patch.path; reply = nil; owner.browse(.diff); try await wait { reply != nil }
        try require(panel?.allowsOtherFileTypes == true && panel?.allowedContentTypes.isEmpty == false, "Source patch/all-files filter absent")
        reply?(.cancel); try await wait { !owner.busy }
        try require(owner.diff.stringValue == patch.path && leaseCalls == 3 && scopes.acquired.count == 3 && scopes.released.count == 2 && acceptedLease != nil, "Cancel changed input or acquired/released an unrelated grant")
        let retired = opener(); retired.setMode(.merging)
        var held: CheckedContinuation<URL?, Never>?
        var retiredLeaseCalls = 0
        retired.makeLease = { url in retiredLeaseCalls += 1; return RepositoryAccessLease(url:url,provider:scopes) }
        retired.choosePath = { _, _ in await withCheckedContinuation { held = $0 } }
        retired.browse(.base); try await wait { held != nil }; retired.close()
        try require(MergeOpenWindowController.activeChoices == 1 && TurtleGitApplicationDelegate().applicationShouldTerminate(NSApplication.shared) == .terminateCancel, "Forced-close picker lost independent Quit lifetime")
        held?.resume(returning: base); held = nil; try await wait { MergeOpenWindowController.activeChoices == 0 }
        try require(retired.base.stringValue.isEmpty && !retired.ok.isEnabled && retiredLeaseCalls == 0 && scopes.acquired.count == 3, "Retired picker republished a result or acquired a late grant")
        let submission = opener(); submission.setMode(.merging); submission.base.stringValue = base.path; submission.mine.stringValue = mine.path
        var attempts = 0
        submission.onAccepted = { _, _ in attempts += 1; submission.accept(); throw Failure(message: "expected preparation failure") }
        submission.accept(); try require(attempts == 1 && submission.ok.isEnabled && !submission.status.stringValue.isEmpty, "Failed/reentrant submission did not preserve retry")
        submission.onAccepted = { _, _ in attempts += 1; submission.accept(); submission.setMode(.applyUnifiedDiff) }
        submission.accept(); submission.accept()
        try require(attempts == 2 && prefs.integer(forKey: "TurtleGitMerge.OpenRadio") == 0 && !submission.ok.isEnabled, "Successful submission duplicated or saved a changed mode")
        owner.setMode(.merging); owner.base.stringValue = base.path; owner.mine.stringValue = mine.path; owner.status.stringValue = ""
        let all = views(owner.window?.contentView)
        try require(Set(all.compactMap { ($0 as? NSBox)?.title }) == Set(["Merging", "Apply unified diff"]), "Source groups absent")
        try require(all.compactMap { $0 as? NSButton }.filter { $0.title == "Browse…" }.count == 5, "Source Browse slots missing")
        if let path = ProcessInfo.processInfo.environment["TURTLEGIT_MERGE_OPEN_CAPTURE"], let window = owner.window { try await capture(window, into: URL(fileURLWithPath: path)) }
        try require(try [base, mine, patch].map { try Data(contentsOf: $0) } == original, "Open controls changed input bytes")
        owners.forEach { $0.close() }; try await wait { MergeOpenWindowController.activeChoices == 0 }
        print("PASS Merge Open source: configured native panels, captured form/slot, grant-before-metadata with wrong-type release, Cancel/duplicate/retired replies without extra grants, independent Quit drain, reentrant retry/success and unchanged input bytes")
    }
}
