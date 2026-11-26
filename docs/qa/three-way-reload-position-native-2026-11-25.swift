// SPDX-License-Identifier: GPL-2.0-or-later
import AppKit
import Darwin
import ObjectiveC
import TurtleGitCore

private extension NSWindow {
    @objc func threeWayReloadQuietOrder(_ order:NSWindow.OrderingMode,relativeTo number:Int) {alphaValue=0;setFrameOrigin(.init(x:-24000,y:-24000));threeWayReloadQuietOrder(order,relativeTo:number)}
    @objc func threeWayReloadQuietSheet(_ child:NSWindow,completionHandler:((NSApplication.ModalResponse)->Void)?) {child.alphaValue=0;child.setFrameOrigin(.init(x:-24000,y:-24000));threeWayReloadQuietSheet(child,completionHandler:completionHandler)}
}
@MainActor @main enum ThreeWayReloadPositionVerification {
    struct Failure:Error,CustomStringConvertible {let description:String}
    static func require(_ value:Bool,_ message:String)throws {if !value {throw Failure(description:message)}}
    static func views(_ view:NSView?)->[NSView] {guard let view else{return []};return [view]+view.subviews.flatMap{views($0)}}
    final class Gate:@unchecked Sendable {
        private let lock=NSLock();private var continuation:CheckedContinuation<Void,Never>?,started=false
        var entered:Bool {lock.lock();defer{lock.unlock()};return started}
        func hold()async {await withCheckedContinuation {reply in lock.lock();started=true;continuation=reply;lock.unlock()}}
        func release(){lock.lock();let reply=continuation;continuation=nil;lock.unlock();reply?.resume()}
    }
    @MainActor final class Context {
        let root:URL,git:URL,prefs:UserDefaults,curved:Bool,suite="TurtleGit.ThreeWayReload."+UUID().uuidString
        var repository:GitRepository!,owner:TextConflictWindowController!
        var index=Data(),head="",initial:[URL:Data]=[:],gates:[Gate]=[]
        var model:TextConflictWindowModel {owner.model}
        var base:URL {root.appendingPathComponent("base.txt")}
        var mine:URL {root.appendingPathComponent("mine.txt")}
        var theirs:URL {root.appendingPathComponent("theirs.txt")}
        var output:URL {root.appendingPathComponent("merged.txt")}
        init(root:URL,git:URL,curved:Bool=false){self.root=root;self.git=git;self.curved=curved;prefs=UserDefaults(suiteName:suite)!}
        func text(count:Int=360,side:Int=0)->String {
            (0..<count).map {line in
                if line==120 && (side==1 || side==3){return "Mine authored change 120\n"}
                if line==200 && (side==2 || side==3){return "Theirs authored change 200\n"}
                return String(format:"row %03d – 🦎 café e\u{301} 雪 ",line)+String(repeating:"long reading content ",count:8)+"\n"
            }.joined()
        }
        func setup(failInitial:Bool=false)async throws {
            try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
            prefs.set(false,forKey:"UseLibgit2");prefs.set(false,forKey:"EnableGravatar");prefs.set(false,forKey:"TurtleGitMerge.AutoAdd");prefs.set(curved,forKey:"TurtleGit.Comparison.CurvedInterface");prefs.set(false,forKey:"TurtleGitMerge.WrapLines")
            MergeGeneralPreferences(firstDifference:true,firstConflict:true).save(to:prefs)
            repository=GitRepository(root:root,executable:git,askpass:nil,libgit2Configuration:.init(enabled:false))
            _=try await repository.run(["init","--template=","-b","main"])
            for(key,value)in[("user.name","Reload QA"),("user.email","reload@example.invalid"),("commit.gpgsign","false"),("core.hooksPath","/dev/null")] {_=try await repository.run(["config",key,value])}
            for(url,side)in[(base,0),(mine,1),(theirs,2),(output,3)] {let bytes=Data(text(side:side).utf8);try bytes.write(to:url);initial[url]=bytes}
            try await repository.stage(["."]);_=try await repository.commit(message:"Private three-way inputs")
            head=try await repository.rebaseCommit("HEAD").hash;index=try Data(contentsOf:root.appendingPathComponent(".git/index"))
            owner=TextConflictWindowController(repository:repository,access:nil,path:"merged.txt",workingMerge:try WorkingTextMerge(base:base,theirs:theirs,mine:mine,merged:output),preferences:prefs,deferInitialLoad:true)
            owner.window?.alphaValue=0;owner.window?.setFrameOrigin(.init(x:-24000,y:-24000));owner.externalReload?.isActive={_ in false}
            // The actual standalone entry binds its accepted output before
            // loading. A bare WorkingTextMerge controller intentionally asks
            // for a destination on first Save and is a different workflow.
            guard let invocation=try MergeToolInvocation.parse(arguments:["--merge-tool","--base",base.path,"--theirs",theirs.path,"--mine",mine.path,"--merged",output.path],currentDirectory:root.path) else {throw Failure(description:"Missing authored four-file Merge invocation")}
            try model.configureMergeTool(invocation)
            try require(model.resultPath==output.path,"Standalone invocation did not bind exact authored output")
            if failInitial {model.prepareReload={_ in throw Failure(description:"authored initial read failure")}}
            owner.showWindow(nil);model.beginTransferredDocument()
            if failInitial {
                try await wait("actual first read failed"){!model.busy && !model.preparing && model.reloadPreparationPending==0 && model.document==nil && model.error != nil}
            } else {try await ready("initial fresh owner")}
        }
        func current(_ role:TextConflictPaneRole)throws->NSTextView {
            let pane=role == .theirs ? 1:role == .mine ? 2:3
            guard let view=views(owner.window?.contentView).compactMap({$0 as? NSTextView}).first(where:{view in
                (view as? MergeFindProviding)?.mergeFindPaneID==pane && (role != .mine || !prefs.bool(forKey:"TurtleGit.Comparison.CurvedInterface") || view.accessibilityLabel()=="Mine") && (view as? MergeContextMenuProviding)?.mergeSourceRowsReady==true && view.window === owner.window && !view.isHiddenOrHasHiddenAncestor
            }) else {throw Failure(description:"Missing actual native pane \(role); "+diagnostic())}
            return view
        }
        func diagnostic()->String {
            let panes=views(owner?.window?.contentView).compactMap{$0 as? NSTextView}.filter{!$0.isFieldEditor}.map{"pane=\(($0 as? MergeFindProviding)?.mergeFindPaneID ?? -1),range=\($0.selectedRange()),length=\($0.string.utf16.count),ready=\(($0 as? MergeContextMenuProviding)?.mergeSourceRowsReady==true),viewport=\(String(describing:$0.enclosingScrollView?.contentView.bounds))"}
            let sheet=owner?.window?.attachedSheet
            let sheetActions=views(sheet?.contentView).compactMap{$0 as? NSButton}.prefix(8).map{"\($0.title):\($0.isEnabled)"}
            let sheetText=views(sheet?.contentView).compactMap{$0 as? NSTextField}.prefix(6).map{String($0.stringValue.prefix(160))}
            return "sheetClass=\(sheet.map{String(describing:type(of:$0))} ?? "nil"),sheetActions=\(sheetActions),sheetText=\(sheetText),resultPath=\(model.resultPath),disposition=\(model.reloadPositionDisposition),busy=\(model.busy),preparing=\(model.preparing),pending=\(model.reloadPositionPending),document=\(model.documentRevision),layout=\(model.sourceLayoutRevision),selection=\(String(describing:model.selectionRequest)),error=\(String(reflecting:model.error)),sheet=\(owner.window?.attachedSheet != nil),panes=\(panes)"
        }
        func wait(_ phase:String,_ predicate:()->Bool)async throws {
            for _ in 0..<2500 {owner.window?.contentView?.layoutSubtreeIfNeeded();if predicate(){return};try await Task.sleep(nanoseconds:10_000_000)}
            throw Failure(description:"Three-way Reload timeout \(phase): "+diagnostic())
        }
        func ready(_ phase:String,restored:Bool=false)async throws {
            try await wait(phase){
                guard !model.busy,!model.preparing,model.nativeEditorReady,!model.reloadPositionPending,
                      !model.lineWrapping.isGeometryPending,model.selectionRequest==nil,model.editorConfigLoading.isEmpty,
                      model.reloadPreparationPending==0,owner.window?.attachedSheet==nil else{return false}
                if restored && !model.reloadPositionDisposition.hasPrefix("restored document=\(model.documentRevision),layout=\(model.sourceLayoutRevision),") {return false}
                return [TextConflictPaneRole.theirs,.mine,.result].allSatisfy {role in
                    guard let view=try? current(role),let clip=view.enclosingScrollView?.contentView else{return false}
                    return (view as? MergeFindProviding)?.mergeFindAllowed==true && clip.bounds.width>0 && clip.bounds.height>0
                }
            }
        }
        func position(_ role:TextConflictPaneRole)throws->MergeEditorReloadPosition {
            let view=try current(role)
            guard let scroll=view.enclosingScrollView,let position=MergeEditorReloadPosition.capture(view:view,scroll:scroll,cells:(view as? MergePaneInputTextView)?.paneInputCells) else{throw Failure(description:"Missing native position")}
            return position
        }
        func author(_ role:TextConflictPaneRole = .mine,line:Int=280,top:Int=260) throws -> MergeEditorReloadPosition {
            try require(model.focusPresentationPane(role),"Actual native pane focus refused")
            let view=try current(role),row=String(format:"row %03d – 🦎 ",line),topText=String(format:"row %03d –",top)
            let range=(view.string as NSString).range(of:row),topRange=(view.string as NSString).range(of:topText)
            try require(range.location != NSNotFound && topRange.location != NSNotFound,"Authored logical row absent")
            let caret=range.location+row.utf16.count
            (view as? MergePaneInputTextView)?.paneInputLayout.reveal(selection:NSRange(location:topRange.location,length:max(0,caret-topRange.location)),in:view)
            view.setSelectedRange(NSRange(location:caret,length:0))
            let scroll=view.enclosingScrollView!,layout=view.layoutManager!,container=view.textContainer!
            layout.ensureLayout(for:container)
            let glyph=layout.glyphIndexForCharacter(at:topRange.location),rect=layout.lineFragmentRect(forGlyphAt:glyph,effectiveRange:nil)
            var bounds=scroll.contentView.bounds;bounds.origin=NSPoint(x:90,y:rect.minY+view.textContainerOrigin.y)
            scroll.contentView.scroll(to:scroll.contentView.constrainBoundsRect(bounds).origin);scroll.reflectScrolledClipView(scroll.contentView)
            let accepted=try position(role)
            try require(accepted.line==line && accepted.column==row.utf16.count && accepted.topLine==top,"Authored source line/UTF16/top not actually installed: "+diagnostic())
            return accepted
        }
        func classicReloadExpected(_ role:TextConflictPaneRole)throws->MergeEditorReloadPosition {
            let caret=try position(role),right=try position(.mine)
            // MainFrm captures Right's logical top for ScrollAllToLine; an
            // independently authored Result viewport is not that anchor.
            return MergeEditorReloadPosition(line:caret.line,column:caret.column,topLine:right.topLine)
        }
        func assertCanonicalViewport(_ phase:String,allPanes:Bool=false,resetLeading:Bool=true)throws {
            let canonical=(try current(.mine)).enclosingScrollView!.contentView.bounds.minY
            for role in [TextConflictPaneRole.theirs,.mine,.result] {
                let view=try current(role)
                if !allPanes && (view as? MergePaneInputTextView)?.paneInputCells==nil {continue}
                let scroll=view.enclosingScrollView!,clip=scroll.contentView
                var proposed=clip.bounds
                proposed.origin=NSPoint(x:resetLeading ? -clip.contentInsets.left:clip.bounds.minX,y:canonical)
                let expected=clip.constrainBoundsRect(proposed).origin
                let actual=clip.bounds.origin
                var details:[String]=[]
                details.append("phase=\(phase),role=\(role),canonicalY=\(canonical),proposed=\(proposed),expected=\(expected),actual=\(actual)")
                details.append("scrollFrame=\(scroll.frame),clipFrame=\(clip.frame),clipBounds=\(clip.bounds),insets=\(clip.contentInsets),visible=\(scroll.documentVisibleRect)")
                details.append("documentFrame=\(view.frame),documentBounds=\(view.bounds),viewportHeight=\(clip.bounds.height),documentMaxY=\(view.frame.maxY),heightMinusViewport=\(view.frame.maxY-clip.bounds.height)")
                // All panes receive Right's exact Y. Native constraints alone
                // may clamp a taller peer earlier at EOF; never approximate
                // that boundary with an arbitrary inter-pane tolerance.
                try require(actual==expected,"Canonical Reload viewport differs from native per-pane constraint: "+details.joined(separator:"; ")+"; "+diagnostic())
            }
        }
        func assertPosition(_ role:TextConflictPaneRole,_ expected:MergeEditorReloadPosition,unchangedOrigin:NSPoint?=nil,phase:String = #function,line:UInt = #line)throws {
            let location="phase=\(phase),caller=\(line),disposition=\(model.reloadPositionDisposition); "
            let actual=try position(role),view=try current(role)
            try require(actual.line==expected.line && actual.column==expected.column && actual.topLine==expected.topLine,"Logical Reload position changed: expected=\(expected.line):\(expected.column)/\(expected.topLine),actual=\(actual.line):\(actual.column)/\(actual.topLine); "+diagnostic())
            let clip=view.enclosingScrollView!.contentView
            if let unchangedOrigin {
                try require(clip.bounds.origin==unchangedOrigin,"Cancelled Reload changed raw viewport: expected=\(unchangedOrigin),actual=\(clip.bounds.origin); "+diagnostic())
            } else {
                try require(abs(clip.bounds.minX+clip.contentInsets.left)<0.01,location+"Reload did not reveal character zero: rawX=\(clip.bounds.minX),leadingInset=\(clip.contentInsets.left); "+diagnostic())
            }
            if !prefs.bool(forKey:"TurtleGit.Comparison.CurvedInterface") {
                try assertCanonicalViewport(phase,resetLeading:unchangedOrigin==nil)
            }
            try require(owner.window?.firstResponder === view,"Reload lost the active native pane")
            try require(!model.canChooseConflict,"Unchanged restored row retained unrelated conflict-choice ownership: "+diagnostic())
            // Ordinary caret navigation owns conflict refusal, but source-row
            // replacement requires an explicit text/block selection. Reload
            // collapses that selection and must not invent a selected block.
            let block=(view as? MergeBlockSelecting)?.mergeSelectedBlockRange
            let metadata="role=\(role),logical=\(actual.line):\(actual.column)/\(actual.topLine),native=\(view.selectedRange()),block=\(String(describing:block)),modelCaret=\(model.caret),selectedConflict=\(model.selectedConflict),cells=\((view as? MergePaneInputTextView)?.paneInputCells?.count ?? -1),sourceTools=\(model.sourceToolsAllowed),mutations=\(model.sourceMutationsAllowed),chooseBlock=\(model.canChooseSourceBlock),chooseConflict=\(model.canChooseConflict)"
            try require(view.selectedRange().length==0 && block==nil,"Reload invented a source selection: "+metadata+"; "+diagnostic())
            try require(!model.canChooseSourceBlock && model.currentSourceBlockCommand(choice:.mine)==nil,"Collapsed restored caret admitted source replacement: "+metadata+"; "+diagnostic())
            if role == .result {
                let prefix=String(format:"row %03d – 🦎 ",expected.line),range=(model.result as NSString).range(of:prefix)
                try require(range.location != NSNotFound && model.caret==NSRange(location:range.location+expected.column,length:0),"Restored result caret did not synchronize serialized model position")
            }
        }
        func f5(expectReadStart:Bool=false)throws {
            let commands=owner.editorCommandMenu!,menu=NSMenu(title:"Private F5 owner"),oldMenu=commands.applicationMenu,oldKey=commands.keyWindow
            commands.applicationMenu={menu};commands.keyWindow={self.owner.window};commands.install()
            defer{commands.remove();commands.applicationMenu=oldMenu;commands.keyWindow=oldKey}
            func items(_ menu:NSMenu)->[NSMenuItem]{menu.items+menu.items.flatMap{$0.submenu.map(items) ?? []}}
            guard let reload=items(menu).first(where:{$0.title==NSLocalizedString("Reload",comment:"")}),commands.validateMenuItem(reload),reload.image != nil else {throw Failure(description:"Actual F5 Reload menu disabled: "+diagnostic())}
            let event=NSEvent.keyEvent(with:.keyDown,location:.zero,modifierFlags:[],timestamp:ProcessInfo.processInfo.systemUptime,windowNumber:owner.window!.windowNumber,context:nil,characters:"\u{f708}",charactersIgnoringModifiers:"\u{f708}",isARepeat:false,keyCode:96)!
            try require(owner.window!.performKeyEquivalent(with:event),"Actual native F5 was not consumed: "+diagnostic())
            if expectReadStart {try require(model.busy && model.preparing,"Consumed initial-retry F5 did not start an owned fresh read: "+diagnostic())}
        }
        func menuReload()throws {
            let commands=owner.editorCommandMenu!,menu=NSMenu(title:"Private Reload owner"),oldMenu=commands.applicationMenu,oldKey=commands.keyWindow
            commands.applicationMenu={menu};commands.keyWindow={self.owner.window};commands.install()
            defer{commands.remove();commands.applicationMenu=oldMenu;commands.keyWindow=oldKey}
            func items(_ menu:NSMenu)->[NSMenuItem]{menu.items+menu.items.flatMap{$0.submenu.map(items) ?? []}}
            guard let item=items(menu).first(where:{$0.title==NSLocalizedString("Reload",comment:"")}),commands.validateMenuItem(item),item.image != nil else {throw Failure(description:"Current native Reload menu missing/disabled")}
            try require(NSApp.sendAction(item.action!,to:item.target,from:item),"Actual Reload menu failed to dispatch")
        }
        @discardableResult func button(_ title:String)async throws->NSWindow {
            try await wait("native Reload choice \(title)"){owner.window?.attachedSheet != nil}
            guard let sheet=owner.window?.attachedSheet,let button=views(sheet.contentView).compactMap({$0 as? NSButton}).first(where:{$0.title==title && $0.isEnabled}) else {throw Failure(description:"Missing actual native button "+title)}
            button.performClick(nil)
            return sheet
        }
        func preserved()async throws {
            try require(try await repository.rebaseCommit("HEAD").hash==head,"Reload changed HEAD")
            try require(try Data(contentsOf:root.appendingPathComponent(".git/index"))==index,"Reload changed index")
        }
        func clean()async {
            gates.forEach{$0.release()}
            if let owner {NativeOwnedWindowCleanup.close([owner.window!],returnCode:.abort);owner.close()}
            for _ in 0..<2500 {if owner == nil || !model.mergeToolHasPendingWork {break};try? await Task.sleep(nanoseconds:10_000_000)}
            prefs.removePersistentDomain(forName:suite)
        }
    }
    static func verify(base:URL,git:URL)async throws {
        try FileManager.default.createDirectory(at:base,withIntermediateDirectories:true)
        let retry=Context(root:base.appendingPathComponent("initial-read-retry"),git:git)
        do {
            try await retry.setup(failInitial:true)
            retry.model.prepareReload={try await $0()};retry.model.error=nil
            try await retry.wait("first-read error sheet detached"){retry.owner.window?.attachedSheet==nil}
            try retry.f5(expectReadStart:true);try await retry.ready("first successful F5 is fresh navigation")
            let first=try retry.position(.result)
            try require(first.line==120 && first.column==0,"F5 recovery suppressed fresh configured initial navigation")
            try await retry.preserved();await retry.clean()
        }catch{await retry.clean();throw error}
        let c=Context(root:base.appendingPathComponent("normal"),git:git)
        do {
            try await c.setup()
            let unhosted=TextConflictWindowModel(repository:c.repository,access:nil,path:"merged.txt")
            defer{unhosted.retire()}
            unhosted.comparisonDefaults=c.prefs;unhosted.workingMerge=c.model.workingMerge;unhosted.document=c.model.document
            unhosted.reload()
            try require(!unhosted.reloadPositionPending,"Unhosted model queued an unconsumable position receipt")
            try await c.wait("unhosted read drains without position authority"){!unhosted.busy && !unhosted.preparing && unhosted.reloadPreparationPending==0}
            try require(!unhosted.reloadPositionPending,"Unhosted completed read retained position authority")
            unhosted.retire()
            let expected=try c.author(),stamp=c.model.documentRevision
            try c.f5();try await c.ready("F5 accepted document",restored:true)
            try require(c.model.documentRevision>stamp,"F5 did not reload the document");try c.assertPosition(.mine,expected,phase:"normal F5")
            let resultPosition=try c.author(.result,line:275,top:255),menuStamp=c.model.documentRevision
            // Canonical top is the Right/Mine source, not an independent result viewport.
            let canonical=try c.classicReloadExpected(.result)
            try c.menuReload();try await c.ready("native menu accepted document",restored:true)
            let resultExpected=canonical
            try require(resultExpected.line==resultPosition.line && resultExpected.column==resultPosition.column,"Capturing canonical viewport changed actual Result caret")
            try require(c.model.documentRevision>menuStamp,"Native menu did not reload");try c.assertPosition(.result,resultExpected,phase:"native menu")
            // Fresh load keeps configured initial navigation instead of inheriting Reload intent.
            c.model.load();try await c.ready("fresh configured navigation")
            let fresh=try c.position(.result)
            try require(fresh.line==120 && fresh.column==0,"Fresh three-way load inherited a retained Reload caret")
            _=try c.author(.result,line:275,top:255)
            // Failed actual source read retains the old accepted document and position; Retry is Reload.
            let oldDoc=c.model.documentRevision,oldResult=c.model.result,source=try Data(contentsOf:c.base)
            try FileManager.default.removeItem(at:c.base);try c.f5()
            try await c.wait("actual failed source read"){!c.model.busy && !c.model.preparing && c.model.error != nil && !c.model.reloadPositionPending}
            try require(c.model.documentRevision==oldDoc && c.model.result==oldResult,"Failed read replaced the document")
            try source.write(to:c.base);c.model.error=nil
            try await c.wait("failed-read alert released"){c.owner.window?.attachedSheet==nil}
            let retryExpected=try c.classicReloadExpected(.result)
            try c.f5();try await c.ready("actual read Retry",restored:true);try c.assertPosition(.result,retryExpected,phase:"actual read Retry")
            // Actual native Cancel leaves the dirty draft, stored bytes and position unchanged.
            guard let edit=c.model.replaceEntireResult else{throw Failure(description:"Missing real native edit hook")}
            edit(c.model.result+"unsaved draft\n");try await c.wait("dirty native draft"){c.model.dirty && c.model.canUndo}
            let dirty=try c.author(.result),dirtyDoc=c.model.documentRevision,draft=c.model.result,outputBefore=try Data(contentsOf:c.output)
            let cancelledOrigin=(try c.current(.result)).enclosingScrollView!.contentView.bounds.origin
            try c.f5();try await c.button("Cancel");try await c.ready("native Cancel paired drain")
            try require(c.model.documentRevision==dirtyDoc && c.model.result==draft && c.model.dirty && (try Data(contentsOf:c.output))==outputBefore,"Cancel mutated the draft/file")
            try c.assertPosition(.result,dirty,unchangedOrigin:cancelledOrigin,phase:"dirty Cancel")
            // Save persists the manual draft. LoadViews(-1) then regenerates
            // Base/Mine/Theirs, rather than reading merged output as a source.
            let expectedWritten=try c.model.encoding.encode(draft),regenerated=c.model.document!.generatedResult
            let acceptedEncoding=c.model.encoding,saveReloadExpected=try c.classicReloadExpected(.result)
            try require(saveReloadExpected.line==dirty.line && saveReloadExpected.column==dirty.column,"Save admission changed authored Result caret")
            try c.menuReload();try await c.button("Save and Reload");try await c.ready("native Save and Reload",restored:true)
            let actualWritten=try Data(contentsOf:c.output)
            let mismatch=zip(expectedWritten,actualWritten).enumerated().first{$0.element.0 != $0.element.1}?.offset
            let writeDiagnostic="output=\(c.model.resultPath),encoding=\(acceptedEncoding),expectedBytes=\(expectedWritten.count),actualBytes=\(actualWritten.count),firstMismatch=\(String(describing:mismatch)); "+c.diagnostic()
            try require(actualWritten==expectedWritten,"Save and Reload did not persist exact encoded draft bytes: "+writeDiagnostic)
            try require(c.model.document?.workingContents==expectedWritten,"Reload did not capture the saved draft baseline: "+writeDiagnostic)
            try require(c.model.result==regenerated && c.model.document?.generatedResult==regenerated && !c.model.canUndo,"Reload did not regenerate exact accepted source result/reset history: "+c.diagnostic())
            try require(c.model.dirty == !regenerated.utf8.elementsEqual(draft.utf8),"Reload dirty state differs from regenerated versus saved draft: "+writeDiagnostic)
            try c.assertPosition(.result,saveReloadExpected,phase:"Save and Reload")
            // A real Save CAS failure must not proceed to Reload or overwrite the outside file.
            c.model.replaceEntireResult?(c.model.result+"next unsaved\n");try await c.wait("next dirty edit"){c.model.dirty}
            let savePos=try c.author(.result),saveDoc=c.model.documentRevision,saveDraft=c.model.result,outside=Data("outside result\n".utf8)
            let failedSaveOrigin=(try c.current(.result)).enclosingScrollView!.contentView.bounds.origin
            try outside.write(to:c.output);try c.f5();try await c.button("Save and Reload")
            try await c.wait("failed owned Save"){!c.model.busy && !c.model.preparing && c.model.error != nil && !c.model.reloadPositionPending}
            try require(c.model.documentRevision==saveDoc && c.model.result==saveDraft && (try Data(contentsOf:c.output))==outside,"Failed Save reloaded or overwrote outside bytes")
            let actual=try c.position(.result);try require(actual.line==savePos.line && actual.column==savePos.column,"Failed Save moved native caret")
            try require((try c.current(.result)).enclosingScrollView!.contentView.bounds.origin==failedSaveOrigin,"Failed Save changed raw viewport: "+c.diagnostic())
            try await c.preserved();await c.clean()
        }catch{await c.clean();throw error}
        let d=Context(root:base.appendingPathComponent("external-clamp"),git:git)
        do {
            try await d.setup();let expected=try d.author(),watch=d.owner.externalReload!
            watch.isActive={_ in true};watch.delayNanoseconds=0
            var answer:((NSApplication.ModalResponse)->Void)?,question:NSAlert?
            watch.presentQuestion={alert,parent,reply in question=alert;answer=reply;alert.window.alphaValue=0;parent.beginSheet(alert.window)}
            watch.activate();try await d.wait("external baseline"){!watch.hasPendingWork}
            var changed=d.text(side:1);changed=changed.replacingOccurrences(of:"row 040",with:"new 040")
            try Data(changed.utf8).write(to:d.mine);watch.activate()
            try await d.wait("actual external question"){question != nil && answer != nil && d.owner.window?.attachedSheet === question?.window}
            d.owner.window!.endSheet(question!.window,returnCode:.alertFirstButtonReturn);answer?(.alertFirstButtonReturn);answer=nil;question=nil
            try await d.ready("accepted external Reload",restored:true);try d.assertPosition(.mine,expected)
            watch.isActive={_ in false}
            _=try d.author(.mine,line:330,top:310)
            let shortened=String(d.text(count:80).dropLast())
            for url in [d.base,d.mine,d.theirs,d.output] {try Data(shortened.utf8).write(to:url)}
            // The accepted external regeneration differs from the saved
            // output baseline. Its real dirty Reload question remains required.
            try require(d.model.dirty,"External regeneration unexpectedly lost its unsaved result: "+d.diagnostic())
            try d.f5()
            let clampQuestion=try await d.button("Reload Without Saving")
            try await d.wait("clamp Reload question exact paired detach"){clampQuestion.sheetParent==nil && d.owner.window?.attachedSheet !== clampQuestion}
            try await d.ready("removed-line clamp",restored:true)
            let clamped=try d.position(.mine)
            try require(clamped.line==79 && clamped.column<=String(d.text(count:80).split(separator:"\n").last!).utf16.count && clamped.topLine<=79,"Removed-line clamp lost source coordinates")
            let scroll=(try d.current(.mine)).enclosingScrollView!
            try require(abs(scroll.contentView.bounds.minX+scroll.contentView.contentInsets.left)<0.01,"Clamp did not reveal character zero: rawX=\(scroll.contentView.bounds.minX),leadingInset=\(scroll.contentView.contentInsets.left); "+d.diagnostic())
            try d.assertCanonicalViewport("removed-line clamp",allPanes:true)
            try await d.preserved();await d.clean()
        }catch{await d.clean();throw error}
        let p4=Context(root:base.appendingPathComponent("p4-layout"),git:git,curved:true)
        do {
            try await p4.setup()
            let authoredRight=try p4.author(.mine,line:280,top:260)
            let left=try p4.author(.theirs,line:100,top:80)
            try require(p4.model.focusPresentationPane(.mine),"P4 active Mine focus refused")
            let right=try p4.position(.mine),leftAtAdmission=try p4.position(.theirs)
            try require(right.line==authoredRight.line && right.column==authoredRight.column,"P4 focus changed authored Mine caret")
            try require(leftAtAdmission.line==left.line && leftAtAdmission.column==left.column && leftAtAdmission.topLine==left.topLine,"P4 focus changed independent Theirs viewport")
            try require(!p4.model.hasUnsavedEditorWork,"P4 first Reload unexpectedly requires a draft choice: "+p4.diagnostic())
            try p4.f5();try await p4.ready("P4 independent source positions",restored:true)
            try p4.assertPosition(.mine,right,phase:"P4 F5")
            let actualLeft=try p4.position(.theirs)
            try require(actualLeft.line==left.line && actualLeft.column==left.column && actualLeft.topLine==left.topLine,"P4 Reload forced Classic viewport alignment")
            let p4Clip=(try p4.current(.theirs)).enclosingScrollView!.contentView
            try require(abs(p4Clip.bounds.minX+p4Clip.contentInsets.left)<0.01,"P4 Reload did not reveal character zero: rawX=\(p4Clip.bounds.minX),leadingInset=\(p4Clip.contentInsets.left); "+p4.diagnostic())
            let gate=Gate();p4.gates.append(gate)
            p4.model.prepareReload={work in let prepared=try await work();await gate.hold();return prepared}
            try require(!p4.model.hasUnsavedEditorWork,"P4 layout-switch read unexpectedly requires a draft choice: "+p4.diagnostic())
            try p4.f5();try await p4.wait("P4 receipt held before layout switch"){gate.entered && p4.model.reloadPositionPending}
            p4.prefs.set(false,forKey:"TurtleGit.Comparison.CurvedInterface");p4.model.objectWillChange.send()
            gate.release();try await p4.ready("changed pane mode retires P4 receipt")
            try require(!p4.model.reloadPositionPending,"Layout change retained old P4 restoration authority")
            try await p4.wait("actual Classic native projection after P4 switch"){
                views(p4.owner.window?.contentView).compactMap{$0 as? MergePaneInputTextView}.contains{
                    $0.paneInputCells != nil && ($0 as? MergeFindProviding)?.mergeFindPaneID==2 && ($0 as? MergeFindProviding)?.mergeFindAllowed==true
                }
            }
            try await p4.preserved();await p4.clean()
        }catch{await p4.clean();throw error}
        let e=Context(root:base.appendingPathComponent("held-close"),git:git)
        do {
            try await e.setup();_=try e.author()
            let intentGate=Gate();e.gates.append(intentGate)
            e.model.prepareReload={work in let prepared=try await work();await intentGate.hold();return prepared}
            try require(!e.model.hasUnsavedEditorWork,"Held navigation read unexpectedly requires a draft choice: "+e.diagnostic())
            try e.f5();try await e.wait("native intent held before adoption"){intentGate.entered && e.model.reloadPositionPending}
            let native=try e.current(.mine)
            // The native navigation protocol retires an older captured intent;
            // this does not assert that a disabled busy pane accepts a key.
            (native as? MergeLineNavigationProviding)?.beginUserNavigation()
            let newer=(native.string as NSString).range(of:"row 042 –")
            try require(newer.location != NSNotFound,"New native source line missing")
            native.setSelectedRange(NSRange(location:newer.location,length:0))
            try require(!e.model.reloadPositionPending,"Superseding native intent retained old Reload position")
            intentGate.release();try await e.ready("superseded position read drains")
            try require(try e.position(.mine).line==42,"Old Reload receipt overwrote newer native selection")
            _=try e.author();let document=e.model.documentRevision,result=e.model.result,gate=Gate();e.gates.append(gate)
            e.model.prepareReload={work in let prepared=try await work();await gate.hold();return prepared}
            try require(!e.model.hasUnsavedEditorWork,"Held close read unexpectedly requires a draft choice: "+e.diagnostic())
            try e.f5();try await e.wait("real prepared worker held"){gate.entered && e.model.reloadPreparationPending>0}
            e.owner.close();try require(e.model.retired && !e.model.reloadPositionPending,"Closed owner kept Reload authority")
            try require(TurtleGitApplicationDelegate().applicationShouldTerminate(NSApp) == .terminateCancel,"Held worker lost Quit lifetime")
            gate.release();try await e.wait("retired worker drain"){!e.model.mergeToolHasPendingWork && e.model.reloadPreparationPending==0}
            try require(e.model.documentRevision==document && e.model.result==result,"Late Reload adopted after owner close")
            try await e.preserved();await e.clean()
        }catch{await e.clean();throw error}
        try require(MergeRegexOperations.activeRequests==0,"Three-way Reload workers leaked")
        print("PASS editor Reload three-way: actual F5/menu/external acceptance, canonical aligned viewport/x0, Unicode logical carets, read Retry/clamp, native dirty Cancel/Save/CAS failure and closed held-worker ownership; private inputs/index/HEAD preserved")
    }
    static func main()async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let order=class_getInstanceMethod(NSWindow.self,#selector(NSWindow.order(_:relativeTo:)))!,hidden=class_getInstanceMethod(NSWindow.self,#selector(NSWindow.threeWayReloadQuietOrder(_:relativeTo:)))!
        let sheet=class_getInstanceMethod(NSWindow.self,#selector(NSWindow.beginSheet(_:completionHandler:)))!,hiddenSheet=class_getInstanceMethod(NSWindow.self,#selector(NSWindow.threeWayReloadQuietSheet(_:completionHandler:)))!
        method_exchangeImplementations(order,hidden);method_exchangeImplementations(sheet,hiddenSheet)
        defer{method_exchangeImplementations(sheet,hiddenSheet);method_exchangeImplementations(order,hidden)}
        let suite="TurtleGit.ThreeWayReload.Geometry."+UUID().uuidString,prefs=UserDefaults(suiteName:suite)!
        DialogGeometry.install(preferences:prefs);defer{DialogGeometry.install(preferences:.standard);prefs.removePersistentDomain(forName:suite)}
        do {try await verify(base:URL(fileURLWithPath:CommandLine.arguments[1]),git:URL(fileURLWithPath:CommandLine.arguments[2]))}
        catch{NativeOwnedWindowCleanup.close(NSApp.windows,returnCode:.abort);throw error}
        NativeOwnedWindowCleanup.close(NSApp.windows,returnCode:.abort)
        try require(NSApp.windows.allSatisfy{!$0.isVisible && $0.attachedSheet==nil},"Three-way Reload native windows did not drain")
    }

}
