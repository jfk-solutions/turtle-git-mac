import AppKit
import SwiftUI
import TurtleGitCore

struct MergeDefaultEncodingVerification {
    @MainActor static func verify() async throws {
        func check(_ value: Bool, _ message: String) throws { if !value { throw NSError(domain: "MergeDefaultEncoding", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) } }
        var observation:()->String = {"bootstrap"}
        func wait(_ phase:String,_ ready: () -> Bool) async throws {
            for _ in 0..<1000 {if ready(){print("Default encoding phase passed: "+phase);return};try await Task.sleep(nanoseconds:10_000_000)}
            throw NSError(domain:"MergeDefaultEncoding",code:1,userInfo:[NSLocalizedDescriptionKey:"Default encoding timeout: "+phase+"; "+observation()])
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("TurtleGitEncodingNative-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let suite = "TurtleGit.EncodingNative." + UUID().uuidString, prefs = UserDefaults(suiteName: suite)!
        defer { prefs.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root) }
        let transaction = SettingsTransaction(), settingsWindow = NSWindow(contentRect: NSRect(x:0,y:0,width:760,height:840),styleMask:[.titled],backing:.buffered,defer:false)
        settingsWindow.isReleasedWhenClosed = false;settingsWindow.alphaValue=0;settingsWindow.setFrameOrigin(.init(x:-24000,y:-24000))
        let settingsModel=MergeEditorSettingsModel(defaults:prefs,commentProfileURL:root.appendingPathComponent("ignorecomments.txt"))
        let host = NSHostingView(rootView: MergeEditorSettings(defaults:prefs,commentProfileURL:root.appendingPathComponent("ignorecomments.txt"),model:settingsModel).environment(\.settingsTransaction,transaction))
        settingsWindow.contentView = host; host.frame = settingsWindow.contentLayoutRect;settingsWindow.orderFront(nil);host.layoutSubtreeIfNeeded()
        defer { transaction.invalidate(); settingsWindow.contentView = nil; settingsWindow.close() }
        func button(_ view:NSView)->NSButton? { if let button=view as? NSButton,button.identifier?.rawValue=="MergeUTF8Default" {return button};return view.subviews.compactMap(button).first }
        var captured:NSButton?
        observation={
            let mounted=button(host)
            return "mounted=\(mounted.map{String(describing:ObjectIdentifier($0))} ?? "nil") captured=\(captured.map{String(describing:ObjectIdentifier($0))} ?? "nil") mountedState=\(mounted?.state.rawValue ?? -1) capturedState=\(captured?.state.rawValue ?? -1) enabled=\(mounted?.isEnabled ?? false) target=\(mounted?.target != nil) attached=\(mounted?.window === settingsWindow) modelAttached=\(settingsModel.window === settingsWindow) active=\(settingsModel.active) preferUTF8=\(settingsModel.preferUTF8) changed=\(settingsModel.changed) modified=\(transaction.modified) busy=\(transaction.busy) stored=\(String(describing:prefs.object(forKey:"TurtleGitMerge.UseUTF8"))) context=\(settingsModel.editContext)"
        }
        try await wait("checkbox owner mount") {settingsWindow.isVisible && settingsModel.window === settingsWindow && settingsModel.active && button(host)?.isEnabled == true}
        // The owner probe rotates the captured edit generation on attachment.
        // Require the hosting display transaction before acting on its controls;
        // an unordered host can expose a stale pre-attachment binding forever.
        await withCheckedContinuation {reply in DispatchQueue.main.async{host.layoutSubtreeIfNeeded();host.displayIfNeeded();reply.resume()}}
        try await wait("checkbox source default") {button(host)?.state == .off && !transaction.modified}
        guard let choice=button(host) else{throw NSError(domain:"MergeDefaultEncoding",code:2)};captured=choice
        try check(choice.state == .off,"Source default is not false")
        choice.performClick(nil); try await wait("first native edit") {transaction.modified && settingsModel.preferUTF8}; transaction.cancel()
        try await wait("Cancel restores mounted checkbox") {button(host)?.state == .off && !settingsModel.preferUTF8 && !transaction.modified}
        // Restore/Apply may replace a representable or retire its old binding.
        // Target the currently mounted native control, not the earlier object.
        guard let reapplied=button(host) else{throw NSError(domain:"MergeDefaultEncoding",code:3)};captured=reapplied
        reapplied.performClick(nil); try await wait("second native edit") {transaction.modified && settingsModel.preferUTF8}; transaction.apply(closeAfter:false)
        try await wait("Apply persists UTF8") { !transaction.busy && ComparisonTextEncoding.preferUTF8(from:prefs) && !transaction.modified }
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
        let settingsObservation=observation
        observation={settingsObservation()+" mergeBusy=\(merge.model.busy) mergeDocument=\(merge.model.document != nil) mergeError=\(merge.model.error ?? "none") output=\(merge.model.workingMergeOutput?.path ?? "nil")"}
        try await wait("three-pane legacy load") { !merge.model.busy && merge.model.document != nil && merge.model.error == nil }
        try check(merge.model.encoding == .windows1252 && merge.model.document?.baseEncoding == .windows1252 && merge.model.result == "café\r\n","Three-pane decoding/metadata differs")
        let output=root.appendingPathComponent("result");merge.model.chooseStandaloneOutput={_,_ in output};merge.model.result="café edit\r\n";merge.model.save(markResolved:false)
        try await wait("standalone legacy Save") { !merge.model.busy && merge.model.workingMergeOutput == output }
        let written=try Data(contentsOf:output), retained=try Data(contentsOf:mine)
        try check(written == Data([0x63,0x61,0x66,0xe9])+Data(" edit\r\n".utf8) && retained == legacy,"Legacy standalone Save changed encoding/input")
        print("Default encoding: native source checkbox Apply/Cancel, ASCII UTF-8/Windows1252 load/reload without relabeling open panes, real legacy two/three-pane decoding and metadata, exact CP1252 standalone Save with inputs retained passed. Owned windows/helpers closed; private preferences only.")
    }
}
