// SPDX-License-Identifier: GPL-2.0-or-later
import AppKit
import Darwin
import ObjectiveC
import TurtleGitCore

private extension NSWindow {
    @objc func diffInputFrame(_ rect:NSRect,to screen:NSScreen?)->NSRect {rect}
    @objc func diffInputOrder(_ mode:NSWindow.OrderingMode,relativeTo number:Int) {alphaValue=0;setFrameOrigin(.init(x:-24000,y:-24000));diffInputOrder(mode,relativeTo:number)}
}
@MainActor @main enum UnifiedDiffInputVerification {
    struct Scope:RepositoryBookmarkProvider {
        let allowed:Bool
        func create(for url:URL)throws->Data {Data(url.path.utf8)}
        func resolve(_ data:Data)throws->ResolvedBookmark {.init(url:URL(fileURLWithPath:String(decoding:data,as:UTF8.self)),stale:false)}
        func startAccessing(_ url:URL)->Bool {allowed}
        func stopAccessing(_ url:URL) {}
    }
    struct Failure:Error,CustomStringConvertible {let description:String}
    static func require(_ value:Bool,_ message:String)throws {if !value {throw Failure(description:message)}}
    static func wait(line:Int = #line,_ ready:()->Bool)async throws {
        for _ in 0..<2000 {if ready(){return};try await Task.sleep(nanoseconds:10_000_000)}
        throw Failure(description:"Unified input timeout at \(line)")
    }
    final class Pipe {
        var input:Int32 = -1,output:Int32 = -1
        init()throws {var values:[Int32]=[-1,-1];guard pipe(&values)==0 else{throw Failure(description:"pipe failed")};input=values[0];output=values[1]}
        func send(_ data:Data)throws {
            let count=data.withUnsafeBytes{Darwin.write(output,$0.baseAddress,$0.count)}
            guard count==data.count else{throw Failure(description:"private pipe write failed")}
        }
        func eof(){if output>=0 {close(output);output = -1}}
        func clean(){eof();if input>=0 {close(input);input = -1}}
        deinit{clean()}
    }
    final class Held:@unchecked Sendable {
        private let lock=NSLock(),gate=DispatchSemaphore(value:0)
        private var began=false,released=false
        var started:Bool {lock.lock();defer{lock.unlock()};return began}
        func read(_ fd:Int32,_ token:OperationCancellation)throws->Data {
            lock.lock();began=true;lock.unlock();gate.wait()
            // Deliberately return bytes even after Cancel to prove the native
            // receipt, rather than only the cooperative reader, fences publish.
            return Data("late contents\n".utf8)
        }
        func streamRead(_ fd:Int32,_ token:OperationCancellation)throws->Data {
            lock.lock();began=true;lock.unlock();gate.wait()
            guard fcntl(fd,F_GETFD)&FD_CLOEXEC != 0 else{throw Failure(description:"Accepted stream copy lacks CLOEXEC")}
            return try UnifiedDiffInputReader.read(descriptor:fd,cancellation:token)
        }
        func release(){lock.lock();let needed = !released;released=true;lock.unlock();if needed{gate.signal()}}
    }
    @MainActor final class Context {
        let root=URL(fileURLWithPath:CommandLine.arguments[1],isDirectory:true)
        let suite="TurtleGit.UnifiedInput."+UUID().uuidString
        let preferences:UserDefaults
        var owners:[PatchWindowController]=[],sessions:[UnifiedDiffInputSession]=[],held:[Held]=[],pipes:[Pipe]=[]
        init(){preferences=UserDefaults(suiteName:suite)!}
        func owner()->PatchWindowController {
            let owner=PatchWindowController(documentDirectory:root,preferences:preferences)
            owner.window?.isReleasedWhenClosed=false;owner.window?.alphaValue=0;owner.window?.setFrameOrigin(.init(x:-24000,y:-24000));owner.showWindow(nil);owners.append(owner);return owner
        }
        func stream()throws->Pipe {let p=try Pipe();pipes.append(p);return p}
        func session(read:UnifiedDiffInputSession.Reader?=nil)->UnifiedDiffInputSession {
            let s=read.map{UnifiedDiffInputSession(read:$0)} ?? UnifiedDiffInputSession();sessions.append(s);return s
        }
        func clean()async {
            for s in sessions{s.cancel()};for h in held{h.release()}
            await UnifiedDiffInputSession.cancelAllAndWait()
            for owner in owners {
                if let window=owner.window,let sheet=window.attachedSheet {window.endSheet(sheet,returnCode:.abort);sheet.close()}
                owner.close()
            }
            for p in pipes{p.clean()}
            preferences.removePersistentDomain(forName:suite)
        }
    }
    static func stream(_ c:Context)async throws {
        let owner=c.owner(),p=try c.stream(),s=c.session()
        let title="Git Café e\u{301} — raw /title:$ literal"
        try require(s.start(controller:owner,descriptor:p.input,title:title),"Startup stream refused")
        try require(s.isReading && owner.model.busy && owner.model.loading && !owner.model.canEditText && owner.window?.title==title+" – Unified Diff – TurtleGit","Empty window did not enter owned loading state")
        let first=Data("diff --git a/café b/café\r\n--- a/café\r\n".utf8),last=Data("+++ b/café\r\n@@ -1 +1 @@\r\n-old\r\n+new 🐢\r\n".utf8)
        try p.send(first)
        try require(owner.model.exportDocument.bytes.isEmpty && s.isReading,"Partial stdin escaped before EOF")
        try p.send(last);p.eof()
        try await wait{!s.isReading && !owner.model.busy}
        try require(try owner.model.encodedDocumentBytes()==first+last,"Raw UTF8/CRLF bytes changed during startup publication")
        try require(owner.model.error==nil && owner.model.canEditText && !owner.model.documentDirty && owner.window?.title==title+" – Unified Diff – TurtleGit" && owner.model.comparisonTitle==title,"Completed stream not editable/clean with immutable title")
        try require(fcntl(p.input,F_GETFD)>=0,"Input reader closed parent descriptor")
        let flags=fcntl(p.input,F_GETFL)
        try require(flags>=0 && flags&O_NONBLOCK==0,"Input reader changed shared descriptor flags")
        let text=owner.model.document.text;owner.model.editDocument(text+"edited\n")
        try require(owner.model.documentDirty,"Startup editor did not retain normal document mutation")
        let empty=c.owner(),end=try c.stream(),e=c.session();end.eof()
        try require(e.start(controller:empty,descriptor:end.input,title:"Empty EOF"),"Empty EOF refused")
        try await wait{!e.isReading}
        try require(empty.model.error==nil && empty.model.exportDocument.bytes.isEmpty && empty.model.canEditText,"Explicit empty EOF treated as an error")
        try require(!s.start(controller:empty,descriptor:end.input,title:"Replacement"),"Single-use session replaced completed document")

        let captured=c.owner(),original=try c.stream(),gate=Held();c.held.append(gate)
        let capture=c.session(read:{try gate.streamRead($0,$1)})
        try require(capture.start(controller:captured,descriptor:original.input,title:"Captured stream"),"Captured stream refused")
        try await wait{gate.started}
        let oldNumber=original.input;close(oldNumber);original.input = -1
        let substitute=open("/dev/null",O_RDONLY)
        guard substitute>=0 else{throw Failure(description:"Private substitute descriptor failed")}
        if substitute != oldNumber {guard dup2(substitute,oldNumber)==oldNumber else{close(substitute);throw Failure(description:"Descriptor reuse failed")};close(substitute)}
        defer{close(oldNumber)}
        let expected=Data("captured original stream\n".utf8);try original.send(expected);original.eof();gate.release()
        try await wait{!capture.isReading}
        try require(captured.model.exportDocument.bytes==expected && captured.model.error==nil,"Queued reader followed reused caller descriptor instead of accepted stream")
    }
    static func lifetime(_ c:Context)async throws {
        let owner=c.owner(),h=Held(),heldPipe=try c.stream();c.held.append(h)
        let s=c.session(read:{try h.read($0,$1)})
        try require(s.start(controller:owner,descriptor:heldPipe.input,title:"Pending close"),"Held session refused")
        try await wait{h.started}
        owner.window?.performClose(nil)
        try require(s.isReading && s.cancelling && !owner.model.retired && UnifiedDiffInputSession.activeOperations==1,"Close released a live worker or ignored cancellation")
        h.release();try await wait{!s.isReading && owner.model.retired}
        try require(owner.model.exportDocument.bytes.isEmpty && UnifiedDiffInputSession.activeOperations==0,"Cancelled close published late bytes or retained worker")

        let retired=c.owner(),late=Held(),latePipe=try c.stream();c.held.append(late)
        let lateSession=c.session(read:{try late.read($0,$1)})
        try require(lateSession.start(controller:retired,descriptor:latePipe.input,title:"Forced close"),"Forced-close read refused")
        try await wait{late.started};retired.close()
        try require(retired.model.retired && lateSession.isReading && UnifiedDiffInputSession.activeOperations==1,"Forced owner retirement forgot active input worker")
        let independent=c.owner(),pipe=try c.stream(),other=c.session()
        try require(other.start(controller:independent,descriptor:pipe.input,title:"Independent"),"Independent stream refused")
        let bytes=Data("independent\n".utf8);try pipe.send(bytes);pipe.eof()
        try await wait{!other.isReading}
        try require(independent.model.exportDocument.bytes==bytes && lateSession.isReading,"Independent input state leaked between windows")
        let delegate=TurtleGitApplicationDelegate();var replies:[Bool]=[]
        delegate.replyToTermination={_,allowed in replies.append(allowed)}
        try require(delegate.applicationShouldTerminate(NSApp) == .terminateLater,"Single Quit did not start owned input drain")
        try require(delegate.applicationShouldTerminate(NSApp) == .terminateLater && replies.isEmpty,"Repeated Quit bypassed in-flight drain")
        try await wait{lateSession.cancelling}
        try require(replies.isEmpty && lateSession.isReading,"Global Quit replied before actual reader exited")
        late.release();try await wait{replies.count==1}
        try require(replies==[true] && UnifiedDiffInputSession.activeOperations==0 && retired.model.exportDocument.bytes.isEmpty && retired.window?.isVisible==false,"Retired input opened/published late or survived single Quit drain")
    }
    static func failure(_ c:Context)async throws {
        let owner=c.owner(),s=c.session()
        try require(s.start(controller:owner,descriptor:-1,title:"Failure owner"),"Invalid descriptor did not start owned read")
        try await wait{!s.isReading}
        try require(!owner.model.busy && owner.model.error != nil && owner.window?.title=="Failure owner – Unified Diff – TurtleGit" && !owner.model.retired,"Input failure was hidden or delivered to another owner")
        let limited=c.owner(),pipe=try c.stream(),limit=c.session(read:{try UnifiedDiffInputReader.read(descriptor:$0,maxBytes:2,cancellation:$1)})
        try require(limit.start(controller:limited,descriptor:pipe.input,title:"Limited"),"Limited read refused")
        try pipe.send(Data("three".utf8));pipe.eof();try await wait{!limit.isReading}
        try require(limited.model.error != nil && limited.model.exportDocument.bytes.isEmpty && UnifiedDiffInputSession.activeOperations==0,"Over-limit input published partial bytes")
        let cancelled=c.owner(),pending=try c.stream(),cancel=c.session()
        try require(cancel.start(controller:cancelled,descriptor:pending.input,title:"Cancel only"),"Cancel read refused")
        cancelled.model.cancelRead();await cancel.cancelAndWait()
        try require(cancelled.model.error==nil && !cancelled.model.retired && !cancelled.model.busy && !cancelled.model.loading && cancelled.model.canEditText,"Cancel button closed owner, errored or left input busy")
        try require(fcntl(pending.input,F_GETFD)>=0,"Cancel closed parent input")
    }
    static func command(_ c:Context)async throws {
        try require(TurtleGitLaunchMode.resolve(arguments:["--unified-diff","--stdin"],currentDirectory:c.root.path) == .unifiedDiff,"Native startup did not select standalone scene")
        try require(TurtleGitLaunchMode.resolve(arguments:["/command:log","/p"],currentDirectory:c.root.path) == .workspace,"Standalone grammar intercepted repository command")
        c.preferences.set("custom",forKey:"TurtleGit.GitEngine")
        c.preferences.set(c.root.appendingPathComponent("missing-git").path,forKey:"TurtleGit.GitExecutable")
        var repositoryRequests=0
        let workspace=RepositoryModel(startMonitoring:false,initializePreferences:false,repositoryFactory:{_ in repositoryRequests += 1;throw Failure(description:"Plain diff attempted Git initialization")})
        workspace.reviewPatchPreferences=c.preferences
        workspace.patchDocumentPresentation={owner in owner.window?.alphaValue=0;owner.window?.setFrameOrigin(.init(x:-24000,y:-24000));owner.showWindow(nil);c.owners.append(owner)}
        defer{workspace.stopMonitoringForTermination()}
        let p=try c.stream();var completions:[Int32]=[]
        try require(workspace.handleUnifiedDiffCommandLine(arguments:["--unified-diff","--stdin","--title","Captured / Unicode 🐢"],currentDirectory:c.root.path,descriptor:p.input,completion:{completions.append($0)}),"Actual repository startup receiver refused stdin")
        guard let owner=workspace.patchDocumentWindows.values.first else{throw Failure(description:"Command receiver omitted document owner")}
        try require(workspace.root==nil && repositoryRequests==0 && owner.model.repository==nil && owner.startupInput?.isReading==true,"Standalone stdin initialized repository or lost owner")
        let bytes=Data("diff --git a/f b/f\n--- a/f\n+++ b/f\n@@ -1 +1 @@\n-a\n+b\n".utf8)
        try p.send(bytes);p.eof();try await wait{owner.startupInput?.isReading==false}
        try require(owner.model.exportDocument.bytes==bytes && owner.model.comparisonTitle=="Captured / Unicode 🐢","Actual startup did not preserve stdin/title")
        let menu=PatchMenuContext(keyWindow:{owner.window});menu.setDarkMode(true)
        try require(owner.model.darkMode && menu.darkMode,"Standalone View dark menu missed exact owner")
        menu.setDarkMode(false);try require(!owner.model.darkMode,"Standalone light menu did not restore owner")
        owner.window?.performClose(nil);try await wait{owner.model.retired}
        try require(completions==[0] && workspace.patchDocumentWindows.isEmpty,"Startup close completion/ownership not exact once")

        let file=c.root.appendingPathComponent("literal.patch");try bytes.write(to:file)
        try require(workspace.handleUnifiedDiffCommandLine(arguments:["--unified-diff","--patchfile",file.path,"--title","File title"],currentDirectory:c.root.path),"Plain file command refused")
        guard let fileOwner=workspace.patchDocumentWindows.values.first else{throw Failure(description:"Plain file owner absent")}
        try await wait{fileOwner.model.exportDocument.bytes==bytes && !fileOwner.model.busy}
        try require(fileOwner.model.error==nil && repositoryRequests==0 && fileOwner.model.repository==nil,"Missing Git preference prevented plain file open")
        fileOwner.documentSession.applyPatch()
        try await wait{fileOwner.model.error != nil}
        try require(fileOwner.model.exportDocument.bytes==bytes && !fileOwner.model.busy && repositoryRequests==0,"Lazy Apply runtime failure damaged plain editor")
        try require(!workspace.handleUnifiedDiffCommandLine(arguments:["/command:log"],currentDirectory:c.root.path),"Standalone handler consumed repository invocation")

        for choice in ["cancel","wrong","exact"] {
            let granted=c.owner();granted.presentDocument(Data(),title:"Grant",comparison:"Grant",information:"")
            let session=granted.documentSession!
            session.requiresFileScope=true
            var acquisitions=0,choices=0,reads=0
            session.acquireAccess={url in acquisitions += 1;return RepositoryAccessLease(url:url,provider:Scope(allowed:choice=="exact" && acquisitions>1))}
            session.chooseOpen={_,reply in choices += 1;reply(choice=="cancel" ? nil : choice=="wrong" ? c.root.appendingPathComponent("other.patch") : file)}
            session.readFile={url,token in reads += 1;return try await Task.detached{try UnifiedDiffInputReader.readFile(url,cancellation:token)}.value}
            session.openFile(file,title:"Explicit grant 🐢",authorizeIfNeeded:true)
            try await wait{choices==1 && PatchDocumentSession.activeOperations==0 && !granted.model.busy}
            switch choice {
            case "cancel":try require(reads==0 && granted.model.error==nil && granted.model.exportDocument.bytes.isEmpty,"Cancelled grant read/published/errored")
            case "wrong":try require(reads==0 && granted.model.error != nil && granted.model.exportDocument.bytes.isEmpty,"Wrong file grant admitted requested file")
            default:try require(reads==1 && acquisitions==2 && granted.model.error==nil && granted.model.exportDocument.bytes==bytes && granted.model.comparisonTitle=="Explicit grant 🐢","Exact file grant/title did not reach real reader")
            }
        }
    }
    static func startup(_ c:Context)async throws {
        @MainActor func bootstrap()throws->(TurtleGitApplicationDelegate,RepositoryModel,PatchWindowController) {
            let workspace=RepositoryModel(startMonitoring:false,initializePreferences:false)
            workspace.reviewPatchPreferences=c.preferences
            workspace.patchDocumentPresentation={owner in owner.window?.alphaValue=0;owner.window?.setFrameOrigin(.init(x:-24000,y:-24000));owner.showWindow(nil);c.owners.append(owner)}
            let delegate=TurtleGitApplicationDelegate()
            delegate.startupArguments=["--unified-diff"];delegate.startupDirectory=c.root.path
            delegate.makeStandaloneWorkspace={workspace};delegate.configureStandaloneServices={_,_ in};delegate.activateStandaloneApplication={};delegate.startupMergeToolExit={_ in}
            delegate.startupDidFinishLaunching()
            guard let owner=workspace.patchDocumentWindows.values.first else{throw Failure(description:"Actual standalone bootstrap omitted viewer")}
            try require(delegate.standaloneWorkspace === workspace && workspace.root==nil && owner.model.canEditText,"Actual bootstrap initialized workspace or disabled empty editor")
            return(delegate,workspace,owner)
        }
        let(cleanDelegate,cleanWorkspace,clean)=try bootstrap()
        try require(cleanDelegate.applicationShouldTerminate(NSApp) == .terminateNow,"Clean actual Unified Diff startup entered endless Merge termination")
        clean.close();cleanWorkspace.stopMonitoringForTermination()

        let(dirtyDelegate,dirtyWorkspace,dirty)=try bootstrap()
        dirty.model.editDocument("unsaved startup draft\n")
        var questions=0,replies:[Bool]=[]
        dirty.documentSession.askChanges={_,reply in questions += 1;reply(.discard)}
        dirtyDelegate.replyToTermination={_,allowed in replies.append(allowed)}
        try require(dirtyDelegate.applicationShouldTerminate(NSApp) == .terminateLater,"Dirty actual startup skipped owned Quit decision")
        try await wait{replies.count==1}
        try require(questions==1 && replies==[true],"Dirty actual startup never completed ordinary document Quit pipeline")
        dirty.close();dirtyWorkspace.stopMonitoringForTermination()

        let(busyDelegate,busyWorkspace,busy)=try bootstrap()
        let h=Held(),pipe=try c.stream();c.held.append(h)
        let input=c.session(read:{try h.read($0,$1)})
        try require(input.start(controller:busy,descriptor:pipe.input,title:"Startup busy"),"Actual bootstrap input refused")
        try await wait{h.started}
        var busyReplies:[Bool]=[]
        busyDelegate.replyToTermination={_,allowed in busyReplies.append(allowed)}
        try require(busyDelegate.applicationShouldTerminate(NSApp) == .terminateLater,"Actual startup did not own input Quit drain")
        try await wait{input.cancelling}
        try require(busyReplies.isEmpty && input.isReading,"Actual startup replied before worker settled")
        h.release();try await wait{busyReplies.count==1}
        try require(busyReplies==[true] && UnifiedDiffInputSession.activeOperations==0 && busy.model.exportDocument.bytes.isEmpty,"Actual startup drained then entered Merge-only completion or published cancelled bytes")
        busy.close();busyWorkspace.stopMonitoringForTermination()
    }
    static func main()async {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let methods=[(class_getInstanceMethod(NSWindow.self,#selector(NSWindow.constrainFrameRect(_:to:))),class_getInstanceMethod(NSWindow.self,#selector(NSWindow.diffInputFrame(_:to:)))),(class_getInstanceMethod(NSWindow.self,#selector(NSWindow.order(_:relativeTo:))),class_getInstanceMethod(NSWindow.self,#selector(NSWindow.diffInputOrder(_:relativeTo:))))]
        for(a,b)in methods{if let a,let b{method_exchangeImplementations(a,b)}}
        defer{for(a,b)in methods.reversed(){if let a,let b{method_exchangeImplementations(a,b)}}}
        let c=Context();DialogGeometry.install(preferences:c.preferences)
        do {
            switch CommandLine.arguments[3] {case "stream":try await stream(c);case "lifetime":try await lifetime(c);case "failure":try await failure(c);case "command":try await command(c);case "startup":try await startup(c);default:throw Failure(description:"Unknown input case")}
            await c.clean();DialogGeometry.install(preferences:.standard)
            try require(UnifiedDiffInputSession.activeOperations==0 && NSApp.windows.allSatisfy{!$0.isVisible && $0.attachedSheet==nil},"Input workers/windows remained after cleanup")
            print("PASS: unified diff input "+CommandLine.arguments[3]);fflush(stdout)
        } catch {await c.clean();DialogGeometry.install(preferences:.standard);fputs("Unified input failed: \(error)\n",stderr);exit(1)}
    }
}
