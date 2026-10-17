import AppKit
import ScreenCaptureKit
import TurtleGitCore

@main struct PatchCodecFamilyVerification {
    struct Failure:Error,CustomStringConvertible {let description:String}
    static func require(_ value:Bool,_ message:String)throws {if !value {throw Failure(description:message)}}
    @MainActor static func wait(_ ready:()->Bool,line:UInt = #line) async throws {
        for _ in 0..<2000 {for window in NSApp.windows {window.contentView?.layoutSubtreeIfNeeded()};if ready(){return};try await Task.sleep(nanoseconds:10_000_000)}
        throw Failure(description:"Patch codec wait at \(line)")
    }
    @MainActor static func capture(_ window:NSWindow) async throws {
        guard let folder=ProcessInfo.processInfo.environment["TURTLEGIT_PATCH_CODEC_CAPTURE"] else{return}
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
            try bytes.write(to:URL(fileURLWithPath:folder).appendingPathComponent("patch-codec-"+name+".png"))
        }
    }
    @MainActor static func main() async throws {
        NSApp.setActivationPolicy(.prohibited)
        let root=URL(fileURLWithPath:CommandLine.arguments[1]),git=URL(fileURLWithPath:CommandLine.arguments[2]),repo=GitRepository(root:root,executable:git),codec=ComparisonTextEncoding.windows1251
        _=try await repo.run(["init","-b","main"])
        for (key,value) in [("user.name","Patch codec QA"),("user.email","codec@example.invalid"),("commit.gpgsign","false")] {_=try await repo.run(["config",key,value])}
        let base="шапка\nстарое\nоставить\nхвост\n",patched="шапка\nновое\nоставить\nхвост\n",conflict="шапка\nместная версия\nоставить\nхвост\n",local="шапка\nстарое\nоставить\nместный хвост\n"
        let paths=["a-clean.txt","b-conflict.txt","c-auto.txt","d-encoding.txt"]
        for path in paths {let file=root.appendingPathComponent(path);try (path==paths[3] ? Data("head\nold\nkeep\ntail\n".utf8):codec.encode(base)).write(to:file);try FileManager.default.setAttributes([.posixPermissions:0o755],ofItemAtPath:file.path)}
        try await repo.stage(paths);_=try await repo.commit(message:"base")
        for path in paths {try (path==paths[3] ? Data("head\n日本語\nkeep\ntail\n".utf8):codec.encode(patched)).write(to:root.appendingPathComponent(path))}
        let patch=try await repo.run(["diff","--full-index","--binary","--"]).stdout
        for (path,text) in zip(paths,[base,conflict,local,"head\nold\nkeep\nместный хвост\n"]) {try codec.encode(text).write(to:root.appendingPathComponent(path))}
        let index=try Data(contentsOf:root.appendingPathComponent(".git/index")),head=try await repo.run(["rev-parse","HEAD"]).stdout
        let suite="TurtleGit.PatchCodec."+UUID().uuidString,prefs=UserDefaults(suiteName:suite)!
        defer {prefs.removePersistentDomain(forName:suite)}
        prefs.set(1251,forKey:"TurtleGitMerge.LegacyCodePage");prefs.set(false,forKey:"TurtleGitMerge.UseUTF8");MergeGeneralPreferences(firstDifference:false,firstConflict:false).save(to:prefs)
        let owner=WorkingTreePatchWindowController(repository:repo,access:nil,fileAccess:nil,bytes:patch,title:"Legacy patch recovery",preferences:prefs),model=owner.model,window=owner.window!
        defer {owner.close()};window.alphaValue=0;window.orderFront(nil)
        try await wait {!model.busy && model.editor?.filtering==false}
        try require(model.editor?.document?.destination.text==patched && model.editor?.encoding(base:false) == codec,"Clean patch preview decoding")
        let files=model.review!.files,b=files.first{$0.path==paths[1]}!,c=files.first{$0.path==paths[2]}!,a=files.first{$0.path==paths[0]}!,d=files.first{$0.path==paths[3]}!
        try require(model.fileState(b)=="conflict" && model.fileInspections[b.pathBytes]?.diagnostic.contains("Preview to merge")==true,"Recovery classification used generic binary decoding")
        prefs.set(1252,forKey:"TurtleGitMerge.LegacyCodePage")
        model.previewFiles([b.id],generation:model.fileListGeneration)
        try await wait {!model.busy && model.conflictEditor?.sourceToolsAllowed==true}
        let editor=model.conflictEditor!
        try require(editor.document?.base==base && editor.document?.mine==conflict && editor.document?.theirs==patched && editor.encoding == codec,"Preview lost captured policy after preference change")
        try await capture(window)
        editor.choose(.theirs);try require(model.canSaveDraft && !editor.hasUnresolvedConflicts,"Native conflict choice")
        var saved:Bool?;model.saveDraft {saved=$0};try await wait {saved != nil && !model.busy}
        try require(saved==true && Data(contentsOf:root.appendingPathComponent(paths[1]))==codec.encode(patched),"Manual patch recovery Save bytes")
        let retiredGeneration=model.fileListGeneration
        model.patchFiles([a.id,c.id],generation:retiredGeneration)
        try await wait {!model.busy && model.fileState(a)=="patched" && model.fileState(c)=="patched"}
        try require(try Data(contentsOf:root.appendingPathComponent(paths[0]))==codec.encode(patched) && Data(contentsOf:root.appendingPathComponent(paths[2]))==codec.encode("шапка\nновое\nоставить\nместный хвост\n"),"Direct/automatic patch lost regional text or local edit")
        try require(!model.canPreviewFiles([d.id],generation:retiredGeneration),"Retired preview command remained available")
        model.patchFiles([d.id],generation:model.fileListGeneration)
        try await wait {!model.busy && model.fileResults[d.pathBytes] != nil}
        try require(model.fileResults[d.pathBytes]?.success==false && model.fileResults[d.pathBytes]?.requiresMerge==true && model.canPreviewFiles([d.id],generation:model.fileListGeneration),"Encoding failure did not retain manual Preview")
        model.previewFiles([d.id],generation:model.fileListGeneration)
        try await wait {!model.busy && model.conflictEditor?.sourceToolsAllowed==true}
        let mixed=model.conflictEditor!
        try require(mixed.encoding==codec && mixed.result=="head\n日本語\nkeep\nместный хвост\n" && !mixed.hasUnresolvedConflicts,"Mixed encoding merge result")
        mixed.changeEncoding(.utf8);saved=nil;model.saveDraft {saved=$0}
        try await wait {saved != nil && !model.busy}
        try require(saved==true && Data(contentsOf:root.appendingPathComponent(paths[3]))==Data("head\n日本語\nkeep\nместный хвост\n".utf8),"Explicit UTF8 recovery Save")
        let afterHead=try await repo.run(["rev-parse","HEAD"]).stdout
        try require(afterHead==head && Data(contentsOf:root.appendingPathComponent(".git/index"))==index,"Patch preview/apply changed HEAD/index")
        for path in paths {try require(try (FileManager.default.attributesOfItem(atPath:root.appendingPathComponent(path).path)[.posixPermissions] as? NSNumber)?.intValue==0o755,"Patch mode changed")}
        owner.close();try await wait {WorkingTreePatchWindowModel.activeOperations==0 && MergeRegexOperations.activeRequests==0}
        print("PASS patch codec family: native legacy preview/status and embedded three-way recovery, captured policy across preference changes, real manual/direct/automatic apply and unrepresentable-result Preview/UTF8 Save, stale command refusal and exact working bytes/local edits/modes with HEAD/index preserved; owned window closed")
    }
}
