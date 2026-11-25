import AppKit
import TurtleGitCore

struct MergeGeneralVerification {
    struct Failure:Error,CustomStringConvertible {let description:String}
    @MainActor static func verify() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("TurtleGitMergeGeneral-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let suite = "TurtleGit.MergeGeneralNative." + UUID().uuidString, defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: folder) }
        let base = folder.appendingPathComponent("before.cpp"), mine = folder.appendingPathComponent("after.cpp")
        var a = (0..<250).map { "unchanged row \($0)\n" }; a[150] = "stable prefix value 1 suffix constant\n"
        a[60]="untouched 🦎 café e\u{301} 雪\n";a[61]="second line naïve Ω\n"
        var b = a; b[150] = "stable prefix value 2 suffix constant\n"
        let baseBytes = Data(a.joined().utf8), mineBytes = Data(b.joined().utf8)
        try baseBytes.write(to: base); try mineBytes.write(to: mine)
        var preferences = MergeGeneralPreferences(fontName: "Missing source family", fontSize: 10)
        preferences.save(to: defaults)
        let controller = FileComparisonWindowController(comparison: try WorkingFileComparison(base: base, destination: mine), permissions: [],preferences:defaults)
        defer { NativeOwnedWindowCleanup.close([controller.window!],returnCode:.abort) }
        controller.window?.alphaValue=0;controller.window?.setFrameOrigin(.init(x:-24000,y:-24000));controller.showWindow(nil)
        let model = controller.model;model.commentProfileURL = folder.appendingPathComponent("ignorecomments.txt")
        func editors()->[NSTextView] {
            TwoPaneEngineVerification.editors(controller.window?.contentView).filter {
                !$0.isFieldEditor && $0.window === controller.window && !$0.isHiddenOrHasHiddenAncestor && $0.enclosingScrollView?.documentView === $0
            }
        }
        func diagnostic()->String {
            let fields=editors().map{"id=\(ObjectIdentifier($0)),selection=\($0.selectedRange()),font=\(String(describing:$0.font?.pointSize)),length=\($0.string.utf16.count)"}
            return "busy=\(model.busy),filtering=\(model.filtering),initial=\(model.initialNavigationPending),selections=\(model.alignmentSelections.keys),generation=\(model.alignmentGeneration),difference=\(model.difference),firstDifference=\(model.generalPreferences.firstDifference),dirty=\(model.dirty),undo=\(model.canUndo),error=\(String(reflecting:model.error)),editors=\(fields)"
        }
        func require(_ value:Bool,_ phase:String)throws {if !value {throw Failure(description:"Merge General \(phase): "+diagnostic())}}
        @MainActor func wait(_ phase:String,_ ready:()->Bool)async throws {
            for _ in 0..<1000 {
                controller.window?.contentView?.layoutSubtreeIfNeeded()
                if ready(){return}
                try await Task.sleep(nanoseconds:10_000_000)
            }
            throw Failure(description:"Merge General timeout \(phase): "+diagnostic())
        }
        @MainActor func settled(_ phase:String)async throws {
            try await wait(phase){!model.busy && !model.filtering && !model.hasPendingEditorChoice && !model.confirmingQuit && model.alignmentSelections.isEmpty && !model.initialNavigationPending && editors().count==2}
        }
        model.load();try await settled("initial current native editors")
        try require(model.difference == 0 && !model.dirty,"initial first difference")
        try await wait("fixed-pitch fallback"){editors().count==2 && editors().allSatisfy{$0.font?.pointSize==10 && $0.font?.isFixedPitch==true}}
        let initialViews=editors(),selected=initialViews.map{$0.selectedRange()},identities=initialViews.map(ObjectIdentifier.init),generation=model.alignmentGeneration
        model.showInlineDiff = true; model.inlineWordDiff = false
        try require(model.inlineDifference(150) != nil,"initial inline difference")
        preferences.fontName = "Menlo"; preferences.fontSize = 16; preferences.maximumInlineLength = 2
        preferences.save(to: defaults); model.refreshPreferences()
        try await wait("live font sizes"){editors().count==2 && editors().allSatisfy{$0.font?.pointSize==16}}
        try require(editors().map(ObjectIdentifier.init)==identities && model.inlineDifference(150)==nil && editors().map{$0.selectedRange()}==selected,"live font refresh changed current owner/selection or inline limit")
        try require(model.alignmentGeneration==generation && !model.dirty && !model.canUndo,"live preferences rebuilt alignment/history")
        // This is a fresh load, not LoadViews(-1)'s retained-position operation.
        // Pin MainFrm.cpp1086–1113 suppresses automatic difference navigation;
        // establish the unchanged header caret independently of the earlier
        // font-refresh selection-preservation oracle and reacquire current views.
        let header=NSRange(location:0,length:0)
        for view in editors(){view.setSelectedRange(header)}
        preferences.firstDifference = false; preferences.firstConflict = false; preferences.save(to: defaults)
        model.load();try await settled("fresh load with first difference disabled")
        try await wait("disabled first-difference current header projection"){editors().count==2 && editors().allSatisfy{$0.selectedRange()==header}}
        try require(!model.generalPreferences.firstDifference && !model.generalPreferences.firstConflict && model.difference == -1 && !model.initialNavigationPending,"disabled first navigation")
        try require(!model.dirty && !model.canUndo,"disabled reload created edits/history")
        // Preserve an authored UTF-16 range across both a native restyle and
        // the temporary provisional/verified projections of a clean reload.
        let selectedText="🦎 café e\u{301} 雪\nsecond line naïve Ω"
        let unicodeRange=(a.joined() as NSString).range(of:selectedText)
        try require(unicodeRange.location != NSNotFound && unicodeRange.length>selectedText.count,"Unicode multiline fixture range")
        let selectedViews=editors(),unicodeGeneration=model.alignmentGeneration
        guard let destination=selectedViews.first(where:{$0.accessibilityLabel()=="Destination file"}),
              controller.window?.makeFirstResponder(destination)==true else {throw Failure(description:"Current destination refused native selection focus: "+diagnostic())}
        for view in selectedViews {view.setSelectedRange(unicodeRange)}
        try require(editors().allSatisfy{$0.selectedRange()==unicodeRange && ($0.string as NSString).substring(with:unicodeRange)==selectedText},"authored Unicode multiline native selection")
        preferences.fontSize=17;preferences.save(to:defaults);model.refreshPreferences()
        try await wait("Unicode selection native font restyle"){editors().count==2 && editors().allSatisfy{$0.font?.pointSize==17}}
        try require(model.alignmentGeneration==unicodeGeneration && editors().allSatisfy{$0.selectedRange()==unicodeRange},"Unicode native restyle selection/generation")
        model.load();try await settled("Unicode selection provisional/verified reload")
        try await wait("Unicode multiline current projection"){editors().count==2 && editors().allSatisfy{$0.selectedRange()==unicodeRange && ($0.string as NSString).substring(with:unicodeRange)==selectedText}}
        try require(!model.generalPreferences.firstDifference && model.difference == -1 && !model.dirty && !model.canUndo,"Unicode reload navigation/history")
        preferences.firstDifference = true; preferences.save(to: defaults)
        model.load();try await settled("fresh load with first difference enabled")
        try require(model.generalPreferences.firstDifference && model.difference==0 && !model.canUndo && !model.dirty,"enabled first navigation")
        let finalBase=try Data(contentsOf:base),finalMine=try Data(contentsOf:mine)
        try require(finalBase==baseBytes && finalMine==mineBytes,"preferences/reloads changed input bytes")
        NativeOwnedWindowCleanup.close([controller.window!],returnCode:.abort)
        try await wait("closed owner helper drain"){MergeRegexOperations.activeRequests==0 && controller.window?.isVisible != true && controller.window?.attachedSheet==nil}
        print("Merge General: native fixed-pitch fallback/live font sizes, current-owner selection and history preservation, actual inline-length gating, fresh-load first-difference enabled/disabled navigation, Unicode multiline restyle/reload preservation and unchanged input bytes passed. Owned window closed.")
    }
}
