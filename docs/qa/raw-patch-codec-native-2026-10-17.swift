// SPDX-License-Identifier: GPL-2.0-or-later
import AppKit
import ScreenCaptureKit
import TurtleGitCore

@main struct RawPatchCodecVerification {
    struct Failure:Error,CustomStringConvertible {let description:String}
    static func require(_ value:Bool,_ message:String)throws {if !value {throw Failure(description:message)}}
    @MainActor static func wait(line:UInt = #line,_ ready:()->Bool) async throws {
        for _ in 0..<1800 {for window in NSApp.windows {window.contentView?.layoutSubtreeIfNeeded()};if ready(){return};try await Task.sleep(nanoseconds:10_000_000)}
        throw Failure(description:"Raw patch codec wait at \(line)")
    }
    @MainActor static func descendants(_ view:NSView)->[NSView] {[view]+view.subviews.flatMap(descendants)}
    @MainActor static func capture(_ window:NSWindow) async throws {
        guard let folder=ProcessInfo.processInfo.environment["TURTLEGIT_RAW_PATCH_CAPTURE"] else{return}
        guard #available(macOS 14.4,*) else{throw Failure(description:"Owned capture unavailable")}
        try require(window.frame.width>=700 && window.frame.height>=400,"Raw patch capture size: \(window.frame)")
        window.alphaValue=1;window.orderFront(nil);defer {window.alphaValue=0}
        for (appearance,name) in [(NSAppearance.Name.aqua,"light"),(.darkAqua,"dark")] {
            window.appearance=NSAppearance(named:appearance);window.contentView?.layoutSubtreeIfNeeded();try await Task.sleep(nanoseconds:250_000_000)
            let content=try await SCShareableContent.currentProcess
            guard let owned=content.windows.first(where:{$0.windowID==CGWindowID(window.windowNumber)}) else{throw Failure(description:"Owned raw patch capture unavailable")}
            let config=SCStreamConfiguration();config.width=Int(window.frame.width*2);config.height=Int(window.frame.height*2);config.showsCursor=false;config.ignoreShadowsSingleWindow=true;config.includeChildWindows=false
            let pixels=try await SCScreenshotManager.captureImage(contentFilter:SCContentFilter(desktopIndependentWindow:owned),configuration:config)
            guard let bytes=NSBitmapImageRep(cgImage:pixels).representation(using:.png,properties:[:]) else{throw Failure(description:"Capture encoding")}
            try bytes.write(to:URL(fileURLWithPath:folder).appendingPathComponent("raw-patch-codec-"+name+".png"))
        }
    }
    @MainActor static func main() async throws {
        NSApp.setActivationPolicy(.prohibited)
        let root=URL(fileURLWithPath:CommandLine.arguments[1]),repo=GitRepository(root:root,executable:URL(fileURLWithPath:CommandLine.arguments[2])),codec=ComparisonTextEncoding.windows1251
        _=try await repo.run(["init","-b","main"])
        for (key,value) in [("user.name","Raw codec QA"),("user.email","raw@example.invalid"),("commit.gpgsign","false"),("core.hooksPath","/dev/null")] {_=try await repo.run(["config",key,value])}
        let file=root.appendingPathComponent("file.txt"),base="шапка\nстарое\nхвост\n",changed="шапка\nновое\nхвост\n"
        try codec.encode(base).write(to:file);try await repo.stage(["file.txt"]);_=try await repo.commit(message:"base")
        try codec.encode(changed).write(to:file)
        let raw=try await repo.patchData(paths:["file.txt"],staged:false),head=try await repo.run(["rev-parse","HEAD"]).stdout
        let suite="TurtleGit.RawPatchCodec."+UUID().uuidString,prefs=UserDefaults(suiteName:suite)!
        defer {prefs.removePersistentDomain(forName:suite)}
        prefs.set(1251,forKey:"TurtleGitMerge.LegacyCodePage")
        let partial=PatchWindowController(repository:repo,access:nil,preferences:prefs),partialModel=partial.model
        defer {partial.close()}
        partialModel.readOnly=false;partialModel.reload(paths:["file.txt"],staged:false)
        try await wait {!partialModel.busy && !partialModel.document.files.isEmpty}
        try require(partialModel.error==nil && partialModel.document.text.contains("+новое") && partialModel.document.bytes==raw,"Regional partial staging display/raw packet")
        let board=NSPasteboard.withUniqueName();defer {board.releaseGlobally()}
        partialModel.copyPatch(to:board)
        try require(PatchClipboard.snapshot(from:board)==raw && board.string(forType:.string)?.contains("+новое")==true,"Partial patch raw/text clipboard flavors")
        partialModel.selectedLines=[partialModel.document.files[0].hunks[0].header];partialModel.apply(entireHunks:true)
        try await wait {!partialModel.busy && PatchWindowModel.activeOperations==0}
        let staged=try await repo.run(["show",":file.txt"]).stdout
        try require(staged==codec.encode(changed) && Data(contentsOf:file)==codec.encode(changed),"Regional partial apply rewrote source bytes")
        _=try await repo.run(["reset","--","file.txt"])
        let index=try Data(contentsOf:root.appendingPathComponent(".git/index"))
        partial.close()
        // Both import surfaces retain raw bytes while rendering the chosen code page.
        let review=WorkingTreePatchWindowController(repository:repo,access:nil,fileAccess:nil,bytes:raw,title:"Regional patch",preferences:prefs,automaticallyRefresh:false)
        defer {review.close()}
        try require(review.model.previewDocument.document.text.contains("+новое") && review.model.previewDocument.exportDocument.bytes==raw,"Original Patch tab decoding/export")
        let patchFile=root.appendingPathComponent("source.patch");try raw.write(to:patchFile)
        let serial=ImportPatchWindowModel(repository:repo,access:nil,preferences:prefs);defer {serial.invalidate()}
        serial.add([patchFile]);serial.selection=[serial.items[0].id]
        prefs.set(1252,forKey:"TurtleGitMerge.LegacyCodePage")
        try await wait {ImportPatchWindowModel.activeWorkers==0 && !serial.preview.isEmpty}
        try require(serial.preview.contains("+новое") && serial.previewDocument.exportDocument.bytes==raw && serial.previewDocument.document.displayLegacyEncoding==codec,"Serial preview lost captured codec")
        try require(review.model.previewDocument.document.displayLegacyEncoding==codec,"Original Patch followed unrelated settings")
        serial.invalidate();review.close()
        // Open captures its codec before asynchronous I/O and retains it through Save As.
        prefs.set(1251,forKey:"TurtleGitMerge.LegacyCodePage");prefs.set(900,forKey:"PartialPatchWindowWidth")
        let owner=PatchWindowController(repository:repo,access:nil,preferences:prefs),model=owner.model,session=owner.documentSession!,window=owner.window!
        defer {owner.close()}
        window.alphaValue=0;window.orderFront(nil);model.allowsDocumentEditing=true;model.setReadOnlyDiff(Data())
        var release:CheckedContinuation<Data,Error>?,started=false
        session.readFile={_,_ in started=true;return try await withCheckedThrowingContinuation {release=$0}}
        session.chooseOpen={_,reply in reply(patchFile)};session.openDocument();try await wait {started}
        prefs.set(1252,forKey:"TurtleGitMerge.LegacyCodePage");release?.resume(returning:raw)
        try await wait {PatchDocumentSession.activeOperations==0 && model.document.text.contains("+новое")}
        guard let text=descendants(window.contentView!).compactMap({$0 as? PatchTextView.PatchText}).first else{throw Failure(description:"Native raw patch text missing")}
        try await wait {text.isEditable && text.string.contains("+новое")}
        model.showFind();model.changeFindText("новое");try await capture(window);model.hideFind()
        window.makeFirstResponder(text)
        text.insertText("+добавлено\r\n",replacementRange:NSRange(location:text.string.utf16.count,length:0))
        try await wait {model.documentDirty}
        try await wait {GitReferenceName.equal(text.string,model.document.text)}
        let edited=text.string,expected=try codec.encode(edited)
        try require(edited.utf8.suffix(2).elementsEqual([13,10]),"Native renderer dropped final CRLF")
        model.copyPatch(to:board)
        try require(PatchClipboard.snapshot(from:board)==expected && board.string(forType:.string)==edited,"Dirty regional clipboard changed codec")
        let saved=root.appendingPathComponent("saved.patch")
        session.chooseSave={_,_,reply in reply(saved)};session.saveDocument(as:true)
        try await wait {PatchDocumentSession.activeOperations==0 && !model.documentDirty}
        try require(try Data(contentsOf:saved)==expected && Data(contentsOf:patchFile)==raw,"Save As changed codec or original patch")
        try await wait {text.isEditable}
        text.insertText("日本語",replacementRange:NSRange(location:text.string.utf16.count,length:0));try await wait {model.documentDirty}
        session.saveDocument();try await wait {PatchDocumentSession.activeOperations==0}
        try require(model.error != nil && model.documentDirty && Data(contentsOf:saved)==expected,"Unrepresentable Save changed disk")
        model.error=nil;try await wait {window.attachedSheet==nil}
        session.askChanges={_,reply in reply(.discard)}
        model.setReadOnlyDiff(Data("+café\n".utf8));try await wait {PatchDocumentSession.activeOperations==0 && !model.documentDirty && text.string=="+café\n" && text.isEditable}
        let nfd="+cafe\u{301}\n"
        text.insertText(nfd,replacementRange:NSRange(location:0,length:text.string.utf16.count));try await wait {model.documentDirty}
        try require(try session.encodedBytes()==Data(nfd.utf8),"Canonical-only Unicode edit was discarded")
        model.copyPatch(to:board);try require(PatchClipboard.snapshot(from:board)==Data(nfd.utf8),"Canonical-only clipboard edit lost")
        owner.close()
        try await wait {PatchDocumentSession.activeOperations==0 && PatchWindowModel.activeOperations==0 && ImportPatchWindowModel.activeWorkers==0}
        let finalHead=try await repo.run(["rev-parse","HEAD"]).stdout
        try require(finalHead==head && Data(contentsOf:root.appendingPathComponent(".git/index"))==index && Data(contentsOf:file)==codec.encode(changed),"Preview/document workflow changed repository")
        print("PASS: raw patch codecs, partial staging, Original Patch, serial preview, captured Open, Save As, clipboard, exact Unicode and ownership")
    }
}
