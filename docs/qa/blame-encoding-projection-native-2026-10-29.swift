// SPDX-License-Identifier: GPL-2.0-or-later
import AppKit
import ObjectiveC
import Darwin
import TurtleGitCore

private extension NSWindow {
    @objc func quietBlameEncodingOrder(_ mode:NSWindow.OrderingMode,relativeTo number:Int) {
        alphaValue=0;quietBlameEncodingOrder(mode,relativeTo:number)
    }
    @objc func quietBlameEncodingSheet(_ sheet:NSWindow,completionHandler:((NSApplication.ModalResponse)->Void)?) {
        sheet.alphaValue=0;quietBlameEncodingSheet(sheet,completionHandler:completionHandler)
    }
}
@MainActor @main struct BlameEncodingProjectionVerification {
    static var diagnosticOwners:[BlameWindowController]=[]
    struct Failure:Error,CustomStringConvertible {let description:String}
    static func phase(_ name:String){print("BLAME ENCODING PHASE \(name) mainThread=\(Thread.isMainThread)");fflush(stdout)}
    static func require(_ value:Bool,_ message:String,line:Int = #line)throws {if !value{throw Failure(description:"\(line): "+message)}}
    static func unwrap<T>(_ value:T?,_ message:String)throws->T {guard let value else{throw Failure(description:message)};return value}
    static func wait(_ message:String,line:Int = #line,_ ready:()->Bool)async throws {
        for _ in 0..<2000 {if ready(){return};try await Task.sleep(nanoseconds:10_000_000)}
        for owner in diagnosticOwners {
            let model=owner.model
            print("BLAME TIMEOUT line=\(line) phase=\(message) busy=\(model.busy) error=\(model.error ?? "none") requestedCodec=\(String(describing:model.sourceEncoding)) displayedCodec=\(String(describing:model.snapshot?.encoding)) retained=\(model.hasRetainedDocument) modelRows=\(model.lines.count) nativeRows=\(String(describing:attributionRows(owner))) historyRows=\(model.historyEntries.count) source=\(String(reflecting:source(owner)?.string)) activeReads=\(BlameWindowModel.activeHistoryOperations)")
        }
        fflush(stdout)
        throw Failure(description:"\(line): "+message)
    }
    static func views(_ view:NSView?)->[NSView] {guard let view else{return []};return [view]+view.subviews.flatMap{views($0)}}
    static func drained()->Bool {BlameWindowModel.activeHistoryOperations==0 && BlameWindowModel.activeSyntaxRequests==0 && BlameDocumentOpener.activeReads==0}
    @MainActor final class Context {
        let root:URL,git:URL,prefs:UserDefaults,suite:String,repository:GitRepository
        let path="legacy 雪.txt"
        var owners:[BlameWindowController]=[],releases:[()->Void]=[]
        var original=Data(),head=Data(),index=Data()
        var trace:URL{root.appendingPathComponent("git.calls")}
        init(root:URL,git:URL)throws {
            self.root=root;self.git=git;repository=GitRepository(root:root,executable:git,libgit2Configuration:.init(enabled:false))
            suite="TurtleGit.BlameEncoding."+UUID().uuidString;prefs=try unwrap(UserDefaults(suiteName:suite),"No private preferences")
            for key in ["UseLibgit2","EnableGravatar","Blame.EnableLexer","EnableLogCache"]{prefs.set(false,forKey:key)}
        }
        func setup()async throws {
            _=try await repository.run(["init","--template=","-b","main"])
            for(key,value)in [("user.name","Encoding QA"),("user.email","qa@example.invalid"),("commit.gpgsign","false"),("core.hooksPath","/dev/null")]{_=try await repository.run(["config",key,value])}
            let first=Data([0x63,0x61,0x66,0xe9,0x20,0x80,0x0a])+Data("second original\nthird stable\n".utf8)
            try first.write(to:root.appendingPathComponent(path));try await repository.stage([path]);_=try await repository.commit(message:"Add legacy source")
            original=Data([0x63,0x61,0x66,0xe9,0x20,0x80,0x0a])+Data("second changed\nthird stable\n".utf8)
            try original.write(to:root.appendingPathComponent(path));try await repository.stage([path]);_=try await repository.commit(message:"Change another attribution")
            head=try await repository.run(["rev-parse","HEAD"]).stdout;index=try Data(contentsOf:root.appendingPathComponent(".git/index"))
            func quote(_ value:String)->String {"'"+value.replacingOccurrences(of:"'",with:"'\\''")+"'"}
            let script="#!/bin/sh\nprintf 'git-call\\n' >> "+quote(trace.path)+"\nexec "+quote(git.path)+" \"$@\"\n"
            let wrapper=root.appendingPathComponent("held-helper");try script.write(to:wrapper,atomically:true,encoding:.utf8);try FileManager.default.setAttributes([.posixPermissions:0o755],ofItemAtPath:wrapper.path)
        }
        func open()->BlameWindowController {
            let repo=GitRepository(root:root,executable:root.appendingPathComponent("held-helper"),libgit2Configuration:.init(enabled:false))
            let owner=BlameWindowController(repository:repo,access:RepositoryAccessLease(url:root),path:path,revision:"HEAD",options:GitBlameOptions(),preferences:prefs)
            owner.window?.alphaValue=0;owner.window?.setFrameOrigin(.init(x:-24000,y:-24000))
            owners.append(owner);diagnosticOwners.append(owner);owner.showWindow(nil);return owner
        }
        func calls()throws->Data {try Data(contentsOf:trace)}
        func clean()async {
            releases.forEach{$0()};releases=[]
            for owner in owners{owner.close();owner.model.retire()}
            for _ in 0..<2000{if drained(){break};try? await Task.sleep(nanoseconds:10_000_000)}
            diagnosticOwners=[]
            prefs.removePersistentDomain(forName:suite)
        }
        func preserved()async throws {
            try require(try await repository.run(["rev-parse","HEAD"]).stdout==head,"Encoding projection changed HEAD")
            try require(try Data(contentsOf:root.appendingPathComponent(".git/index"))==index,"Encoding projection changed index")
            try require(try Data(contentsOf:root.appendingPathComponent(path))==original,"Encoding projection changed source bytes")
        }
    }
    static func source(_ owner:BlameWindowController)->NSTextView? {views(owner.window?.contentView).compactMap{$0 as? NSTextView}.first{$0.accessibilityLabel()=="Blame source text"}}
    static func attributionRows(_ owner:BlameWindowController)->Int? {
        owner.window?.contentView?.layoutSubtreeIfNeeded()
        return views(owner.window?.contentView).compactMap{$0 as? NSScrollView}.first{$0.accessibilityIdentifier()=="BlameAttributionScroll"}.flatMap{$0.documentView as? NSTableView}?.numberOfRows
    }
    static func selectedEditorLine(_ owner:BlameWindowController)->Int? {
        guard let editor=source(owner) else{return nil}
        let text=editor.string as NSString,range=editor.selectedRange()
        guard range.location != NSNotFound,range.location<=text.length else{return nil}
        return text.substring(to:range.location).filter{$0=="\n"}.count+1
    }
    static func metadata(_ model:BlameWindowModel)->String {
        "history=\(model.historyEntries.map(\.hash)) version=\(model.historyVersion) head=\(model.historyHead ?? "none") working=\(model.historyHasWorkingTree) branch=\(model.historyCurrentBranch ?? "none") refs=\(model.historyReferencesByHash) svn=\(model.hasGitSVN):\(model.svnRevisions)"
    }
    static func verify(_ c:Context)async throws {
        phase("begin independent File Open preparation")
        let cp=try unwrap(GitBlameEncoding.available.first{$0.windowsCodePage==1252},"Windows1252 codec unavailable")
        let latin=try unwrap(GitBlameEncoding.available.first{$0.windowsCodePage==28591},"ISO8859-1 codec unavailable")
        let executable=c.git
        let opener=BlameDocumentOpener(requireScope:false,factory:{GitRepository(root:$0,executable:executable,libgit2Configuration:.init(enabled:false))})
        let opened=try await opener.prepare(file:c.root.appendingPathComponent(c.path),scope:RepositoryAccessLease(url:c.root),options:GitBlameOptions())
        try require(opened.decodingError != nil && opened.annotationDocument.contents==c.original && opened.snapshot.lines.allSatisfy{$0.source.isEmpty} && opened.history.count==2,"File Open discarded recoverable annotation bytes or invented decoded source")
        try require(try opened.annotationDocument.project(encoding:cp).lines.first?.source=="café €","File Open retained document cannot recover explicit codec")
        phase("File Open prepared; construct native Blame owner")
        let owner=c.open(),model=owner.model
        var loadedNotifications=0;model.onLoaded={loadedNotifications += 1}
        try await wait("Automatic legacy failure did not retain raw document/history"){!model.busy && model.error != nil && model.hasRetainedDocument && model.historyEntries.count==2 && drained()}
        try require(model.snapshot==nil && model.lines.isEmpty,"Invalid automatic decoding rendered source")
        try await wait("Undecoded source retained stale native attribution rows"){attributionRows(owner)==0}
        phase("automatic failure retained document; recover CP1252")
        try require(loadedNotifications==0,"Undecoded initial document notified successful load")
        var trace=try c.calls();let initialMetadata=metadata(model)
        model.error=nil;model.setEncoding(cp)
        try await wait("Explicit legacy recovery did not publish source"){!model.busy && model.error==nil && model.snapshot?.encoding==cp && source(owner)?.string=="café €\nsecond changed\nthird stable\n" && drained()}
        try await wait("Recovery did not populate three native attribution rows"){attributionRows(owner)==3}
        try require(try c.calls()==trace,"Encoding recovery fetched Git/history again")
        try require(metadata(model)==initialMetadata,"Encoding recovery replaced history metadata")
        try require(loadedNotifications==1,"First successful recovery did not notify load exactly once")
        let snapshot=try unwrap(model.snapshot,"No recovered source snapshot"),hashes=snapshot.lines.map(\.hash)
        phase("CP1252 native source ready; compatibility install")
        try require(snapshot.contents==c.original && snapshot.lines.count==3 && Set(hashes).count==2,"Recovery lost actual bytes/attribution")
        var installedOptions=GitBlameOptions();installedOptions.encoding=cp
        let installed=BlameWindowModel(repository:model.repository,access:nil,path:c.path,revision:"HEAD",options:installedOptions,labelDefaults:c.prefs)
        defer{installed.retire()}
        installed.install(snapshot,history:model.historyEntries,options:installedOptions)
        installed.setEncoding(latin)
        try await wait("Compatibility install(snapshot:) did not retain reprojectable bytes"){!installed.busy && installed.snapshot?.encoding==latin && drained()}
        try require(installed.hasRetainedDocument && installed.lines.map(\.hash)==hashes && installed.snapshot?.contents==c.original && c.calls()==trace,"Compatibility install fetched Git or lost raw attribution bytes")
        model.goToLine(2);let chosen=try unwrap(model.lines.first?.hash,"No first attribution")
        try await wait("Native editor did not navigate to requested source line"){selectedEditorLine(owner)==2}
        model.selectedLogHashes=[chosen]
        let selection=model.selection,logSelection=model.selectedLogHashes,version=model.historyVersion
        phase("switch Latin1")
        model.setEncoding(latin)
        try await wait("Compatible codec switch did not reproject"){!model.busy && model.snapshot?.encoding==latin && source(owner)?.string=="café \u{80}\nsecond changed\nthird stable\n" && drained()}
        try await wait("Codec switch desynchronized native attribution/caret"){attributionRows(owner)==3 && selectedEditorLine(owner)==2}
        try require(model.lines.map(\.hash)==hashes && model.selection==selection && model.selectedLogHashes==logSelection && model.historyVersion==version,"Codec switch reset selection/attribution/history")
        try require(metadata(model)==initialMetadata && c.calls()==trace,"Compatible codec switch queried Git or changed metadata")
        model.setEncoding(.utf8)
        phase("invalid UTF8 projection")
        try await wait("Invalid explicit codec did not clear rendered source"){!model.busy && model.error != nil && model.snapshot==nil && model.lines.isEmpty && drained()}
        try await wait("Invalid projection left stale native source text"){source(owner)?.string.isEmpty != false}
        try await wait("Invalid projection left native attribution rows"){attributionRows(owner)==0}
        try require(model.hasRetainedDocument && model.selection==selection && model.selectedLogHashes==logSelection && metadata(model)==initialMetadata,"Invalid projection discarded recovery/metadata/selection")
        model.error=nil;model.setEncoding(cp)
        phase("recover after invalid UTF8")
        try await wait("Second explicit recovery did not restore exact source"){!model.busy && model.snapshot?.encoding==cp && source(owner)?.string=="café €\nsecond changed\nthird stable\n" && drained()}
        try await wait("Second recovery lost native attribution/caret"){attributionRows(owner)==3 && selectedEditorLine(owner)==2}
        try require(try c.calls()==trace && model.lines.map(\.hash)==hashes,"Recovery after invalid codec queried Git or replaced attribution")
        // Hold the pure decoder, with no process and no selection mutation.
        var release:CheckedContinuation<Void,Never>?,token:OperationCancellation?
        c.releases.append{release?.resume();release=nil}
        model.projectDocument={document,encoding,cancellation in
            token=cancellation
            await withCheckedContinuation{release=$0}
            return try document.project(encoding:encoding,cancellation:cancellation)
        }
        model.setEncoding(latin)
        phase("held codec projection and Cancel")
        try await wait("Owned projection did not enter held executor"){release != nil && model.busy && BlameWindowModel.activeHistoryOperations>0}
        model.setEncoding(.utf8)
        try require(model.sourceEncoding==latin,"Busy encoding action superseded accepted projection")
        model.cancelReload()
        try require(token?.isCancelled==true && model.busy && BlameWindowModel.activeHistoryOperations>0,"Cancel abandoned actual projection worker before drain")
        release?.resume();release=nil
        try await wait("Canceled projection did not drain"){!model.busy && drained()}
        try require(model.snapshot?.encoding==cp && model.error==nil && model.hasRetainedDocument,"Canceled projection published stale result/error or lost retained bytes")
        model.projectDocument={document,encoding,cancellation in try await Task.detached{try document.project(encoding:encoding,cancellation:cancellation)}.value}
        model.setEncoding(cp)
        try await wait("Recovery following Cancel did not settle"){!model.busy && model.snapshot?.encoding==cp && drained()}
        try require(try c.calls()==trace && loadedNotifications==1,"Codec projections queried Git or repeated loaded notification")
        // Explicit Reload is allowed to read Git. Its candidate document and
        // metadata must remain private if projection is canceled afterward.
        let prior=try unwrap(model.snapshot,"No accepted snapshot before Reload"),priorMetadata=metadata(model)
        model.projectDocument={document,encoding,cancellation in token=cancellation;await withCheckedContinuation{release=$0};return try document.project(encoding:encoding,cancellation:cancellation)}
        model.reload()
        phase("explicit Reload with held projection and Cancel")
        try await wait("Explicit Reload did not reach staged projection"){release != nil && model.busy}
        model.cancelReload();try require(token?.isCancelled==true && model.busy,"Reload Cancel dropped active decoder ownership")
        release?.resume();release=nil
        try await wait("Canceled Reload projection did not drain"){!model.busy && drained()}
        try require(model.snapshot?.contents==prior.contents && model.snapshot?.encoding==prior.encoding && model.lines.map(\.hash)==prior.lines.map(\.hash) && metadata(model)==priorMetadata && model.selection==selection && model.selectedLogHashes==logSelection && model.hasRetainedDocument && model.error==nil,"Canceled Reload replaced accepted document/history/selection")
        trace=try c.calls()
        model.projectDocument={document,encoding,cancellation in token=cancellation;await withCheckedContinuation{release=$0};return try document.project(encoding:encoding,cancellation:cancellation)}
        model.setEncoding(latin)
        phase("held projection and owner retirement")
        try await wait("Retired projection did not enter held executor"){release != nil && model.busy}
        owner.close()
        try require(model.retired && !model.hasRetainedDocument && token?.isCancelled==true && BlameWindowModel.activeHistoryOperations>0,"Retirement lost active projection ownership or retained raw document")
        release?.resume();release=nil
        try await wait("Retired pure projection did not drain"){drained() && owner.window?.isVisible != true}
        try require(model.snapshot?.encoding != latin && c.calls()==trace,"Retired projection published stale source or fetched Git")
        try await c.preserved()
    }
    static func main()async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let normal=class_getInstanceMethod(NSWindow.self,#selector(NSWindow.order(_:relativeTo:)))!,hidden=class_getInstanceMethod(NSWindow.self,#selector(NSWindow.quietBlameEncodingOrder(_:relativeTo:)))!
        let sheet=class_getInstanceMethod(NSWindow.self,#selector(NSWindow.beginSheet(_:completionHandler:)))!,hiddenSheet=class_getInstanceMethod(NSWindow.self,#selector(NSWindow.quietBlameEncodingSheet(_:completionHandler:)))!
        method_exchangeImplementations(normal,hidden);method_exchangeImplementations(sheet,hiddenSheet)
        defer{method_exchangeImplementations(sheet,hiddenSheet);method_exchangeImplementations(normal,hidden)}
        let c=try Context(root:URL(fileURLWithPath:CommandLine.arguments[1]),git:URL(fileURLWithPath:CommandLine.arguments[2]))
        DialogGeometry.install(preferences:c.prefs)
        defer{DialogGeometry.install(preferences:.standard)}
        phase("setup private repository")
        do{try await c.setup();try await verify(c);phase("cleanup");await c.clean()}catch{phase("failure cleanup: \(error)");await c.clean();throw error}
        try require(drained() && NSApp.windows.allSatisfy{!$0.isVisible && $0.attachedSheet==nil},"Owned Blame windows/workers survived cleanup")
        print("PASS: Blame retained-byte encoding projection, recovery, native source, metadata/no-Git and owned cancellation/retirement")
    }
}
