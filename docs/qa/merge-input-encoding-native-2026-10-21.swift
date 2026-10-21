// SPDX-License-Identifier: GPL-2.0-or-later
import AppKit
import Darwin
import ObjectiveC
import ScreenCaptureKit
import TurtleGitCore

private extension NSWindow {
    @objc func inputEncodingHiddenOrder(_ place:NSWindow.OrderingMode,relativeTo number:Int) {
        alphaValue=0;setFrameOrigin(.init(x:-20000,y:-20000));inputEncodingHiddenOrder(place,relativeTo:number)
    }
}
@MainActor @main enum MergeInputEncodingVerification {
    struct Failure:Error,CustomStringConvertible {let description:String}
    static func require(_ condition:Bool,_ message:String,line:Int = #line)throws {if !condition{throw Failure(description:"\(line): "+message)}}
    static func unwrap<T>(_ value:T?,_ message:String)throws->T {guard let value else{throw Failure(description:message)};return value}
    static func wait(line:Int = #line,_ predicate:()->Bool)async throws {for _ in 0..<3000 {if predicate(){return};try await Task.sleep(nanoseconds:10_000_000)};throw Failure(description:"Input encoding timeout at \(line)")}
    static func views(_ root:NSView?)->[NSView] {guard let root else{return []};return [root]+root.subviews.flatMap{views($0)}}
    static func items(_ menu:NSMenu)->[NSMenuItem] {menu.items.flatMap {[$0]+($0.submenu.map{items($0)} ?? [])}}
    static func capture(_ window:NSWindow?)async throws {
        guard let directory=ProcessInfo.processInfo.environment["TURTLEGIT_INPUT_ENCODING_CAPTURES"],let window else{return}
        guard #available(macOS 14.4,*)else{throw Failure(description:"Owned capture unavailable")}
        let alpha=window.alphaValue;defer{window.alphaValue=alpha}
        window.center();window.orderFront(nil);window.alphaValue=1
        for(theme,suffix)in[(NSAppearance.Name.aqua,"light"),(.darkAqua,"dark")] {
            window.appearance=NSAppearance(named:theme);window.contentView?.layoutSubtreeIfNeeded();try await Task.sleep(nanoseconds:150_000_000)
            let content=try await SCShareableContent.currentProcess,owned=try unwrap(content.windows.first{$0.windowID==CGWindowID(window.windowNumber)},"Owned input-encoding capture missing")
            let config=SCStreamConfiguration();config.width=Int(window.frame.width*2);config.height=Int(window.frame.height*2);config.showsCursor=false;config.ignoreShadowsSingleWindow=true;config.includeChildWindows=false
            let pixels=try await SCScreenshotManager.captureImage(contentFilter:SCContentFilter(desktopIndependentWindow:owned),configuration:config)
            let bytes=try unwrap(NSBitmapImageRep(cgImage:pixels).representation(using:.png,properties:[:]),"Capture encoding failed")
            try bytes.write(to:URL(fileURLWithPath:directory).appendingPathComponent("merge-input-encoding-"+suffix+".png"))
        }
    }
    static func send(_ item:NSMenuItem)throws {let action=try unwrap(item.action,"Missing actual menu action");_ = NSApp.sendAction(action,to:item.target,from:item)}
    static func drained()->Bool {FileListComparisonSession.activeOperations==0 && MergeRegexOperations.activeRequests==0 && FileComparisonWindowModel.activeProjectionChoices==0 && MergeExternalReloadCoordinator.activeRequests==0}
    static func settled(_ model:FileComparisonWindowModel)async throws {try await wait{model.window?.contentView?.layoutSubtreeIfNeeded();return !model.busy && !model.filtering && !model.hasPendingEditorChoice && !model.confirmingQuit}}
    @MainActor final class Context {
        let base=URL(fileURLWithPath:CommandLine.arguments[1]),git=URL(fileURLWithPath:CommandLine.arguments[2])
        let suite="TurtleGit.InputEncoding."+UUID().uuidString,prefs:UserDefaults,pasteboard=NSPasteboard.withUniqueName()
        var compares:[FileComparisonWindowController]=[],merges:[TextConflictWindowController]=[],hashes:[String]=[],index=Data(),head=Data(),mergeHead=Data()
        let baseText="café\nbase\n",mineText="café\nmine\n",theirsText="café\nremote\n"
        var repo:GitRepository {GitRepository(root:base.appendingPathComponent("repository"),executable:git,askpass:nil,libgit2Configuration:.init(enabled:false))}
        var left:URL {base.appendingPathComponent("left.txt")};var right:URL {base.appendingPathComponent("right.txt")}
        init(){prefs=UserDefaults(suiteName:suite)!;prefs.set(false,forKey:"TurtleGitMerge.UseUTF8");prefs.set(false,forKey:"UseLibgit2");prefs.set(true,forKey:"ShowAppContextMenuIcons");prefs.set(1252,forKey:"TurtleGitMerge.LegacyCodePage");MergeComparisonOptions.exact.save(to:prefs);MergeGeneralPreferences(firstDifference:false,firstConflict:false).save(to:prefs)}
        func seed()async throws {
            try FileManager.default.createDirectory(at:repo.root,withIntermediateDirectories:true)
            _=try await repo.run(["init","-b","main"])
            for(key,value)in[("user.name","Input encoding QA"),("user.email","encoding@example.invalid"),("commit.gpgsign","false"),("tag.gpgsign","false"),("core.hooksPath","/dev/null"),("core.autocrlf","false")] {_=try await repo.run(["config",key,value])}
            try Data(baseText.utf8).write(to:repo.root.appendingPathComponent("file.txt"));try await repo.stage(["file.txt"]);_=try await repo.commit(message:"base");hashes.append(try await repo.rebaseCommit("HEAD").hash)
            _=try await repo.run(["branch","theirs"])
            try Data(mineText.utf8).write(to:repo.root.appendingPathComponent("file.txt"));try await repo.stage(["file.txt"]);_=try await repo.commit(message:"mine");hashes.append(try await repo.rebaseCommit("HEAD").hash)
            _=try await repo.run(["checkout","theirs"]);try Data(theirsText.utf8).write(to:repo.root.appendingPathComponent("file.txt"));try await repo.stage(["file.txt"]);_=try await repo.commit(message:"theirs")
            _=try await repo.run(["checkout","main"]);_=try await repo.run(["merge","theirs"],successfulExitCodes:0...1)
            let conflicts=try await repo.conflicts();try require(conflicts.count==1 && conflicts[0].path=="file.txt","Fixture did not create the actual three-stage conflict")
            index=try Data(contentsOf:repo.root.appendingPathComponent(".git/index"));head=try await repo.run(["rev-parse","HEAD"]).stdout;mergeHead=try await repo.run(["rev-parse","MERGE_HEAD"]).stdout
            try Data(baseText.utf8).write(to:left);try Data(mineText.utf8).write(to:right)
        }
        func compare()async throws->FileComparisonWindowController {
            let owner=FileComparisonWindowController(comparison:try WorkingFileComparison(base:left,destination:right),permissions:[],preferences:prefs)
            compares.append(owner);owner.model.commentProfileURL=base.appendingPathComponent("profiles");owner.window?.alphaValue=0;owner.window?.orderFront(nil);owner.model.load();try await settled(owner.model)
            try require(owner.model.error==nil,"Compare load failed: "+(owner.model.error ?? "nil"));return owner
        }
        func merge()async throws->TextConflictWindowController {
            let owner=TextConflictWindowController(repository:repo,access:RepositoryAccessLease(url:repo.root),path:"file.txt",preferences:prefs)
            configure(owner.model)
            merges.append(owner);owner.window?.orderFront(nil);owner.model.load();try await wait{!owner.model.busy && owner.model.document != nil && owner.model.sourceToolsAllowed}
            try require(owner.model.error==nil,"Merge load failed: "+(owner.model.error ?? "nil"));return owner
        }
        func configure(_ model:TextConflictWindowModel) {
            model.commentProfileURL=base.appendingPathComponent("profiles");model.regexDefaults=prefs;model.refreshRegexFilters()
        }
        func preserved()async throws {
            try require(try Data(contentsOf:repo.root.appendingPathComponent(".git/index"))==index,"Input decoding staged or changed conflict index")
            let currentHead=try await repo.run(["rev-parse","HEAD"]).stdout,currentMerge=try await repo.run(["rev-parse","MERGE_HEAD"]).stdout
            try require(currentHead==head && currentMerge==mergeHead,"Input decoding changed HEAD or merge operation")
        }
        func clean()async {
            compares.forEach{$0.close()};merges.forEach{$0.close()}
            for window in NSApp.windows {if let sheet=window.attachedSheet{window.endSheet(sheet,returnCode:.cancel);sheet.orderOut(nil)};window.orderOut(nil);window.close()}
            for _ in 0..<3000 {if drained() && compares.allSatisfy({!$0.model.mergeToolHasPendingWork}) && merges.allSatisfy({!$0.model.mergeToolHasPendingWork}) {break};try? await Task.sleep(nanoseconds:10_000_000)}
            prefs.removePersistentDomain(forName:suite);pasteboard.releaseGlobally()
        }
    }
    static func editor(_ owner:FileComparisonWindowController,base:Bool)throws->NSTextView {try unwrap(views(owner.window?.contentView).compactMap{$0 as? NSTextView}.first{$0.accessibilityLabel()==(base ? "Base file":"Destination file")},"Actual native comparison editor missing")}
    static func reloadItem(_ view:NSView,_ c:Context,_ encoding:ComparisonTextEncoding)throws->NSMenuItem {
        let menu:NSMenu
        if let source=view as? ComparisonContextMenuProviding {menu=source.comparisonContextMenu(defaults:c.prefs,pasteboard:c.pasteboard)}
        else if let source=view as? MergeContextMenuProviding {menu=source.mergeContextMenu(defaults:c.prefs,pasteboard:c.pasteboard)}
        else {throw Failure(description:"Actual input context menu missing")}
        let parent=try unwrap(items(menu).first{$0.title=="Reload with encoding"},"Input reload menu missing")
        try require(parent.image != nil,"Input reload source icon missing")
        let submenu=try unwrap(parent.submenu,"Input reload submenu missing")
        let item=try unwrap(submenu.items.first{$0.title==encoding.rawValue},"Selected decoder missing")
        try require(item.isEnabled,"Read-only input reload disabled");return item
    }
    static func two(_ c:Context)async throws {
        let owner=try await c.compare(),model=owner.model
        // Deliberately select a legacy decoder; automatic UTF-8 detection is
        // independent of the default-encoding preference for valid UTF-8 bytes.
        model.reloadInputEncoding(.windows1252,base:true);try await settled(model)
        model.reloadInputEncoding(.windows1252,base:false);try await settled(model)
        try require(model.document?.base.text != c.baseText && model.document?.base.encoding == .windows1252,"Fixture did not start with alternate interpretation")
        let initialBytes=model.document!.base.bytes
        try await wait{(try? editor(owner,base:true)) != nil}
        let action=try reloadItem(editor(owner,base:true),c,.utf8);try send(action);try await settled(model)
        try require(model.document?.base.text==c.baseText && model.document?.destination.text != c.mineText && model.inputEncoding(base:true) == .utf8,"Reload failed to reinterpret only selected input")
        let beforeSwap=try unwrap(model.inputEncodingReceipt(base:true),"Pre-swap decoder receipt missing")
        model.switchSides();try await settled(model)
        try require(model.document?.destination.text==c.baseText && model.document?.base.text != c.mineText && model.inputEncoding(base:false) == .utf8 && model.inputEncoding(base:true) == .windows1252,"Input codec did not follow its physical source across swap")
        let swappedGeneration=model.alignmentGeneration
        model.reloadInputEncoding(.windows1252,base:true,receipt:beforeSwap);try await settled(model)
        try require(model.alignmentGeneration==swappedGeneration && model.document?.destination.text==c.baseText,"Pre-swap input receipt retargeted other source")
        model.switchSides();try await settled(model)
        model.reloadInputEncoding(.utf8,base:false);try await settled(model)
        try require(model.document?.destination.text==c.mineText && !model.dirty,"Selected destination reload changed data or left stale draft")
        let text=model.draftText(base:true),generation=model.alignmentGeneration
        model.reloadInputEncoding(.utf16LE,base:true);try await settled(model)
        try require(model.error != nil && model.draftText(base:true)==text && model.alignmentGeneration==generation && model.inputEncoding(base:true) == .utf8,"Failed decoder replaced accepted view or override")
        model.error=nil;try await wait{owner.window?.attachedSheet==nil};model.load();try await settled(model)
        try require(model.document?.base.text==c.baseText && model.document?.destination.text==c.mineText && model.document?.base.bytes==initialBytes,"F5 lost input overrides/raw bytes")
        try require(try Data(contentsOf:c.left)==Data(c.baseText.utf8) && Data(contentsOf:c.right)==Data(c.mineText.utf8),"Reinterpretation wrote source files")
        try await wait{(try? editor(owner,base:true).string.contains("café"))==true && (try? editor(owner,base:false).string.contains("café"))==true && views(owner.window?.contentView).filter{$0.identifier?.rawValue=="Base encoding" || $0.identifier?.rawValue=="Mine encoding"}.count==2}
        try await capture(owner.window)
        let acceptedReceipt=try unwrap(model.inputEncodingReceipt(base:true),"Accepted source receipt missing")
        let replacement=try await c.compare(),replacementGeneration=replacement.model.alignmentGeneration
        let replacementText=replacement.model.document?.base.text
        replacement.model.reloadInputEncoding(.utf8,base:true,receipt:acceptedReceipt);try await settled(replacement.model)
        try require(replacement.model.alignmentGeneration==replacementGeneration && replacement.model.document?.base.text==replacementText && replacement.model.inputEncoding(base:true)==nil,"Old document receipt changed a new comparison")
        let raw=c.base.appendingPathComponent("undecoded.txt"),plain=c.base.appendingPathComponent("plain.txt"),rawBytes=Data([0,0x4e])
        try rawBytes.write(to:raw);try Data("plain\n".utf8).write(to:plain)
        let binary=FileComparisonWindowController(comparison:try WorkingFileComparison(base:raw,destination:plain),permissions:[],preferences:c.prefs)
        c.compares.append(binary);binary.model.commentProfileURL=c.base.appendingPathComponent("profiles");binary.window?.alphaValue=0;binary.window?.orderFront(nil);binary.model.load();try await settled(binary.model)
        try require(binary.model.document?.base.text==nil && binary.model.inputEncodingReceipt(base:true) != nil,"Undecoded regular source has no input reload route")
        binary.model.reloadInputEncoding(.utf16LE,base:true);try await settled(binary.model)
        try require(binary.model.document?.base.text=="一" && binary.model.document?.base.bytes==rawBytes && binary.model.alignment != nil,"Explicit decoder could not recover initially undecoded raw bytes")
    }
    static func history(_ c:Context)async throws {
        let index=try Data(contentsOf:c.repo.root.appendingPathComponent(".git/index")),working=try Data(contentsOf:c.repo.root.appendingPathComponent("file.txt"))
        let snapshot=try await c.repo.revisionComparison(from:.revision(c.hashes[0]),to:.revision(c.hashes[1]))
        let owner=FileComparisonWindowController(repository:c.repo,access:RepositoryAccessLease(url:c.repo.root),snapshot:snapshot,path:"file.txt",preferences:c.prefs)
        c.compares.append(owner);owner.window?.orderFront(nil);owner.model.load();try await settled(owner.model)
        let model=owner.model;try require(!model.canTransfer(toBase:true) && !model.canTransfer(toBase:false),"Historical fixture writable")
        model.reloadInputEncoding(.utf8,base:true);try await settled(model);model.reloadInputEncoding(.utf8,base:false);try await settled(model)
        try require(model.document?.base.text==c.baseText && model.document?.destination.text==c.mineText,"Historical immutable inputs cannot be reinterpreted")
        let stale=try unwrap(model.inputEncodingReceipt(base:true),"Input receipt missing")
        model.load();try await settled(model);let generation=model.alignmentGeneration
        model.reloadInputEncoding(.windows1252,base:true,receipt:stale);try await settled(model)
        try require(model.document?.base.text==c.baseText && model.alignmentGeneration==generation,"Old menu receipt survived reload")
        try require(try Data(contentsOf:c.repo.root.appendingPathComponent(".git/index"))==index && Data(contentsOf:c.repo.root.appendingPathComponent("file.txt"))==working,"Historical reload modified conflict inputs/index")
    }
    static func three(_ c:Context)async throws {
        let index=try Data(contentsOf:c.repo.root.appendingPathComponent(".git/index")),working=try Data(contentsOf:c.repo.root.appendingPathComponent("file.txt"))
        let owner=try await c.merge(),model=owner.model
        for role in [TextConflictWindowModel.InputEncodingRole.base,.mine,.theirs] {model.reloadInputEncoding(.windows1252,role:role);try await wait{!model.busy && model.inputEncodingReloadAvailable}}
        try require(model.document?.mine != c.mineText,"Three-pane fixture already used UTF-8")
        let outputEncoding=model.encoding
        try await wait{model.inputEncodingReloadAvailable && views(owner.window?.contentView).compactMap{$0 as? NSTextView}.contains{$0.accessibilityLabel()?.hasPrefix("Mine")==true}}
        let mineView=try unwrap(views(owner.window?.contentView).compactMap{$0 as? NSTextView}.first{$0.accessibilityLabel()?.hasPrefix("Mine")==true},"Actual Mine editor missing")
        let mineAction=try reloadItem(mineView,c,.utf8);try send(mineAction);try await wait{!model.busy && model.inputEncodingReloadAvailable}
        let acceptedLayout=model.sourceLayoutRevision;try send(mineAction)
        try require(model.sourceLayoutRevision==acceptedLayout,"Consumed source menu callback reloaded twice")
        for role in [TextConflictWindowModel.InputEncodingRole.base,.theirs] {model.reloadInputEncoding(.utf8,role:role);try await wait{!model.busy && model.inputEncodingReloadAvailable}}
        try require(model.document?.base==c.baseText && model.document?.mine==c.mineText && model.document?.theirs==c.theirsText,"Three-pane role decoding lost raw inputs")
        try require(model.sourceComparison != nil && model.result.contains("café") && !model.result.contains("Ã"),"Actual merge was not regenerated with decoded inputs")
        try require(model.encoding==outputEncoding && model.inputEncodingOverrides.base == .utf8 && model.inputEncodingOverrides.mine == .utf8 && model.inputEncodingOverrides.theirs == .utf8,"Input decoding changed output format or lost accepted roles")
        let stale=try unwrap(model.captureInputEncoding(role:.mine),"Captured source decoder missing")
        var sourceChild:FileComparisonWindowController?
        model.sourceComparisonPresentation={child in sourceChild=child;c.compares.append(child);child.model.commentProfileURL=c.base.appendingPathComponent("profiles");child.model.regexDefaults=c.prefs}
        model.compareSourceWithBase(mine:true)
        try await wait{sourceChild?.model.document != nil && sourceChild?.model.busy==false}
        let childDocument=try unwrap(sourceChild?.model.document,"Actual Compare with Base child missing")
        try require(childDocument.base.bytes==Data(c.baseText.utf8) && childDocument.destination.bytes==Data(c.mineText.utf8) && childDocument.base.text==c.baseText && childDocument.destination.text==c.mineText,"Source comparison lost raw bytes or accepted input decoders")
        sourceChild?.close()
        let result=model.result,source=model.document!.mine
        model.reloadInputEncoding(.utf16LE,role:.base);try await wait{!model.busy}
        try require(model.error != nil && model.result==result && model.document?.mine==source,"Failed merge decode replaced accepted merge")
        model.error=nil;try await wait{owner.window?.attachedSheet==nil};model.load();try await wait{!model.busy && model.inputEncodingReloadAvailable}
        try require(model.document?.mine==c.mineText && model.document?.theirs==c.theirsText,"Merge F5 lost forced inputs")
        let afterReload=model.sourceLayoutRevision;model.applyInputEncoding(stale,encoding:.windows1252)
        try require(model.sourceLayoutRevision==afterReload && model.document?.mine==c.mineText,"Retained input decoder survived F5")
        try require(try Data(contentsOf:c.repo.root.appendingPathComponent(".git/index"))==index && Data(contentsOf:c.repo.root.appendingPathComponent("file.txt"))==working,"Input encoding wrote result or staged conflict")
        // Standalone three-file Merge must share the same source interpretation.
        let theirs=c.base.appendingPathComponent("theirs.txt"),bom=Data([0xef,0xbb,0xbf])
        try (bom+Data(c.baseText.utf8)).write(to:c.left);try (bom+Data(c.mineText.utf8)).write(to:c.right);try (bom+Data(c.theirsText.utf8)).write(to:theirs)
        let standalone=TextConflictWindowController(repository:c.repo,access:nil,path:c.right.path,workingMerge:try WorkingTextMerge(base:c.left,theirs:theirs,mine:c.right),preferences:c.prefs)
        c.configure(standalone.model);standalone.model.chooseReload={.discard}
        c.merges.append(standalone);standalone.window?.orderFront(nil);standalone.model.load();try await wait{!standalone.model.busy && standalone.model.inputEncodingReloadAvailable}
        for role in [TextConflictWindowModel.InputEncodingRole.base,.mine,.theirs] {standalone.model.reloadInputEncoding(.utf8,role:role);try await wait{!standalone.model.busy && standalone.model.inputEncodingReloadAvailable}}
        try require(standalone.model.document?.base==c.baseText && standalone.model.document?.mine==c.mineText && standalone.model.document?.theirs==c.theirsText,"Standalone source decoding differs")
        var bomChild:FileComparisonWindowController?
        standalone.model.sourceComparisonPresentation={child in bomChild=child;c.compares.append(child);child.model.commentProfileURL=c.base.appendingPathComponent("profiles");child.model.regexDefaults=c.prefs}
        standalone.model.compareSourceWithBase(mine:true);try await wait{bomChild?.model.document != nil && bomChild?.model.busy==false}
        let bomDocument=try unwrap(bomChild?.model.document,"BOM source comparison missing")
        try require(bomDocument.base.bytes==bom+Data(c.baseText.utf8) && bomDocument.destination.bytes==bom+Data(c.mineText.utf8) && bomDocument.base.text==c.baseText && bomDocument.destination.text==c.mineText,"BOM-normalized input handoff changed raw bytes or inserted BOM text")
    }
    static func ownership(_ c:Context)async throws {
        let owner=try await c.compare(),model=owner.model
        model.activatePane(base:false);model.editingEnabled=true;try await wait{model.canTransfer(toBase:false)}
        let view=try editor(owner,base:false);view.insertText("draft",replacementRange:(view.string as NSString).range(of:"mine"));try await settled(model)
        let draft=model.draftText(base:false),generation=model.alignmentGeneration,undo=model.canUndo
        var reply:((NSApplication.ModalResponse)->Void)?,question:NSAlert?
        model.presentProjectionQuestion={alert,parent,completion in question=alert;reply=completion;parent.beginSheet(alert.window,completionHandler:completion)}
        model.reloadInputEncoding(.utf8,base:true);try await wait{question?.window.sheetParent === owner.window}
        try require(!owner.windowShouldClose(owner.window!) && TurtleGitApplicationDelegate().applicationShouldTerminate(NSApp) == .terminateCancel,"Encoding reload decision lost native owner")
        let cancel=try unwrap(question?.buttons.firstIndex{$0.title=="Cancel"},"Cancel action missing")
        reply?(.init(rawValue:NSApplication.ModalResponse.alertFirstButtonReturn.rawValue+cancel));try await settled(model)
        try require(model.draftText(base:false)==draft && model.alignmentGeneration==generation && model.canUndo==undo && model.inputEncoding(base:true) != .utf8,"Cancel changed draft/history/input codec")
        question=nil;model.reloadInputEncoding(.utf8,base:true);try await wait{question != nil}
        let discard=try unwrap(question?.buttons.firstIndex{$0.title=="Don’t Save"},"Discard action missing")
        reply?(.init(rawValue:NSApplication.ModalResponse.alertFirstButtonReturn.rawValue+discard));try await settled(model)
        try require(model.document?.base.text==c.baseText && !model.dirty && !model.canUndo,"Accepted reload did not reset draft/history")
        model.activatePane(base:false);model.editingEnabled=true;try await wait{model.canTransfer(toBase:false)}
        let saveEditor=try editor(owner,base:false)
        saveEditor.insertText("saved",replacementRange:(saveEditor.string as NSString).range(of:"mine"));try await settled(model)
        let savedText=model.draftText(base:false),savedEncoding=try unwrap(model.encoding(base:false),"Save input codec missing")
        let savedBytes=try savedEncoding.encode(savedText)
        question=nil;model.reloadInputEncoding(.utf8,base:true);try await wait{question != nil}
        let save=try unwrap(question?.buttons.firstIndex{$0.title=="Save"},"Actual Save-and-reload choice missing")
        reply?(.init(rawValue:NSApplication.ModalResponse.alertFirstButtonReturn.rawValue+save));try await settled(model)
        try require(try Data(contentsOf:c.right)==savedBytes,"Save-and-reload did not save actual edited source bytes")
        try require(model.document?.base.text==c.baseText && model.draftText(base:false)==savedText && !model.dirty && !model.canUndo,"Save-and-reload failed to accept refreshed inputs and reset Undo")
        let stale=try unwrap(model.inputEncodingReceipt(base:true),"Captured decoder owner missing")
        owner.close();model.reloadInputEncoding(.windows1252,base:true,receipt:stale)
        try await wait{drained()};try require(model.document?.base.text==c.baseText,"Retired receipt changed source")
        let merge=try await c.merge(),three=merge.model
        three.result="unsaved result\n";var decisions=0;three.chooseReload={decisions += 1;return .cancel};let original=three.document!.mine
        try await wait{three.inputEncodingReloadAvailable}
        three.reloadInputEncoding(.utf8,role:.mine);try await wait{decisions==1 && !three.busy && three.inputEncodingReloadAvailable}
        try require(three.result=="unsaved result\n" && three.document?.mine==original,"Three-pane Cancel discarded result")
        three.chooseReload={decisions += 1;return .discard};three.reloadInputEncoding(.utf8,role:.mine);try await wait{decisions==2 && !three.busy && three.inputEncodingReloadAvailable && three.inputEncodingOverrides.mine == .utf8}
        try require(three.document?.mine==c.mineText && three.result != "unsaved result\n","Three-pane accepted reload failed")
        let index=try Data(contentsOf:c.repo.root.appendingPathComponent(".git/index"))
        three.result="saved draft café\n";three.chooseReload={.save};try await wait{three.inputEncodingReloadAvailable};three.reloadInputEncoding(.utf8,role:.theirs)
        try await wait{!three.busy && !three.preparing && three.inputEncodingOverrides.theirs == .utf8}
        let savedResultBytes=try Data(contentsOf:c.repo.root.appendingPathComponent("file.txt"))
        let expectedSaved=try three.encoding.encode("saved draft café\n"),currentIndex=try Data(contentsOf:c.repo.root.appendingPathComponent(".git/index"))
        try require(savedResultBytes==expectedSaved && currentIndex==index,"Save and Reload lost draft output or staged conflict")
        // Actual owned dirty question must keep its sheets/work through close;
        // late Ignore-style affirmative replies cannot adopt a decoder.
        three.result="late dirty draft\n";three.chooseReload=nil
        var mergeReply:((NSApplication.ModalResponse)->Void)?,mergeQuestion:NSAlert?
        three.presentInputReloadQuestion={parent,alert,reply in mergeQuestion=alert;mergeReply=reply;parent.beginSheet(alert.window)}
        try await wait{three.inputEncodingReloadAvailable}
        three.reloadInputEncoding(.windows1252,role:.mine);try await wait{mergeQuestion?.window.sheetParent === merge.window}
        let acceptedMine=three.inputEncodingOverrides.mine
        try require(three.mergeToolHasPendingWork,"Owned reload question lost pending accounting")
        merge.close();mergeReply?(.alertSecondButtonReturn);mergeReply?(.alertSecondButtonReturn)
        try await wait{drained() && mergeQuestion?.window.sheetParent==nil}
        try require(three.inputEncodingOverrides.mine==acceptedMine && three.result=="late dirty draft\n","Retired dirty reload adopted late reply")
    }
    static func main()async throws {
        let visual=ProcessInfo.processInfo.environment["TURTLEGIT_INPUT_ENCODING_CAPTURES"] != nil
        NSApplication.shared.setActivationPolicy(visual ? .regular:.prohibited)
        let normal=class_getInstanceMethod(NSWindow.self,#selector(NSWindow.order(_:relativeTo:)))!,hidden=class_getInstanceMethod(NSWindow.self,#selector(NSWindow.inputEncodingHiddenOrder(_:relativeTo:)))!
        if !visual {method_exchangeImplementations(normal,hidden)};defer{if !visual{method_exchangeImplementations(normal,hidden)}}
        let c=Context();DialogGeometry.install(preferences:c.prefs);defer{DialogGeometry.install(preferences:.standard)}
        do {
            try await c.seed();let which=CommandLine.arguments[3]
            switch which {case "two":try await two(c);case "history":try await history(c);case "three":try await three(c);case "ownership":try await ownership(c);default:throw Failure(description:"Unknown case")}
            try await c.preserved()
            await c.clean();try require(drained() && c.compares.allSatisfy{!$0.model.mergeToolHasPendingWork} && c.merges.allSatisfy{!$0.model.mergeToolHasPendingWork} && NSApp.windows.allSatisfy{!$0.isVisible && $0.attachedSheet==nil},"Native encoding receiver did not drain")
            print("PASS: Merge input encoding "+which)
        }catch{await c.clean();throw error}
    }
}
