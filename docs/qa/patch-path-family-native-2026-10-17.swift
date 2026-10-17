// SPDX-License-Identifier: GPL-2.0-or-later
import AppKit
import ScreenCaptureKit
import UniformTypeIdentifiers
import TurtleGitCore

@main struct PatchPathFamilyVerification {
    struct Failure:Error,CustomStringConvertible {let description:String}
    static func require(_ value:Bool,_ message:String)throws {if !value {throw Failure(description:message)}}
    @MainActor static func wait(line:UInt = #line,_ ready:()->Bool) async throws {
        for _ in 0..<1800 {for window in NSApp.windows {window.contentView?.layoutSubtreeIfNeeded()};if ready(){return};try await Task.sleep(nanoseconds:10_000_000)}
        throw Failure(description:"Patch path wait at \(line)")
    }
    @MainActor static func capture(_ window:NSWindow) async throws {
        guard let folder=ProcessInfo.processInfo.environment["TURTLEGIT_PATCH_PATH_CAPTURE"] else{return}
        guard #available(macOS 14.4,*) else{throw Failure(description:"Owned capture unavailable")}
        try require(window.frame.width>=1000 && window.frame.height>=700,"Patch capture collapsed")
        window.alphaValue=1;window.orderFront(nil);defer {window.alphaValue=0}
        for (appearance,name) in [(NSAppearance.Name.aqua,"light"),(.darkAqua,"dark")] {
            window.appearance=NSAppearance(named:appearance);window.contentView?.layoutSubtreeIfNeeded();try await Task.sleep(nanoseconds:250_000_000)
            let content=try await SCShareableContent.currentProcess
            guard let owned=content.windows.first(where:{$0.windowID==CGWindowID(window.windowNumber)}) else{throw Failure(description:"Owned patch capture unavailable")}
            let config=SCStreamConfiguration();config.width=Int(window.frame.width*2);config.height=Int(window.frame.height*2);config.showsCursor=false;config.ignoreShadowsSingleWindow=true;config.includeChildWindows=false
            let pixels=try await SCScreenshotManager.captureImage(contentFilter:SCContentFilter(desktopIndependentWindow:owned),configuration:config)
            guard let bytes=NSBitmapImageRep(cgImage:pixels).representation(using:.png,properties:[:]) else{throw Failure(description:"Capture encoding")}
            try bytes.write(to:URL(fileURLWithPath:folder).appendingPathComponent("patch-paths-"+name+".png"))
        }
    }
    @MainActor static func main() async throws {
        NSApp.setActivationPolicy(.prohibited)
        let root=URL(fileURLWithPath:CommandLine.arguments[1]),repo=GitRepository(root:root,executable:URL(fileURLWithPath:CommandLine.arguments[2]))
        _=try await repo.run(["init","-b","main"])
        for (key,value) in [("user.name","Patch path QA"),("user.email","path@example.invalid"),("commit.gpgsign","false"),("core.hooksPath","/dev/null"),("core.precomposeunicode","false")] {_=try await repo.run(["config",key,value])}
        let old="old-café/--file[*]\n.txt",new="new-cafe\u{301}/--target? &.txt"
        let oldURL=FileTransferPaths.fileURL(root.path+"/"+old),newURL=FileTransferPaths.fileURL(root.path+"/"+new)
        let base=(0..<12).map {"base line \($0)\n"}.joined(),patched=base.replacingOccurrences(of:"base line 4",with:"patched line 4"),local=base.replacingOccurrences(of:"base line 4",with:"local line 4")
        try FileManager.default.createDirectory(at:oldURL.deletingLastPathComponent(),withIntermediateDirectories:true)
        try Data(base.utf8).write(to:oldURL);try FileManager.default.setAttributes([.posixPermissions:0o755],ofItemAtPath:oldURL.path)
        let before=try await repo.run(["hash-object","-w","--stdin"],input:Data(base.utf8)).text.trimmingCharacters(in:.newlines)
        _=try await repo.run(["update-index","-z","--index-info"],input:Data("100755 \(before)\t\(old)\0".utf8));_=try await repo.commit(message:"source")
        let after=try await repo.run(["hash-object","-w","--stdin"],input:Data(patched.utf8)).text.trimmingCharacters(in:.newlines)
        _=try await repo.run(["update-index","-z","--index-info"],input:Data(("0 "+String(repeating:"0",count:40)+"\t"+old+"\0"+"100755 "+after+"\t"+new+"\0").utf8))
        let patch=try await repo.run(["diff","--cached","--binary","--full-index","--find-renames=50%","HEAD","--"]).stdout
        _=try await repo.run(["read-tree","HEAD"]);try Data(local.utf8).write(to:oldURL)
        let head=try await repo.run(["rev-parse","HEAD"]).stdout,index=try Data(contentsOf:root.appendingPathComponent(".git/index"))
        let suite="TurtleGit.PatchPaths."+UUID().uuidString,prefs=UserDefaults(suiteName:suite)!
        defer {prefs.removePersistentDomain(forName:suite)}
        prefs.set(true,forKey:"TurtleGitMerge.UseUTF8");MergeEditorPreferences(autoAdd:false).save(to:prefs);MergeGeneralPreferences(firstDifference:false,firstConflict:false).save(to:prefs)
        let owner=WorkingTreePatchWindowController(repository:repo,access:nil,fileAccess:nil,bytes:patch,title:"Renamed-file patch recovery",preferences:prefs),model=owner.model,window=owner.window!
        defer {owner.close()};window.alphaValue=0;window.orderFront(nil)
        try await wait {!model.busy && model.conflictEditor?.sourceToolsAllowed==true}
        guard let comparison=model.comparison,let conflict=model.conflictEditor,let file=model.review?.files.first else{throw Failure(description:"Rename recovery missing")}
        try require(Data(comparison.document.base.path.utf8)==Data(old.utf8) && Data(comparison.document.destination.path.utf8)==Data(new.utf8) && file.pathBytes==Data(new.utf8),"Rename source/destination spelling changed")
        try require(conflict.document?.base==base && conflict.document?.mine==local && conflict.document?.theirs==patched,"Recorded/current/patched rename contents")
        try await capture(window)
        let generation=model.fileListGeneration
        conflict.choose(.theirs);try require(model.canSaveDraft && !conflict.hasUnresolvedConflicts,"Rename recovery choice")
        var saved:Bool?;model.saveDraft {saved=$0};try await wait {saved != nil && !model.busy}
        try require(saved==true && model.appliedPaths.contains(Data(new.utf8)) && !FileManager.default.fileExists(atPath:oldURL.path) && Data(contentsOf:newURL)==Data(patched.utf8),"Rename recovery Save path/bytes")
        try require((try FileManager.default.attributesOfItem(atPath:newURL.path)[.posixPermissions] as? NSNumber)?.intValue==0o755,"Rename recovery Save mode")
        try require(!model.canPreviewFiles([file.id],generation:generation) && model.canSaveDraft==false,"Completed rename command stayed active")
        owner.close()
        // Provider URLs retain distinct valid UTF8 spellings. Byte-identical drops
        // and directory providers are still ignored; direct Add keeps source duplicates.
        let a=FileTransferPaths.fileURL(root.path+"/café.patch"),b=FileTransferPaths.fileURL(root.path+"/cafe\u{301}.patch")
        try patch.write(to:a)
        func provider(_ url:URL)->NSItemProvider {
            let item=NSItemProvider();item.registerDataRepresentation(forTypeIdentifier:UTType.fileURL.identifier,visibility:.all) {done in done(url.dataRepresentation,nil);return nil};return item
        }
        let serial=ImportPatchWindowModel(repository:repo,access:nil,preferences:prefs);defer {serial.invalidate()}
        serial.add([a]);let context=serial.formContext
        try require(serial.receiveDrop([provider(root),provider(b),provider(a),provider(b)]),"File drop not accepted")
        try await wait {!serial.receivingDrop && ImportPatchWindowModel.activeWorkers==0}
        try require(serial.items.map {Data($0.file.path.utf8)} == [Data(a.path.utf8),Data(b.path.utf8)],"Drop collapsed Unicode peer or kept exact duplicate")
        let ids=serial.items.map(\.id);serial.select([ids[1]],context:context)
        try require(serial.selection.isEmpty,"Stale import callback changed new file catalog")
        serial.selection=[ids[1]];try await wait {ImportPatchWindowModel.activeWorkers==0 && !serial.preview.isEmpty}
        try require(serial.previewDocument.exportDocument.bytes==patch,"Selected peer preview changed patch bytes")
        serial.add([a]);try require(serial.items.count==3,"Direct Add no longer retains source duplicate rows")
        serial.invalidate();try await wait {ImportPatchWindowModel.activeWorkers==0 && WorkingTreePatchWindowModel.activeOperations==0}
        let finalHead=try await repo.run(["rev-parse","HEAD"]).stdout
        try require(finalHead==head && Data(contentsOf:root.appendingPathComponent(".git/index"))==index,"Rename/drop workflow changed HEAD/index")
        print("PASS: exact renamed-file recorded-base preview/save, modes, completed command gates, serial provider Unicode peers/order/duplicate rules, original preview bytes and retired ownership")
    }
}
