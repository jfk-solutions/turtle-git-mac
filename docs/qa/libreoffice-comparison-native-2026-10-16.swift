import AppKit
import TurtleGitCore
@main struct LibreOfficeComparisonNativeVerification {
    struct Failure:Error,LocalizedError { let message:String;var errorDescription:String? { message } }
    static func require(_ value:Bool,_ message:String) throws { if !value { throw Failure(message:message) } }
    @MainActor static func wait(_ ready:()->Bool,line:Int = #line) async throws { for _ in 0..<1500 { if ready() { return }; try await Task.sleep(nanoseconds:10_000_000) };throw Failure(message:"LibreOffice merge timeout at \(line)") }
    @MainActor static func main() async {
        NSApplication.shared.setActivationPolicy(.prohibited)
        do { try await verify() } catch { fputs("LibreOffice merge failed: \(error)\n",stderr);exit(1) }
    }
    @MainActor static func verifyDiff(root:URL) async throws {
        let bundle=root.appendingPathComponent("Fake LibreOffice.app"),python=bundle.appendingPathComponent("Contents/Frameworks/LibreOfficePython.framework/Versions/Current/Resources/Python.app")
        let executable=python.appendingPathComponent("Contents/MacOS/Python"),office=bundle.appendingPathComponent("Contents/MacOS/soffice")
        for file in [executable,office] {try FileManager.default.createDirectory(at:file.deletingLastPathComponent(),withIntermediateDirectories:true);try Data("#!/bin/sh\nexit 0\n".utf8).write(to:file);try FileManager.default.setAttributes([.posixPermissions:0o700],ofItemAtPath:file.path)}
        try PropertyListSerialization.data(fromPropertyList:["CFBundleIdentifier":"org.turtlegit.qa.python","CFBundleExecutable":"Python","CFBundlePackageType":"APPL"],format:.xml,options:0).write(to:python.appendingPathComponent("Contents/Info.plist"))
        let runtime=try LibreOfficeComparisonAutomation.Runtime(bundle:bundle)
        try require(runtime.application.resolvingSymlinksInPath().path==python.resolvingSymlinksInPath().path && runtime.office.path==office.path,"LibreOffice nested runtime discovery failed: app=\(runtime.application.path), expected=\(python.path), office=\(runtime.office.path), expectedOffice=\(office.path)")
        let a=root.appendingPathComponent("base # %.odt"),b=root.appendingPathComponent("new \" 雪.odt")
        let old=Data([0,1,255]),new=Data([0,2,254]);try old.write(to:a);try new.write(to:b)
        let suite="TurtleGit.LibreOfficeNative."+UUID().uuidString,prefs=UserDefaults(suiteName:suite)!
        let saved=DiffToolApplication.compareLibreOffice
        var owners:[FileComparisonWindowController]=[],copies:[URL]=[],calls=0
        defer{DiffToolApplication.compareLibreOffice=saved;prefs.removePersistentDomain(forName:suite);owners.forEach{$0.close()};copies.forEach{try? FileManager.default.removeItem(at:$0)}}
        DiffToolApplication.compareLibreOffice={ preview,_ in
            calls += 1;copies.append(preview.directory)
            if NSWorkspace.shared.urlForApplication(withBundleIdentifier:"org.libreoffice.script") == nil {
                do{try await LibreOfficeComparisonAutomation.compare(preview,cancellation:.init());throw Failure(message:"Missing LibreOffice runtime accepted")}
                catch LibreOfficeComparisonFailure.application {}
            }
            try JSONEncoder().encode(LibreOfficeComparisonPreview.Receipt(success:true,possiblyOpened:true,message:"")).write(to:preview.reply)
            try require(try LibreOfficeComparisonAutomation.readReceipt(preview).success,"Valid UNO receipt rejected")
            try Data(repeating:0,count:65_537).write(to:preview.reply)
            do {_ = try LibreOfficeComparisonAutomation.readReceipt(preview);throw Failure(message:"Oversized receipt accepted")}catch let failure as LibreOfficeComparisonFailure {try require(failure.possiblyOpened,"Malformed receipt lost uncertainty")}
            try require((try Data(contentsOf:preview.base))==old && (try Data(contentsOf:preview.destination))==new,"LibreOffice diff lost exact bytes")
        }
        func controller()throws->FileComparisonWindowController{let c=try FileComparisonWindowController(comparison:WorkingFileComparison(base:a,destination:b),permissions:[],preferences:prefs,deferInitialLoad:true);owners.append(c);return c}
        let first=try controller();first.model.beginTransferredDocument();try await wait{!first.model.busy && calls==1}
        try require(first.model.error==nil,"LibreOffice native default route failed")
        let raw=try controller();raw.model.captureToolChoice(true);raw.model.beginTransferredDocument();try await wait{!raw.model.busy}
        try require(calls==1 && raw.model.document?.destination.bytes==new,"LibreOffice Shift bypass lost bytes")
        var denied:URL?
        DiffToolApplication.compareLibreOffice={ preview,_ in denied=preview.directory;throw LibreOfficeComparisonFailure.application }
        let unavailable=try controller();unavailable.model.beginTransferredDocument();try await wait{!unavailable.model.busy}
        try require(unavailable.model.error?.contains("LibreOffice")==true && denied != nil && !FileManager.default.fileExists(atPath:denied!.path),"Unavailable runtime lost cleanup/error")
        var completion:CheckedContinuation<Void,Error>?,late:URL?
        DiffToolApplication.compareLibreOffice={preview,_ in copies.append(preview.directory);late=preview.directory;try await withCheckedThrowingContinuation{completion=$0}}
        let retired=try controller();retired.model.beginTransferredDocument();try await wait{completion != nil};retired.close()
        try require(DiffToolApplication.activeRequests==1 && TurtleGitApplicationDelegate().applicationShouldTerminate(NSApp) == .terminateCancel,"Retired LibreOffice runtime lost Quit ownership")
        completion?.resume();completion=nil;try await wait{DiffToolApplication.activeRequests==0}
        try require(late != nil && FileManager.default.fileExists(atPath:late!.path) && retired.model.error==nil,"Late accepted comparison removed copies or published obsolete error")
        try require((try Data(contentsOf:a))==old && (try Data(contentsOf:b))==new,"LibreOffice modified original inputs")
    }
    @MainActor static func verify() async throws {
        let root=URL(fileURLWithPath:CommandLine.arguments[1]); try await verifyDiff(root:root)
        let repo=GitRepository(root:root,executable:URL(fileURLWithPath:CommandLine.arguments[2]))
        _=try await repo.run(["init","-b","main"])
        for (key,value) in [("user.name","LibreOffice QA"),("user.email","qa@example.invalid"),("commit.gpgsign","false"),("core.hooksPath","/dev/null")] { _=try await repo.run(["config",key,value]) }
        let path="conflict \" 雪.odt",file=root.appendingPathComponent(path)
        try Data([0,1,255]).write(to:file);try await repo.stage([path]);_=try await repo.commit(message:"base")
        _=try await repo.run(["checkout","-b","side"]);try Data([0,3,253]).write(to:file);try await repo.stage([path]);_=try await repo.commit(message:"theirs")
        _=try await repo.run(["checkout","main"]);try Data([0,2,254]).write(to:file);try await repo.stage([path]);_=try await repo.commit(message:"mine")
        _=try await repo.run(["merge","--no-edit","side"],successfulExitCodes:0...1)
        let input=try await repo.externalMergeInputs(path:path),index=root.appendingPathComponent(".git/index"),before=try Data(contentsOf:index),working=try Data(contentsOf:file),head=try await repo.run(["rev-parse","HEAD"]).stdout
        let owner=NSWindow(contentRect:.init(x:0,y:0,width:500,height:250),styleMask:[.titled,.closable],backing:.buffered,defer:false);owner.isReleasedWhenClosed=false;owner.alphaValue=0;owner.orderFront(nil)
        defer { owner.close() }
        let oldExecutor=MergeToolApplication.mergeLibreOffice,oldConfigure=MergeToolApplication.configureLibreOfficeSession
        defer { MergeToolApplication.mergeLibreOffice=oldExecutor;MergeToolApplication.configureLibreOfficeSession=oldConfigure }
        var copies:[URL]=[];defer { for folder in copies { try? FileManager.default.removeItem(at:folder) } }
        let suite="TurtleGit.LibreOfficeMergeNative."+UUID().uuidString,prefs=UserDefaults(suiteName:suite)!;defer{prefs.removePersistentDomain(forName:suite)}
        var custom=DiffToolAssociation();custom.pattern=".txt";custom.program.enabled=false
        let associations=ToolAssociationsModel(associations:[custom],tool:"merge");associations.restoreDefaults()
        try require(associations.valid && associations.draft.count==7 && associations.draft.contains(custom) && associations.draft.first{$0.id==associations.selected}?.pattern==".docx","Native Merge Restore Defaults lost rows/selection")
        var initial=MergeToolPreferences();initial.associations=[custom];try initial.save(to:prefs)
        let draft=ToolSettingsDraft(initial,valid:{$0.valid},persist:{try $0.save(to:prefs)})
        draft.value.associations=associations.draft;try require(MergeToolPreferences.load(from:prefs)==initial,"Merge defaults persisted before Apply")
        draft.cancel();try require(draft.value==initial,"Merge Cancel retained new defaults")
        draft.value.associations=associations.draft;try require(draft.apply() && MergeToolPreferences.load(from:prefs)==draft.value,"Merge Apply lost LibreOffice defaults")
        var settings=MergeToolPreferences();settings.restoreBundledAssociations();settings.blockWhileMerging=true
        var calls=0,questions:[String]=[]
        MergeToolApplication.mergeLibreOffice={ preview,_ in
            calls += 1;copies.append(preview.directory)
            try require((try Data(contentsOf:preview.base))==input.theirs && (try Data(contentsOf:preview.destination))==input.mine,"LibreOffice merge lost exact stage bytes/orientation")
            let request=try JSONDecoder().decode(LibreOfficeComparisonPreview.Request.self,from:Data(contentsOf:preview.request))
            try require(request.base==preview.base.path && request.destination==preview.destination.path && request.result==file.path,"LibreOffice literal paths/merge orientation lost")
            try Data("private reviewed mine".utf8).write(to:preview.destination)
        }
        MergeToolApplication.configureLibreOfficeSession={ session in session.presentConfirmation={ _,alert,reply in
            questions.append(alert.buttons[0].title)
            if alert.buttons[0].title=="OK" { reply(.alertFirstButtonReturn) }
            else { precondition(alert.buttons[1].keyEquivalent=="\r");reply(.alertSecondButtonReturn);reply(.alertFirstButtonReturn) }
        } }
        let opened=try await MergeToolApplication.open(repository:repo,access:nil,path:path,alternate:false,owner:owner,preferences:settings)
        try require(opened && calls==1 && questions==["OK","Mark Resolved"] && (try Data(contentsOf:index))==before && (try Data(contentsOf:file))==working,"LibreOffice No changed the real result/index or repeated confirmation")
        MergeToolApplication.discardAll();try require(FileManager.default.fileExists(atPath:copies[0].path),"LibreOffice merge private files lost after accepted handoff")
        var denied:URL?
        MergeToolApplication.mergeLibreOffice={ preview,_ in denied=preview.directory;copies.append(preview.directory);throw LibreOfficeComparisonFailure.worker("Unavailable runtime",possiblyOpened:false) }
        do { _=try await MergeToolApplication.open(repository:repo,access:nil,path:path,alternate:false,owner:owner,preferences:settings);throw Failure(message:"Denied LibreOffice merge succeeded") }
        catch let failure as LibreOfficeComparisonFailure { try require(!failure.possiblyOpened,"Denied merge considered opened") }
        try require(denied != nil && !FileManager.default.fileExists(atPath:denied!.path) && (try Data(contentsOf:index))==before,"Denied LibreOffice merge leaked files or staged")
        var pendingReply:((NSApplication.ModalResponse)->Void)?
        MergeToolApplication.configureLibreOfficeSession={ session in session.presentConfirmation={ _,_,reply in pendingReply=reply } }
        let retiring=NSWindow(contentRect:.init(x:0,y:0,width:500,height:250),styleMask:[.titled,.closable],backing:.buffered,defer:false);retiring.isReleasedWhenClosed=false;retiring.alphaValue=0;retiring.orderFront(nil)
        defer { retiring.close() }
        let cancelled=Task { try await MergeToolApplication.open(repository:repo,access:nil,path:path,alternate:false,owner:retiring,preferences:settings) }
        try await wait { pendingReply != nil };retiring.close();pendingReply?(.alertFirstButtonReturn);pendingReply?(.alertFirstButtonReturn);_=try await cancelled.value
        try require(calls==1 && MergeToolApplication.activeRequests==0 && (try Data(contentsOf:index))==before,"Closed instructions allowed a late merge or released an unfinished operation")
        var worker:CheckedContinuation<Void,Error>?,late:URL?
        MergeToolApplication.configureLibreOfficeSession={ session in session.presentConfirmation={ _,_,reply in reply(.alertFirstButtonReturn) } }
        MergeToolApplication.mergeLibreOffice={ preview,_ in late=preview.directory;copies.append(preview.directory);try await withCheckedThrowingContinuation { worker=$0 } }
        let retiringWorker=NSWindow(contentRect:.init(x:0,y:0,width:500,height:250),styleMask:[.titled,.closable],backing:.buffered,defer:false);retiringWorker.isReleasedWhenClosed=false;retiringWorker.alphaValue=0;retiringWorker.orderFront(nil)
        defer { retiringWorker.close() }
        let waiting=Task { try await MergeToolApplication.open(repository:repo,access:nil,path:path,alternate:false,owner:retiringWorker,preferences:settings) }
        try await wait { worker != nil };retiringWorker.close()
        try require(MergeToolApplication.activeRequests==1 && TurtleGitApplicationDelegate().applicationShouldTerminate(NSApp) == .terminateCancel,"Closed merge worker released Quit early")
        worker?.resume();worker=nil;_=try await waiting.value
        try require(late != nil && FileManager.default.fileExists(atPath:late!.path) && (try Data(contentsOf:index))==before,"Late accepted LibreOffice merge lost inputs or resolved")
        let reviewed=Data("reviewed document bytes".utf8)
        MergeToolApplication.mergeLibreOffice={ preview,_ in copies.append(preview.directory);try reviewed.write(to:file) }
        _=try await MergeToolApplication.open(repository:repo,access:nil,path:path,alternate:false,owner:owner,preferences:settings)
        let staged=try await repo.run(["show",":"+path]).stdout,remaining=try await repo.conflicts()
        try require(staged==reviewed && remaining.isEmpty,"Explicit Mark Resolved did not stage the saved original result")
        try require(try await repo.run(["rev-parse","HEAD"]).stdout==head,"LibreOffice merge changed HEAD")
        print("PASS: LibreOffice source theirs/mine copies, literal JSON, Save As/No/late answer refusal, explicit saved result staging, unavailable cleanup and retired worker/Quit; unchanged HEAD")
    }
}
