// SPDX-License-Identifier: GPL-2.0-or-later
import AppKit
import ObjectiveC
import TurtleGitCore

private extension NSWindow {
    @objc func exactRetryOrder(_ place:NSWindow.OrderingMode,relativeTo number:Int) {
        alphaValue=0;setFrameOrigin(.init(x:-20000,y:-20000));exactRetryOrder(place,relativeTo:number)
    }
    @objc func exactRetryFrame(_ rect:NSRect,to screen:NSScreen?)->NSRect {rect}
}

@MainActor @main enum OperationExactRetryVerification {
    struct Failure:Error,LocalizedError {let message:String;var errorDescription:String? {message}}
    static func require(_ value:Bool,_ message:String)throws {if !value {throw Failure(message:message)}}
    static func wait(_ condition:()->Bool)async throws {
        for _ in 0..<3000 {if condition(){return};try await Task.sleep(nanoseconds:10_000_000)}
        throw Failure(message:"Exact-name native operation did not drain")
    }
    static func exact(_ a:String,_ b:String)->Bool {a.utf8.elementsEqual(b.utf8)}
    static func main()async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let order=class_getInstanceMethod(NSWindow.self,#selector(NSWindow.order(_:relativeTo:)))!,hidden=class_getInstanceMethod(NSWindow.self,#selector(NSWindow.exactRetryOrder(_:relativeTo:)))!
        let frame=class_getInstanceMethod(NSWindow.self,#selector(NSWindow.constrainFrameRect(_:to:)))!,offscreen=class_getInstanceMethod(NSWindow.self,#selector(NSWindow.exactRetryFrame(_:to:)))!
        method_exchangeImplementations(order,hidden);method_exchangeImplementations(frame,offscreen)
        defer {method_exchangeImplementations(frame,offscreen);method_exchangeImplementations(order,hidden)}
        let root=URL(fileURLWithPath:CommandLine.arguments[1]),git=URL(fileURLWithPath:CommandLine.arguments[2])
        let repo=GitRepository(root:root,executable:git,askpass:nil,libgit2Configuration:.init(enabled:false))
        let suite="TurtleGit.ExactRetry."+UUID().uuidString,prefs=UserDefaults(suiteName:suite)!
        defer {prefs.removePersistentDomain(forName:suite)}
        prefs.set(0,forKey:"AutoCloseGitProgress");prefs.set(false,forKey:"ConfirmKillProcess")
        let store=ActionLogStore(storageURL:root.appendingPathComponent("private-actions.log"))
        ProgressActionLog.install(store:store,preferences:prefs)
        var owners=[RevertProgressWindowController](),release:CheckedContinuation<Void,Never>?
        func closeOwners()async throws {
            release?.resume();release=nil
            owners.forEach{$0.close()}
            try await wait {RevertProgressWindowModel.activeOperations==0 && RevertProgressWindowController.activeReleases==0}
            try require(NSApp.windows.allSatisfy{!$0.isVisible && $0.attachedSheet==nil},"Exact-name check left an owned window visible")
        }
        do {
            _=try await repo.run(["init","-b","main"])
            for (key,value) in [("user.name","Exact Retry QA"),("user.email","qa@example.invalid"),("commit.gpgsign","false"),("core.hooksPath","/dev/null"),("core.precomposeunicode","true")] {_=try await repo.run(["config",key,value])}
            let nfc="café.txt",nfd="cafe\u{301}.txt",base=Data("base exact name\n".utf8)
            let blob=try await repo.run(["hash-object","-w","--stdin"],input:base).text.trimmingCharacters(in:.newlines)
            func packet(_ object:String,_ name:String)->Data {Data("100644 \(object)\t\(name)\0".utf8)}
            _=try await repo.run(["update-index","-z","--index-info"],input:packet(blob,nfc)+packet(blob,nfd))
            _=try await repo.commit(message:"canonical index peers")
            let head=try await repo.run(["rev-parse","HEAD"]).stdout
            let neighbor=try await repo.run(["hash-object","-w","--stdin"],input:Data("retained NFC staged peer\n".utf8)).text.trimmingCharacters(in:.newlines)
            _=try await repo.run(["update-index","-z","--index-info"],input:packet(neighbor,nfc))
            let selected=try await repo.status().filter{exact($0.path,nfd)}
            try require(selected.count==1,"Private fixture did not retain the exact NFD index name")
            let owner=RevertProgressWindowController(repository:repo,access:nil,entries:selected,amend:false,againstHead:false,autoCloseSuccess:false,preferences:prefs,policy:.init(recycle:false,recycleRenamedFiles:false))
            owners.append(owner)
            var attempts=0,finished=[Bool](),copied=[String]()
            let policy=owner.model.policy
            owner.model.onFinished={_,success in finished.append(success)}
            owner.model.progress.publishClipboard={copied.append($0)}
            owner.model.execute={entries,token,progress,output in
                attempts+=1
                let result=try await repo.revertWorkingFiles(entries,policy:policy,cancellation:token,progress:progress,onOutput:output)
                if attempts==1 {throw GitFailure(arguments:["revert"],code:1,message:"Private post-restore failure")}
                return result
            }
            owner.model.start();try await wait{!owner.model.busy && RevertProgressWindowModel.activeOperations==0}
            try require(owner.model.failed && owner.model.information.contains("Private post-restore failure") && owner.model.trashedFiles.isEmpty,"First attempt lost its actual restoration or failure result")
            try require(try Data(contentsOf:root.appendingPathComponent(nfd))==base,"First attempt did not restore selected working bytes")
            owner.model.retry();owner.model.retry()
            try await wait{!owner.model.busy && RevertProgressWindowModel.activeOperations==0}
            try require(attempts==2 && finished==[false,true] && !owner.model.failed && !owner.model.cancelled,"Clean exact-name Retry was lost, duplicated or narrowed")
            let files=owner.model.progress.rows.filter{$0.kind == .file}
            try require(!files.isEmpty && files.allSatisfy{exact($0.path,nfd)},"Native result rows promoted the canonical peer")
            owner.model.copyOutput()
            let copiedRows=copied.first?.components(separatedBy:"\n\n").first ?? ""
            try require(copied.count==1 && Data(copiedRows.utf8).range(of:Data(nfd.utf8)) != nil && Data(copiedRows.utf8).range(of:Data(nfc.utf8))==nil,"Private copied result rows lost exact UTF8 identity")
            let log=try Data(contentsOf:store.storageURL);owner.close()
            try await wait{RevertProgressWindowController.activeReleases==0}
            try require(try Data(contentsOf:store.storageURL)==log,"Closing a settled Retry duplicated its action-log snapshot")
            owner.model.retry();owner.model.copyOutput()
            try require(attempts==2 && copied.count==1,"Retired result accepted Retry or clipboard commands")
            let clean=try await repo.workingFileRevertSelection(selected)
            let late=RevertProgressWindowController(repository:repo,access:nil,entries:clean,amend:false,againstHead:false,autoCloseSuccess:false,preferences:prefs,policy:.init(recycle:false,recycleRenamedFiles:false))
            owners.append(late);var callbacks=0
            late.model.onFinished={_,_ in callbacks+=1}
            late.model.execute={entries,token,progress,output in
                let result=try await repo.revertWorkingFiles(entries,policy:policy,cancellation:token,progress:progress,onOutput:output)
                await withCheckedContinuation {release=$0}
                return result
            }
            late.model.start();try await wait{release != nil}
            late.close();let frozen=late.model.commandOutput
            try require(late.model.retired && RevertProgressWindowModel.activeOperations>0,"Retirement abandoned the held exact-name worker")
            release?.resume();release=nil
            try await wait{RevertProgressWindowModel.activeOperations==0 && RevertProgressWindowController.activeReleases==0}
            try require(callbacks==0 && late.model.commandOutput==frozen,"Retired exact-name result published a late completion")
            let index=try await repo.run(["-c","core.precomposeunicode=false","ls-files","--stage","-z"]).stdout
            for (object,name) in [(neighbor,nfc),(blob,nfd)] {try require(index.split(separator:0).contains{$0.elementsEqual(Data("100644 \(object) 0\t\(name)".utf8))},"Exact-name operation changed the wrong index entry")}
            try require(try await repo.run(["rev-parse","HEAD"]).stdout==head,"Exact-name Retry committed or moved HEAD")
            try require(try await repo.run(["config","core.precomposeunicode"]).text.trimmingCharacters(in:.newlines)=="true","Exact-name reads changed persistent Git configuration")
            try await closeOwners()
            print("PASS: exact-name Revert clean Retry, canonical peer index, native result/clipboard, attempt log and retired worker")
        } catch {
            let failure=error
            do {try await closeOwners()} catch {throw Failure(message:"\(failure); cleanup: \(error)")}
            throw failure
        }
    }
}
