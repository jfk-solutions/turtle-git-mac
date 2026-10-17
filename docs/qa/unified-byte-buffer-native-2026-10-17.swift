// SPDX-License-Identifier: GPL-2.0-or-later
import AppKit
import ScreenCaptureKit
import TurtleGitCore

@main struct UnifiedByteBufferVerification {
    struct Failure:Error,CustomStringConvertible {let description:String}
    static func require(_ value:Bool,_ message:String)throws {if !value {throw Failure(description:message)}}
    @MainActor static func wait(line:UInt = #line,_ ready:()->Bool) async throws {
        for _ in 0..<1800 {for window in NSApp.windows {window.contentView?.layoutSubtreeIfNeeded()};if ready(){return};try await Task.sleep(nanoseconds:10_000_000)}
        throw Failure(description:"Byte buffer wait at \(line)")
    }
    @MainActor static func descendants(_ view:NSView)->[NSView] {[view]+view.subviews.flatMap(descendants)}
    @MainActor static func capture(_ window:NSWindow) async throws {
        guard let folder=ProcessInfo.processInfo.environment["TURTLEGIT_BYTE_BUFFER_CAPTURE"] else{return}
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
            try bytes.write(to:URL(fileURLWithPath:folder).appendingPathComponent("unified-byte-buffer-"+name+".png"))
        }
    }
    @MainActor static func main() async throws {
        NSApp.setActivationPolicy(.prohibited)
        let root=URL(fileURLWithPath:CommandLine.arguments[1]),repo=GitRepository(root:root,executable:URL(fileURLWithPath:CommandLine.arguments[2])),codec=ComparisonTextEncoding.windows1251
        _=try await repo.run(["init","-b","main"])
        for (key,value) in [("user.name","Byte editor QA"),("user.email","byte@example.invalid"),("commit.gpgsign","false"),("core.hooksPath","/dev/null")] {_=try await repo.run(["config",key,value])}
        try Data("base\n".utf8).write(to:root.appendingPathComponent("file"));try await repo.stage(["file"]);_=try await repo.commit(message:"base")
        let head=try await repo.run(["rev-parse","HEAD"]).stdout,index=try Data(contentsOf:root.appendingPathComponent(".git/index"))
        let header=Data("diff --git a/settings.txt b/settings.txt\n--- a/settings.txt\n+++ b/settings.txt\n@@ -1,2 +1,2 @@\n".utf8)
        let original=header+Data("+日本語\n".utf8)+(try codec.encode("-исходный\r\n"))+Data(" opaque: ".utf8)+Data([0x98,0,0xff,10])
        let first=header+Data("+日本語 🐢\n".utf8)+(try codec.encode("-исходный\r\n"))+Data(" opaque: ".utf8)+Data([0x98,0,0xff,10])
        let changed=header+Data("+日本語 🐢\n".utf8)+(try codec.encode("-новый\r\n"))+Data(" opaque: ".utf8)+Data([0x98,0,0xff,10])
        let suite="TurtleGit.UnifiedByteBuffer."+UUID().uuidString,prefs=UserDefaults(suiteName:suite)!
        defer {prefs.removePersistentDomain(forName:suite)}
        prefs.set(1251,forKey:"TurtleGitMerge.LegacyCodePage");prefs.set(900,forKey:"PartialPatchWindowWidth")
        let owner=PatchWindowController(repository:repo,access:nil,preferences:prefs),model=owner.model,session=owner.documentSession!,window=owner.window!
        defer {owner.close()};window.alphaValue=0;window.orderFront(nil);owner.presentDocument(original,title:"Mixed encoding patch – TurtleGit",comparison:"mixed.patch",information:"Patch document. Edits retain original byte fragments.")
        try await wait {descendants(window.contentView!).contains{($0 as? PatchTextView.PatchText)?.isEditable==true}}
        let text=descendants(window.contentView!).compactMap{$0 as? PatchTextView.PatchText}.first!
        @MainActor func ready(line:UInt = #line) async throws {try await wait(line:line){text.isEditable && model.canEditText && GitReferenceName.equal(text.string,model.document.text)}}
        @MainActor func replace(_ find:String,_ replacement:String) async throws {
            try await ready();window.makeFirstResponder(text);text.breakUndoCoalescing()
            let range=(text.string as NSString).range(of:find);try require(range.location != NSNotFound,"Native edit target missing")
            text.setSelectedRange(range);text.insertText(replacement,replacementRange:range);try await ready();try await Task.sleep(nanoseconds:30_000_000)
        }
        try await ready();try require(text.string.unicodeScalars.contains{$0.value==0},"Native renderer dropped NUL")
        try await replace("日本語","日本語 🐢");try require(try session.encodedBytes()==first,"UTF8 edit transcoded regional/opaque bytes")
        try await replace("исходный","новый");try require(try session.encodedBytes()==changed,"Regional edit transcoded UTF8/opaque bytes")
        model.showFind();model.changeFindText("новый");try await capture(window);model.hideFind()
        let board=NSPasteboard.withUniqueName();defer {board.releaseGlobally()};model.copyPatch(to:board)
        try require(PatchClipboard.snapshot(from:board)==changed && board.string(forType:.string).map{GitReferenceName.equal($0,model.document.text)}==true,"Mixed edited clipboard byte/text representations")
        // The exact byte/presentation snapshot is held through an owned Save As.
        let saved=root.appendingPathComponent("mixed.patch");var releaseSave:((URL?)->Void)?
        session.chooseSave={_,_,reply in releaseSave=reply};session.saveDocument(as:true)
        try await wait {releaseSave != nil && model.busy}
        prefs.set(1252,forKey:"TurtleGitMerge.LegacyCodePage");let held=model.document.text;model.editDocument("stale callback")
        try require(GitReferenceName.equal(model.document.text,held),"Held Save accepted source edits")
        releaseSave?(saved);releaseSave=nil
        try await wait {PatchDocumentSession.activeOperations==0 && !model.documentDirty};try await ready()
        try require(try Data(contentsOf:saved)==changed && model.exportDocument.bytes==changed && GitReferenceName.equal(model.exportDocument.displayText,text.string),"Save As lost byte spans/presentation")
        text.undoManager?.undo();try await ready()
        let undone=try session.encodedBytes()
        if undone==first {
            try require(model.documentDirty,"First Undo did not leave savepoint")
            text.undoManager?.undo();try await ready();try require(try session.encodedBytes()==original,"Second Undo did not restore original bytes")
            text.undoManager?.redo();try await ready();try require(try session.encodedBytes()==first,"Byte Redo first edit")
        } else {try require(undone==original && model.documentDirty,"Coalesced Undo did not restore original bytes")}
        text.undoManager?.redo();try await ready();try require(!model.documentDirty && session.encodedBytes()==changed,"Redo did not return to exact savepoint")
        try await replace("opaque:","opaque edited:")
        let withOpaque=header+Data("+日本語 🐢\n".utf8)+(try codec.encode("-новый\r\n"))+Data(" opaque edited: ".utf8)+Data([0x98,0,0xff,10])
        session.saveDocument();try await wait {PatchDocumentSession.activeOperations==0 && !model.documentDirty};try await ready()
        try require(try Data(contentsOf:saved)==withOpaque,"Editing beside NUL changed opaque bytes")
        try await replace("\u{98}","")
        let withoutOpaque=header+Data("+日本語 🐢\n".utf8)+(try codec.encode("-новый\r\n"))+Data(" opaque edited: ".utf8)+Data([0,0xff,10])
        session.saveDocument();try await wait {PatchDocumentSession.activeOperations==0 && !model.documentDirty};try await ready()
        try require(try Data(contentsOf:saved)==withoutOpaque,"Deleting projected byte rewrote its neighbors")
        text.undoManager?.undo();try await ready();let restoredOpaque=try session.encodedBytes()
        // AppKit may coalesce the prefix edit and byte deletion in one native
        // event. Both captured prior states must restore 0x98 and NUL exactly.
        try require((restoredOpaque==withOpaque || restoredOpaque==changed) && model.documentDirty,"Undo after Save did not restore captured opaque-byte state")
        var asked=false;session.askChanges={_,reply in asked=true;reply(.cancel)}
        model.setReadOnlyDiff(Data("replacement\n".utf8));try await wait {asked && PatchDocumentSession.activeOperations==0}
        try require(try session.encodedBytes()==restoredOpaque && Data(contentsOf:saved)==withoutOpaque,"Cancelled replacement changed mixed byte buffer")
        owner.close();try await wait {PatchDocumentSession.activeOperations==0}
        // A retired save chooser cannot publish its captured bytes to disk.
        let late=PatchWindowController(repository:repo,access:nil,preferences:prefs),lateModel=late.model,lateSession=late.documentSession!
        defer {late.close()};lateModel.allowsDocumentEditing=true;lateModel.setReadOnlyDiff(original)
        var reply:((URL?)->Void)?;lateSession.chooseSave={_,_,response in reply=response};lateSession.saveDocument(as:true)
        try await wait {reply != nil};late.close();try require(PatchDocumentSession.activeOperations>0,"Retired save lost operation ownership")
        let unwanted=root.appendingPathComponent("retired.patch");reply?(unwanted);reply=nil;try await wait {PatchDocumentSession.activeOperations==0}
        try require(!FileManager.default.fileExists(atPath:unwanted.path),"Retired save wrote captured snapshot")
        let finalHead=try await repo.run(["rev-parse","HEAD"]).stdout
        try require(finalHead==head && Data(contentsOf:root.appendingPathComponent(".git/index"))==index,"Byte document editor changed repository")
        print("PASS: native mixed UTF8/regional/opaque edits, NUL retention, exact clipboard, held Save As, Undo/Redo across saves, projected-byte deletion/restoration, replacement cancellation and retired save ownership")
    }
}
