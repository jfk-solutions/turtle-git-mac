// SPDX-License-Identifier: GPL-2.0-or-later
import AppKit
import ScreenCaptureKit
import TurtleGitCore

@main struct SVNSourceVerification {
    struct Failure:Error,CustomStringConvertible {let description:String}
    @MainActor static var owners=[SVNWindowController]()
    static func require(_ value:Bool,_ message:String)throws {if !value {throw Failure(description:message)}}
    @MainActor static func wait(line:UInt = #line,_ condition:()->Bool)async throws {
        for _ in 0..<1800 {if condition() {return};try await Task.sleep(nanoseconds:10_000_000)}
        throw Failure(description:"SVN did not settle at fixture line \(line)")
    }
    @MainActor static func capture(_ owner:SVNWindowController,_ label:String)async throws {
        guard let destination=ProcessInfo.processInfo.environment["TURTLEGIT_SVN_SOURCE_CAPTURE"],let window=owner.window else{return}
        guard #available(macOS 14.4,*) else {throw Failure(description:"Capture API unavailable")}
        window.alphaValue=1;window.orderFront(nil);defer{window.alphaValue=0}
        for (name,suffix) in [(NSAppearance.Name.aqua,"light"),(.darkAqua,"dark")] {
            window.appearance=NSAppearance(named:name);window.contentView?.layoutSubtreeIfNeeded()
            try await Task.sleep(nanoseconds:250_000_000)
            let content=try await SCShareableContent.currentProcess
            guard let own=content.windows.first(where:{$0.windowID==CGWindowID(window.windowNumber)}) else {throw Failure(description:"Owned SVN window missing")}
            let options=SCStreamConfiguration();options.width=Int(window.frame.width*2);options.height=Int(window.frame.height*2)
            options.showsCursor=false;options.ignoreShadowsSingleWindow=true;options.includeChildWindows=false
            let image=try await SCScreenshotManager.captureImage(contentFilter:SCContentFilter(desktopIndependentWindow:own),configuration:options)
            try NSBitmapImageRep(cgImage:image).representation(using:.png,properties:[:])!.write(to:URL(fileURLWithPath:destination).appendingPathComponent(label+"-"+suffix+".png"))
            print("Captured \(label)-\(suffix): \(options.width)x\(options.height)")
        }
    }
    @MainActor static func main()async {
        _=NSApplication.shared;NSApp.setActivationPolicy(.prohibited)
        setenv("TURTLEGIT_SVN_TEST_GIT",CommandLine.arguments[2],1)
        do {
            try await source()
            if ProcessInfo.processInfo.environment["TURTLEGIT_SVN_SOURCE_ONLY"] != "1" {try await SVNNativeVerification.verify()}
            owners.forEach{$0.close()};owners=[]
            try await wait {SVNWindowModel.activeOperations==0}
            print("PASS: SVN source/workflow family, captured options/post-actions, source forms, owned questions and failed-load Retry")
        } catch {
            owners.forEach{$0.close()};owners=[]
            for _ in 0..<1800 {if SVNWindowModel.activeOperations==0 {break};try? await Task.sleep(nanoseconds:10_000_000)}
            fputs("SVN source family failed: \(error)\n",stderr);exit(1)
        }
    }
    @MainActor static func source()async throws {
        let suite="TurtleGit.SVN.Source."+UUID().uuidString,preferences=UserDefaults(suiteName:suite)!
        let clipboard=NSPasteboard(name:.init(suite))
        defer{preferences.removePersistentDomain(forName:suite);clipboard.clearContents()}
        func owner(_ repository:GitRepository,_ operation:GitSVNOperation)->SVNWindowController {
            let value=SVNWindowController(repository:repository,access:nil,operation:operation,preferences:preferences,clipboard:clipboard)
            owners.append(value);value.window?.alphaValue=0;value.window?.orderFront(nil);value.model.load();return value
        }
        let (root,repo,old,next)=try await GitSVNFixture.create()
        defer{try? FileManager.default.removeItem(at:root)}
        let dcommit=owner(repo,.dcommit),model=dcommit.model
        try await wait {!model.busy}
        try require(model.canStart && model.phase == .options,"DCommit source options absent")
        try require(dcommit.window?.contentLayoutRect.size==NSSize(width:620,height:300) && dcommit.window?.contentView?.constraints.contains(where:{$0.firstAttribute == .height && $0.relation == .greaterThanOrEqual && $0.constant==300}) == true,"DCommit compact/native minimum geometry")
        let context=model.formContext,type=model.option(\.removeEmptyDirectories,context:context),remember=model.option(\.remember,context:context)
        type.wrappedValue=true;remember.wrappedValue=true
        try await capture(dcommit,"svn-dcommit-source")
        try Data("private captured edit\n".utf8).write(to:root.appendingPathComponent("file"))
        var heldStash:CheckedContinuation<Bool,Never>?
        model.confirmStash={await withCheckedContinuation{heldStash=$0}}
        model.confirmPop={true}
        model.start(context:context);model.start(context:context)
        model.removeEmptyDirectories=false;model.remember=false
        type.wrappedValue=false;remember.wrappedValue=false
        try await wait {heldStash != nil}
        try require(!model.canStart,"Pending DCommit accepted another submission")
        heldStash?.resume(returning:true);heldStash=nil
        try await wait {!model.busy}
        try require(model.success && model.error==nil,"Captured DCommit failed: \(model.error ?? "none")")
        let saved=try await repo.svnCommitType()
        let commands=try String(contentsOf:root.appendingPathComponent(".git/svn-qa-log"))
        try require(saved==true && commands.contains("[\"svn\", \"dcommit\", \"--rmdir\"]"),"DCommit reread fields after OK or confirmation")
        try require(try Data(contentsOf:root.appendingPathComponent("file"))==Data("private captured edit\n".utf8),"Created stash was not restored")
        model.start(context:context);try require(!model.busy,"Old OK action restarted finished DCommit")
        dcommit.close();_=try await repo.run(["restore","--","file"])
        let ignore=owner(repo,.ignore),importer=ignore.model
        try await wait {!importer.busy}
        try require(ignore.window?.contentLayoutRect.size==NSSize(width:740,height:260) && ignore.window?.contentView?.constraints.contains(where:{$0.firstAttribute == .height && $0.relation == .greaterThanOrEqual && $0.constant==260}) == true,"Ignore compact/native minimum geometry")
        let ignoreContext=importer.formContext,destination=importer.option(\.ignoreDestination,context:ignoreContext)
        try await capture(ignore,"svn-ignore-source")
        _=try await repo.run(["config","svn-test.fail","true"])
        importer.start(context:ignoreContext);importer.ignoreDestination = .gitignore;destination.wrappedValue = .gitignore
        try await wait {!importer.busy}
        try require(importer.canRetry && importer.error != nil,"Expected exclude failure missing")
        try await capture(ignore,"svn-error-source")
        let failedContext=importer.formContext
        _=try await repo.run(["config","svn-test.fail","false"])
        importer.retry(context:failedContext);importer.retry(context:failedContext)
        try await wait {!importer.busy}
        let exclude=try await repo.svnIgnoreExcludeURL()
        let patterns=try Data(contentsOf:exclude)
        try require(importer.success && patterns==Data("ignored*\n雪*\n".utf8) && !FileManager.default.fileExists(atPath:root.appendingPathComponent(".gitignore").path),"Retry lost accepted exclude destination")
        importer.retry(context:failedContext);try require(!importer.busy,"Old Retry action started another request")
        ignore.close()
        let fetch=owner(repo,.fetch),fetcher=fetch.model
        try await wait {!fetcher.busy}
        try require(fetcher.fetched?.oldHash==old && fetcher.fetched?.newHash==next,"Captured Fetch range missing")
        try await capture(fetch,"svn-fetch-source")
        guard let result=fetcher.fetched else {throw Failure(description:"Fetch result missing")}
        let resultContext=fetcher.formContext
        var comparisons=0,logs=0
        fetcher.onCompare={a,b in if a==old && b==next {comparisons += 1}}
        fetcher.onLog={if $0.range==old+".."+next {logs += 1}}
        fetcher.compare(result,context:resultContext);fetcher.log(result,context:resultContext)
        try require(comparisons==1 && logs==1,"Captured Diff/Log actions lost the result")
        var response:((NSApplication.ModalResponse)->Void)?
        fetch.presentQuestion={alert,_,reply in
            response=reply
            precondition(alert.buttons[0].keyEquivalent.isEmpty && alert.buttons[1].keyEquivalent=="\r")
        }
        let question=Task{await fetch.ask("Private source question",yes:"Continue",no:"Abort")}
        try await wait {response != nil}
        try require(fetcher.hasQuestion && !fetcher.canShowFetched && !fetcher.canCancel && !fetch.windowShouldClose(fetch.window!),"Owned question did not gate finished controls/Close")
        fetcher.compare(result,context:resultContext);fetcher.log(result,context:resultContext)
        response?(.alertSecondButtonReturn);response?(.alertFirstButtonReturn)
        let answer=await question.value
        fetcher.compare(result,context:resultContext);fetcher.log(result,context:resultContext)
        try require(!answer && !fetcher.hasQuestion && comparisons==1 && logs==1,"Question replay revived old result actions")
        fetcher.compare(result,context:fetcher.formContext);fetcher.log(result,context:fetcher.formContext)
        try require(comparisons==2 && logs==2,"Fresh result actions were disabled")
        fetch.close();fetcher.compare(result,context:fetcher.formContext)
        try require(comparisons==2,"Retired Fetch dispatched a result")
        let (badRoot,badRepo,_,_)=try await GitSVNFixture.create()
        defer{try? FileManager.default.removeItem(at:badRoot)}
        let marker=badRoot.appendingPathComponent(".git/svn/.metadata")
        try FileManager.default.removeItem(at:marker)
        let failed=owner(badRepo,.ignore),failedModel=failed.model
        try await wait {!failedModel.busy}
        try require(failedModel.canRetry,"Missing SVN marker was accepted")
        failedModel.retry();try await wait {!failedModel.busy}
        try require(!failedModel.success && failedModel.canRetry,"Retry bypassed failed repository eligibility")
        let before=try String(contentsOf:badRoot.appendingPathComponent(".git/svn-qa-log"))
        try require(!before.contains("show-ignore") && !before.contains("create-ignore"),"Failed initial Retry ran SVN mutation")
        try Data().write(to:marker);failedModel.retry();try await wait {!failedModel.busy}
        try require(failedModel.canStart && failedModel.phase == .options,"Recovered initial Retry skipped source options")
        failed.close()
        try require(SVNWindowModel.activeOperations==0,"SVN ownership did not settle")
    }
}
