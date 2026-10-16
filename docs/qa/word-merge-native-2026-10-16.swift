import AppKit
import TurtleGitCore
@main struct WordMergeNativeVerification {
    struct Failure:Error,LocalizedError { let message:String;var errorDescription:String? { message } }
    static func require(_ value:Bool,_ message:String) throws { if !value { throw Failure(message:message) } }
    @MainActor static func wait(_ ready:()->Bool,line:Int = #line) async throws { for _ in 0..<1500 { if ready() { return }; try await Task.sleep(nanoseconds:10_000_000) };throw Failure(message:"Word merge timeout at \(line)") }
    @MainActor static func main() async {
        NSApplication.shared.setActivationPolicy(.prohibited)
        do { try await verify() } catch { fputs("Word merge failed: \(error)\n",stderr);exit(1) }
    }
    @MainActor static func verify() async throws {
        let root=URL(fileURLWithPath:CommandLine.arguments[1]),repo=GitRepository(root:root,executable:URL(fileURLWithPath:CommandLine.arguments[2]))
        _=try await repo.run(["init","-b","main"])
        for (key,value) in [("user.name","Word Merge QA"),("user.email","qa@example.invalid"),("commit.gpgsign","false"),("core.hooksPath","/dev/null")] { _=try await repo.run(["config",key,value]) }
        let path="conflict \" 雪.docx",file=root.appendingPathComponent(path)
        try Data([0,1,255]).write(to:file);try await repo.stage([path]);_=try await repo.commit(message:"base")
        _=try await repo.run(["checkout","-b","side"]);try Data([0,3,253]).write(to:file);try await repo.stage([path]);_=try await repo.commit(message:"theirs")
        _=try await repo.run(["checkout","main"]);try Data([0,2,254]).write(to:file);try await repo.stage([path]);_=try await repo.commit(message:"mine")
        _=try await repo.run(["merge","--no-edit","side"],successfulExitCodes:0...1)
        let input=try await repo.externalMergeInputs(path:path),index=root.appendingPathComponent(".git/index"),before=try Data(contentsOf:index),working=try Data(contentsOf:file),head=try await repo.run(["rev-parse","HEAD"]).stdout
        let owner=NSWindow(contentRect:.init(x:0,y:0,width:500,height:250),styleMask:[.titled,.closable],backing:.buffered,defer:false);owner.isReleasedWhenClosed=false;owner.alphaValue=0;owner.orderFront(nil)
        defer { owner.close() }
        let oldExecutor=MergeToolApplication.mergeWord,oldConfigure=MergeToolApplication.configureWordSession
        defer { MergeToolApplication.mergeWord=oldExecutor;MergeToolApplication.configureWordSession=oldConfigure }
        var copies:[URL]=[];defer { for folder in copies { try? FileManager.default.removeItem(at:folder) } }
        let suite="TurtleGit.WordMergeNative."+UUID().uuidString,prefs=UserDefaults(suiteName:suite)!;defer{prefs.removePersistentDomain(forName:suite)}
        var custom=DiffToolAssociation();custom.pattern=".txt";custom.program.enabled=false
        let associations=ToolAssociationsModel(associations:[custom],tool:"merge");associations.restoreDefaults()
        try require(associations.valid && associations.draft.count==4 && associations.draft.contains(custom) && associations.draft.first{$0.id==associations.selected}?.pattern==".docx","Native Merge Restore Defaults lost rows/selection")
        var initial=MergeToolPreferences();initial.associations=[custom];try initial.save(to:prefs)
        let draft=ToolSettingsDraft(initial,valid:{$0.valid},persist:{try $0.save(to:prefs)})
        draft.value.associations=associations.draft;try require(MergeToolPreferences.load(from:prefs)==initial,"Merge defaults persisted before Apply")
        draft.cancel();try require(draft.value==initial,"Merge Cancel retained new defaults")
        draft.value.associations=associations.draft;try require(draft.apply() && MergeToolPreferences.load(from:prefs)==draft.value,"Merge Apply lost Word defaults")
        var settings=MergeToolPreferences();settings.restoreBundledAssociations();settings.blockWhileMerging=true
        var calls=0,questions:[String]=[]
        MergeToolApplication.mergeWord={ preview,_ in
            calls += 1;copies.append(preview.directory)
            try require((try Data(contentsOf:preview.base))==input.base && (try Data(contentsOf:preview.mine))==input.mine && (try Data(contentsOf:preview.theirs))==input.theirs,"Word merge lost exact stage bytes/orientation")
            let args=WordComparisonAutomation.mergeEvent(preview).paramDescriptor(forKeyword:0x2d2d2d2d)
            try require(args?.numberOfItems==4 && args?.atIndex(1)?.stringValue==preview.base.path && args?.atIndex(2)?.stringValue==preview.theirs.path && args?.atIndex(3)?.stringValue==preview.mine.path && args?.atIndex(4)?.stringValue==file.path,"Word merge paths were interpolated/retargeted")
            try Data("private reviewed mine".utf8).write(to:preview.mine)
        }
        MergeToolApplication.configureWordSession={ session in session.presentConfirmation={ _,alert,reply in
            questions.append(alert.buttons[0].title)
            if alert.buttons[0].title=="OK" { reply(.alertFirstButtonReturn) }
            else { precondition(alert.buttons[1].keyEquivalent=="\r");reply(.alertSecondButtonReturn);reply(.alertFirstButtonReturn) }
        } }
        let opened=try await MergeToolApplication.open(repository:repo,access:nil,path:path,alternate:false,owner:owner,preferences:settings)
        try require(opened && calls==1 && questions==["OK","Mark Resolved"] && (try Data(contentsOf:index))==before && (try Data(contentsOf:file))==working,"Word No changed the real result/index or repeated confirmation")
        MergeToolApplication.discardAll();try require(FileManager.default.fileExists(atPath:copies[0].path),"Word merge private files lost after accepted handoff")
        var denied:URL?
        MergeToolApplication.mergeWord={ preview,_ in denied=preview.directory;copies.append(preview.directory);throw WordMergeFailure.automation(-1743,"denied",possiblyOpened:false) }
        do { _=try await MergeToolApplication.open(repository:repo,access:nil,path:path,alternate:false,owner:owner,preferences:settings);throw Failure(message:"Denied Word merge succeeded") }
        catch let failure as WordMergeFailure { try require(!failure.possiblyOpened,"Denied merge considered opened") }
        try require(denied != nil && !FileManager.default.fileExists(atPath:denied!.path) && (try Data(contentsOf:index))==before,"Denied Word merge leaked files or staged")
        var pendingReply:((NSApplication.ModalResponse)->Void)?
        MergeToolApplication.configureWordSession={ session in session.presentConfirmation={ _,_,reply in pendingReply=reply } }
        let retiring=NSWindow(contentRect:.init(x:0,y:0,width:500,height:250),styleMask:[.titled,.closable],backing:.buffered,defer:false);retiring.isReleasedWhenClosed=false;retiring.alphaValue=0;retiring.orderFront(nil)
        defer { retiring.close() }
        let cancelled=Task { try await MergeToolApplication.open(repository:repo,access:nil,path:path,alternate:false,owner:retiring,preferences:settings) }
        try await wait { pendingReply != nil };retiring.close();pendingReply?(.alertFirstButtonReturn);pendingReply?(.alertFirstButtonReturn);_=try await cancelled.value
        try require(calls==1 && MergeToolApplication.activeRequests==0 && (try Data(contentsOf:index))==before,"Closed instructions allowed a late merge or released an unfinished operation")
        var worker:CheckedContinuation<Void,Error>?,late:URL?
        MergeToolApplication.configureWordSession={ session in session.presentConfirmation={ _,_,reply in reply(.alertFirstButtonReturn) } }
        MergeToolApplication.mergeWord={ preview,_ in late=preview.directory;copies.append(preview.directory);try await withCheckedThrowingContinuation { worker=$0 } }
        let retiringWorker=NSWindow(contentRect:.init(x:0,y:0,width:500,height:250),styleMask:[.titled,.closable],backing:.buffered,defer:false);retiringWorker.isReleasedWhenClosed=false;retiringWorker.alphaValue=0;retiringWorker.orderFront(nil)
        defer { retiringWorker.close() }
        let waiting=Task { try await MergeToolApplication.open(repository:repo,access:nil,path:path,alternate:false,owner:retiringWorker,preferences:settings) }
        try await wait { worker != nil };retiringWorker.close()
        try require(MergeToolApplication.activeRequests==1 && TurtleGitApplicationDelegate().applicationShouldTerminate(NSApp) == .terminateCancel,"Closed merge worker released Quit early")
        worker?.resume();worker=nil;_=try await waiting.value
        try require(late != nil && FileManager.default.fileExists(atPath:late!.path) && (try Data(contentsOf:index))==before,"Late accepted Word merge lost inputs or resolved")
        let reviewed=Data("reviewed document bytes".utf8)
        MergeToolApplication.mergeWord={ preview,_ in copies.append(preview.directory);try reviewed.write(to:preview.result) }
        _=try await MergeToolApplication.open(repository:repo,access:nil,path:path,alternate:false,owner:owner,preferences:settings)
        let staged=try await repo.run(["show",":"+path]).stdout,remaining=try await repo.conflicts()
        try require(staged==reviewed && remaining.isEmpty,"Explicit Mark Resolved did not stage the saved original result")
        if ProcessInfo.processInfo.environment["TURTLEGIT_CHECK_WORD_TERMINOLOGY"]=="1" {
            _=try WordComparisonAutomation.compile(merging:true)
            try require(WordComparisonAutomation.source.contains("set automation security to 3") && WordComparisonAutomation.mergeSource.contains("set automation security to previousSecurity"),"Word macro suppression/restoration absent")
            print("PASS: Word merge fixed handler compiled against installed terminology; no Word operation executed")
        }
        try require(try await repo.run(["rev-parse","HEAD"]).stdout==head,"Word merge changed HEAD")
        print("PASS: Word three-way stage copies/descriptor routing, source instructions, No/late answer refusal, explicit reviewed result staging, permission cleanup and retired worker/Quit; unchanged HEAD")
    }
}
