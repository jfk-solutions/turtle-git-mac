// SPDX-License-Identifier: GPL-2.0-or-later
import AppKit
import TurtleGitCore

@MainActor enum RebaseExecutionRecoveryVerification {
    struct Failure:Error,CustomStringConvertible {let description:String}
    static func require(_ value:Bool,_ message:String)throws {if !value {throw Failure(description:message)}}
    static func wait(line:Int = #line,_ ready:()->Bool)async throws {
        for _ in 0..<3000 {if ready(){return};try await Task.sleep(nanoseconds:10_000_000)}
        throw Failure(description:"Replay recovery did not settle at \(line)")
    }
    static func views(_ root:NSView)->[NSView] {[root]+root.subviews.flatMap(views)}
    static func requirePromptGeometry(_ window:NSWindow)throws {
        guard let content=window.contentView else{throw Failure(description:"Missing alert content")}
        content.layoutSubtreeIfNeeded()
        let descendants=views(content)
        guard let scroll=descendants.compactMap({$0 as? NSScrollView}).first else{throw Failure(description:"Missing diagnostic scroll pane")}
        let diagnostic=content.convert(scroll.bounds,from:scroll)
        try require(diagnostic.width>=499 && abs(diagnostic.height-140)<1,"Recovery diagnostic pane lost bounded explicit size")
        try require(content.bounds.insetBy(dx:-1,dy:-1).contains(diagnostic),"Recovery diagnostic pane escaped the actual sheet")
        let controls=descendants.compactMap{$0 as? NSButton}.filter{["Skip","Retry","Cancel","Abort","Do the same for the rest"].contains($0.title)}
        for control in controls {
            let frame=content.convert(control.bounds,from:control)
            try require(content.bounds.insetBy(dx:-1,dy:-1).contains(frame),"Recovery control escaped sheet: "+control.title)
            try require(!frame.intersects(diagnostic),"Recovery control overlaps diagnostic pane: "+control.title)
        }
        try require(window.frame.width<=900 && window.frame.height<=800,"Recovery alert exceeded normal screen bounds")
    }
    static func capture(_ window:NSWindow,name:String)throws {
        try requirePromptGeometry(window)
        guard let path=ProcessInfo.processInfo.environment["TURTLEGIT_REBASE_RECOVERY_CAPTURES"],let view=window.contentView else{return}
        let folder=URL(fileURLWithPath:path);try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
        // Render the actual AppKit controls with the requested drawing appearance.
        // The window stays invisible; its chrome/background lives outside the
        // content view, so composite the native content over its opaque color.
        for (appearance,suffix) in [(NSAppearance.Name.aqua,"light"),(.darkAqua,"dark")] {
            window.appearance=NSAppearance(named:appearance);view.layoutSubtreeIfNeeded()
            guard let bitmap=view.bitmapImageRepForCachingDisplay(in:view.bounds) else{throw Failure(description:"Missing alert bitmap")}
            window.effectiveAppearance.performAsCurrentDrawingAppearance {view.cacheDisplay(in:view.bounds,to:bitmap)}
            guard let opaque=NSBitmapImageRep(bitmapDataPlanes:nil,pixelsWide:bitmap.pixelsWide,pixelsHigh:bitmap.pixelsHigh,bitsPerSample:8,samplesPerPixel:4,hasAlpha:true,isPlanar:false,colorSpaceName:.deviceRGB,bytesPerRow:0,bitsPerPixel:0),let context=NSGraphicsContext(bitmapImageRep:opaque) else {throw Failure(description:"Missing opaque capture surface")}
            opaque.size=view.bounds.size
            NSGraphicsContext.saveGraphicsState();NSGraphicsContext.current=context
            context.cgContext.scaleBy(x:CGFloat(bitmap.pixelsWide)/view.bounds.width,y:CGFloat(bitmap.pixelsHigh)/view.bounds.height)
            window.effectiveAppearance.performAsCurrentDrawingAppearance {
                NSColor.windowBackgroundColor.setFill();NSRect(origin:.zero,size:view.bounds.size).fill()
                let content=NSImage(size:view.bounds.size);content.addRepresentation(bitmap)
                content.draw(in:NSRect(origin:.zero,size:view.bounds.size),from:.zero,operation:.sourceOver,fraction:1)
            }
            NSGraphicsContext.restoreGraphicsState()
            guard let png=opaque.representation(using:.png,properties:[:]) else{throw Failure(description:"Missing alert PNG")}
            try png.write(to:folder.appendingPathComponent(name+"-"+suffix+".png"))
        }
    }
    @MainActor struct Context {
        let repository:GitRepository,owner:RebaseWindowController,preferences:UserDefaults,domain:String
        let original:String,upstream:String
        var model:RebaseWindowModel {owner.model}
    }
    static func setup(_ name:String,count:Int=2,cherryPick:Bool=false)async throws->Context {
        let root=URL(fileURLWithPath:CommandLine.arguments[1]).appendingPathComponent(name)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        let repository=GitRepository(root:root,executable:URL(fileURLWithPath:CommandLine.arguments[2]))
        _=try await repository.run(["init","-b","main"])
        for (key,value) in [("user.name","Replay Recovery QA"),("user.email","qa@example.invalid"),("core.hooksPath","/dev/null"),("commit.gpgsign","false")] {_=try await repository.run(["config",key,value])}
        func commit(_ file:String)async throws {try Data((file+"\n").utf8).write(to:root.appendingPathComponent(file));try await repository.stage([file]);_=try await repository.commit(message:file)}
        try await commit("base");let base=try await repository.rebaseCommit("HEAD")
        _=try await repository.run(["switch","-c","upstream"]);try await commit("upstream");let upstream=try await repository.rebaseCommit("HEAD")
        _=try await repository.run(["switch","-c","topic",base.hash]);var picks:[String]=[]
        for number in 1...count {try await commit("topic-\(number)");picks.append(try await repository.rebaseCommit("HEAD").hash)}
        let original=try await repository.rebaseCommit("HEAD").hash
        if cherryPick {_=try await repository.run(["switch","upstream"])}
        let domain="TurtleGit.ReplayRecovery.QA."+UUID().uuidString,preferences=UserDefaults(suiteName:domain)!
        preferences.set(false,forKey:"EnableLogCache");preferences.set(false,forKey:"EnableGravatar")
        let owner=RebaseWindowController(repository:repository,access:nil,preferences:preferences),model=owner.model
        owner.window?.alphaValue=0;owner.window?.setFrameOrigin(NSPoint(x:-12000,y:-12000));owner.window?.orderFront(nil)
        model.editorExecutable=URL(fileURLWithPath:CommandLine.arguments[3])
        model.load(upstream:cherryPick ? nil:"refs/heads/upstream",cherryPick:cherryPick ? picks:nil)
        do {
            try await wait {!model.busy && !model.loadingPlan && model.canStart && RebaseWindowModel.activePreparationReads==0}
            _=try await repository.run(["config","commit.gpgsign","true"])
            _=try await repository.run(["config","gpg.program","/usr/bin/false"])
            return Context(repository:repository,owner:owner,preferences:preferences,domain:domain,original:cherryPick ? upstream.hash:original,upstream:upstream.hash)
        } catch {
            owner.close();preferences.removePersistentDomain(forName:domain)
            try await wait {RebaseWindowModel.activePreparationReads==0 && RebaseWindowModel.activeColumnReads==0}
            throw error
        }
    }
    static func cleanup(_ context:Context)async throws {
        defer {context.preferences.removePersistentDomain(forName:context.domain)}
        context.owner.close()
        _=try? await context.repository.run(["config","commit.gpgsign","false"])
        try? FileManager.default.removeItem(at:context.repository.root.appendingPathComponent(".git/index.lock"))
        try await wait {RebaseWindowModel.activeReplayOperations==0 && RebaseWindowModel.activePreparationReads==0 && RebaseWindowModel.activeColumnReads==0}
        if try await context.repository.rebaseState().active {_=try await context.repository.abortRebase()}
    }
    static func promptCancel()async throws {
        let context=try await setup("prompt-cancel"),model=context.model
        do {
            model.execute("start")
            try await wait {model.hasReplayQuestion && context.owner.window?.attachedSheet != nil}
            let sheet=context.owner.window!.attachedSheet!,buttons=views(sheet.contentView!).compactMap{$0 as? NSButton}
            for title in ["Skip","Retry","Cancel","Do the same for the rest"] {try require(buttons.contains{$0.title==title},"Missing source failed-Pick control: "+title)}
            try require(buttons.first{$0.title=="Skip"}?.image != nil && buttons.first{$0.title=="Retry"}?.image != nil,"Failed-Pick source artwork missing")
            try require(sheet.defaultButtonCell === buttons.first{$0.title=="Skip"}?.cell,"Source Skip default changed")
            try require(RebaseWindowModel.activeReplayOperations>0 && TurtleGitApplicationDelegate().applicationShouldTerminate(NSApp) == .terminateCancel,"Failed-Pick question lost replay/Quit ownership")
            try capture(sheet,name:"rebase-failed-pick")
            buttons.first{$0.title=="Do the same for the rest"}?.state = .on
            NSApp.endSheet(sheet,returnCode:NSApplication.ModalResponse.alertThirdButtonReturn.rawValue)
            try await wait {!model.busy && RebaseWindowModel.activeReplayOperations==0}
            try require(model.active && model.failedPickRecoveryCancelled && !model.automaticallySkipFailedPicks && model.error==nil,"Cancel with rest checked skipped or reopened a generic error")
            let current=try await context.repository.rebaseCommit("HEAD")
            try require(current.hash==context.upstream,"Cancel changed the failed occurrence's HEAD")
        } catch {try await cleanup(context);throw error};try await cleanup(context)
    }
    static func retry(cherryPick:Bool)async throws {
        let context=try await setup(cherryPick ? "cherry-retry":"rebase-retry",cherryPick:cherryPick),model=context.model
        do {
            var questions=0,failure:Error?
            model.chooseFailedPickRecovery={_ in questions += 1;do {_=try await context.repository.run(["config","commit.gpgsign","false"]);return .retry}catch {failure=error;return .cancel}}
            model.execute("start");try await wait {!model.busy && RebaseWindowModel.activeReplayOperations==0}
            if let failure {throw failure}
            try require(questions==1 && model.finished && !model.active && model.error==nil,"Same-occurrence Retry did not finish exactly once: "+(model.error ?? "none"))
            let log=try await context.repository.run(["log","--format=%s",context.upstream+"..HEAD"])
            try require(log.text.split(separator:"\n").count==2,"Retry duplicated or dropped a replay occurrence")
        } catch {try await cleanup(context);throw error};try await cleanup(context)
    }
    static func skipRest()async throws {
        let context=try await setup("skip-rest",count:3),model=context.model
        do {
            var questions=0;model.chooseFailedPickRecovery={_ in questions += 1;return .skip(remember:true)}
            model.execute("start");try await wait {!model.busy && RebaseWindowModel.activeReplayOperations==0}
            try require(questions==1 && model.finished && !model.active && model.error==nil,"Remembered Skip did not handle subsequent failed Picks: "+(model.error ?? "none"))
            try require(model.replayRows.count==3 && model.replayRows.allSatisfy{$0.action == .skip && $0.progress == .completed},"Earlier skipped occurrences lost Skip action/progress during later failure refresh")
            let head=try await context.repository.rebaseCommit("HEAD")
            try require(head.hash==context.upstream && !model.automaticallySkipFailedPicks,"Skip-rest changed wrong commits or escaped completed replay")
            try require((1...3).allSatisfy{!FileManager.default.fileExists(atPath:context.repository.root.appendingPathComponent("topic-\($0)").path)},"Skipped changes remained in working tree")
        } catch {try await cleanup(context);throw error};try await cleanup(context)
    }
    static func cleanupRetry()async throws {
        let context=try await setup("cleanup-retry",count:2),model=context.model
        do {
            var setupFailure:Error?,questions=0
            model.chooseFailedPickRecovery={_ in questions += 1;do {try Data("held by replay QA\n".utf8).write(to:context.repository.root.appendingPathComponent(".git/index.lock"));return .skip(remember:true)}catch {setupFailure=error;return .cancel}}
            model.execute("start");try await wait {context.owner.window?.attachedSheet != nil || !model.busy}
            if let setupFailure {throw setupFailure}
            guard let sheet=context.owner.window?.attachedSheet else{throw Failure(description:"Failed Skip did not offer cleanup Retry/Abort: "+(model.error ?? "none"))}
            let buttons=views(sheet.contentView!).compactMap{$0 as? NSButton}
            try require(buttons.contains{$0.title=="Retry"} && buttons.contains{$0.title=="Abort"},"Source cleanup choices missing")
            try require(sheet.defaultButtonCell === buttons.first{$0.title=="Retry"}?.cell,"Source cleanup Retry default changed")
            let text=(views(sheet.contentView!).compactMap{$0 as? NSTextField}.map(\.stringValue)+views(sheet.contentView!).compactMap{$0 as? NSTextView}.map(\.string)).joined(separator:"\n")
            try require(text.contains("index.lock") && text.contains("git"),"Cleanup question lost exact command/diagnostic")
            try capture(sheet,name:"rebase-cleanup-retry")
            try FileManager.default.removeItem(at:context.repository.root.appendingPathComponent(".git/index.lock"))
            NSApp.endSheet(sheet,returnCode:NSApplication.ModalResponse.alertFirstButtonReturn.rawValue)
            try await wait {!model.busy && RebaseWindowModel.activeReplayOperations==0}
            try require(questions==1 && model.finished && !model.active && model.error==nil,"Cleanup Retry discarded remembered Skip, replayed or stranded the skipped item: "+(model.error ?? "none"))
            try require(try await context.repository.rebaseCommit("HEAD").hash==context.upstream,"Cleanup Retry picked the occurrence it should skip")
        } catch {try await cleanup(context);throw error};try await cleanup(context)
    }
    static func cleanupAbortReopen()async throws {
        for rollBack in [false,true] {
            let context=try await setup(rollBack ? "cleanup-abort-rollback":"cleanup-abort-continue",count:1),model=context.model
            var reopened:RebaseWindowController?
            do {
                var failure:Error?
                model.chooseFailedPickRecovery={_ in do {try Data("held by replay QA\n".utf8).write(to:context.repository.root.appendingPathComponent(".git/index.lock"));return .skip(remember:false)}catch {failure=error;return .cancel}}
                model.chooseFailedPickCleanup={_ in false}
                model.execute("start");try await wait {!model.busy && RebaseWindowModel.activeReplayOperations==0}
                if let failure {throw failure}
                try require(model.active && model.failedPickRecoveryCancelled && model.state?.hasFailedPickCleanup==true,"Cleanup Abort lost durable approved Skip")
                let head=try await context.repository.rebaseCommit("HEAD")
                try require(head.hash==context.upstream,"Cleanup Abort silently rolled back the replay")
                context.owner.close();try FileManager.default.removeItem(at:context.repository.root.appendingPathComponent(".git/index.lock"))
                let next=RebaseWindowController(repository:context.repository,access:nil,preferences:context.preferences);reopened=next
                next.window?.alphaValue=0;next.window?.setFrameOrigin(NSPoint(x:-12000,y:-12000));next.window?.orderFront(nil)
                next.model.editorExecutable=URL(fileURLWithPath:CommandLine.arguments[3]);next.model.load()
                try await wait {!next.model.busy && next.model.active && RebaseWindowModel.activePreparationReads==0}
                try require(next.model.state?.hasFailedPickCleanup==true && !next.model.fileRecovery,"Reopen offered Commit instead of approved Skip cleanup")
                next.model.execute(rollBack ? "abort":"continue")
                try await wait {!next.model.busy && RebaseWindowModel.activeReplayOperations==0}
                let after=try await context.repository.rebaseCommit("HEAD")
                try require(!next.model.active && next.model.error==nil && after.hash==(rollBack ? context.original:context.upstream),"Reopened Continue/main Abort lost recovery intent: "+(next.model.error ?? "none"))
                next.close();reopened=nil
            } catch {reopened?.close();try await cleanup(context);throw error};try await cleanup(context)
        }
    }
    static func changedAndRetired()async throws {
        for retired in [false,true] {
            let context=try await setup(retired ? "retired":"changed"),model=context.model
            do {
                var held:CheckedContinuation<RebaseWindowModel.FailedPickDecision,Never>?
                defer {held?.resume(returning:.cancel);held=nil}
                model.chooseFailedPickRecovery={_ in await withCheckedContinuation{held=$0}}
                model.execute("start");try await wait {held != nil}
                let before=try await context.repository.rebaseCommit("HEAD"),index=try Data(contentsOf:context.repository.root.appendingPathComponent(".git/index"))
                if retired {context.owner.close()}else{try Data("external change\n".utf8).write(to:context.repository.root.appendingPathComponent("base"))}
                held?.resume(returning:retired ? .skip(remember:true):.retry);held=nil
                try await wait {!model.busy && RebaseWindowModel.activeReplayOperations==0}
                let head=try await context.repository.rebaseCommit("HEAD"),after=try Data(contentsOf:context.repository.root.appendingPathComponent(".git/index"))
                try require(head.hash==before.hash && after==index,"Changed/retired answer mutated failed replay")
                try require(retired ? model.retired:model.error != nil,"Changed/retired reply was not fenced")
            } catch {try await cleanup(context);throw error};try await cleanup(context)
        }
    }
    static func main()async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        if ProcessInfo.processInfo.environment["TURTLEGIT_REBASE_RECOVERY_CAPTURES_ONLY"]=="1" {
            try await promptCancel();try await cleanupRetry()
            print("PASS: Rebase recovery capture acceptance")
            return
        }
        try await promptCancel();try await retry(cherryPick:false);try await retry(cherryPick:true)
        try await skipRest();try await cleanupRetry();try await cleanupAbortReopen();try await changedAndRetired()
        try require(RebaseWindowModel.activeReplayOperations==0,"Replay receiver leaked owned work")
        print("PASS: Rebase execution recovery — real signing failure, source native choices/defaults/icons, Cancel/rest safety, same-item Rebase/Cherry Pick Retry, sticky Skip, cleanup Retry/rest retention, cleanup Abort/reopen/Continue/main rollback, changed/retired answer fences and owned worker drain")
    }
}
