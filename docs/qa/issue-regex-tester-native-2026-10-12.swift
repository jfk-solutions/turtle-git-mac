import AppKit
import TurtleGitCore

@main struct IssueRegexTesterVerification {
    @MainActor static func main() async {do {try await verify()}catch{fputs("Regex tester failed: \(error)\n",stderr);exit(1)}}
    @MainActor static func verify() async throws {
        func require(_ value:Bool,_ message:String)throws{if !value{throw NSError(domain:message,code:1)}}
        func wait(_ ready:()->Bool)async throws{for _ in 0..<1000{if ready(){return};try await Task.sleep(nanoseconds:10_000_000)};throw NSError(domain:"Regex tester did not settle",code:1)}
        let helper=URL(fileURLWithPath:FileManager.default.currentDirectoryPath).appendingPathComponent("build/Build/Products/Debug/TurtleGitMac.app/Contents/Helpers/IssueRegex/issue-regex")
        let suite="TurtleGit.RegexTester.QA."+UUID().uuidString,prefs=UserDefaults(suiteName:suite)!,clipboard=NSPasteboard(name:NSPasteboard.Name("TurtleGit.RegexTester."+UUID().uuidString))
        defer{prefs.removePersistentDomain(forName:suite);clipboard.clearContents()}
        let model=IssueRegexTesterModel(check:"#([0-9]+)",executable:helper,preferences:prefs,clipboard:clipboard),controller=IssueRegexTesterController(model:model)
        defer{controller.close()}
        var completion:(String,String)?,completed=0
        controller.completed={completion=$0;completed += 1}
        try await wait{!model.busy}
        let expected=try IssueRegexRuntime.match(message:model.message,check:model.check,executable:helper)
        try require(model.ranges==expected.ranges && !model.ranges.isEmpty && model.error==nil,"Source sample extraction differs")
        controller.window?.contentView?.layoutSubtreeIfNeeded()
        func editor(_ view:NSView)->IssueRegexSampleTextView?{if let value=view as? IssueRegexSampleTextView{return value};return view.subviews.compactMap{editor($0)}.first}
        try await wait{controller.window?.contentView.flatMap{editor($0)} != nil}
        let native=editor(controller.window!.contentView!)!
        try await wait{native.textStorage?.attribute(.underlineStyle,at:model.ranges[0].location,effectiveRange:nil) != nil}
        try require(native.isEditable && native.allowsUndo && native.string==IssueRegexTesterModel.sample,"Native sample editor differs")
        native.setSelectedRange(model.ranges[0]);native.copy(nil)
        try require(clipboard.string(forType:.string)=="55","Copy did not use private UTF-16 issue selection")
        try require(native.sampleMenu().items.map(\.title)==["Cut","Copy","Paste","Select All"] && native.sampleMenu().items.allSatisfy{$0.image != nil},"Native sample context icons/order differ")
        let beforeTyping=native.string
        native.undoManager?.removeAllActions();native.setSelectedRange(NSRange(location:(native.string as NSString).length,length:0))
        clipboard.clearContents();clipboard.setString("#901",forType:.string);native.paste(nil)
        try await wait{!model.busy}
        try require(model.message==beforeTyping+"#901" && native.string==model.message,"Native Paste did not update sample/model")
        let pasted=model.ranges.last!;native.setSelectedRange(pasted);native.cut(nil);try await wait{!model.busy}
        try require(clipboard.string(forType:.string)=="901" && model.message==beforeTyping+"#","Native Cut did not preserve plain text/private clipboard")
        for name in [NSAppearance.Name.aqua,.darkAqua]{native.appearance=NSAppearance(named:name);native.layoutSubtreeIfNeeded();try require(native.textStorage?.attribute(.foregroundColor,at:model.ranges[0].location,effectiveRange:nil) as? NSColor != nil,"Issue color missing")}
        model.message="😀 雪 #42 and #7";try await wait{!model.busy}
        let unicode=try IssueRegexRuntime.match(message:model.message,check:model.check,executable:helper)
        try require(model.ranges==unicode.ranges && (model.message as NSString).substring(with:model.ranges[0])=="42","UTF-16 Unicode extraction differs")
        model.check="#[0-9]+";model.extract="[0-9]+";try await wait{!model.busy}
        try require(model.ranges==unicode.ranges,"Two-expression matching differs")
        model.check="(";try await wait{!model.busy}
        try require(model.error != nil && model.ranges==unicode.ranges,"Invalid expression lost last valid styling")
        model.message="😀 #9";try await wait{!model.busy}
        try require(model.error != nil && model.ranges.count==1 && (model.message as NSString).substring(with:model.ranges[0])=="9","Invalid edit did not restyle current message using prior expressions")
        model.check="";model.extract="(";try await wait{!model.busy};try require(model.error != nil,"Empty first field skipped second-field validation")
        model.check="  #([0-9]+)  ";model.extract="";try await wait{!model.busy};try require(model.error==nil,"Valid expression did not recover")
        controller.finish(accept:true);controller.finish(accept:false)
        try require(completed==1 && completion?.0=="#([0-9]+)" && completion?.1=="" && !model.canAccept,"OK return/trimming/once-only completion differs")
        let late=IssueRegexTesterModel(check:"#([0-9]+)",executable:helper,preferences:prefs,clipboard:clipboard),lateController=IssueRegexTesterController(model:late)
        defer{lateController.close()};try await wait{!late.busy}
        let captured=try IssueRegexRuntime.match(message:"#100",check:"#([0-9]+)",executable:helper)
        var held:CheckedContinuation<IssueRegexMatch,Error>?,calls=0
        late.matcher={_,_,_,_ in calls += 1;if calls==1{return try await withCheckedThrowingContinuation{held=$0}};return try IssueRegexRuntime.match(message:"#8",check:"#([0-9]+)",executable:helper)}
        late.message="#100";try await wait{held != nil}
        try require(TurtleGitApplicationDelegate().applicationShouldTerminate(NSApplication.shared) == .terminateCancel,"Quit did not wait for owned matcher")
        late.message="#8";try await wait{calls==2 && !late.busy};let latest=late.ranges
        held?.resume(returning:captured);held=nil;try await wait{IssueRegexTesterModel.activeRequests==0}
        try require(late.ranges==latest && (late.message as NSString).substring(with:latest[0])=="8","Late matcher overwrote newer preview")
        calls=0;late.message="#100";try await wait{held != nil};let before=late.ranges;var closed=0
        lateController.completed={value in try! require(value==nil,"Close accepted a result");closed += 1}
        lateController.close();held?.resume(returning:captured);held=nil;try await wait{IssueRegexTesterModel.activeRequests==0}
        try require(closed==1 && !late.busy && late.ranges==before && !late.canAccept,"Retired matcher published or completed twice")
        print("Regex Tester: source sample, native editable issue styling/private clipboard/icon menu/light-dark hosts, single/two-expression C++ matching, Unicode UTF-16 offsets, invalid recovery and prior-expression styling, trimmed OK/Cancel once-only, debounce/newer-preview/retirement fences and owned matcher Quit accounting passed. No Git/config writes or general clipboard.")
    }
}
