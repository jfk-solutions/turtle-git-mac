// SPDX-License-Identifier: GPL-2.0-or-later
import AppKit
import SwiftUI
import ScreenCaptureKit
import TurtleGitCore

struct IssueTrackerSourceVerification {
    struct Failure:Error,CustomStringConvertible {let description:String}
    static func require(_ yes:Bool,_ message:String)throws {if !yes {throw Failure(description:message)}}
    @MainActor static func wait(_ yes:()->Bool,line:UInt = #line)async throws {for _ in 0..<2500 {if yes(){return};try await Task.sleep(nanoseconds:10_000_000)};throw Failure(description:"Issue source timeout at \(line)")}
    @MainActor static func views(_ root:NSView?)->[NSView] {guard let root else{return []};return [root]+root.subviews.flatMap{views($0)}}
    @MainActor static func capture(_ window:NSWindow,name:String,folder:URL)async throws {
        guard #available(macOS 14.4,*) else {throw Failure(description:"Capture requires macOS 14.4")}
        try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
        for (mode,suffix) in [(NSAppearance.Name.aqua,"light"),(.darkAqua,"dark")] {
            window.appearance=NSAppearance(named:mode);window.alphaValue=1;window.orderFront(nil);window.contentView?.layoutSubtreeIfNeeded();try await Task.sleep(nanoseconds:250_000_000)
            try require(window.frame.height<=1100,"Issue window escaped native bounds")
            let content=try await SCShareableContent.excludingDesktopWindows(false,onScreenWindowsOnly:false)
            guard let own=content.windows.first(where:{$0.windowID==CGWindowID(window.windowNumber)}) else {throw Failure(description:"Capture owner missing")}
            let config=SCStreamConfiguration();config.includeChildWindows=false;config.width=Int(window.frame.width*2);config.height=Int(window.frame.height*2);config.showsCursor=false
            let pixels=try await SCScreenshotManager.captureImage(contentFilter:SCContentFilter(desktopIndependentWindow:own),configuration:config)
            guard let png=NSBitmapImageRep(cgImage:pixels).representation(using:.png,properties:[:]) else {throw Failure(description:"PNG missing")}
            try png.write(to:folder.appendingPathComponent(name+"-"+suffix+".png"))
        };window.orderOut(nil);window.alphaValue=0
    }
    @MainActor static func verify()async throws {
        let root=URL(fileURLWithPath:CommandLine.arguments[1]),repo=GitRepository(root:root,executable:URL(fileURLWithPath:CommandLine.arguments[2]))
        _=try await repo.run(["init","-b","main"]);_=try await repo.run(["config","bugtraq.label","é"]);_=try await repo.run(["config","bugtraq.url","https://issues.invalid/%BUGID%"]);_=try await repo.run(["config","bugtraq.logregex","#([0-9]+)"])
        let suite="TurtleGit.IssueSource."+UUID().uuidString,prefs=UserDefaults(suiteName:suite)!,transaction=SettingsTransaction(),workspace=RepositoryModel(startMonitoring:false)
        let model=IssueTrackerSettingsModel(preferences:prefs);model.authorizeFile={_ in true};model.confirmSavingTo={_ in true}
        let helper=URL(fileURLWithPath:FileManager.default.currentDirectoryPath).appendingPathComponent("build/Build/Products/Debug/TurtleGitMac.app/Contents/Helpers/IssueRegex/issue-regex")
        model.regexExecutable=helper
        let window=NSWindow(contentRect:.init(x:0,y:0,width:820,height:960),styleMask:[.titled,.closable,.resizable],backing:.buffered,defer:false)
        window.title="Issue Tracker Config – TurtleGit";window.isReleasedWhenClosed=false;window.alphaValue=0
        let viewport=SettingsPageViewport(frame:.zero),host=NSHostingView(rootView:IssueTrackerSettingsPage(workspace:workspace,model:model,contextProvider:{(repo,nil,true)},preferences:prefs).environment(\.settingsTransaction,transaction))
        window.contentView=viewport;viewport.pageDocument.addSubview(host);host.translatesAutoresizingMaskIntoConstraints=false
        NSLayoutConstraint.activate([host.leadingAnchor.constraint(equalTo:viewport.pageDocument.leadingAnchor),host.trailingAnchor.constraint(equalTo:viewport.pageDocument.trailingAnchor),host.topAnchor.constraint(equalTo:viewport.pageDocument.topAnchor),host.bottomAnchor.constraint(equalTo:viewport.pageDocument.bottomAnchor)])
        defer {model.invalidate();transaction.invalidate();window.close();prefs.removePersistentDomain(forName:suite)}
        window.orderFront(nil);viewport.layoutSubtreeIfNeeded();try await wait {model.loaded && !model.busy && model.window===window}
        let effective=model.editContext;model.chooseSource(.local,context:effective);try await wait {model.source == .local && model.loaded && !model.busy}
        let context=model.editContext,old=model.fieldBinding(.label,context:model.editContext),before=model.state
        model.fieldBinding(.label,context:effective).wrappedValue="wrong source"
        try require(model.draft.fields[.label]?.value=="é","Effective-source callback reached Local")
        model.inheritBinding(.label,context:context).wrappedValue=true;old.wrappedValue="old field"
        try require(model.draft.fields[.label]?.value=="é" && model.draft.fields[.label]?.inherit==true,"Inherited field accepted old text")
        model.cancel();old.wrappedValue="after cancel"
        try require(!model.modified && model.draft.fields[.label]?.value=="é","Cancel left prior callbacks active")
        let decomposed="e\u{301}"
        model.fieldBinding(.label,context:model.editContext).wrappedValue=decomposed
        try require(model.modified && model.state != before,"Equivalent Unicode spelling was lost from draft state")
        try await wait {transaction.modified};transaction.apply(closeAfter:false);try await wait {!transaction.busy && !model.busy}
        let written=try await repo.issueTrackerSettings(source:.local)
        try require(transaction.error==nil && !model.modified && written.fields[.label]?.value.utf8.elementsEqual(decomposed.utf8)==true,"Exact Unicode spelling did not reach config: transaction=\(String(describing:transaction.error)), model=\(String(describing:model.error)), modified=\(model.modified), active=\(model.active), source=\(model.source), destination=\(model.destination), written=\(Array((written.fields[.label]?.value ?? "").utf8)), draft=\(Array((model.draft.fields[.label]?.value ?? "").utf8))")
        // Tester result must describe the same complete parent draft and destination.
        var child:IssueRegexTesterController?
        model.presentTester={value,_ in child=value;return true};model.testRegex()
        try require(model.hasTester,"Owned tester missing")
        model.destination = .project;child?.model.check="changed";child?.finish(accept:true)
        try require(!model.hasTester && model.draft.fields[.regex]?.value=="#([0-9]+)","Tester overwrote a changed destination/draft")
        model.cancel()
        // No write follows a held destination decision for a replaced draft.
        model.draft.fields[.label]=GitConfigurationIdentity(value:"captured",inherit:false);model.destination = .global
        var answer:CheckedContinuation<Bool,Never>?
        model.confirmSavingTo={_ in await withCheckedContinuation {answer=$0}}
        let configBefore=try Data(contentsOf:root.appendingPathComponent(".git/config"))
        let save=Task {await model.apply(owner:window)};try await wait {answer != nil}
        model.fieldBinding(.label,context:model.editContext).wrappedValue="disabled field"
        try require(model.draft.fields[.label]?.value=="captured","Busy field callback changed pending save")
        model.draft.fields[.label]=GitConfigurationIdentity(value:"newer",inherit:false);answer?.resume(returning:true);answer=nil
        let saved=await save.value,configAfter=try Data(contentsOf:root.appendingPathComponent(".git/config"))
        try require(!saved && configBefore==configAfter && model.draft.fields[.label]?.value=="newer" && model.modified,"Changed save context wrote or lost draft")
        model.cancel();model.confirmSavingTo={_ in true}
        if let path=ProcessInfo.processInfo.environment["TURTLEGIT_ISSUE_SOURCE_CAPTURE"] {try await capture(window,name:"issue-tracker-source",folder:URL(fileURLWithPath:path))}
        // Actual sample editor handles UTF-16 offset changes for equivalent text.
        let clipboard=NSPasteboard(name:.init("TurtleGit.IssueSource."+UUID().uuidString));defer{clipboard.clearContents()}
        let regex=IssueRegexTesterModel(check:"#([0-9]+)",executable:helper,preferences:prefs,clipboard:clipboard),tester=IssueRegexTesterController(model:regex)
        defer{tester.close()};tester.window?.alphaValue=0;tester.window?.orderFront(nil)
        try await wait {!regex.busy && views(tester.window?.contentView).contains{$0 is IssueRegexSampleTextView}}
        let editor=views(tester.window?.contentView).compactMap{$0 as? IssueRegexSampleTextView}.first!
        regex.message="é #42";try await wait {!regex.busy && regex.ranges.first?.location==3}
        regex.message="e\u{301} #42";try await wait {!regex.busy && regex.ranges.first?.location==4 && editor.string.utf8.elementsEqual(regex.message.utf8)}
        editor.setSelectedRange(.init(location:(editor.string as NSString).length,length:0));regex.message="x"
        try await wait {!regex.busy && editor.string=="x"};try require(editor.selectedRange().location<=1,"Shortened sample kept out-of-bounds selection")
        regex.message="é #42 and #7";try await wait {!regex.busy && regex.ranges.count==2}
        if let path=ProcessInfo.processInfo.environment["TURTLEGIT_ISSUE_SOURCE_CAPTURE"] {try await capture(tester.window!,name:"issue-regex-source",folder:URL(fileURLWithPath:path))}
        let bound=regex.binding(\.check),check=regex.check,message=regex.message
        editor.setSelectedRange(regex.ranges[0]);clipboard.clearContents();clipboard.setString("sentinel",forType:.string)
        tester.close();bound.wrappedValue="late";editor.copy(nil);editor.cut(nil);editor.paste(nil)
        try require(regex.check==check && regex.message==message && clipboard.string(forType:.string)=="sentinel","Retired tester/clipboard callback survived")
        // Hidden Settings Apply is authorized; closed-owner Apply is not.
        window.orderFront(nil);model.activate(repository:repo,access:nil,localAvailable:true)
        model.fieldBinding(.label,context:model.editContext).wrappedValue="hidden save";let hidden=model.fieldBinding(.label,context:model.editContext)
        host.removeFromSuperview();try await wait { !model.active };hidden.wrappedValue="hidden callback"
        let applied=await model.apply(owner:window)
        try require(applied && !model.active && !model.modified && model.draft.fields[.label]?.value=="hidden save","Hidden Apply/reactivation fence failed")
        window.close();try require(!(await model.apply(owner:window)),"Closed owner applied settings")
        try await wait {IssueTrackerSettingsModel.activeReads==0 && IssueTrackerSettingsModel.activeSaves==0 && IssueRegexTesterModel.activeRequests==0}
        print("PASS native issue source: source/inheritance/captured fields, exact Unicode settings and UTF-16 sample offsets, coherent confirmation/tester results, private writes, hidden Apply/closed-owner refusal and retired clipboard/editor guards")
    }
}
