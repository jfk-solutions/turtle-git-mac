// SPDX-License-Identifier: GPL-2.0-or-later
import AppKit
import ObjectiveC
import UniformTypeIdentifiers
import Darwin
import TurtleGitCore

private extension NSWindow {
    @objc func rawTransferQAOrder(_ mode:NSWindow.OrderingMode,relativeTo number:Int){alphaValue=0;setFrameOrigin(.init(x:-24000,y:-24000));rawTransferQAOrder(mode,relativeTo:number)}
}
@MainActor @main enum RawHistoricalFileTransfersVerification {
    struct Failure:Error,CustomStringConvertible{let description:String}
    static func require(_ value:Bool,_ message:String,line:Int = #line)throws{if !value{throw Failure(description:"line \(line): "+message)}}
    nonisolated static func unwrap<T>(_ value:T?,_ message:String)throws->T{guard let value else{throw Failure(description:message)};return value}
    static func wait(_ message:String,line:Int = #line,_ ready:()->Bool)async throws{for _ in 0..<2500{if ready(){return};try await Task.sleep(nanoseconds:10_000_000)};throw Failure(description:"Raw transfer timeout at \(line): "+message)}
    static func views(_ view:NSView)->[NSView]{[view]+view.subviews.flatMap(views)}
    static func key(_ data:Data)throws->String{try RepositoryBrowserGitPath(rawData:data).key}
    static func quote(_ text:String)->String{"'"+text.replacingOccurrences(of:"'",with:"'\\''")+"'"}
    final class Reply<Value>:@unchecked Sendable {
        private let lock=NSLock();private var stored:Result<Value,Error>?
        var result:Result<Value,Error>?{lock.lock();defer{lock.unlock()};return stored}
        func finish(_ value:Value?,_ error:Error?){lock.lock();defer{lock.unlock()};stored=error.map{.failure($0)} ?? value.map{.success($0)} ?? .failure(Failure(description:"Missing provider reply"))}
    }
    @MainActor final class Context {
        let folder=URL(fileURLWithPath:CommandLine.arguments[1]),git=URL(fileURLWithPath:CommandLine.arguments[2]),suite="TurtleGit.RawTransfers.QA."+UUID().uuidString
        let preferences:UserDefaults,board=NSPasteboard.withUniqueName()
        var root:URL{folder.appendingPathComponent("repository")}
        var repo:GitRepository{GitRepository(root:root,executable:git,askpass:nil,libgit2Configuration:.init(mask:0))}
        var browsers:[RepositoryBrowserWindowController]=[],logs:[LogWindowController]=[],comparisons:[RevisionComparisonWindowController]=[]
        var first="",revision="",alternate="",head=Data(),index=Data(),config=Data(),working=Data()
        var bytes:[String:Data]=[:],names:[String:String]=[:],modes:[String:Int]=[:]
        let rawA=Data([255])+Data(" same.PNG".utf8),rawB=Data([254])+Data(" same.PNG".utf8),rawOpaque=Data("opaque.".utf8)+Data([253]),rawLink=Data([250])+Data(".link".utf8),rawDirectory=Data([251])+Data(" folder".utf8)
        var a:String{try! key(rawA)};var b:String{try! key(rawB)};var opaque:String{try! key(rawOpaque)};var link:String{try! key(rawLink)}
        var nested:String{try! key(rawDirectory+Data("/nested.txt".utf8))}
        var selection:[String]{[a,b,"valid.txt",opaque,link]}
        init(){preferences=UserDefaults(suiteName:suite)!;preferences.set(false,forKey:"UseLibgit2");preferences.set(false,forKey:"EnableGravatar");preferences.set(false,forKey:"EnableLogCache");preferences.set(false,forKey:"LogIncludeWorkingTreeChanges")}
        func oid(_ args:[String],input:Data?=nil)async throws->String{try await repo.run(args,input:input).text.trimmingCharacters(in:.newlines)}
        func tree(_ entries:[(String,String,String,Data)])async throws->String{var packet=Data();for(mode,type,oid,path)in entries{packet.append(Data("\(mode) \(type) \(oid)\t".utf8));packet.append(path);packet.append(0)};return try await oid(["mktree","-z"],input:packet)}
        func prepare()async throws {
            try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true);_=try await repo.run(["init","--template=","-b","main"])
            for(k,v)in[("user.name","Raw transfer QA"),("user.email","raw-transfer@example.invalid"),("commit.gpgsign","false"),("core.hooksPath","/dev/null")]{_=try await repo.run(["config",k,v])}
            try Data("working sentinel\n".utf8).write(to:root.appendingPathComponent("sentinel.txt"));try await repo.stage(["sentinel.txt"]);_=try await repo.commit(message:"seed");first=try await oid(["rev-parse","HEAD"])
            let sentinel=try await oid(["rev-parse","HEAD:sentinel.txt"]),same=Data([0,0x50,0x4e,0x47,255,0x10]),opaqueBytes=Data([0,253,10]),linkBytes=Data([46,46,47,254,10]),text=Data("valid historical contents\n".utf8)
            bytes=[a:same,b:same,opaque:opaqueBytes,link:linkBytes,"valid.txt":text,nested:Data("raw ancestor leaf\n".utf8)]
            names=[a:"Git-path-5133e31a7780a732e9143c96a065d4ef36ef6fb38ad0960a3284ed9d9f4d7d9f.PNG",b:"Git-path-1a23f02526ee62290e00188513ce169a4fe81b820a9df690d2c4d9f771b0e569.PNG",opaque:"Git-path-68e27b25eb4fb8ccb11c2141dcf053c39804ac372b116c2a95f9f46c8bbb61c6",link:"Git-path-d477efebd9ec80885591e7ce83d11ca335d38442f5aa7f18ff805d41a6388349.link","valid.txt":"valid.txt",nested:"Git-path-e7a2c1c1ae6e1f1e88cd379558a428a5cab566cdc108daa07c3c19723359a302.txt"]
            modes=[a:0o755,b:0o644,opaque:0o644,link:0o644,"valid.txt":0o644,nested:0o644]
            var objects:[String:String]=[:];for(path,data)in bytes{objects[path]=try await oid(["hash-object","-w","--stdin"],input:data)}
            let unsafeChild=try await tree([("100644","blob",objects["valid.txt"]!,Data([252])+Data(".txt".utf8))]),rawChild=try await tree([("100644","blob",objects[nested]!,Data("nested.txt".utf8))])
            var entries:[(String,String,String,Data)]=[("100644","blob",sentinel,Data("sentinel.txt".utf8)),("040000","tree",unsafeChild,Data("unsafe folder".utf8)),("040000","tree",rawChild,rawDirectory)]
            for(path,raw,mode)in [(a,rawA,"100755"),(b,rawB,"100644"),(opaque,rawOpaque,"100644"),(link,rawLink,"120000"),("valid.txt",Data("valid.txt".utf8),"100644")]{entries.append((mode,"blob",objects[path]!,raw))}
            let capturedTree=try await tree(entries);revision=try await oid(["commit-tree",capturedTree,"-p",first],input:Data("raw individual files\n".utf8))
            let nextTree=try await tree([("100644","blob",sentinel,Data("sentinel.txt".utf8))]);alternate=try await oid(["commit-tree",nextTree,"-p",revision],input:Data("later revision\n".utf8))
            _=try await repo.run(["update-ref","refs/heads/main",revision]);_=try await repo.run(["update-ref","refs/heads/raw-transfer",revision])
            head=try await repo.run(["rev-parse","HEAD"]).stdout;index=try Data(contentsOf:root.appendingPathComponent(".git/index"));config=try Data(contentsOf:root.appendingPathComponent(".git/config"));working=try Data(contentsOf:root.appendingPathComponent("sentinel.txt"))
        }
        func browser()async throws->RepositoryBrowserWindowController {
            let owner=RepositoryBrowserWindowController(repository:repo,access:RepositoryAccessLease(url:root),revision:"raw-transfer",preferences:preferences);browsers.append(owner);owner.window?.alphaValue=0;owner.showWindow(nil);owner.model.refresh()
            try await wait("actual raw Browser listing ready"){!owner.model.busy && !owner.model.hasPendingWork && owner.model.snapshot != nil && owner.contentsTable?.numberOfRows==owner.model.entries.count}
            try require(owner.model.error==nil,owner.model.error ?? "Browser failed");return owner
        }
        func unchanged()async throws {
            let current=try await repo.run(["rev-parse","HEAD"]).stdout
            try require(current==head && (try Data(contentsOf:root.appendingPathComponent(".git/index")))==index && (try Data(contentsOf:root.appendingPathComponent(".git/config")))==config && (try Data(contentsOf:root.appendingPathComponent("sentinel.txt")))==working,"Historical transfer changed HEAD/index/config/worktree")
            try require(try FileManager.default.contentsOfDirectory(atPath:root.path).sorted()==[".git","sentinel.txt"],"Historical transfer materialized an original raw checkout path")
        }
        func clean()async throws {
            for owner in browsers{owner.close()};for owner in logs{owner.close()};for owner in comparisons{owner.close()}
            try await wait("owned historical transfer workers drain"){RepositoryBrowserExportFiles.activeLoads==0 && FileListDrag.activeLoads==0 && browsers.allSatisfy{!$0.hasPendingWork} && logs.allSatisfy{$0.model.pendingHistoryLoads==0 && !$0.model.noteWorkPending} && comparisons.allSatisfy{!$0.model.busy}}
            RepositoryBrowserExportFiles.discardAll();FileListDrag.discardAll();preferences.removePersistentDomain(forName:suite);board.releaseGlobally()
        }
    }
    struct Delivered:Sendable {let bytes:Data,mode:Int,kind:FileAttributeType}
    nonisolated static func delivered(_ url:URL)throws->Delivered {
        let attributes=try FileManager.default.attributesOfItem(atPath:url.path)
        return .init(bytes:try Data(contentsOf:url),mode:(attributes[.posixPermissions] as? NSNumber)?.intValue ?? -1,kind:attributes[.type] as? FileAttributeType ?? .typeUnknown)
    }
    static func check(_ value:Delivered,path:String,_ c:Context)throws {
        try require(value.bytes==c.bytes[path] && value.mode==c.modes[path] && value.kind == .typeRegular,"Delivered bytes/mode/type changed for captured path \(RepositoryBrowserGitPath.display(key:path))")
    }
    static func promise(_ provider:NSFilePromiseProvider,to output:URL)async throws {
        let reply=Reply<Bool>()
        if let delegate=provider.delegate as? RepositoryBrowserFilePromise {
            try require(delegate.filePromiseProvider(provider,fileNameForType:provider.fileType)==output.lastPathComponent,"Browser promised leaf differs from captured name")
            delegate.filePromiseProvider(provider,writePromiseTo:output){reply.finish($0==nil ? true:nil,$0)}
        }else if let delegate=provider.delegate as? FileListFilePromise {
            try require(delegate.filePromiseProvider(provider,fileNameForType:provider.fileType)==output.lastPathComponent,"Shared promised leaf differs from captured name")
            delegate.filePromiseProvider(provider,writePromiseTo:output){reply.finish($0==nil ? true:nil,$0)}
        }else{throw Failure(description:"Missing production file promise delegate")}
        try await wait("actual promise callback"){reply.result != nil};_=try reply.result!.get()
    }
    static func item(_ provider:NSItemProvider,path:String,_ c:Context)async throws {
        try require(provider.suggestedName==c.names[path],"NSItemProvider lost safe path-derived name")
        let type=UTType(filenameExtension:(c.names[path]! as NSString).pathExtension) ?? .data
        try require(provider.hasItemConformingToTypeIdentifier(type.identifier),"Provider lost safe-name type")
        let reply=Reply<Delivered>()
        let progress=provider.loadFileRepresentation(forTypeIdentifier:type.identifier){url,error in
            do{if let error{throw error};reply.finish(try delivered(unwrap(url,"Missing representation URL")),nil)}catch{reply.finish(nil,error)}
        }
        try await wait("actual file representation callback"){reply.result != nil};try check(reply.result!.get(),path:path,c);withExtendedLifetime(progress){}
    }
    static func deliver(_ writers:[NSPasteboardWriting],providers:[NSItemProvider],paths:[String],label:String,_ c:Context)async throws {
        let promises=writers.compactMap{$0 as? NSFilePromiseProvider}
        try require(promises.count==paths.count && providers.count==paths.count,"Materializable occurrences lost/merged")
        let destination=c.folder.appendingPathComponent(label);try FileManager.default.createDirectory(at:destination,withIntermediateDirectories:true)
        for(index,path)in paths.enumerated(){
            let output=destination.appendingPathComponent(c.names[path]!)
            try require(promises[index].fileType==(UTType(filenameExtension:output.pathExtension) ?? .data).identifier,"Promise type differs from safe leaf")
            try await promise(promises[index],to:output);try check(delivered(output),path:path,c)
            try await item(providers[index],path:path,c)
        }
        // Delivery must refuse an existing receiver file rather than overwrite it.
        let existing=destination.appendingPathComponent(c.names[paths[0]]!),before=try delivered(existing)
        var refused=false
        do{try await promise(promises[0],to:existing)}catch{refused=true}
        try require(refused,"Promise overwrote existing recipient output")
        let after=try delivered(existing);try require(before.bytes==after.bytes && before.mode==after.mode,"Refused delivery modified recipient")
    }
    static func clipboard(_ paths:[String],text:String,writers:[NSPasteboardWriting],write:()->Bool,_ c:Context)throws {
        let expected=paths.map{RepositoryBrowserGitPath.display(key:$0)+"\r\n"}.joined()
        try require(text==expected && !text.utf8.contains(0),"Transfer text exposed opaque namespace keys/NUL or changed order")
        try require(write() && c.board.string(forType:.string)==expected,"Private clipboard omitted escaped aggregate text")
        try require(c.board.pasteboardItems?.count==writers.count && writers.compactMap{$0 as? NSFilePromiseProvider}.count==paths.count,"Clipboard lost actual file promises")
    }
    static func browser(_ c:Context)async throws {
        let owner=try await c.browser(),model=owner.model
        let entries=try c.selection.map{path in try unwrap(model.entries.first{$0.path==path},"Raw Browser row missing")}
        model.selection=Set(entries.map(\.id))
        let drag=try unwrap(model.captureTransfer(entries.map(\.id)),"Actual Browser aggregate raw transfer refused")
        try require(drag.paths==c.selection && drag.names==c.selection.map{c.names[$0]!} && drag.names[0] != drag.names[1],"Browser lost path order or merged same-blob names")
        try clipboard(drag.paths,text:drag.text,writers:drag.writers,write:{drag.write(to:c.board)},c)
        model.copy(pasteboard:c.board,entries:entries)
        try require(c.board.string(forType:.string)==entries.map{$0.name+"\r\n"}.joined() && c.board.pasteboardItems?.count==1,"Browser CopyPath ceased names-only escaped text")
        let single=try unwrap(model.dragProvider(entries[0]),"Browser raw individual provider refused")
        let rawFolder=try unwrap(model.entries.first{$0.path==(try? key(c.rawDirectory))},"Missing raw folder")
        let unsafe=try unwrap(model.entries.first{$0.path=="unsafe folder"},"Missing raw descendant folder")
        model.selection=[rawFolder.id];try require(model.captureTransfer([rawFolder.id])==nil,"Raw folder transfer unexpectedly widened scope")
        model.selection=[unsafe.id];try require(model.captureTransfer([unsafe.id])==nil,"Folder with raw descendants bypassed literal-folder refusal")
        // Capture a leaf beneath a raw ancestor, using the actual directory reader.
        model.openFolder(rawFolder.path)
        try await wait("raw ancestor listing"){!model.busy && !model.hasPendingWork && model.entries.contains{$0.path==c.nested}}
        let nested=try unwrap(model.entries.first{$0.path==c.nested},"Missing nested raw leaf");model.selection=[nested.id]
        let nestedDrag=try unwrap(model.captureTransfer([nested.id]),"Raw ancestor individual leaf refused")
        _=try await c.repo.run(["update-ref","refs/heads/raw-transfer",c.alternate]);c.preferences.set(true,forKey:"UseLibgit2")
        owner.close();try require(model.captureTransfer([nested.id])==nil,"Retired Browser created transfer")
        try await deliver(drag.writers,providers:drag.providers,paths:c.selection,label:"browser-delivery",c)
        try await item(single,path:c.a,c)
        try await deliver(nestedDrag.writers,providers:nestedDrag.providers,paths:[c.nested],label:"nested-delivery",c)
        c.preferences.set(false,forKey:"UseLibgit2");_=try await c.repo.run(["update-ref","refs/heads/raw-transfer",c.revision])
    }
    static func shared(_ c:Context)async throws {
        let log=LogWindowController(repository:c.repo,access:RepositoryAccessLease(url:c.root),labelDefaults:c.preferences,savesColumnLayout:false,savesGeometry:false,loadsImmediately:false)
        c.logs.append(log);log.window?.alphaValue=0;log.showWindow(nil);log.model.reload()
        try await wait("actual Log history"){!log.model.busy && log.model.entries.contains{$0.hash==c.revision}}
        log.model.select([c.revision]);try await wait("actual historical changed files"){!log.model.busy && c.selection.allSatisfy{path in log.model.files.contains{$0.path==path}} && log.model.fileDragGeneration != nil}
        // Set the actual model binding; this fixture does not claim physical mouse selection.
        log.model.selectedFiles=GitPathSet(c.selection)
        let drag=try unwrap(log.model.captureFileDrag(c.selection),"Log raw historical capture refused")
        let one=try unwrap(log.model.fileDragProvider(log.model.fileMenuSnapshot(GitPathSet([c.a]))),"Log raw historical provider refused")
        try require(drag.revision == .revision(c.revision) && drag.paths==c.selection,"Log lost selected revision/path identity")
        try clipboard(drag.paths,text:drag.text,writers:drag.writers,write:{drag.write(to:c.board)},c)
        let comparison=RevisionComparisonWindowController(repository:c.repo,access:RepositoryAccessLease(url:c.root),from:.revision(c.first),to:.revision(c.revision),preferences:c.preferences,savesGeometry:false)
        c.comparisons.append(comparison);comparison.window?.alphaValue=0;comparison.showWindow(nil)
        try await wait("actual historical comparison"){!comparison.model.busy && comparison.model.snapshot != nil && comparison.model.fileDragGeneration != nil}
        comparison.model.selection=GitPathSet(c.selection)
        let compared=try unwrap(comparison.model.captureFileDrag(c.selection),"Comparison raw historical capture refused")
        let context=try unwrap(comparison.model.captureFileMenu([c.a]),"Comparison raw file menu missing")
        let comparedOne=try unwrap(comparison.model.fileDragProvider(context),"Comparison raw provider refused")
        try require(compared.paths==c.selection && compared.revision == .revision(c.revision),"Comparison lost destination endpoint identity")
        try clipboard(compared.paths,text:compared.text,writers:compared.writers,write:{compared.write(to:c.board)},c)
        let files=try c.selection.map{path in try unwrap(log.model.files.first{$0.path==path},"Missing shared fixture file")}
        let empty=try unwrap(FileListSelectionDrag(repository:c.repo,access:RepositoryAccessLease(url:c.root),files:files,revision:.emptyTree,backend:.init(mask:0)),"Empty-tree raw text-only refused")
        try require(empty.paths==c.selection && empty.providers.isEmpty && empty.fileURLs.isEmpty && empty.writers.count==1 && empty.operationMask == .copy && !empty.text.utf8.contains(0),"Empty-tree fabricated contents/working URLs")
        try require(FileListSelectionDrag(repository:c.repo,access:RepositoryAccessLease(url:c.root),files:files,revision:.workingTree,backend:.init(mask:0))==nil,"Raw working-tree transfer bypassed refusal")
        do{_=try FileListDragPlan(root:c.root,revision:.workingTree,files:files,backend:.init(mask:0));throw Failure(description:"Raw working plan admitted") }catch is Failure{throw Failure(description:"Raw working plan admitted")}catch{}
        // Duplicate occurrences retain independent item identities; raw names remain path based.
        let duplicate=try FileListDragPlan(root:c.root,revision:.revision(c.revision),files:[files[0],files[0],files[1]],backend:.init(mask:0))
        try require(duplicate.items.count==3 && Set(duplicate.items.map(\.id)).count==3 && duplicate.items[0].name==duplicate.items[1].name && duplicate.items[0].name != duplicate.items[2].name,"Duplicate occurrences or same-blob paths collapsed")
        log.close();comparison.close();try require(log.model.captureFileDrag(c.selection)==nil && comparison.model.captureFileDrag(c.selection)==nil,"Retired historical owner accepted new transfer")
        c.preferences.set(true,forKey:"UseLibgit2")
        try await deliver(drag.writers,providers:drag.providers,paths:c.selection,label:"log-delivery",c)
        try await deliver(compared.writers,providers:compared.providers,paths:c.selection,label:"comparison-delivery",c)
        try await item(one,path:c.a,c);try await item(comparedOne,path:c.a,c);c.preferences.set(false,forKey:"UseLibgit2")
    }
    final class Scope:RepositoryBookmarkProvider {
        var starts=0,stops=0
        func create(for url:URL)throws->Data{Data(url.path.utf8)}
        func resolve(_ bytes:Data)throws->ResolvedBookmark{.init(url:URL(fileURLWithPath:String(decoding:bytes,as:UTF8.self)),stale:false)}
        func startAccessing(_ url:URL)->Bool{starts += 1;return true}
        func stopAccessing(_ url:URL){stops += 1}
    }
    static func retainedGrant(_ c:Context)async throws {
        let scope=Scope();var lease:RepositoryAccessLease?=RepositoryAccessLease(url:c.root,provider:scope)
        let file=CommitFile(path:c.a,oldPath:nil,action:"A",added:nil,removed:nil,hasStatistics:false,isSubmodule:false)
        let plan=try FileListDragPlan(root:c.root,revision:.revision(c.revision),files:[file],backend:.init(mask:0))
        var provider:NSFilePromiseProvider?=try FileListFilePromise(repository:c.repo,access:lease,plan:plan,itemAt:0).provider();lease=nil
        try require(scope.starts==1 && scope.stops==0,"Accepted transfer did not retain released caller authority")
        let folder=c.folder.appendingPathComponent("independent-grant");try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
        let output=folder.appendingPathComponent(c.names[c.a]!);try await promise(provider!,to:output);try check(delivered(output),path:c.a,c)
        provider=nil;try await wait("accepted transfer releases its own grant"){scope.stops==1}
    }
    static func cancellation(_ c:Context)async throws {
        let wrapper=c.folder.appendingPathComponent("held-git"),pid=c.folder.appendingPathComponent("held-git.pid"),done=c.folder.appendingPathComponent("held-git.finished")
        let script="#!/bin/sh\nprevious=\"\"\nfor argument in \"$@\"; do\n if [ \"$previous\" = cat-file ] && [ \"$argument\" = blob ]; then\n  echo $$ > "+quote(pid.path)+"\n  exec /bin/sleep 30\n fi\n previous=$argument\ndone\nexec "+quote(c.git.path)+" \"$@\"\n"
        try Data(script.utf8).write(to:wrapper);try FileManager.default.setAttributes([.posixPermissions:0o755],ofItemAtPath:wrapper.path)
        let repo=GitRepository(root:c.root,executable:wrapper,askpass:nil,libgit2Configuration:.init(mask:0))
        let file=CommitFile(path:c.a,oldPath:nil,action:"A",added:nil,removed:nil,hasStatistics:false,isSubmodule:false)
        let plan=try FileListDragPlan(root:c.root,revision:.revision(c.revision),files:[file],backend:.init(mask:0))
        let promise=try FileListFilePromise(repository:repo,access:RepositoryAccessLease(url:c.root),plan:plan,itemAt:0),token=OperationCancellation(),output=c.folder.appendingPathComponent("canceled-output")
        let task=Task {do{try await promise.write(to:output,cancellation:token);try Data("success".utf8).write(to:done)}catch{try? Data("cancelled".utf8).write(to:done)}}
        do {
            try await wait("actual cat-file helper held"){FileManager.default.fileExists(atPath:pid.path)}
            let process=Int32(String(decoding:try Data(contentsOf:pid),as:UTF8.self).trimmingCharacters(in:.whitespacesAndNewlines))!
            try require(FileListDrag.activeLoads>0,"Held transfer was not owned")
            token.cancel();await task.value
            try await wait("actual canceled helper reaped"){kill(process,0) != 0 && FileListDrag.activeLoads==0}
            try require(!FileManager.default.fileExists(atPath:output.path) && String(decoding:try Data(contentsOf:done),as:UTF8.self)=="cancelled","Canceled promise published output/success")
        }catch{token.cancel();await task.value;throw error}
    }
    static func providerCancellation(_ c:Context)async throws {
        let wrapper=c.folder.appendingPathComponent("provider-held-git"),pid=c.folder.appendingPathComponent("provider-held-git.pid")
        let script="#!/bin/sh\nprevious=\"\"\nfor argument in \"$@\"; do\n if [ \"$previous\" = cat-file ] && [ \"$argument\" = blob ]; then\n  echo $$ > "+quote(pid.path)+"\n  exec /bin/sleep 30\n fi\n previous=$argument\ndone\nexec "+quote(c.git.path)+" \"$@\"\n"
        try Data(script.utf8).write(to:wrapper);try FileManager.default.setAttributes([.posixPermissions:0o755],ofItemAtPath:wrapper.path)
        let repo=GitRepository(root:c.root,executable:wrapper,askpass:nil,libgit2Configuration:.init(mask:0))
        let snapshot=try await c.repo.browseRepository(revision:c.revision,backend:.init(mask:0))
        let entry=try unwrap(snapshot.entries.first{$0.path==c.a},"Missing Browser cancellation raw entry")
        let provider=RepositoryBrowserDrag.provider(repository:repo,access:RepositoryAccessLease(url:c.root),snapshot:snapshot,entry:entry,directory:nil,name:c.names[c.a]!,folder:false,backend:.init(mask:0)),reply=Reply<Bool>()
        let progress=provider.loadFileRepresentation(forTypeIdentifier:UTType.png.identifier){url,error in reply.finish(error==nil && url != nil ? true:nil,error)}
        do {
            try await wait("Browser provider actual helper held"){FileManager.default.fileExists(atPath:pid.path)}
            let process=Int32(String(decoding:try Data(contentsOf:pid),as:UTF8.self).trimmingCharacters(in:.whitespacesAndNewlines))!
            try require(RepositoryBrowserExportFiles.activeLoads>0,"Provider helper not owned")
            progress.cancel();try await wait("Browser provider canceled callback and helper drain"){reply.result != nil && RepositoryBrowserExportFiles.activeLoads==0 && kill(process,0) != 0}
            if case .success=reply.result!{throw Failure(description:"Canceled Browser provider delivered success")}
        }catch{progress.cancel();try? await wait("failed provider actual drain"){reply.result != nil && RepositoryBrowserExportFiles.activeLoads==0};throw error}
    }

    static func main()async {
        let app=NSApplication.shared;app.setActivationPolicy(.prohibited)
        if let a=class_getInstanceMethod(NSWindow.self,#selector(NSWindow.order(_:relativeTo:))),let b=class_getInstanceMethod(NSWindow.self,#selector(NSWindow.rawTransferQAOrder(_:relativeTo:))){method_exchangeImplementations(a,b)}
        let c=Context()
        do{try FileManager.default.createDirectory(at:c.folder,withIntermediateDirectories:true);try await c.prepare();try await browser(c);try await shared(c);try await retainedGrant(c);try await cancellation(c);try await providerCancellation(c);try await c.unchanged();try await c.clean();print("PASS raw historical file transfers: Browser/Log/Comparison exact raw paths, safe promises/providers, text-only Copy, captured endpoints, owner retirement and cancellation drain")}catch{fputs("Raw historical transfer verification failed: \(error)\n",stderr);do{try await c.clean()}catch{fputs("Cleanup failed: \(error)\n",stderr)};exit(1)}
    }
}
