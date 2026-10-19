// SPDX-License-Identifier: GPL-2.0-or-later
import AppKit
import Security
import SecurityInterface
import QuartzCore
@testable import TurtleGitCore

@MainActor enum SMTPCertificateFixture {
    static func require(_ value:Bool,_ message:String)throws{if !value{throw NSError(domain:message,code:1)}}
    static func wait(line:UInt = #line,_ ready:()->Bool)async throws{for _ in 0..<2500{if ready(){return};try await Task.sleep(nanoseconds:10_000_000)};throw NSError(domain:"SMTP certificate wait at \(line)",code:2)}
    static func hide(_ controller:NSWindowController){controller.window?.alphaValue=0;controller.window?.appearance=NSAppearance(named:.darkAqua);controller.window?.setFrameOrigin(NSPoint(x:-12000,y:-12000));controller.showWindow(nil)}
    static func json(_ root:URL,_ file:String="state.json")throws->[String:Any]{try JSONSerialization.jsonObject(with:Data(contentsOf:root.appendingPathComponent(file))) as! [String:Any]}
    static func noSubmission(_ root:URL)throws{
        let state=try json(root)
        try require((state["auth"] as? Int)==0 && (state["data"] as? Int)==0 && (state["accepted"] as? Int)==0 && (state["mail"] as? [String])?.isEmpty==true,"SMTP credentials or message escaped pending/rejected certificate review")
    }
    static func capture(_ controller:NSWindowController,name:String)async throws{
        guard let directory=ProcessInfo.processInfo.environment["TURTLEGIT_SMTP_CERTIFICATE_CAPTURE"],let window=controller.window,let content=window.contentView else{return}
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
    @MainActor final class Server {
        let root:URL,process:Process,port:Int
        init(root:URL,process:Process,port:Int){self.root=root;self.process=process;self.port=port}
        func stop(){if process.isRunning{process.terminate()};process.waitUntilExit()}
        func result()async throws->[String:Any]{try await wait{FileManager.default.fileExists(atPath:root.appendingPathComponent("result.json").path)};process.waitUntilExit();return try json(root,"result.json")}
    }
    static func start(_ name:String,mode:String="implicit-auth",certificate:URL?=nil,port:Int=0)async throws->Server{
        let root=URL(fileURLWithPath:CommandLine.arguments[1]).appendingPathComponent(name)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
        if let certificate{for file in ["cert.pem","key.pem","certificate.der"]{try FileManager.default.copyItem(at:certificate.appendingPathComponent(file),to:root.appendingPathComponent(file))}}
        else{
            let config="[req]\nprompt=no\ndistinguished_name=dn\nx509_extensions=ext\n[dn]\nCN=localhost\nO=TurtleGit private SMTP fixture\n[ext]\nsubjectAltName=DNS:localhost\nbasicConstraints=critical,CA:TRUE\nkeyUsage=critical,digitalSignature,keyEncipherment,keyCertSign\nextendedKeyUsage=serverAuth\n"
            let configuration=root.appendingPathComponent("openssl.cnf");try Data(config.utf8).write(to:configuration)
            for arguments in [["req","-x509","-newkey","rsa:2048","-nodes","-days","1","-config",configuration.path,"-keyout",root.appendingPathComponent("key.pem").path,"-out",root.appendingPathComponent("cert.pem").path],["x509","-in",root.appendingPathComponent("cert.pem").path,"-outform","DER","-out",root.appendingPathComponent("certificate.der").path]]{
                let process=Process();process.executableURL=URL(fileURLWithPath:"/usr/bin/openssl");process.arguments=arguments;process.standardOutput=FileHandle.nullDevice;process.standardError=FileHandle.nullDevice
                try process.run();process.waitUntilExit();try require(process.terminationStatus==0,"Private TLS certificate generation failed")
            }
        }
        let process=Process();process.executableURL=URL(fileURLWithPath:"/usr/bin/python3");process.arguments=[ProcessInfo.processInfo.environment["TURTLEGIT_SMTP_SERVER_SCRIPT"]!,root.path,mode,"30",String(port)];process.standardOutput=FileHandle.nullDevice;process.standardError=FileHandle.nullDevice
        try process.run();var ready=false
        defer{if !ready{if process.isRunning{process.terminate()};process.waitUntilExit()}}
        try await wait{FileManager.default.fileExists(atPath:root.appendingPathComponent("ready.json").path)}
        let port=try json(root,"ready.json")["port"] as! Int;ready=true;return Server(root:root,process:process,port:port)
    }
    static func message()->PatchMailMessage{
        PatchMailMessage(to:["to@example.invalid"],cc:["copy@example.invalid"],subject:"Private certificate review",body:Data("Captured body 雪\r\n".utf8),attachments:[])
    }
}

@MainActor enum SMTPCertificateVerification {
    typealias F=SMTPCertificateFixture
    static func owner(_ server:F.Server,preferences:UserDefaults,cache:SMTPCertificateAcceptanceCache,hostname:String="localhost")->SendPatchProgressWindowController{
        var configuration=EmailConfiguration(preferences:preferences);configuration.delivery = .configured;configuration.server=hostname;configuration.port=UInt32(server.port);configuration.encryption = .tls;configuration.authenticate=true
        let request=SendPatchRequest(files:[],options:PatchMailOptions(),messages:[F.message()],delivery:configuration)
        let repository=GitRepository(root:URL(fileURLWithPath:CommandLine.arguments[1]),executable:URL(fileURLWithPath:CommandLine.arguments[2]))
        weak var liveModel:SendPatchProgressModel?
        let model=SendPatchProgressModel(request:request,repository:repository,access:nil,preferences:preferences,submission:{token,progress in
            guard let model=liveModel else{throw OperationCancellationFailure.cancelled};let review=model.reviewCertificate
            var destination=SMTPServer(host:hostname,port:server.port,encryption:.tls);destination.connectTimeoutMilliseconds=3000;destination.timeoutMilliseconds=5000
            return try await PatchMailSMTP.sendSeries(messages:request.messages,sender:PatchMailSender(name:"Private certificate sender",email:"sender@example.invalid"),server:destination,authentication:SMTPAuthentication(login:"fixture-user",password:"fixture-password"),cancellation:token,onProgress:progress,reviewCertificate:review,certificateApprovals:cache)
        })
        liveModel=model;return SendPatchProgressWindowController(model:model)
    }
    static func settings()->(String,UserDefaults){let suite="TurtleGit.SMTPCertificate."+UUID().uuidString,p=UserDefaults(suiteName:suite)!;p.set(0,forKey:"AutoCloseGitProgress");p.set(false,forKey:"ConfirmKillProcess");return(suite,p)}
    static func review(_ owner:SendPatchProgressWindowController)async throws->SMTPCertificateReviewWindowController{
        try await F.wait{owner.certificateReviewController != nil && owner.certificateReviewController?.window?.sheetParent === owner.window}
        return owner.certificateReviewController!
    }
    static func settle(_ owner:SendPatchProgressWindowController)async throws{
        try await F.wait{!owner.model.busy && !owner.model.hasPendingWork && owner.certificateReviewController == nil && owner.window?.attachedSheet==nil}
    }
    static func acceptanceAndIsolation()async throws{
        let(suite,prefs)=settings();defer{prefs.removePersistentDomain(forName:suite)}
        let cache=SMTPCertificateAcceptanceCache()
        let rejected=try await F.start("default-cancel");defer{rejected.stop()}
        let first=owner(rejected,preferences:prefs,cache:cache);defer{first.close()};F.hide(first);first.model.start()
        let declined=try await review(first),der=try Data(contentsOf:rejected.root.appendingPathComponent("certificate.der"))
        try F.require(declined.details.der==der && declined.hostname=="localhost" && declined.details.fingerprints.contains("SHA-1:") && declined.details.fingerprints.contains("SHA-256:"),"Native certificate review lost actual peer/hostname/fingerprints")
        try F.require(declined.window?.defaultButtonCell === (declined.cancelButton.cell as? NSButtonCell) && declined.window?.initialFirstResponder === declined.cancelButton && declined.acceptButton.keyEquivalent != "\r","Certificate review does not default to Cancel")
        try F.noSubmission(rejected.root);declined.cancelButton.performClick(nil);try await settle(first)
        let denied=try await rejected.result();try F.require((denied["auth"] as? Int)==0 && (denied["data"] as? Int)==0 && !first.model.success,"Default Cancel sent credentials or message")
        first.close();rejected.stop()
        let accepted=try await F.start("accepted",certificate:rejected.root,port:rejected.port);defer{accepted.stop()}
        let second=owner(accepted,preferences:prefs,cache:cache);defer{second.close()};F.hide(second);second.model.start()
        let permitted=try await review(second);try F.noSubmission(accepted.root)
        try F.require(permitted.window?.appearance?.name==NSAppearance.Name.darkAqua && permitted.window?.alphaValue==0 && second.model.notificationPreferences===prefs,"Certificate review lost captured private preferences/appearance")
        permitted.acceptButton.performClick(nil);permitted.acceptButton.performClick(nil);try await settle(second)
        let result=try await accepted.result()
        try F.require(second.model.success && second.model.accepted==1 && permitted.window?.sheetParent==nil && (result["auth"] as? Int)==1 && (result["data"] as? Int)==1 && (result["accepted"] as? Int)==1,"Explicit same-peer review did not detach before one authenticated message")
        // Inspect the independent SMTP server's MIME-decoded payload: the wire
        // serializer correctly base64-encodes this Unicode message body.
        let message=try Data(contentsOf:accepted.root.appendingPathComponent("message.eml")),parts=result["parts"] as? [[String:Any]] ?? []
        let body=(parts.first?["payload"] as? String).flatMap{Data(base64Encoded:$0)}
        try F.require(!message.isEmpty && parts.count==1 && body==F.message().body,"TLS delivery lost exact captured MIME-decoded message body")
        accepted.stop();second.close()
        let reused=try await F.start("accepted-cache",certificate:accepted.root,port:accepted.port);defer{reused.stop()}
        let third=owner(reused,preferences:prefs,cache:cache);defer{third.close()};var reviews=0;third.configureCertificateReview={_ in reviews+=1};F.hide(third);third.model.start();try await settle(third)
        let reusedResult=try await reused.result();try F.require(reviews==0 && third.model.success && (reusedResult["accepted"] as? Int)==1,"Exact same host/port/certificate did not reuse explicit workflow acceptance")
        third.close();reused.stop()
        let changed=try await F.start("changed-peer",port:accepted.port);defer{changed.stop()}
        let fourth=owner(changed,preferences:prefs,cache:cache);defer{fourth.close()};F.hide(fourth);fourth.model.start();let changedReview=try await review(fourth)
        try F.require(changedReview.details.der != der,"Changed peer test did not change actual certificate")
        try F.noSubmission(changed.root);changedReview.cancelButton.performClick(nil);try await settle(fourth);_ = try await changed.result();fourth.close();changed.stop()
        let otherHost=try await F.start("changed-host",certificate:accepted.root,port:accepted.port);defer{otherHost.stop()}
        let fifth=owner(otherHost,preferences:prefs,cache:cache,hostname:"127.0.0.1");defer{fifth.close()};F.hide(fifth);fifth.model.start();let hostReview=try await review(fifth)
        try F.require(hostReview.hostname=="127.0.0.1" && hostReview.details.der==der,"Changed-host test did not retain original peer/change authority")
        try F.noSubmission(otherHost.root);hostReview.cancelButton.performClick(nil);try await settle(fifth);let hostResult=try await otherHost.result();try F.require((hostResult["auth"] as? Int)==0 && (hostResult["data"] as? Int)==0,"Acceptance leaked to another hostname")
        print("PASS private actual TLS native defaultCancel/accept and noAUTH/DATA untilreview; exact authority/certificate acceptance reuse, changedpeer and hostname isolation")
    }
}

private final class SMTPExportGate:@unchecked Sendable {
    private let lock=NSLock()
    private var continuation:CheckedContinuation<Void,Never>?,started=false,released=false
    var waiting:Bool{lock.lock();defer{lock.unlock()};return started && !released}
    func pause()async{await withCheckedContinuation{reply in lock.lock();started=true;if released{lock.unlock();reply.resume()}else{continuation=reply;lock.unlock()}}}
    func release(){lock.lock();released=true;let reply=continuation;continuation=nil;lock.unlock();reply?.resume()}
}
extension SMTPCertificateVerification {
    static func ownership()async throws{
        let(suite,prefs)=settings(),board=NSPasteboard.withUniqueName();defer{prefs.removePersistentDomain(forName:suite);board.releaseGlobally()}
        let server=try await F.start("held-inspector");defer{server.stop()}
        let progress=owner(server,preferences:prefs,cache:SMTPCertificateAcceptanceCache());defer{progress.close()}
        progress.configureCertificateReview={review in review.makeInspector={SMTPCertificateInspectorWindowController(details:$0,pasteboard:board)}}
        var closed=0;progress.onClosed={closed+=1};F.hide(progress);progress.model.start();let heldReview=try await review(progress)
        try await F.capture(heldReview,name:"smtp-certificate-review")
        heldReview.openButton.performClick(nil);try await F.wait{heldReview.inspector?.window?.sheetParent === heldReview.window}
        let inspector=heldReview.inspector!,der=try Data(contentsOf:server.root.appendingPathComponent("certificate.der"))
        try F.require(inspector.tabs.numberOfTabViewItems==2 && (inspector.certificateView.value(forKey:"editable") as? Bool)==false && (inspector.certificateView.value(forKey:"trustDisplayed") as? Bool)==false,"SMTP inspector permits trust editing or lost actual certificate/text pages")
        try await F.capture(inspector,name:"smtp-certificate-inspector")
        inspector.copyButton.performClick(nil);try F.require(board.string(forType:.string)==heldReview.details.fingerprints,"Inspector copy touched wrong board or changed fingerprint text")
        try F.require(!heldReview.acceptButton.isEnabled && !heldReview.cancelButton.isEnabled,"Parent certificate decision remained enabled behind inspector")
        heldReview.acceptTemporary();try F.noSubmission(server.root)
        var exportReply:((NSApplication.ModalResponse)->Void)?,panel:NSSavePanel?
        inspector.presentExport={value,parent,reply in panel=value;exportReply=reply;parent.beginSheet(value)}
        let exported=URL(fileURLWithPath:CommandLine.arguments[1]).appendingPathComponent("inspected-peer.der"),gate=SMTPExportGate()
        defer{gate.release()};inspector.exportDestination={_ in exported}
        inspector.writeExport={bytes,url in await gate.pause();try bytes.write(to:url,options:.atomic)}
        inspector.exportButton.performClick(nil);try await F.wait{panel?.sheetParent === inspector.window}
        try F.require(panel!.alphaValue==0 && inspector.window?.appearance?.name==NSAppearance.Name.darkAqua,"Certificate export lost captured hidden appearance")
        exportReply?(.OK);exportReply?(.OK);try await F.wait{gate.waiting && inspector.exporting && panel?.sheetParent==nil}
        try F.noSubmission(server.root)
        try F.require(TurtleGitApplicationDelegate().applicationShouldTerminate(NSApp) == .terminateCancel,"Quit escaped actual SMTP certificate/inspector/export ownership")
        progress.close();heldReview.acceptTemporary();heldReview.reject();inspector.close()
        try F.require(closed==0 && inspector.hasPendingWork,"Forced SMTP close released accepted export/review before actual work")
        gate.release();try await F.wait{closed==1 && !progress.model.hasPendingWork && progress.certificateReviewController==nil && heldReview.inspector==nil && !inspector.hasPendingWork && progress.window?.attachedSheet==nil}
        let result=try await server.result();try F.require((result["auth"] as? Int)==0 && (result["data"] as? Int)==0 && (try Data(contentsOf:exported))==der,"Retired certificate review submitted mail or changed accepted certificate export bytes")
        let cancelled=try await F.start("cancel-review");defer{cancelled.stop()}
        let cancelOwner=owner(cancelled,preferences:prefs,cache:SMTPCertificateAcceptanceCache());defer{cancelOwner.close()};F.hide(cancelOwner);cancelOwner.model.start();let late=try await review(cancelOwner)
        cancelOwner.model.cancel();try await settle(cancelOwner);late.acceptTemporary();late.reject()
        let cancellation=try await cancelled.result();try F.require(cancelOwner.model.cancelled && !cancelOwner.model.success && (cancellation["auth"] as? Int)==0 && (cancellation["data"] as? Int)==0,"Cancelling held certificate review accepted a late answer or sent credentials")
        let quit=try await F.start("quit-review");defer{quit.stop()}
        let quitOwner=owner(quit,preferences:prefs,cache:SMTPCertificateAcceptanceCache());defer{quitOwner.close()};F.hide(quitOwner);quitOwner.model.start();let stale=try await review(quitOwner)
        quitOwner.model.confirmingQuit=true;quitOwner.model.confirmingQuit=false;stale.acceptTemporary();try await settle(quitOwner)
        let quitResult=try await quit.result();try F.require(!quitOwner.model.success && (quitResult["auth"] as? Int)==0 && (quitResult["data"] as? Int)==0,"Pre-Quit certificate answer escaped roundtrip epoch fence")
        print("PASS actual SMTP review/inspector/private Copy/owned Export child detach; accepted held export survives forceclose until actual drain; pendingreview Cancel/Quit and late native replies reject beforeAUTH/DATA")
    }
    static func uncertain()async throws{
        let(suite,prefs)=settings();defer{prefs.removePersistentDomain(forName:suite)}
        let server=try await F.start("uncertain",mode:"implicit-drop-final");defer{server.stop()}
        let progress=owner(server,preferences:prefs,cache:SMTPCertificateAcceptanceCache());defer{progress.close()};var reviews=0;progress.configureCertificateReview={_ in reviews+=1}
        F.hide(progress);progress.model.start();let allowed=try await review(progress);try F.noSubmission(server.root);allowed.acceptButton.performClick(nil);try await settle(progress)
        let state=try await server.result()
        try F.require(reviews==1 && !progress.model.success && !progress.model.cancelled && progress.model.accepted==0 && progress.model.error?.contains("may have accepted")==true,"Lost final TLS reply was not preserved as uncertain delivery")
        try F.require((state["auth"] as? Int)==1 && (state["data"] as? Int)==1 && (state["accepted"] as? Int)==0 && !progress.model.output.contains("Retrying"),"Possible submission retried or sent more than one captured message")
        let body=try Data(contentsOf:server.root.appendingPathComponent("message.eml"));progress.model.start();progress.model.cancel()
        try F.require(!progress.model.busy && reviews==1 && (try Data(contentsOf:server.root.appendingPathComponent("message.eml")))==body,"Completed uncertain submission restarted or changed retained mail bytes")
        print("PASS explicit TLS certificate acceptance retains uncertain-delivery warning, one authenticated DATA upload and no automatic retry/restart")
    }
}
