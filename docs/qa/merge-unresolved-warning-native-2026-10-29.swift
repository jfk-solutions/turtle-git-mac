// SPDX-License-Identifier: GPL-2.0-or-later
import AppKit
import ObjectiveC
import Darwin
import TurtleGitCore

private extension NSWindow {
    @objc func unresolvedOrder(_ mode:NSWindow.OrderingMode,relativeTo number:Int){alphaValue=0;setFrameOrigin(.init(x:-24000,y:-24000));unresolvedOrder(mode,relativeTo:number)}
    @objc func unresolvedBeginSheet(_ sheet:NSWindow,completionHandler:((NSApplication.ModalResponse)->Void)?){sheet.alphaValue=0;sheet.setFrameOrigin(.init(x:-24000,y:-24000));unresolvedBeginSheet(sheet,completionHandler:completionHandler)}
}
@MainActor @main enum MergeUnresolvedWarningVerification {
    struct Failure:Error,CustomStringConvertible{let description:String}
    static func require(_ value:Bool,_ message:String)throws{if !value{throw Failure(description:message)}}
    static func wait(_ message:String,_ ready:()->Bool)async throws{for _ in 0..<2500{if ready(){return};try await Task.sleep(nanoseconds:10_000_000)};throw Failure(description:"Unresolved warning timeout: "+message)}
    static func views(_ view:NSView?)->[NSView]{guard let view else{return[]};return[view]+view.subviews.flatMap{views($0)}}
    static func items(_ menu:NSMenu)->[NSMenuItem]{menu.items.flatMap{[$0]+($0.submenu.map(items) ?? [])}}
    static func quote(_ value:String)->String{"'"+value.replacingOccurrences(of:"'",with:"'\\''")+"'"}
    @MainActor final class Case {
        let root:URL,repo:GitRepository,real:GitRepository,path:String,owner:TextConflictWindowController,prefs:UserDefaults,suite:String,index:Data,working:Data,head:String,menu:NSMenu
        var model:TextConflictWindowModel{owner.model}
        var file:URL{root.appendingPathComponent(path)}
        init(root:URL,repo:GitRepository,real:GitRepository,path:String,owner:TextConflictWindowController,prefs:UserDefaults,suite:String,index:Data,working:Data,head:String,menu:NSMenu){self.root=root;self.repo=repo;self.real=real;self.path=path;self.owner=owner;self.prefs=prefs;self.suite=suite;self.index=index;self.working=working;self.head=head;self.menu=menu}
        func clearDiagnostic()async throws{model.error=nil;try await wait("owned diagnostic release"){owner.window?.attachedSheet==nil}}
        func close()async throws{if let window=owner.window,let sheet=window.attachedSheet{window.endSheet(sheet,returnCode:.cancel);sheet.orderOut(nil);sheet.close()};owner.close();try await wait("owned warning/save readers drain"){!model.mergeToolHasPendingWork && MergeRegexOperations.activeRequests==0};prefs.removePersistentDomain(forName:suite)}
    }
    static func make(_ root:URL,git:URL,wrapped:Bool=false)async throws->Case {
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        let real=GitRepository(root:root,executable:git,libgit2Configuration:.init(enabled:false)),path="-conflict 雪\t[*].txt",file=root.appendingPathComponent(path)
        _=try await real.run(["init","--template=","-b","main"])
        for(key,value)in[("user.name","Unresolved warning QA"),("user.email","warning@example.invalid"),("commit.gpgsign","false"),("core.hooksPath","/dev/null")]{_=try await real.run(["config",key,value])}
        try Data("head\nbase\ntail\n".utf8).write(to:file);try await real.stage([path]);_=try await real.commit(message:"base")
        _=try await real.run(["switch","-c","side"]);try Data("head\ntheirs\ntail\n".utf8).write(to:file);try await real.stage([path]);_=try await real.commit(message:"side")
        _=try await real.run(["switch","main"]);try Data("head\nmine\ntail\n".utf8).write(to:file);try await real.stage([path]);_=try await real.commit(message:"main")
        let merged=try await real.run(["merge","--no-edit","side"],successfulExitCodes:0...1);try require(merged.exitCode==1,"Real repository conflict setup failed")
        let helper=root.appendingPathComponent("stage-wrapper")
        if wrapped {
            guard mkfifo(helper.path+".fifo",mode_t(0o600))==0 else{throw Failure(description:"Private stage FIFO unavailable")}
            let script="""
            #!/bin/sh
            task_add=false
            for task_arg in "$@"; do if [ "$task_arg" = add ]; then task_add=true; fi; done
            if [ "$task_add" = true ] && [ -f "$0.mode" ]; then
              printf '%s\\0' "$@" > "$0.arguments"
              printf '%s\\n' "$$" > "$0.entered"
              IFS= read -r task_mode < "$0.mode"
              if [ "$task_mode" = fail ]; then printf '%s\\n' 'Controlled conflict Add failure' >&2; exit 17; fi
              if [ "$task_mode" = hold ]; then IFS= read -r task_release < "$0.fifo"; fi
            fi
            exec \(quote(git.path)) "$@"
            """
            try script.write(to:helper,atomically:true,encoding:.utf8);try FileManager.default.setAttributes([.posixPermissions:0o755],ofItemAtPath:helper.path)
        }
        let repo=GitRepository(root:root,executable:wrapped ? helper:git,libgit2Configuration:.init(enabled:false))
        let suite="TurtleGit.UnresolvedWarning."+UUID().uuidString,prefs=UserDefaults(suiteName:suite)!
        prefs.set(false,forKey:"TurtleGitMerge.Backup");prefs.set(false,forKey:"UseLibgit2");prefs.set(false,forKey:"TurtleGit.Comparison.CurvedInterface")
        let owner=TextConflictWindowController(repository:repo,access:RepositoryAccessLease(url:root),path:path,preferences:prefs,deferInitialLoad:true)
        owner.model.commentProfileURL=root.appendingPathComponent("private-comments.txt");owner.model.regexDefaults=prefs
        do {
            owner.showWindow(nil);owner.model.beginTransferredDocument()
            try await wait("actual conflicted native result ready"){!owner.model.busy && owner.model.document != nil && owner.model.nativeEditorReady}
            try require(owner.model.error==nil && owner.model.hasUnresolvedConflicts && !owner.model.blocks.isEmpty,"Actual unresolved native conflict missing")
            let menu=NSMenu(title:"Private unresolved commands")
            for title in ["Fixture","File","Edit"]{let root=NSMenuItem(title:title,action:nil,keyEquivalent:"");root.submenu=NSMenu(title:title);menu.addItem(root)}
            NSApp.mainMenu=menu
            guard let router=owner.editorCommandMenu else{throw Failure(description:"Actual native editor command router missing")}
            router.keyWindow={ [weak owner] in owner?.window};router.install(in:menu)
            return Case(root:root,repo:repo,real:real,path:path,owner:owner,prefs:prefs,suite:suite,index:try Data(contentsOf:root.appendingPathComponent(".git/index")),working:try Data(contentsOf:file),head:try await real.rebaseCommit("HEAD").hash,menu:menu)
        }catch{owner.close();try? await wait("failed initial warning owner drain"){!owner.model.mergeToolHasPendingWork};prefs.removePersistentDomain(forName:suite);throw error}
    }
    static func requestMenuMark(_ c:Case)async throws {
        try await wait("Mark as resolved native menu enabled despite unresolved result"){
            c.owner.editorCommandMenu?.install(in:c.menu);return items(c.menu).first{$0.title=="Mark as resolved"}?.isEnabled==true
        }
        guard let item=items(c.menu).first(where:{$0.title=="Mark as resolved"}),let action=item.action else{throw Failure(description:"Actual Mark as resolved native action missing")}
        try require(NSApp.sendAction(action,to:item.target,from:item),"Native Mark as resolved dispatch refused")
    }
    static func warning(_ c:Case)async throws->NSWindow {
        try await wait("actual unresolved warning sheet"){c.owner.window?.attachedSheet != nil}
        guard let sheet=c.owner.window?.attachedSheet else{throw Failure(description:"Warning sheet lost owner")}
        let buttons=views(sheet.contentView).compactMap{$0 as? NSButton}
        try require(Set(buttons.map(\.title)).isSuperset(of:["Save Anyway","Continue Resolving","Cancel"]),"Source warning choices missing")
        let defaultControl=sheet.defaultButtonCell?.controlView as? NSButton
        try require(sheet.defaultButtonCell?.title=="Continue Resolving" && defaultControl?.title=="Continue Resolving" && buttons.contains(where:{$0 === defaultControl}) && buttons.first{$0.title=="Save Anyway"}?.keyEquivalent != "\r" && buttons.first{$0.title=="Cancel"}?.keyEquivalent=="\u{1b}","Continue/Cancel native default and Escape routes incorrect: default=\(sheet.defaultButtonCell?.title ?? "nil") buttons=\(buttons.map{($0.title,$0.keyEquivalent.unicodeScalars.map{Int($0.value)})})")
        try require(c.model.busy && !c.owner.windowShouldClose(c.owner.window!) && TurtleGitApplicationDelegate().applicationShouldTerminate(NSApp) == .terminateCancel,"Actual warning sheet lost Close/Quit ownership")
        return sheet
    }
    static func press(_ title:String,_ sheet:NSWindow)throws {
        guard let button=views(sheet.contentView).compactMap({$0 as? NSButton}).first(where:{$0.title==title && $0.isEnabled})else{throw Failure(description:"Actual native warning button unavailable: "+title)}
        button.performClick(nil)
    }
    static func unchanged(_ c:Case)async throws {
        try require((try Data(contentsOf:c.file))==c.working && (try Data(contentsOf:c.root.appendingPathComponent(".git/index")))==c.index,"Negative/stale warning reply wrote/staged conflict")
        let current=try await c.real.rebaseCommit("HEAD").hash;try require(current==c.head,"Warning action committed history")
    }
    static func realButtons(_ folder:URL,git:URL)async throws {
        let c=try await make(folder,git:git)
        do {
            try await requestMenuMark(c);try press("Cancel",try await warning(c));try await wait("Cancel actual warning complete"){!c.model.busy && c.owner.window?.attachedSheet==nil};try await unchanged(c)
            let editor=views(c.owner.window?.contentView).compactMap{$0 as? NSTextView}.first{$0.isEditable}
            editor?.setSelectedRange(NSRange(location:editor?.string.utf16.count ?? 0,length:0))
            try await requestMenuMark(c)
            let continueSheet=try await warning(c)
            guard let defaultControl=continueSheet.defaultButtonCell?.controlView as? NSButton else{throw Failure(description:"Actual Continue default control unavailable")}
            defaultControl.performClick(nil)
            try await wait("Continue returns actual result focus"){
                !c.model.busy && c.owner.window?.attachedSheet==nil && c.model.selectedConflict==0 && editor != nil && c.owner.window?.firstResponder === editor && (editor?.selectedRange().location ?? Int.max)<(editor?.string.utf16.count ?? 0)
            };try await unchanged(c)
            var saved:Bool?;let expected=try c.model.encoding.encode(c.model.result)
            c.model.save(markResolved:false){saved=$0};try press("Save Anyway",try await warning(c))
            try await wait("ordinary Save Anyway completes without staging"){saved != nil && !c.model.busy && c.owner.window?.attachedSheet==nil}
            try require(saved==true && (try Data(contentsOf:c.file))==expected && (try Data(contentsOf:c.root.appendingPathComponent(".git/index")))==c.index,"Ordinary Save Anyway staged conflict or lost exact markers")
            try await requestMenuMark(c);try press("Save Anyway",try await warning(c))
            try await wait("Mark Resolved Save Anyway actual stage completes"){!c.model.busy && c.owner.window?.isVisible != true && !c.model.mergeToolHasPendingWork}
            let unresolved=try await c.real.run(["ls-files","-u","-z"]).stdout,staged=try await c.real.run(["show",":"+c.path]).stdout
            let head=try await c.real.rebaseCommit("HEAD").hash
            try require(unresolved.isEmpty && staged==expected && head==c.head,"Explicit Mark Resolved approval did not stage exact unresolved result without commit")
            try await c.close()
        }catch{try? await c.close();throw error}
    }
    static func heldReplies(_ folder:URL,git:URL)async throws {
        let c=try await make(folder,git:git)
        var reply:CheckedContinuation<MergeUnresolvedSaveChoice,Never>?,queries=0
        defer{reply?.resume(returning:.cancel)}
        c.model.chooseUnresolvedSave={_ in queries += 1;return await withCheckedContinuation{reply=$0}}
        do {
            var saved:Bool?;c.model.save(markResolved:true){saved=$0};try await wait("typed warning actual held"){reply != nil}
            var duplicate:Bool?;c.model.save(markResolved:true){duplicate=$0}
            try require(queries==1 && duplicate==false && c.model.busy,"Duplicate Mark Resolved bypassed held warning")
            let draft=c.model.result+"changed while warning pending\n";c.model.result=draft
            reply?.resume(returning:.saveAnyway);reply=nil;try await wait("stale edited warning completion"){saved != nil && !c.model.busy}
            try require(saved==false && c.model.result==draft,"Old approval overwrote newer draft")
            try await unchanged(c);try await c.clearDiagnostic()
            c.model.result=String(decoding:c.working,as:UTF8.self);saved=nil;c.model.save(markResolved:true){saved=$0};try await wait("canceled warning held"){reply != nil}
            c.model.cancelSaveOperation();reply?.resume(returning:.saveAnyway);reply=nil;try await wait("canceled warning drains"){saved != nil && !c.model.busy}
            try require(saved==false && queries==2,"Canceled per-attempt approval survived")
            try await unchanged(c);try await c.clearDiagnostic()
            saved=nil;c.model.save(markResolved:true){saved=$0};try await wait("retired warning held"){reply != nil}
            let active=MergeRegexOperations.activeRequests;c.owner.close()
            try require(MergeRegexOperations.activeRequests==active && active>0 && TurtleGitApplicationDelegate().applicationShouldTerminate(NSApp) == .terminateCancel,"Retirement abandoned actual pending warning response")
            reply?.resume(returning:.saveAnyway);reply=nil;try await wait("late retired warning response drains"){saved != nil && MergeRegexOperations.activeRequests==0}
            try require(saved==false && c.model.retired,"Retired approval saved conflict")
            try await unchanged(c);try await c.close()
        }catch{reply?.resume(returning:.cancel);reply=nil;try? await c.close();throw error}
    }
    static func stageRecovery(_ folder:URL,git:URL,cancel:Bool)async throws {
        let c=try await make(folder,git:git,wrapped:true)
        do {
            let helper=c.root.appendingPathComponent("stage-wrapper"),mode=URL(fileURLWithPath:helper.path+".mode"),entered=URL(fileURLWithPath:helper.path+".entered")
            try (cancel ? "hold\n":"fail\n").write(to:mode,atomically:true,encoding:.utf8)
            let expected=try c.model.encoding.encode(c.model.result);try require(MergeText.hasMarkers(String(decoding:expected,as:UTF8.self)),"Stage recovery did not capture actual unresolved markers")
            var saved:Bool?;c.model.save(markResolved:true){saved=$0};try press("Save Anyway",try await warning(c))
            try await wait("actual postwrite Git stage entered"){FileManager.default.fileExists(atPath:entered.path)}
            let pid=Int32(try String(contentsOf:entered).trimmingCharacters(in:.whitespacesAndNewlines))
            if cancel{try require(c.model.busy,"Stage cancellation lost operation ownership");c.model.cancelSaveOperation()}
            try await wait("actual stage failure/cancel drains"){saved != nil && !c.model.busy && !c.model.mergeToolHasPendingWork}
            try require(saved==false && !c.model.dirty && c.owner.window?.isVisible==true && c.model.document?.workingContents==expected,"Stage failure/cancel did not adopt successful save baseline while retaining owner")
            try require((try Data(contentsOf:c.file))==expected && (try Data(contentsOf:c.root.appendingPathComponent(".git/index")))==c.index,"Stage failure/cancel lost saved bytes or changed conflict stages")
            if let pid{try require(kill(pid,0) != 0,"Canceled/failed stage helper survived completion")}
            let arguments=try Data(contentsOf:URL(fileURLWithPath:helper.path+".arguments")).split(separator:0).map{String(decoding:$0,as:UTF8.self)}
            try require(Array(arguments.suffix(4))==["add","-f","--",c.path],"Mark Resolved did not use exact literal selected conflict path")
            try await c.clearDiagnostic()
            let beforeRetry=try FileManager.default.attributesOfItem(atPath:c.file.path)[.systemFileNumber] as? NSNumber
            var questions=0;c.model.chooseUnresolvedSave={_ in questions += 1;return .cancel};saved=nil
            c.model.save(markResolved:true){saved=$0};try await wait("fresh retry warning refuses default consent"){saved != nil && !c.model.busy}
            try require(questions==1 && saved==false && (try FileManager.default.attributesOfItem(atPath:c.file.path)[.systemFileNumber] as? NSNumber)==beforeRetry && (try Data(contentsOf:c.root.appendingPathComponent(".git/index")))==c.index,"Prior Save Anyway approval leaked into new retry attempt")
            c.model.chooseUnresolvedSave=nil;try await c.clearDiagnostic();try "pass\n".write(to:mode,atomically:true,encoding:.utf8)
            try await requestMenuMark(c);try press("Save Anyway",try await warning(c))
            try await wait("fresh approved literal stage retry completes"){!c.model.busy && c.owner.window?.isVisible != true && !c.model.mergeToolHasPendingWork}
            let stages=try await c.real.run(["ls-files","-u","-z"]).stdout,staged=try await c.real.run(["show",":"+c.path]).stdout,head=try await c.real.rebaseCommit("HEAD").hash
            try require(stages.isEmpty && staged==expected && head==c.head,"Fresh explicit approval did not stage saved unresolved bytes exactly")
            try await c.close()
        }catch{try? await c.close();throw error}
    }
    static func main()async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let oldMenu=NSApp.mainMenu
        let order=class_getInstanceMethod(NSWindow.self,#selector(NSWindow.order(_:relativeTo:)))!,hidden=class_getInstanceMethod(NSWindow.self,#selector(NSWindow.unresolvedOrder(_:relativeTo:)))!
        let begin=class_getInstanceMethod(NSWindow.self,#selector(NSWindow.beginSheet(_:completionHandler:)))!,hiddenBegin=class_getInstanceMethod(NSWindow.self,#selector(NSWindow.unresolvedBeginSheet(_:completionHandler:)))!
        method_exchangeImplementations(order,hidden);method_exchangeImplementations(begin,hiddenBegin)
        defer{method_exchangeImplementations(order,hidden);method_exchangeImplementations(begin,hiddenBegin);NSApp.mainMenu=oldMenu}
        let folder=URL(fileURLWithPath:CommandLine.arguments[1]),git=URL(fileURLWithPath:CommandLine.arguments[2])
        try await realButtons(folder.appendingPathComponent("native-buttons"),git:git)
        try await heldReplies(folder.appendingPathComponent("held-replies"),git:git)
        try await stageRecovery(folder.appendingPathComponent("stage-failure"),git:git,cancel:false)
        try await stageRecovery(folder.appendingPathComponent("stage-cancellation"),git:git,cancel:true)
        print("PASS: repository unresolved warning native menus/buttons, Continue/Cancel/Save Anyway, captured attempts and real stage failure/cancel/fresh retry ownership")
    }
}
