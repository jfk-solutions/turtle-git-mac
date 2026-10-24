// SPDX-License-Identifier: GPL-2.0-or-later
import AppKit
import ObjectiveC
import TurtleGitCore

extension NSWindow {
    @objc func historicalFrame(_ rect:NSRect,to screen:NSScreen?)->NSRect{rect}
    @objc func historicalOrder(_ mode:NSWindow.OrderingMode,relativeTo number:Int){alphaValue=0;historicalOrder(mode,relativeTo:number)}
}
@MainActor @main struct HistoricalNavigationVerification {
    struct Failure:Error,CustomStringConvertible{let description:String}
    static func require(_ value:Bool,_ message:String)throws{if !value{throw Failure(description:message)}}
    static func wait(line:UInt = #line,_ ready:()->Bool)async throws{for _ in 0..<3000{if ready(){return};try await Task.sleep(nanoseconds:10_000_000)};throw Failure(description:"Historical navigation timeout at \(line)")}
    static func quote(_ value:String)->String{"'"+value.replacingOccurrences(of:"'",with:"'\\''")+"'"}
    @MainActor final class Context {
        let base=URL(fileURLWithPath:CommandLine.arguments[1]),git=URL(fileURLWithPath:CommandLine.arguments[2])
        let suite="TurtleGit.HistoricalNavigation."+UUID().uuidString,prefs:UserDefaults
        var root:URL{base.appendingPathComponent("repository")};var helper:URL{base.appendingPathComponent("historical-helper")}
        var trace:URL{base.appendingPathComponent("trace")};var malformed:URL{base.appendingPathComponent("malformed")}
        var hold:URL{base.appendingPathComponent("hold")};var started:URL{base.appendingPathComponent("started")};var release:URL{base.appendingPathComponent("release")}
        var repo:GitRepository!,cli:GitRepository!,old="",head="",rows:[LogEntry]=[],owners:[NSWindowController]=[]
        init(){prefs=UserDefaults(suiteName:suite)!;prefs.set(true,forKey:"UseLibgit2");prefs.set(0,forKey:"UseLibgit2_mask");prefs.set(false,forKey:"EnableLogCache");prefs.set(false,forKey:"ConfirmKillProcess")}
        func own<T:NSWindowController>(_ owner:T)->T{owners.append(owner);owner.window?.isReleasedWhenClosed=false;owner.window?.alphaValue=0;owner.window?.setFrameOrigin(.init(x:-20000,y:-20000));owner.window?.orderFront(nil);return owner}
        func prepare()async throws {
            try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
            cli=GitRepository(root:root,executable:git,askpass:nil,libgit2Configuration:.init(enabled:false))
            _=try await cli.run(["init","--template=","-b","main"])
            for(k,v)in[("user.name","Historical QA"),("user.email","historical@example.invalid"),("core.hooksPath","/dev/null"),("commit.gpgsign","false"),("core.precomposeunicode","true")] {_=try await cli.run(["config",k,v])}
            try Data("old\n".utf8).write(to:root.appendingPathComponent("file.txt"));try await cli.stage(["."]);_=try await cli.commit(message:"old")
            old=try await cli.run(["rev-parse","HEAD"]).text.trimmingCharacters(in:.newlines)
            try Data("new\n".utf8).write(to:root.appendingPathComponent("file.txt"));try await cli.stage(["."]);_=try await cli.commit(message:"new")
            head=try await cli.run(["rev-parse","HEAD"]).text.trimmingCharacters(in:.newlines)
            let runtime=URL(fileURLWithPath:FileManager.default.currentDirectoryPath).appendingPathComponent("build/libgit2-runtime/LibGit2/bin/turtlegit-libgit2")
            let resource=base.appendingPathComponent("owned-resource");try Data().write(to:resource)
            let script="""
            #!/bin/sh
            exec 9< \(quote(resource.path))
            printf '%s\\n' "$*" >> \(quote(trace.path))
            case "$*" in
              *turtlegit-revision-lookup*|*turtlegit-historical-gitlink*)
                if test -f \(quote(hold.path)); then : > \(quote(started.path)); while ! test -f \(quote(release.path)); do /bin/sleep .02; done; fi
                if test -f \(quote(malformed.path)); then printf 'invalid protocol\\n'; exit 0; fi ;;
            esac
            exec \(quote(runtime.path)) "$@"
            """
            try Data(script.utf8).write(to:helper);try FileManager.default.setAttributes([.posixPermissions:0o700],ofItemAtPath:helper.path)
            repo=GitRepository(root:root,executable:git,askpass:nil,libgit2Configuration:.init(enabled:false,mask:0,helperURL:helper))
            rows=try await cli.history(options:HistoryOptions())
        }
        func calls()->String{(try? String(contentsOf:trace,encoding:.utf8)) ?? ""}
        func clear()throws{try Data().write(to:trace)}
        func log()->LogWindowController {
            let owner=own(LogWindowController(repository:repo,access:RepositoryAccessLease(url:root),labelDefaults:prefs,savesColumnLayout:false,savesGeometry:false,loadsImmediately:false))
            owner.model.entries=rows;owner.model.graph=CommitGraph.layout(rows);owner.model.selected=[old];owner.model.bare=false;return owner
        }
        func clean()async {
            try? Data().write(to:release)
            for owner in owners.reversed(){if let window=owner.window{if let sheet=window.attachedSheet{window.endSheet(sheet,returnCode:.abort);sheet.close()};window.makeFirstResponder(nil)};owner.close()}
            for window in NSApp.windows{if let parent=window.sheetParent{parent.endSheet(window,returnCode:.abort)};window.close()}
            for _ in 0..<3000{if drained(){break};try? await Task.sleep(nanoseconds:10_000_000)}
            prefs.removePersistentDomain(forName:suite)
        }
    }
    static func drained()->Bool{LogWindowModel.activeReferenceReads==0 && LogWindowModel.activeFileOpenReads==0 && LogWindowModel.activeActionReads==0 && LogWindowModel.activeHistoryDeletions==0 && RepositoryBrowserWindowModel.activeOperations==0 && RevisionComparisonWindowModel.activeFileOperations==0 && BisectWindowModel.activeOperations==0}
    static func log(_ c:Context)async throws {
        let nfc="caf\u{e9}",nfd="cafe\u{301}"
        try Data(("# pack-refs with: peeled fully-peeled sorted\n"+c.old+" refs/heads/"+nfd+"\n"+c.head+" refs/heads/"+nfc+"\n").utf8).write(to:c.root.appendingPathComponent(".git/packed-refs"))
        let owner=c.log(),m=owner.model
        let index=try unwrap(m.entries.firstIndex{$0.hash==c.old},"Old Log row missing")
        m.entries[index].references=[.init(name:"refs/heads/"+nfd)]
        var result:String?;m.onRebaseRevision={result=$0}
        try c.clear();m.requestIntegration(.rebase);c.prefs.set(false,forKey:"UseLibgit2")
        try await wait{!m.busy && LogWindowModel.activeReferenceReads==0}
        try require(result?.utf8.elementsEqual(nfd.utf8)==true && m.acceptedNavigationRepository?.libgit2Configuration?.enabled==true && c.calls().contains("turtlegit-revision-lookup"),"Log integration lost literal preferred ref or accepted backend: \(m.error ?? "none")")
        c.prefs.set(true,forKey:"UseLibgit2")
        var deletion:HistoryReferenceDeletion?
        m.confirmReferenceDeletion={snapshot in deletion=snapshot;c.prefs.set(false,forKey:"UseLibgit2");return .abort}
        m.deleteReferences([LogReferenceMenuTarget(hash:c.old,name:"refs/heads/"+nfd)])
        try await wait{!m.busy && LogWindowModel.activeHistoryDeletions==0}
        try require(deletion?.name.utf8.elementsEqual(("refs/heads/"+nfd).utf8)==true && deletion?.objectID==c.old && deletion?.acceptedBackend?.enabled==true,"Log deletion preflight chose canonical sibling or lost accepted settings")
        _=try await c.cli.run(["-c","core.precomposeunicode=false","update-ref","refs/heads/"+nfd,c.head])
        result=nil;m.requestIntegration(.rebase);try await wait{!m.busy && LogWindowModel.activeReferenceReads==0}
        try require(result==nil && m.error != nil,"Moved preferred ref retargeted accepted Log integration")
        c.prefs.set(true,forKey:"UseLibgit2");try Data().write(to:c.malformed);m.error=nil;m.requestIntegration(.rebase)
        try await wait{!m.busy && LogWindowModel.activeReferenceReads==0}
        try require(result==nil && m.error != nil,"Selected malformed helper silently fell back in Log integration")
        try FileManager.default.removeItem(at:c.malformed)
        try Data().write(to:c.hold);m.requestIntegration(.rebase)
        try await wait{FileManager.default.fileExists(atPath:c.started.path)};owner.close();try Data().write(to:c.release)
        try await wait{LogWindowModel.activeReferenceReads==0}
        try require(result==nil && m.isInvalidated,"Closed Log published a late integration")
    }
    static func unwrap<T>(_ value:T?,_ message:String)throws->T{guard let value else{throw Failure(description:message)};return value}
    static func browser(_ c:Context)async throws {
        c.prefs.set(false,forKey:"UseLibgit2")
        let owner=c.own(RepositoryBrowserWindowController(repository:c.repo,access:RepositoryAccessLease(url:c.root),revision:c.old,preferences:c.prefs)),m=owner.model
        try await wait{!m.busy && !m.hasPendingWork && m.snapshot != nil}
        try require(m.error==nil && m.snapshot?.objectID==c.old && c.calls().contains("turtlegit-revision-lookup"),"Browser ReadTree did not force the source initialization engine")
        let entry=try unwrap(m.snapshot?.entries.first{$0.path=="file.txt"},"Browser entry absent")
        try c.clear();m.markForComparison(entry);try await wait{!m.busy && !m.hasPendingWork}
        try require(m.comparisonMark?.revision==c.old && !c.calls().contains("turtlegit-revision-lookup"),"Browser mark did not obey disabled master or pinned revision")
        c.prefs.set(true,forKey:"UseLibgit2");var pair:(PreparedFileComparisonMark,PreparedFileComparisonMark)?
        m.onPreparedFileCompare={pair=($0,$1)};try c.clear();m.compareWithMarkedFile(entry);c.prefs.set(false,forKey:"UseLibgit2")
        try await wait{!m.busy && !m.hasPendingWork}
        try require(pair?.0.revision==c.old && pair?.1.revision==c.old && m.acceptedNavigationRepository?.libgit2Configuration?.enabled==true && c.calls().contains("turtlegit-revision-lookup"),"Browser comparison recaptured preferences or changed marked objects")
        c.prefs.set(true,forKey:"UseLibgit2");try Data().write(to:c.malformed);m.comparisonMark=nil;m.markForComparison(entry)
        try await wait{!m.busy && !m.hasPendingWork}
        try require(m.comparisonMark==nil && m.error != nil,"Browser mark accepted malformed selected lookup")
        try FileManager.default.removeItem(at:c.malformed);try Data().write(to:c.hold);m.error=nil;m.markForComparison(entry)
        try await wait{FileManager.default.fileExists(atPath:c.started.path)};owner.close();try Data().write(to:c.release);try await wait{!m.hasPendingWork}
        try require(!m.active && m.comparisonMark==nil,"Closed Browser published a late mark")
    }
    static func submodule(_ c:Context)async throws {
        let source=c.base.appendingPathComponent("child-source");try FileManager.default.createDirectory(at:source,withIntermediateDirectories:true)
        let child=GitRepository(root:source,executable:c.git,askpass:nil,libgit2Configuration:.init(enabled:false))
        _=try await child.run(["init","--template=","-b","main"])
        _=try await child.run(["config","user.name","Child QA"]);_=try await child.run(["config","user.email","child@example.invalid"])
        try Data("child\n".utf8).write(to:source.appendingPathComponent("child.txt"));try await child.stage(["."]);_=try await child.commit(message:"child")
        let childHash=try await child.run(["rev-parse","HEAD"]).text.trimmingCharacters(in:.newlines)
        _=try await c.cli.run(["-c","protocol.file.allow=always","submodule","add",source.path,"module"]);_=try await c.cli.commit(message:"module")
        let moduleCommit=try await c.cli.run(["rev-parse","HEAD"]).text.trimmingCharacters(in:.newlines)
        c.rows=try await c.cli.history(options:HistoryOptions());c.old=moduleCommit
        let owner=c.log(),m=owner.model
        let entry=try unwrap(m.revision,"Submodule Log revision missing")
        m.fileGroups=try await c.cli.logFileGroups(in:entry);m.files=m.fileGroups.flatMap(\.files)
        let file=try unwrap(m.visibleFiles.first{$0.isSubmodule},"Submodule row missing")
        var delivered:[String?]=[];m.onSubmoduleFileLog={_,revision in delivered.append(revision)}
        for enabled in [false,true] {
            c.prefs.set(enabled,forKey:"UseLibgit2");try c.clear();m.showSubmoduleFileLog([file.id]);c.prefs.set(!enabled,forKey:"UseLibgit2")
            try await wait{!m.busy && LogWindowModel.activeFileOpenReads==0}
            try require(delivered.count==(enabled ? 2:1) && delivered.last! == (enabled ? childHash:nil) && m.acceptedNavigationRepository?.libgit2Configuration?.enabled==enabled,"Log submodule master policy or child handoff wrong: \(m.error ?? "none")")
            try require(c.calls().contains("turtlegit-historical-gitlink")==enabled,"Disabled master still attempted pinned submodule hash lookup")
        }
        c.prefs.set(true,forKey:"UseLibgit2")
        let comparison=c.own(RevisionComparisonWindowController(repository:c.repo,access:RepositoryAccessLease(url:c.root),from:.revision(c.head),to:.revision(moduleCommit),preferences:c.prefs,savesGeometry:false))
        let cm=comparison.model;cm.load();try await wait{!cm.busy && cm.snapshot != nil}
        var actual:String?;cm.onSubmoduleLog={_,value in actual=value};cm.logSubmodules(["module"]);c.prefs.set(false,forKey:"UseLibgit2")
        try await wait{!cm.busy && RevisionComparisonWindowModel.activeFileOperations==0}
        try require(actual==childHash && cm.acceptedNavigationRepository?.libgit2Configuration?.enabled==true,"Changed Files did not inherit accepted pinned submodule reader: \(cm.error ?? "none")")
    }
    static func main()async {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let pairs=[(class_getInstanceMethod(NSWindow.self,#selector(NSWindow.constrainFrameRect(_:to:))),class_getInstanceMethod(NSWindow.self,#selector(NSWindow.historicalFrame(_:to:)))),(class_getInstanceMethod(NSWindow.self,#selector(NSWindow.order(_:relativeTo:))),class_getInstanceMethod(NSWindow.self,#selector(NSWindow.historicalOrder(_:relativeTo:))))]
        for(a,b)in pairs{if let a,let b{method_exchangeImplementations(a,b)}};defer{for(a,b)in pairs.reversed(){if let a,let b{method_exchangeImplementations(a,b)}}}
        let c=Context();DialogGeometry.install(preferences:c.prefs);defer{DialogGeometry.install(preferences:.standard)}
        do{try await c.prepare();let mode=CommandLine.arguments[3];switch mode{case "log":try await log(c);case "browser":try await browser(c);case "submodule":try await submodule(c);default:try await HistoricalBisectVerification.verify(base:c.base,git:c.git)};await c.clean();try require(drained() && NSApp.windows.allSatisfy{!$0.isVisible && $0.sheetParent==nil && $0.attachedSheet==nil},"Historical navigation owners survived cleanup");print("PASS: historical navigation "+mode)}catch{await c.clean();fputs("Historical navigation failure: \(error)\n",stderr);exit(1)}
    }
}
