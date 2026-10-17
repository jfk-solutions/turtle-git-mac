// SPDX-License-Identifier: GPL-2.0-or-later
import AppKit
import ScreenCaptureKit
import TurtleGitCore

struct UnifiedFindSourceVerification {
    struct Failure:Error,CustomStringConvertible {let description:String}
    @MainActor static var owners=[PatchWindowController]()
    static func require(_ value:Bool,_ message:String)throws {if !value {throw Failure(description:message)}}
    @MainActor static func wait(line:UInt = #line,_ condition:()->Bool)async throws {
        for _ in 0..<1500 {if condition() {return};try await Task.sleep(nanoseconds:10_000_000)}
        throw Failure(description:"Unified Find did not settle at fixture line \(line)")
    }
    @MainActor static func views(_ view:NSView)->[NSView] {[view]+view.subviews.flatMap(views)}
    @MainActor static func capture(_ owner:PatchWindowController,_ label:String)async throws {
        guard let directory=ProcessInfo.processInfo.environment["TURTLEGIT_UNIFIED_FIND_CAPTURE"],let window=owner.window else{return}
        guard #available(macOS 14.4,*) else {throw Failure(description:"Native capture API unavailable")}
        window.alphaValue=1;window.orderFront(nil);defer{window.alphaValue=0}
        for (name,suffix) in [(NSAppearance.Name.aqua,"light"),(.darkAqua,"dark")] {
            window.appearance=NSAppearance(named:name);window.contentView?.layoutSubtreeIfNeeded()
            try await Task.sleep(nanoseconds:250_000_000)
            let content=try await SCShareableContent.currentProcess
            guard let own=content.windows.first(where:{$0.windowID==CGWindowID(window.windowNumber)}) else {throw Failure(description:"Owned patch capture missing")}
            let options=SCStreamConfiguration();options.width=Int(window.frame.width*2);options.height=Int(window.frame.height*2)
            options.showsCursor=false;options.ignoreShadowsSingleWindow=true;options.includeChildWindows=false
            let image=try await SCScreenshotManager.captureImage(contentFilter:SCContentFilter(desktopIndependentWindow:own),configuration:options)
            try NSBitmapImageRep(cgImage:image).representation(using:.png,properties:[:])!.write(to:URL(fileURLWithPath:directory).appendingPathComponent(label+"-"+suffix+".png"))
            print("Captured \(label)-\(suffix): \(options.width)x\(options.height)")
        }
    }
    @MainActor static func verify()async throws {
        let root=URL(fileURLWithPath:CommandLine.arguments[1]),engine=URL(fileURLWithPath:CommandLine.arguments[2]),repository=GitRepository(root:root,executable:engine)
        let suite="TurtleGit.UnifiedFind.QA."+UUID().uuidString,preferences=UserDefaults(suiteName:suite)!
        defer{owners.forEach{$0.close()};owners=[];preferences.removePersistentDomain(forName:suite)}
        let owner=PatchWindowController(repository:repository,access:nil,preferences:preferences),model=owner.model,window=owner.window!
        owners.append(owner);window.alphaValue=0;window.orderFront(nil)
        model.readOnly=true;model.document=GitPatch(text:"🦎 Straße\nSTRASSE\ncafé cafe\u{301}\nİ ı Σς\nlast needle")
        window.contentView?.layoutSubtreeIfNeeded()
        func source()->PatchTextView.PatchText? {views(window.contentView!).compactMap{$0 as? PatchTextView.PatchText}.first}
        try await wait {source()?.string.utf8.elementsEqual(model.document.text.utf8)==true && model.sourceAttached()}
        let text=source()!
        text.setSelectedRange(NSRange(location:0,length:0));model.showFind()
        let context=model.findContext,field=model.findField(context:context),matchCase=model.findCase(context:context)
        field.wrappedValue="STRASSE"
        try require(text.selectedRange()==NSRange(location:3,length:6),"Native UTF-16 expanding fold result")
        model.search(previous:false,context:context)
        try require((text.string as NSString).substring(with:text.selectedRange())=="STRASSE","Native Next lost source range")
        matchCase.wrappedValue=true;field.wrappedValue="cafe\u{301}"
        try require((text.string as NSString).substring(with:text.selectedRange()).utf8.elementsEqual("cafe\u{301}".utf8),"Native Find normalized Unicode")
        let query=model.findText,selection=text.selectedRange()
        model.hideFind(context:context);field.wrappedValue="hidden";matchCase.wrappedValue=false;model.search(previous:false,context:context)
        try require(!model.findVisible && model.findText.utf8.elementsEqual(query.utf8) && model.findMatchCase && text.selectedRange()==selection,"Hidden Find accepted retained fields/actions")
        text.setSelectedRange(NSRange(location:0,length:0));model.showFind()
        field.wrappedValue="reopened"
        try require(model.findText.utf8.elementsEqual(query.utf8),"Reopened Find revived old controls")
        let beforeBusy=model.findContext
        model.busy=true;model.busy=false
        model.findField(context:beforeBusy).wrappedValue="old busy roundtrip"
        try require(model.findText.utf8.elementsEqual(query.utf8),"Busy roundtrip revived old field")
        let beforeQuestion=model.findContext
        model.confirmingQuit=true;model.confirmingQuit=false
        model.hideFind(context:beforeQuestion)
        try require(model.findVisible,"Dismissed question revived old Close Find")
        let beforeDocument=model.findContext
        model.setReadOnlyDiff(Data("different needle\nStraße".utf8));try await wait {text.string=="different needle\nStraße"}
        model.findField(context:beforeDocument).wrappedValue="old document"
        try require(model.findText.utf8.elementsEqual(query.utf8),"Replacement document accepted retained query")
        let beforeDetach=model.findContext,oldSelect=model.selectSource,oldFocus=model.focusSource
        let scroll=text.enclosingScrollView!
        scroll.documentView=nil
        try require(!model.canUseFind(beforeDetach),"Detached editor accepted Find")
        oldSelect(NSRange(location:2,length:2));oldFocus()
        scroll.documentView=text
        try await wait {model.sourceAttached()}
        model.findField(context:beforeDetach).wrappedValue="old attachment"
        try require(model.findText.utf8.elementsEqual(query.utf8),"Reattachment revived an old bar")
        let staleSelection=text.selectedRange()
        let fresh=PatchWindowModel(repository:repository,access:nil,appearancePreferences:preferences)
        text.coordinator?.model=fresh
        oldSelect(NSRange(location:0,length:1));oldFocus()
        try require(text.selectedRange()==staleSelection,"Old registered callback changed a rebound editor")
        text.coordinator?.model=model
        model.hideFind();model.readOnly=false
        model.document=GitPatch(text:"diff --git a/example.swift b/example.swift\nindex 1234567..7654321 100644\n--- a/example.swift\n+++ b/example.swift\n@@ -1,3 +1,4 @@\n let turtle = true\n-let label = \"STRASSE\"\n+let label = \"Straße\"\n+let nativeFind = true\n let colorful = true\n")
        try await wait {text.string==model.document.text}
        text.setSelectedRange(NSRange(location:0,length:0));model.showFind();model.findMatchCase=false;model.changeFindText("STRASSE")
        window.setContentSize(NSSize(width:460,height:500));try await capture(owner,"partial-find-source")
        model.hideFind();model.readOnly=true;model.readOnlyInformation="Read-only comparison. Search preserves the original patch bytes.";model.comparisonTitle="Unified Diff"
        window.setContentSize(NSSize(width:1000,height:600));model.showFind();model.changeFindText("Straße")
        try await capture(owner,"unified-find-source")
        let retired=model.findContext,retiredField=model.findField(context:retired)
        owner.close();retiredField.wrappedValue="retired";model.hideFind(context:retired)
        try require(model.retired && model.findText=="Straße" && !model.canUseFind(retired),"Retired Find accepted controls")
        print("PASS: Unified Find source controls, literal pinned Unicode matching, document/close/busy/question/attachment generations and stale native callback ownership")
    }
}
