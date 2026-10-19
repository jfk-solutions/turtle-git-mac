// SPDX-License-Identifier: GPL-2.0-or-later
import AppKit
import QuartzCore
import TurtleGitCore

private actor RemoteExportGate{
    private(set) var waiting=false
    private var continuation:CheckedContinuation<Void,Never>?
    func pause()async{waiting=true;await withCheckedContinuation{continuation=$0}}
    func release(){continuation?.resume();continuation=nil}
}
@main struct GitLibGit2NativeVerification{
    struct Failure:Error{let message:String}
    static func require(_ value:Bool,_ message:String)throws{if !value{throw Failure(message:message)}}
    @MainActor static func wait(_ message:String,_ ready:()->Bool)async throws{for _ in 0..<3000{if ready(){return};try await Task.sleep(nanoseconds:10_000_000)};throw Failure(message:"Timeout: "+message)}
    @MainActor static func capture(_ controller:NSWindowController,name:String)async throws{
        guard let directory=ProcessInfo.processInfo.environment["TURTLEGIT_LIBGIT2_CAPTURE"],let window=controller.window,let content=window.contentView else{return}
        let folder=URL(fileURLWithPath:directory);try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
        let original=window.appearance;defer{window.appearance=original}
        func invalidate(_ view:NSView){view.needsLayout=true;view.needsDisplay=true;view.layer?.setNeedsDisplay();view.subviews.forEach(invalidate)}
        for (nameOfAppearance,suffix) in [(NSAppearance.Name.aqua,"light"),(.darkAqua,"dark")]{
            guard let appearance=NSAppearance(named:nameOfAppearance) else{continue}
            window.appearance=appearance;invalidate(content)
            // Let actual AppKit controls replace appearance-dependent cached
            // layers before caching their native drawing offscreen.
            await Task.yield();try await Task.sleep(nanoseconds:120_000_000)
            invalidate(content);content.layoutSubtreeIfNeeded();content.displayIfNeeded();CATransaction.flush();await Task.yield()
            guard let bitmap=content.bitmapImageRepForCachingDisplay(in:content.bounds) else{print("Optional native content capture unavailable: \(name)-\(suffix)");continue}
            var opaque:CGImage?
            appearance.performAsCurrentDrawingAppearance{
                content.cacheDisplay(in:content.bounds,to:bitmap)
                guard let source=bitmap.cgImage,let space=CGColorSpace(name:CGColorSpace.sRGB),let context=CGContext(data:nil,width:source.width,height:source.height,bitsPerComponent:8,bytesPerRow:source.width*4,space:space,bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue) else{return}
                let background=NSColor.windowBackgroundColor.usingColorSpace(.sRGB) ?? .windowBackgroundColor
                context.setFillColor(background.cgColor);context.fill(CGRect(x:0,y:0,width:source.width,height:source.height))
                context.interpolationQuality = .none;context.draw(source,in:CGRect(x:0,y:0,width:source.width,height:source.height));opaque=context.makeImage()
            }
            guard let opaque,let png=NSBitmapImageRep(cgImage:opaque).representation(using:.png,properties:[:]) else{print("Optional native content encoding unavailable: \(name)-\(suffix)");continue}
            try png.write(to:folder.appendingPathComponent(name+"-"+suffix+".png"))
        }
    }
    @MainActor static func main()async throws{
        let root=URL(fileURLWithPath:CommandLine.arguments[1]),git=URL(fileURLWithPath:CommandLine.arguments[2]),helper=URL(fileURLWithPath:CommandLine.arguments[3])
        try await backend(root:root,git:git,helper:helper)
        try await prompts(root:root)
        try await wait("Owned libgit2 native work survived"){CloneProgressWindowModel.activeOperations==0 && FetchProgressWindowModel.activeOperations==0 && NSApp.windows.allSatisfy{!$0.isVisible && $0.attachedSheet==nil && $0.sheetParent==nil}}
        print("PASS libgit2 native family: private backend snapshots/default CLI/actual local clone+fetch; isolated combined Git credentials; source certificate default Cancel, fingerprints, read-only native inspector, held accepted export then parent cancellation/reject and actual drain. No public remote, Keychain or system trust changes.")
    }
    @MainActor static func backend(root:URL,git:URL,helper:URL)async throws{
        let suite="TurtleGit.Libgit2.Native."+UUID().uuidString,prefs=UserDefaults(suiteName:suite)!
        defer{prefs.removePersistentDomain(forName:suite)}
        let source=root.appendingPathComponent("source"),repository=GitRepository(root:source,executable:git)
        try FileManager.default.createDirectory(at:source,withIntermediateDirectories:true)
        _=try await repository.run(["init","-b","main"])
        for (key,value) in [("user.name","Native Git fixture"),("user.email","native@example.invalid"),("commit.gpgsign","false"),("core.hooksPath","/dev/null")]{_=try await repository.run(["config",key,value])}
        try Data("first\n".utf8).write(to:source.appendingPathComponent("file"));try await repository.stage(["file"]);_=try await repository.commit(message:"first")
        let defaults=GitLibGit2Configuration.load(from:prefs,helperURL:helper)
        try require(defaults.enabled && defaults.mask==GitLibGit2Configuration.defaultMask && !defaults.requests(.clone) && !defaults.requests(.fetch),"Source default backend mask changed")
        let grant=RepositoryAccessLease(url:root)
        var options=CloneOptions();options.source=source.path
        let cli=CloneProgressWindowModel(options:options,destination:root.appendingPathComponent("cli"),executable:git,destinationAccess:grant,sourceAccess:nil,keyAccess:nil,preferences:prefs)
        try require(!cli.backend.requests(.clone),"Native Clone ignores private source-default backend")
        prefs.set(true,forKey:"UseLibgit2");prefs.set(6,forKey:"UseLibgit2_mask")
        let selected=GitLibGit2Configuration.load(from:prefs,helperURL:helper)
        let native=CloneProgressWindowModel(options:options,destination:root.appendingPathComponent("native"),executable:git,destinationAccess:grant,sourceAccess:nil,keyAccess:nil,preferences:prefs,backend:selected)
        prefs.set(false,forKey:"UseLibgit2");prefs.set(0,forKey:"UseLibgit2_mask")
        try require(native.backend.requests(.clone) && native.backend.requests(.fetch),"New preferences replaced accepted native backend")
        await cli.run();await native.run()
        try require(cli.success && native.success && !cli.hasPendingWork && !native.hasPendingWork,"Actual native CLI/libgit2 clone failed")
        let cloned=GitRepository(root:root.appendingPathComponent("native"),executable:git)
        try Data("second\n".utf8).write(to:source.appendingPathComponent("file"));try await repository.stage(["file"]);_=try await repository.commit(message:"second")
        let tip=try await repository.run(["rev-parse","HEAD"]).stdout
        var fetch=FetchOptions();fetch.remote="origin"
        let progress=FetchProgressWindowModel(repository:cloned,access:grant,options:fetch,preferences:prefs,backend:selected)
        try require(progress.backend.requests(.fetch),"Fetch lost accepted backend snapshot")
        await progress.run();try require(progress.success,"Actual native selected libgit2 fetch failed")
        let fetched=try await cloned.run(["rev-parse","refs/remotes/origin/main"]).stdout
        try require(fetched==tip,"Native Fetch did not update actual tracking ref")
        cli.invalidate();native.invalidate();progress.invalidate()
    }
    @MainActor static func prompts(root:URL)async throws{
        let credentials=GitSVNAuthenticationPrompt(kind:.credentials,realm:"https://localhost/private.git",username:"fixture-user",maySave:false)
        let encoded=try GitRemoteAuthenticationPrompt.encoded(credentials)
        try require(try GitRemoteAuthenticationPrompt.decode(encoded,enabled:false)==nil,"Git remote native gate ignored")
        try require(try GitSVNAuthenticationPrompt.decode(encoded,enabled:true)==nil,"Remote protocol leaked into SVN gate")
        try require(try GitRemoteAuthenticationPrompt.decode(encoded,enabled:true)==credentials,"Remote combined schema changed")
        var replies:[GitSVNAuthenticationResponse?]=[]
        let owner=GitSVNPromptWindowController(prompt:credentials,icon:MenuIcon.turtle.image(size:32),transportName:"Git"){replies.append($0)}
        owner.window!.alphaValue=0;owner.showWindow(nil)
        defer{owner.close()}
        try require(owner.window!.title=="Git Authentication" && owner.username.stringValue=="fixture-user" && owner.save.superview==nil,"Git combined prompt/title/no-persistence adaptation missing")
        owner.password.stringValue="fixture-password";try await capture(owner,name:"git-transport-credentials");owner.submit();owner.submit()
        try await wait("Combined credentials did not close/answer once"){replies.count==1 && owner.window?.isVisible==false}
        try require(replies[0]?.username=="fixture-user" && replies[0]?.password=="fixture-password" && replies[0]?.save==false && owner.password.stringValue.isEmpty,"Combined response/secret clearing failed")
        let der=try Data(contentsOf:URL(fileURLWithPath:ProcessInfo.processInfo.environment["TURTLEGIT_CERTIFICATE_FIXTURE"]!)),details=try GitCertificateDetails(base64DER:der.base64EncodedString())
        let trust=GitSVNAuthenticationPrompt(kind:.trust,realm:"Private fixture issuer is not trusted.",maySave:false,failures:8,hostname:"localhost",issuer:"Private fixture issuer",fingerprint:details.sha256,certificate:der.base64EncodedString())
        let board=NSPasteboard(name:.init("TurtleGit.Libgit2.Certificate."+UUID().uuidString));defer{board.releaseGlobally()}
        var trustReplies:[GitSVNAuthenticationResponse?]=[]
        let review=GitSVNPromptWindowController(prompt:trust,icon:MenuIcon.originalImage(resource:"certcheck",size:32),transportName:"Git"){trustReplies.append($0)}
        review.makeCertificateViewer={GitCertificateDetailsWindowController(details:$0,pasteboard:board,images:{MenuIcon.originalImage(resource:$0)})}
        review.window!.alphaValue=0;review.window!.appearance=NSAppearance(named:.darkAqua);review.showWindow(nil);defer{review.close()}
        try require(review.remoteCancelButton != nil && review.remoteCancelButton!.cell as? NSButtonCell === review.window!.defaultButtonCell && review.remoteAcceptButton?.title=="Accept certificate" && review.sha1.stringValue==details.sha1,"Source-shaped Git certificate controls/fingerprints missing")
        try await capture(review,name:"git-transport-certificate")
        review.remoteOpenButton!.performClick(nil)
        try await wait("Actual certificate inspector was not attached"){review.certificateViewer?.window?.sheetParent===review.window}
        let inspector=review.certificateViewer!;inspector.copyButton.performClick(nil)
        try require(board.string(forType:.string)==details.fingerprints && (inspector.certificateView.value(forKey:"editable") as? Bool)==false && (inspector.certificateView.value(forKey:"trustDisplayed") as? Bool)==false,"Inspector changed trust or copied different bytes")
        let target=root.appendingPathComponent("certificate.pem"),gate=RemoteExportGate()
        var answer:((NSApplication.ModalResponse)->Void)?
        inspector.format.selectItem(at:1);inspector.exportDestination={_ in target}
        inspector.presentExport={panel,parent,reply in answer=reply;panel.alphaValue=0;parent.beginSheet(panel,completionHandler:nil)}
        inspector.writeExport={bytes,url in await gate.pause();try bytes.write(to:url,options:.atomic)}
        inspector.exportButton.performClick(nil);try await wait("Native export sheet missing"){answer != nil && inspector.window!.attachedSheet != nil}
        answer?(.OK);answer?(.OK)
        for _ in 0..<3000{if await gate.waiting{break};try await Task.sleep(nanoseconds:10_000_000)}
        try require(inspector.exporting,"Accepted export worker was not retained")
        review.abort();review.trustTemporary();try require(trustReplies.isEmpty,"Parent cancellation replied before accepted export drain")
        await gate.release();try await wait("Git cancelled certificate reply did not drain once"){trustReplies.count==1 && review.window!.attachedSheet==nil && inspector.window!.sheetParent==nil && !inspector.exporting}
        try require(trustReplies[0]?.decision == .reject && trustReplies[0]?.save==false && (try Data(contentsOf:target))==details.encoded(as:.pem),"Cancelled Git review accepted certificate or lost owned export")
        let cancel=GitSVNPromptWindowController(prompt:trust,icon:MenuIcon.originalImage(resource:"certcheck",size:32),transportName:"Git"){trustReplies.append($0)};cancel.window!.alphaValue=0;cancel.showWindow(nil);cancel.remoteCancelButton!.performClick(nil)
        try await wait("Actual default Cancel did not reject"){trustReplies.count==2 && !cancel.window!.isVisible};cancel.close()
    }
}
