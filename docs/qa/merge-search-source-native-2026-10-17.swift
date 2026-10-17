// SPDX-License-Identifier: GPL-2.0-or-later
import AppKit
import ScreenCaptureKit
import TurtleGitCore

struct MergeSearchSourceVerification {
    struct Failure: Error { let message: String }
    static func require(_ yes: Bool, _ message: String) throws { if !yes { throw Failure(message: message) } }
    @MainActor static func wait(_ yes: () -> Bool) async throws {
        for _ in 0..<2000 { if yes() { return }; try await Task.sleep(nanoseconds: 10_000_000) }
        throw Failure(message: "Search source timeout")
    }
    @MainActor static func capture(_ window: NSWindow, name: String, into folder: URL) async throws {
        guard #available(macOS 14.4, *) else { throw Failure(message: "Capture requires macOS 14.4") }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for (appearance, suffix) in [(NSAppearance.Name.aqua, "light"), (.darkAqua, "dark")] {
            window.appearance = NSAppearance(named: appearance); window.alphaValue = 1; window.orderFront(nil); window.contentView?.layoutSubtreeIfNeeded()
            try await Task.sleep(nanoseconds: 250_000_000)
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
            guard let own = content.windows.first(where: { $0.windowID == CGWindowID(window.windowNumber) }) else { throw Failure(message: "Capture owner missing") }
            let options = SCStreamConfiguration(); options.includeChildWindows = false; options.width = Int(window.frame.width*2); options.height = Int(window.frame.height*2); options.showsCursor = false
            let image = try await SCScreenshotManager.captureImage(contentFilter: SCContentFilter(desktopIndependentWindow: own), configuration: options)
            guard let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else { throw Failure(message: "PNG missing") }
            try data.write(to: folder.appendingPathComponent(name + "-" + suffix + ".png"))
        }
        window.orderOut(nil); window.alphaValue = 0
    }
    @MainActor static func verify() async throws {
        let fm = FileManager.default, root = fm.temporaryDirectory.appendingPathComponent("TurtleGitSearchSource-" + UUID().uuidString)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        let suite = "TurtleGit.SearchSource." + UUID().uuidString, prefs = UserDefaults(suiteName: suite)!
        defer { prefs.removePersistentDomain(forName: suite); try? fm.removeItem(at: root) }
        MergeGeneralPreferences(firstDifference: false, firstConflict: false).save(to: prefs)
        let base = root.appendingPathComponent("base.txt"), mine = root.appendingPathComponent("mine.txt")
        let originals = [Data("head foo\nbase foo\ntail\n".utf8), Data("head foo\nmine foo\ntail\n".utf8)]
        try originals[0].write(to: base); try originals[1].write(to: mine)
        let owner = FileComparisonWindowController(comparison: try WorkingFileComparison(base: base, destination: mine), permissions: [], preferences: prefs)
        defer { owner.close() }; owner.window?.alphaValue = 0; owner.window?.orderFront(nil); owner.model.load()
        try await TwoPaneEngineVerification.settled(owner.model)
        let editors = TwoPaneEngineVerification.editors(owner.window?.contentView)
        let right = editors.first { $0.string.contains("mine foo") }!, left = editors.first { $0.string.contains("base foo") }!
        let target = right as! MergeFindProviding, navigation = right as! (NSTextView & MergeLineNavigationProviding)
        try require(target.mergeFindPaneID == 2 && (left as! MergeFindProviding).mergeFindPaneID == 1, "Source pane identity differs")
        prefs.set(["old history"], forKey: "TurtleGitMerge.History.Find.Search")
        right.setSelectedRange(NSRange(location: 0, length: 0))
        let find = MergeFindWindowController(text: right, defaults: prefs); target.mergeFindController = find; find.present(show: false)
        defer { find.close() }; find.window?.alphaValue = 0; find.window?.orderOut(nil)
        try require(find.search.stringValue.isEmpty && find.search.numberOfItems == 1, "Unselected first opening used history as query")
        find.search.stringValue = "draft"; right.setSelectedRange(NSRange(location: 5, length: 3)); find.present(show: false)
        try require(find.search.stringValue == "draft", "Existing Find command reseeded a draft")
        find.search.stringValue = "foo"; find.searchUp.state = .on; find.count()
        try require(find.status.stringValue == "2 match(es).", "Find Count differs")
        find.window?.setFrameOrigin(NSPoint(x: owner.window!.frame.minX + 90, y: owner.window!.frame.minY + 90)); find.count()
        let firstPosition = prefs.array(forKey: "TurtleGitMerge.FindDlgOffset.2") as? [Double]
        try require(firstPosition?.count == 2, "Pane-relative offset not saved")
        let query = target.mergeFindHighlights.query, history = prefs.stringArray(forKey: "TurtleGitMerge.History.Find.Search")
        find.close(); try require(target.mergeFindController == nil && !find.countButton.isEnabled && !find.search.isEnabled, "Closed Find retained pane ownership or controls")
        find.search.stringValue = "retired"; find.count(); find.find(); find.replace(all: true); find.present(show: false)
        try require(target.mergeFindHighlights.query == query && prefs.stringArray(forKey: "TurtleGitMerge.History.Find.Search") == history && find.window?.parent == nil, "Retired Find accepted commands")
        let reopened = MergeFindWindowController(text: right, defaults: prefs); target.mergeFindController = reopened; reopened.present(show: false)
        defer { reopened.close() }; reopened.window?.alphaValue = 0; reopened.window?.orderOut(nil)
        try require(reopened !== find && reopened.search.stringValue == "foo" && reopened.searchUp.state == .off, "Recreated Find lost selection seed/session reset")
        reopened.count()
        let restored = prefs.array(forKey: "TurtleGitMerge.FindDlgOffset.2") as? [Double]
        try require(restored == firstPosition, "Pane-relative position did not restore")
        let source = MergeFindWindowController(text: left, defaults: prefs); (left as! MergeFindProviding).mergeFindController = source
        defer { source.close() }; source.present(show: false); source.window?.setFrameOrigin(NSPoint(x: owner.window!.frame.minX + 10, y: owner.window!.frame.minY + 20)); source.search.stringValue = "foo"; source.count()
        try require(prefs.array(forKey: "TurtleGitMerge.FindDlgOffset.1") != nil && prefs.array(forKey: "TurtleGitMerge.FindDlgOffset.2") as? [Double] == restored, "Source pane overwrote peer Find placement")
        reopened.search.stringValue = ""; reopened.wholeWord.state = .on; reopened.status.stringValue = "previous result"; reopened.count()
        try require(prefs.bool(forKey: "TurtleGitMerge.FindWholeWord") && reopened.status.stringValue.isEmpty && reopened.countButton.isEnabled, "Empty Count did not persist source options/clear status")
        // A pending Go to Line excludes Find and owns Quit independently of editor visibility.
        var held: CheckedContinuation<Int?, Never>?
        navigation.chooseNavigationLine = { _, _ in await withCheckedContinuation { held = $0 } }
        navigation.navigateToSourceLine(); try await wait { held != nil }; reopened.updateGates()
        try require(!reopened.countButton.isEnabled && !reopened.matchCase.isEnabled && !reopened.search.isEnabled && MergeNavigationRequests.activeRequests == 1, "Pending navigation did not fence Find")
        let committed = target.mergeFindHighlights.query; reopened.search.stringValue = "new query"; reopened.count()
        try require(target.mergeFindHighlights.query == committed && TurtleGitApplicationDelegate().applicationShouldTerminate(NSApplication.shared) == .terminateCancel, "Pending navigation allowed search/Quit")
        held?.resume(returning: 3); held = nil; try await wait { !navigation.navigationPending && MergeNavigationRequests.activeRequests == 0 }
        try require(right.selectedRange().location == "head foo\nmine foo\n".utf16.count, "Go to Line did not map original third line")
        reopened.updateGates(); reopened.search.stringValue = "foo"; reopened.wholeWord.state = .off; reopened.count()
        if let path = ProcessInfo.processInfo.environment["TURTLEGIT_SEARCH_SOURCE_CAPTURE"], let window = reopened.window { try await capture(window, name: "merge-find-source", into: URL(fileURLWithPath: path)) }
        let prompt = MergeLineNumberPrompt(limit: 3); defer { prompt.close() }; prompt.window?.alphaValue = 0
        var answers: [Int?] = []; prompt.present(owner: owner.window!) { answers.append($0) }
        try require(prompt.field.stringValue.isEmpty && !prompt.ok.isEnabled && prompt.window?.sheetParent === owner.window, "Native Go to Line initial layout/owner differs")
        for invalid in ["", "0", "4", "-1", " 1", "１", "1.5", "999999999999999999999999"] {
            prompt.field.stringValue = invalid; prompt.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification)); prompt.accept()
            try require(!prompt.ok.isEnabled && answers.isEmpty && !prompt.status.stringValue.isEmpty, "Invalid Go to Line input accepted")
        }
        prompt.field.stringValue = "02"; prompt.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification))
        try require(prompt.ok.isEnabled && prompt.status.stringValue.isEmpty, "Valid Go to Line input disabled")
        if let path = ProcessInfo.processInfo.environment["TURTLEGIT_SEARCH_SOURCE_CAPTURE"] {
            // Capture the unchanged production prompt on its own: ScreenCaptureKit
            // folds an attached sheet into the alpha-zero owner/child window group.
            let standalone = MergeLineNumberPrompt(limit: 3); defer { standalone.close() }
            standalone.field.stringValue = "02"; standalone.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification))
            if let window = standalone.window { try await capture(window, name: "merge-goto-source", into: URL(fileURLWithPath: path)) }
        }
        prompt.accept(); prompt.accept(); try require(answers.count == 1 && answers[0] == 2 && prompt.window?.sheetParent == nil, "Go to Line response not single use")
        let cancelled = MergeLineNumberPrompt(limit: 3); defer { cancelled.close() }; cancelled.window?.alphaValue = 0
        var cancelledAnswers: [Int?] = []; cancelled.present(owner: owner.window!) { cancelledAnswers.append($0) }; cancelled.close(); cancelled.accept()
        try require(cancelledAnswers.count == 1 && cancelledAnswers[0] == nil, "Cancel accepted a stale line")
        navigation.navigateToSourceLine(); try await wait { held != nil }
        let abandoned = MergeLineNumberPrompt(limit: 3); defer { abandoned.close() }; abandoned.window?.alphaValue = 0
        var abandonedAnswers: [Int?] = []; abandoned.present(owner: owner.window!) { abandonedAnswers.append($0) }
        owner.close(); try require(abandonedAnswers.count == 1 && abandonedAnswers[0] == nil && abandoned.window?.sheetParent == nil, "Owner closure did not cancel the native prompt")
        try require(target.mergeFindController == nil && (left as! MergeFindProviding).mergeFindController == nil && MergeNavigationRequests.activeRequests == 1, "Owner closure lost search or pending navigation lifetime")
        try require(TurtleGitApplicationDelegate().applicationShouldTerminate(NSApplication.shared) == .terminateCancel, "Retired navigation allowed Quit before drain")
        held?.resume(returning: 1); held = nil; try await wait { MergeNavigationRequests.activeRequests == 0 }
        try require(try Data(contentsOf: base) == originals[0] && Data(contentsOf: mine) == originals[1], "Search/navigation changed input bytes")
        print("PASS Merge search source: fresh Find ownership/draft/session gates, separate relative pane positions, empty Count options, pending/retired navigation Quit drain and native Go to Line validation/Cancel/single response; input bytes unchanged")
    }
}
