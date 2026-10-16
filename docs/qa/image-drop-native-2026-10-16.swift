import AppKit
import TurtleGitCore

struct ImageDropVerification {
    struct Failure:Error,CustomStringConvertible {let description:String}
    static func require(_ value:Bool,_ message:String)throws {if !value {throw Failure(description:message)}}
    @MainActor static func wait(line:UInt = #line,_ ready:()->Bool)async throws {
        for _ in 0..<1500 {if ready(){return};try await Task.sleep(nanoseconds:10_000_000)}
        throw Failure(description:"Image drop timeout at line \(line)")
    }
    final class ScopeLog {var starts=0,stops=0}
    struct ScopeProvider:RepositoryBookmarkProvider {
        let log:ScopeLog
        func create(for url:URL)throws->Data {Data()}
        func resolve(_ data:Data)throws->ResolvedBookmark {throw Failure(description:"Unexpected bookmark resolution")}
        func startAccessing(_ url:URL)->Bool {log.starts += 1;return true}
        func stopAccessing(_ url:URL){log.stops += 1}
    }
    struct DeniedScope:RepositoryBookmarkProvider {
        func create(for url:URL)throws->Data {Data()}
        func resolve(_ data:Data)throws->ResolvedBookmark {throw Failure(description:"Unexpected bookmark resolution")}
        func startAccessing(_ url:URL)->Bool {false}
        func stopAccessing(_ url:URL){}
    }
    @MainActor static func descendants(_ view:NSView)->[NSView] {[view]+view.subviews.flatMap(descendants)}
    @MainActor static func verify()async throws {
        let root=URL(fileURLWithPath:CommandLine.arguments[1]),suite="TurtleGit.ImageDrop."+UUID().uuidString,prefs=UserDefaults(suiteName:suite)!
        defer {prefs.removePersistentDomain(forName:suite)}
        UserDefaults.standard.setVolatileDomain(["TurtleGit.DiffTools":try JSONEncoder().encode(DiffToolPreferences())],forName:"NSArgumentDomain")
        let left=root.appendingPathComponent("left.png"),right=root.appendingPathComponent("right.png"),other=root.appendingPathComponent("dropped 雪\nimage.bin"),bad=root.appendingPathComponent("unsupported.png")
        let a=ImagePointerVerification.png(200,150,.red),b=ImagePointerVerification.png(300,250,.blue),c=ImagePointerVerification.png(400,350,.green),invalid=Data("not an image\n".utf8)
        for (url,data) in [(left,a),(right,b),(other,c),(bad,invalid)] {try data.write(to:url)}
        let owner=FileComparisonWindowController(images:try ImageFileComparison(base:left,destination:right),permissions:[],preferences:prefs)
        defer {owner.close()};let window=owner.window!,parent=owner.model,model=parent.imageViewerModel
        window.alphaValue=0;window.orderFront(nil);parent.load()
        func scrolls()->[ImageComparisonScrollView] {descendants(window.contentView!).compactMap{$0 as? ImageComparisonScrollView}}
        try await wait {window.contentView?.layoutSubtreeIfNeeded();return !parent.busy && parent.imageComparison != nil && scrolls().count==2}
        let base=scrolls().first{$0.documentView?.accessibilityLabel()=="Base image"}!,peer=scrolls().first{$0 !== base}!,original=parent.document!,peerID=model.currentImage(base:false)!.id
        let pasteboard=NSPasteboard.withUniqueName();defer {pasteboard.releaseGlobally()}
        pasteboard.writeObjects([bad as NSURL,other as NSURL])
        try require(base.registeredDraggedTypes.contains(.fileURL) && base.validateFileDrop(pasteboard),"Native file drop registration/validation missing")
        try require(base.receiveFileDrop(pasteboard),"Native first-file drop was refused")
        try await wait {!model.receivingDrop}
        try require(model.droppedFiles[true]?.bytes==invalid && model.currentImage(base:true)==nil && model.currentImage(base:false)?.id==peerID,"First unsupported file was skipped or peer replaced")
        try require(model.dropError==nil && parent.document?.base.bytes==a,"Unsupported image preview mutated source or became read error")
        pasteboard.clearContents();pasteboard.writeObjects([other as NSURL,left as NSURL])
        let log=ScopeLog();model.requiresDropScope=true;model.makeDropPermission={RepositoryAccessLease(url:$0,provider:ScopeProvider(log:log))}
        try require(base.receiveFileDrop(pasteboard),"Authorized native drop refused")
        try require(!model.commandState(.open).enabled && !peer.validateFileDrop(pasteboard),"Read left another command/drop enabled")
        try await wait {!model.receivingDrop && model.currentImage(base:true)?.pixels.width==400}
        try require(log.starts==1 && log.stops==0 && model.droppedFiles[true]?.path==other.path && model.fit,"Drop did not retain scope/title/fit")
        let info=model.information(base:true,bytes:0)
        try require(info.contains("File size: \(c.count) bytes") && info.contains("Width: 400 pixels") && info.contains(where:{$0.hasPrefix("Zoom: ")}),"Dropped metadata/zoom did not update")
        // Ordinary SwiftUI reconstruction must retain a drop against unchanged inputs.
        model.configureImages(base:parent.imageComparison!.base,destination:parent.imageComparison!.destination)
        try require(model.droppedFiles[true]?.bytes==c,"Unchanged input reconstruction discarded drop")
        parent.load();try await wait {!parent.busy && model.droppedFiles.isEmpty}
        try require(model.currentImage(base:true)?.pixels.width==200 && log.stops==1,"Reload did not restore original inputs/release grant")
        model.makeDropPermission={RepositoryAccessLease(url:$0,provider:DeniedScope())}
        try require(!model.dropFile(other,base:false) && model.dropError != nil,"Missing scope was accepted")
        model.requiresDropScope=false
        try require(model.dropFile(root,base:false),"Directory validation did not reach owned read")
        try await wait {!model.receivingDrop && model.dropError != nil}
        try require(model.currentImage(base:false)?.pixels.width==300 && model.droppedFiles[false]==nil,"Failed read replaced original preview")
        // Retire a suspended non-cooperative read; scope/Quit lifetime lasts to settlement.
        let lateLog=ScopeLog();model.makeDropPermission={RepositoryAccessLease(url:$0,provider:ScopeProvider(log:lateLog))}
        var continuation:CheckedContinuation<ComparisonFileContent,Never>?
        let content=try ImageFileComparison(base:other,destination:nil).read().base
        model.readDroppedFile={_,_ in await withCheckedContinuation{continuation=$0}}
        try require(model.dropFile(other,base:false),"Delayed drop refused")
        try await wait {continuation != nil}
        try require(ImageComparisonViewModel.activeFileReads==1 && TurtleGitApplicationDelegate().applicationShouldTerminate(NSApp) == .terminateCancel,"Read lost actual Quit ownership")
        owner.close()
        try require(ImageComparisonViewModel.activeFileReads==1 && lateLog.stops==0,"Retirement released live read/scope")
        continuation?.resume(returning:content);continuation=nil
        try await wait {ImageComparisonViewModel.activeFileReads==0 && lateLog.stops==1}
        try require(model.droppedFiles[false]==nil && !model.receivingDrop,"Retired read published replacement")
        try require(!base.receiveFileDrop(pasteboard),"Retired native drop was accepted")
        for (url,data) in [(left,a),(right,b),(other,c),(bad,invalid)] {try require(Data(contentsOf:url)==data,"Drop changed file bytes")}
        try require(original.base.bytes==a && original.destination.bytes==b,"Original comparison changed")
        print("PASS: native per-pane first-file drops, unsupported/failed reads, metadata, unchanged-input reconstruction, Reload restoration, grant lifetime/permission refusal, busy gates, late retirement/Quit accounting and immutable inputs")
    }
}
