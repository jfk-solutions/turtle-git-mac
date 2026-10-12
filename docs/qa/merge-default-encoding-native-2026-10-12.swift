import AppKit
import SwiftUI
import TurtleGitCore

struct MergeDefaultEncodingVerification {
    @MainActor static func verify() async throws {
        func check(_ value: Bool, _ message: String) throws { if !value { throw NSError(domain: "MergeDefaultEncoding", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) } }
        func wait(_ ready: () -> Bool) async throws { for _ in 0..<1000 { if ready() { return }; try await Task.sleep(nanoseconds: 10_000_000) }; throw NSError(domain: "Default encoding did not settle", code: 1) }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("TurtleGitEncodingNative-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let suite = "TurtleGit.EncodingNative." + UUID().uuidString, prefs = UserDefaults(suiteName: suite)!
        defer { prefs.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root) }
        let transaction = SettingsTransaction(), settingsWindow = NSWindow(contentRect: NSRect(x:0,y:0,width:760,height:840),styleMask:[.titled],backing:.buffered,defer:false)
        settingsWindow.isReleasedWhenClosed = false
        let host = NSHostingView(rootView: MergeEditorSettings(defaults:prefs,commentProfileURL:root.appendingPathComponent("ignorecomments.txt")).environment(\.settingsTransaction,transaction))
        settingsWindow.contentView = host; host.frame = settingsWindow.contentLayoutRect; host.layoutSubtreeIfNeeded()
        defer { transaction.invalidate(); settingsWindow.contentView = nil; settingsWindow.close() }
        func button(_ view:NSView)->NSButton? { if let button=view as? NSButton,button.identifier?.rawValue=="MergeUTF8Default" {return button};return view.subviews.compactMap(button).first }
        try await wait { button(host) != nil }; let choice=button(host)!
        try check(choice.state == .off,"Source default is not false")
        choice.performClick(nil); try await wait { transaction.modified }; transaction.cancel()
        try await wait { choice.state == .off && !transaction.modified }
        choice.performClick(nil); try await wait { transaction.modified }; transaction.apply(closeAfter:false)
        try await wait { !transaction.busy && ComparisonTextEncoding.preferUTF8(from:prefs) && !transaction.modified }
        let base=root.appendingPathComponent("base"),mine=root.appendingPathComponent("mine")
        let ascii=Data("plain ASCII\r\nlast".utf8); try ascii.write(to:base); try ascii.write(to:mine)
        let owner=FileComparisonWindowController(comparison:try WorkingFileComparison(base:base,destination:mine),permissions:[],preferences:prefs)
        defer { owner.window?.close() }
        let model=owner.model; model.commentProfileURL=root.appendingPathComponent("ignorecomments.txt");model.load();try await TwoPaneEngineVerification.settled(model)
        try check(model.encoding(base:false) == .utf8,"Enabled default did not load UTF-8")
        prefs.set(false,forKey:"TurtleGitMerge.UseUTF8");model.refreshPreferences()
        try check(model.encoding(base:false) == .utf8,"Preference silently relabeled an open document")
        model.load();try await TwoPaneEngineVerification.settled(model);try check(model.encoding(base:false) == .windows1252,"Reload did not apply source ASCII default")
        let legacy=Data([0x63,0x61,0x66,0xe9,13,10]);try legacy.write(to:base);try legacy.write(to:mine)
        model.load();try await TwoPaneEngineVerification.settled(model)
        try check(model.draftText(base:false) == "café\r\n" && model.encoding(base:false) == .windows1252,"Legacy file did not load losslessly")
        let theirs=root.appendingPathComponent("theirs");try legacy.write(to:theirs)
        let engine=try WorkingTextMerge(base:base,theirs:theirs,mine:mine)
        let merge=TextConflictWindowController(repository:GitRepository(root:root),access:nil,path:"mine",workingMerge:engine,preferences:prefs)
        defer { merge.window?.close() }
        merge.model.commentProfileURL=root.appendingPathComponent("ignorecomments.txt");merge.model.load()
        try await wait { !merge.model.busy && merge.model.document != nil && merge.model.error == nil }
        try check(merge.model.encoding == .windows1252 && merge.model.document?.baseEncoding == .windows1252 && merge.model.result == "café\r\n","Three-pane decoding/metadata differs")
        let output=root.appendingPathComponent("result");merge.model.chooseStandaloneOutput={_,_ in output};merge.model.result="café edit\r\n";merge.model.save(markResolved:false)
        try await wait { !merge.model.busy && merge.model.workingMergeOutput == output }
        let written=try Data(contentsOf:output), retained=try Data(contentsOf:mine)
        try check(written == Data([0x63,0x61,0x66,0xe9])+Data(" edit\r\n".utf8) && retained == legacy,"Legacy standalone Save changed encoding/input")
        print("Default encoding: native source checkbox Apply/Cancel, ASCII UTF-8/Windows1252 load/reload without relabeling open panes, real legacy two/three-pane decoding and metadata, exact CP1252 standalone Save with inputs retained passed. Owned windows/helpers closed; private preferences only.")
    }
}
