// SPDX-License-Identifier: GPL-2.0-or-later
import AppKit
import ObjectiveC
import ApplicationServices
import TurtleGitCore

private extension NSWindow {
    @objc func headerVerificationOrder(_ mode:NSWindow.OrderingMode,relativeTo number:Int) {
        alphaValue=0;setFrameOrigin(.init(x:-24000,y:-24000));headerVerificationOrder(mode,relativeTo:number)
    }
}
@MainActor @main enum MergePaneHeaderVerification {
    struct Failure:Error,CustomStringConvertible {let description:String}
    static func require(_ value:Bool,_ message:String,line:UInt = #line)throws {if !value {throw Failure(description:"Pane header \(line): "+message)}}
    static func views(_ view:NSView?)->[NSView] {
        guard let view else{return []}
        let selector=#selector(getter:NSView.subviews)
        typealias Getter = @convention(c)(AnyObject,Selector)->Unmanaged<NSArray>
        let getter=unsafeBitCast(view.method(for:selector),to:Getter.self)
        let children=getter(view,selector).takeUnretainedValue().copy() as! NSArray
        var result=[view]
        for index in 0..<children.count {
            let object=children.object(at:index) as AnyObject
            guard let native=object as? NSObject,native.isKind(of:NSView.self) else{continue}
            result += views(unsafeBitCast(object,to:NSView.self))
        }
        return result
    }
    struct SystemHeader:@unchecked Sendable {
        var element:AXUIElement?
        var actions=[String:String]()
        var control=false
        var diagnostics=[String]()
    }
    // NSHostingView.accessibilityChildren is not the external AX hierarchy:
    // an isolated standard SwiftUI Button is absent there too. Query only this
    // owned process through the public AX server, from a background task while
    // MainActor services accessibility callbacks. Never request TCC permission.
    static func systemHeader(_ header:MergePaneHeaderView,in window:NSWindow?)async->SystemHeader {
        let pid=getpid(),title=window?.title ?? "",label=header.accessibilityLabel() ?? "",help=header.accessibilityHelp() ?? ""
        let expected=Set((header.accessibilityCustomActions() ?? []).map(\.name))
        return await Task.detached {
            var result=SystemHeader(),windows:CFTypeRef?
            let status=AXUIElementCopyAttributeValue(AXUIElementCreateApplication(pid),kAXWindowsAttribute as CFString,&windows)
            guard status == .success else{result.diagnostics=["Owned AX server error \(status.rawValue)"];return result}
            var remaining=4096,seen=Set<CFHashCode>()
            func value(_ element:AXUIElement,_ name:String)->CFTypeRef? {
                var value:CFTypeRef?;return AXUIElementCopyAttributeValue(element,name as CFString,&value) == .success ? value:nil
            }
            func visit(_ element:AXUIElement,_ depth:Int) {
                guard depth<48,remaining>0,seen.insert(CFHash(element)).inserted else{return};remaining-=1
                let role=value(element,kAXRoleAttribute) as? String,caption=(value(element,kAXDescriptionAttribute) as? String) ?? (value(element,kAXTitleAttribute) as? String),location=value(element,kAXHelpAttribute) as? String
                var raw:CFArray?;_ = AXUIElementCopyActionNames(element,&raw)
                let names=raw as? [String] ?? []
                if role==kAXButtonRole && caption=="Save" && names.contains(kAXPressAction){result.control=true}
                if result.diagnostics.count<100 {result.diagnostics.append("depth=\(depth) role=\(String(reflecting:role)) caption=\(String(reflecting:caption)) help=\(String(reflecting:location))")}
                if role==kAXButtonRole,caption==label,location==help {
                    var described=[String:String]()
                    for action in names {var description:CFString?;if AXUIElementCopyActionDescription(element,action as CFString,&description) == .success,let description {described[description as String]=action}}
                    if expected.isSubset(of:Set(described.keys)) && names.contains(kAXShowMenuAction) {result.element=element;result.actions=described}
                }
                for child in value(element,kAXChildrenAttribute) as? [AXUIElement] ?? [] {visit(child,depth+1)}
            }
            for window in windows as? [AXUIElement] ?? [] where (value(window,kAXTitleAttribute) as? String)==title {visit(window,0)}
            return result
        }.value
    }
    static func requireAccessible(_ header:MergePaneHeaderView,in window:NSWindow?)async throws {
        try require(header.isAccessibilityElement() && header.accessibilityRole() == .button && !header.titleField.isAccessibilityElement(),"Header is still exposed only as a static text child")
        let actual=await systemHeader(header,in:window)
        try require(actual.control,"System AX standard Save button control unavailable: \(actual.diagnostics)")
        try require(header.accessibilityChildren()?.isEmpty != false && actual.element != nil,"Owning header button/ShowMenu/custom actions absent from actual system AX hierarchy: \(actual.diagnostics)")
    }
    static func wait(_ window:NSWindow?,line:UInt = #line,_ ready:()->Bool)async throws {
        for _ in 0..<2500 {window?.contentView?.layoutSubtreeIfNeeded();if ready(){return};try await Task.sleep(nanoseconds:10_000_000)}
        if let window {
            let states=views(window.contentView).compactMap{$0 as? MergePaneHeaderView}.map {header in
                let actions=header.contextMenu().items.map{$0.title+":"+String($0.isEnabled)}
                return "title=\(String(reflecting:header.titleField.stringValue)) tooltip=\(String(reflecting:header.toolTip)) attached=\(header.window === window) actions=\(actions)"
            }
            print("Pane header timeout diagnostics \(line): headers=\(states), sheet=\(window.attachedSheet != nil), modal=\(NSApp.modalWindow != nil)")
            if let owner=window.windowController as? TextConflictWindowController {print("Merge state: busy=\(owner.model.busy) preparing=\(owner.model.preparing) ready=\(owner.model.nativeEditorReady) tools=\(owner.model.sourceToolsAllowed) error=\(String(reflecting:owner.model.error))")}
            if let owner=window.windowController as? FileComparisonWindowController {print("Compare state: busy=\(owner.model.busy) filtering=\(owner.model.filtering) presentation=\(owner.model.panePresentationAvailable) error=\(String(reflecting:owner.model.error))")}
        }
        throw Failure(description:"Pane header timeout \(line)")
    }
    static func dispatch(_ item:NSMenuItem)throws {
        guard let action=item.action else{throw Failure(description:"Native header menu action missing")}
        try require(item.isEnabled && NSApp.sendAction(action,to:item.target,from:item),"Native header menu dispatch refused")
    }
    static func deliverRetained(_ item:NSMenuItem)throws {
        guard let action=item.action else{throw Failure(description:"Retained native action missing")}
        _=NSApp.sendAction(action,to:item.target,from:item)
    }
    static func item(_ menu:NSMenu,_ title:String)throws->NSMenuItem {
        guard let item=menu.items.first(where:{$0.title==title}) else{throw Failure(description:"Missing native header action "+title)};return item
    }
    static func drained()->Bool {FileListComparisonSession.activeOperations==0 && MergeSourceExport.activeExports==0 && FileComparisonWindowModel.activePaneExports==0 && MergeRegexOperations.activeRequests==0 && MergeExternalReloadCoordinator.activeRequests==0}
    @MainActor final class Context {
        let root:URL,git:URL,prefs:UserDefaults,suite:String,repository:GitRepository
        let base:URL,mine:URL,theirs:URL
        var owners=[NSWindowController](),pending=[()->Void]()
        let original=[Data("head\nbase\ntail\n".utf8),Data("head\nmine 🐢\ntail\n".utf8),Data("head\ntheirs\ntail\n".utf8)]
        var head=Data(),index=Data()
        init()throws {
            root=URL(fileURLWithPath:CommandLine.arguments[1],isDirectory:true).standardizedFileURL.resolvingSymlinksInPath()
            git=URL(fileURLWithPath:CommandLine.arguments[2]);try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
            suite="TurtleGit.Header."+UUID().uuidString
            guard let preferences=UserDefaults(suiteName:suite) else{throw Failure(description:"Private preferences unavailable")};prefs=preferences
            MergeGeneralPreferences(firstDifference:false,firstConflict:false).save(to:prefs);MergeComparisonOptions.exact.save(to:prefs)
            prefs.set(true,forKey:"TurtleGitMerge.UseUTF8");prefs.set(false,forKey:"TurtleGitMerge.OnePane")
            repository=GitRepository(root:root,executable:git,libgit2Configuration:.init(enabled:false))
            base=root.appendingPathComponent("Base Café.txt");mine=root.appendingPathComponent("Mine 🐢.txt");theirs=root.appendingPathComponent("Theirs.txt")
            for (url,data) in zip([base,mine,theirs],original){try data.write(to:url)}
        }
        func seed()async throws {
            _=try await repository.run(["init","-q"]);_=try await repository.run(["config","user.name","Header Fixture"]);_=try await repository.run(["config","user.email","header@example.invalid"])
            _=try await repository.run(["add","--",base.lastPathComponent,mine.lastPathComponent,theirs.lastPathComponent]);_=try await repository.run(["commit","-qm","Private header inputs"])
            head=try await repository.run(["rev-parse","HEAD"]).stdout;index=try Data(contentsOf:root.appendingPathComponent(".git/index"))
        }
        func own(_ owner:NSWindowController){owners.append(owner);owner.window?.isReleasedWhenClosed=false;owner.window?.alphaValue=0;owner.window?.setFrameOrigin(.init(x:-24000,y:-24000));owner.window?.orderFront(nil)}
        func pair()async throws->FileComparisonWindowController {
            let owner=FileComparisonWindowController(comparison:try WorkingFileComparison(base:base,destination:mine),permissions:[],preferences:prefs)
            own(owner);owner.model.useInternalMergeViewer();owner.model.load();try await pairReady(owner);return owner
        }
        func merge(unnamed:Bool=false)async throws->TextConflictWindowController {
            let working=try WorkingTextMerge(base:base,theirs:theirs,mine:mine,merged:unnamed ? nil:mine)
            // Tool metadata must be installed before the first accepted load.
            // NSHostingController can start onAppear during construction.
            let owner=TextConflictWindowController(repository:repository,access:nil,path:mine.lastPathComponent,workingMerge:working,preferences:prefs,deferInitialLoad:true)
            own(owner)
            if !unnamed {
                guard let invocation=try MergeToolInvocation.parse(arguments:["--merge-tool","--base",base.path,"--theirs",theirs.path,"--mine",mine.path,"--merged",mine.path,"--basename","Captured Base","--minename","Captured Mine"],currentDirectory:root.path) else{throw Failure(description:"Actual merge invocation missing")}
                try owner.model.configureMergeTool(invocation)
            }
            owner.model.beginTransferredDocument();try await wait(owner.window){owner.model.sourceToolsAllowed && owner.model.nativeEditorReady && owner.model.externalReloadSources.count==3};return owner
        }
        func witness()async throws {
            let after=try await repository.run(["rev-parse","HEAD"]).stdout
            let afterIndex=try Data(contentsOf:root.appendingPathComponent(".git/index"))
            try require(after==head && afterIndex==index,"Header operation changed HEAD/index")
            for (url,data) in zip([base,mine,theirs],original){try require(try Data(contentsOf:url)==data,"Header operation overwrote original input")}
        }
        func cleanup()async throws {
            for finish in pending {finish()};pending=[]
            for owner in owners {if let window=owner.window,let sheet=window.attachedSheet {window.endSheet(sheet,returnCode:.cancel)};owner.close()}
            try await wait(nil){drained() && self.owners.allSatisfy{$0.window?.attachedSheet==nil && $0.window?.isVisible != true}}
            prefs.removePersistentDomain(forName:suite)
        }
    }
    static func pairReady(_ owner:FileComparisonWindowController)async throws {
        try await wait(owner.window){!owner.model.busy && !owner.model.filtering && owner.model.alignment != nil && views(owner.window?.contentView).compactMap{$0 as? NSTextView}.filter{view in
            guard let pane=view as? MergeFindProviding,let scroll=view.enclosingScrollView else{return false}
            let base=pane.mergeFindPaneID==1
            return owner.model.ownsViewport(scroll,base:base) && owner.model.ownsEditor(scroll,base:base)
        }.count==(owner.model.onePaneActive ? 1:2)}
    }
    static func headers(_ owner:NSWindowController)->[MergePaneHeaderView]{views(owner.window?.contentView).compactMap{$0 as? MergePaneHeaderView}}
    static func comparison(_ c:Context)async throws {
        let owner=try await c.pair(),model=owner.model
        try await wait(owner.window){headers(owner).count==2}
        guard let left=headers(owner).first(where:{$0.toolTip?.contains(c.base.lastPathComponent)==true}) else{throw Failure(description:"Actual base header missing")}
        try await requireAccessible(left,in:owner.window)
        var revealed=[URL]();model.revealPaneInFinder={revealed.append($0)}
        c.prefs.set(false,forKey:"ShowAppContextMenuIcons")
        let hidden=left.contextMenu();try require(hidden.items.count==2 && hidden.items.allSatisfy{$0.image==nil},"Private header icon-off ignored")
        try dispatch(try item(hidden,"Reveal in Finder"));try require(revealed==[c.base],"Header reveal used reflected title instead of actual file")
        try dispatch(try item(hidden,"Reveal in Finder"));try require(revealed.count==1,"Retained menu command dispatched twice")
        c.prefs.set(true,forKey:"ShowAppContextMenuIcons");try require(left.contextMenu().items.allSatisfy{$0.image != nil},"Header source artwork missing")
        let output=c.root.appendingPathComponent("saved header base.txt");model.chooseExportLocation={_,_,_ in output}
        try dispatch(try item(left.contextMenu(),"Save this pane as…"));try await wait(owner.window){!model.busy && !model.hasPendingEditorChoice && model.savedPaneURL(base:true)==output}
        try require(try Data(contentsOf:output)==c.original[0],"Header Save As lost exact source bytes")
        try await pairReady(owner);try await wait(owner.window){headers(owner).count==2}
        guard let rebound=headers(owner).first(where:{$0.toolTip?.contains(output.lastPathComponent)==true}) else{throw Failure(description:"Rebound header missing")}
        try dispatch(try item(rebound.contextMenu(),"Reveal in Finder"));try require(revealed.last==output,"Rebound header revealed old file")
        let stale=try item(rebound.contextMenu(),"Reveal in Finder"),count=revealed.count
        model.switchPaneMode(true);try await pairReady(owner)
        try deliverRetained(stale);try require(revealed.count==count,"Outgoing header retargeted combined pane")
        try await c.witness()
    }
    static func merging(_ c:Context)async throws {
        let owner=try await c.merge(),model=owner.model
        // Native-editor readiness precedes its deferred status publication.
        // Establish the actual three-pane report before taking the baseline;
        // do not force focus or compare startup defaults to a later report.
        let initialMarks=[MergePaneMarkCount(label:"L",count:0),.init(label:"R",count:0),.init(label:"B",count:0)]
        try await wait(owner.window){
            let actual=owner.window?.firstResponder as? NSTextView
            let focused=actual.flatMap {$0 is MergeFindProviding && $0.window === owner.window ? $0:nil}
            let role:TextConflictPaneRole?
            switch (focused as? MergeFindProviding)?.mergeFindPaneID {case 1:role = .theirs;case 2:role = .mine;case 3:role = .result;default:role=nil}
            return model.sourceToolsAllowed && model.nativeEditorReady && headers(owner).count==3 &&
                headers(owner).allSatisfy{$0.contextMenu().items.contains{$0.isEnabled}} &&
                model.presentationMarkedCounts==initialMarks && model.activePresentationPane==role &&
                model.presentationColumn==MergePanePresentation.column(in:focused)
        }
        let column=model.presentationColumn,focus=model.activePresentationPane,marks=model.presentationMarkedCounts
        let responder=(owner.window?.firstResponder).map{ObjectIdentifier($0)}
        model.showBase=true
        try await wait(owner.window){headers(owner).count==4 && headers(owner).contains {header in
            header.toolTip?.contains(c.base.path)==true && header.contextMenu().items.contains{$0.title=="Reveal in Finder" && $0.isEnabled}
        }}
        try require(model.presentationColumn==column && model.activePresentationPane==focus && model.presentationMarkedCounts==marks,"Optional Base mount changed settled report: before column=\(column) role=\(String(reflecting:focus)) marks=\(marks) responder=\(String(reflecting:responder)); after column=\(model.presentationColumn) role=\(String(reflecting:model.activePresentationPane)) marks=\(model.presentationMarkedCounts) responder=\(String(reflecting:(owner.window?.firstResponder).map{ObjectIdentifier($0)}))")
        model.showBase=false
        try await wait(owner.window){headers(owner).count==3 && model.nativeEditorReady}
        let originalResult=model.result
        // The child compares accepted original inputs, never the edited result.
        model.result="private unsaved result\n"
        try await wait(owner.window){model.nativeEditorReady && headers(owner).contains {header in header.titleField.stringValue.contains("Mine") && header.contextMenu().items.contains {$0.title=="Show diff separately" && $0.isEnabled}}}
        var child:FileComparisonWindowController?
        model.sourceComparisonPresentation={next in c.own(next);child=next}
        guard let mine=headers(owner).first(where:{$0.titleField.stringValue.contains("Mine")}) else{throw Failure(description:"Actual Mine header missing")}
        let menu=mine.contextMenu();try require(menu.items.map(\.title).contains("Show diff separately"),"Source header caption differs")
        try dispatch(try item(menu,"Show diff separately"));try await wait(owner.window){child?.model.document != nil && child?.model.busy==false && child?.model.filtering==false}
        guard let child else{throw Failure(description:"Independent source comparison missing")}
        try require(child.model.document?.base.bytes==c.original[0] && child.model.document?.destination.bytes==c.original[1] && model.result=="private unsaved result\n","Source header comparison used mutable merged text")
        let actualBaseTitle=child.model.mergeToolDescriptiveName(base:true),actualSideTitle=child.model.mergeToolDescriptiveName(base:false)
        try require(actualBaseTitle=="Captured Base" && actualSideTitle=="Captured Mine","Separate source comparison lost original descriptive titles: base=\(String(reflecting:actualBaseTitle)), side=\(String(reflecting:actualSideTitle)), parentBase=\(model.mergeToolPaneTitle("Base")), parentMine=\(model.mergeToolPaneTitle("Mine",mine:true))")
        try require(child.window?.title=="Captured Mine – TurtleGitMerge" && child.window?.title.contains("TurtleGitSourceCompare-")==false,"Separate source frame exposed its private storage path instead of captured descriptive title: \(child.window?.title ?? "nil")")
        try require(!child.model.canTransfer(toBase:true) && !child.model.canTransfer(toBase:false),"Source comparison snapshot became writable")
        let generation=child.model.alignmentGeneration
        child.model.load();try await wait(child.window){child.model.alignmentGeneration>generation};try await pairReady(child)
        try require(child.window?.title=="Captured Mine – TurtleGitMerge","Reload replaced descriptive source frame title with storage path")
        try await wait(child.window){child.model.canSwitchSides}
        child.model.switchSides();try await pairReady(child)
        try require(child.model.sidesReversed && child.window?.title=="Captured Base – TurtleGitMerge" && child.model.mergeToolDescriptiveName(base:false)=="Captured Base","Side swap did not orient captured descriptions with immutable input identity")
        try await wait(child.window){child.model.canSwitchSides}
        child.model.switchSides();try await pairReady(child)
        try require(!child.model.sidesReversed && child.window?.title=="Captured Mine – TurtleGitMerge" && child.model.document?.base.bytes==c.original[0] && child.model.document?.destination.bytes==c.original[1],"Round-trip side swap lost descriptive title or original input bytes")
        let temporary=child.model.snapshot.root;child.close()
        try await wait(nil){!child.model.mergeToolHasPendingWork && !FileManager.default.fileExists(atPath:temporary.path)}
        try require(!FileManager.default.fileExists(atPath:temporary.path),"Source header comparison leaked private files")
        var revealed=[URL]();model.revealPaneInFinder={revealed.append($0)}
        let result=model.paneHeaderActions(.result)
        guard let reveal=result.commands.first(where:{$0.title=="Reveal in Finder"}) else{throw Failure(description:"Known saved result Reveal missing")}
        try require(reveal.invoke() && revealed==[c.mine] && !reveal.invoke(),"Result/P4 command lost actual output or accepted duplicate invocation")
        // Base is an optional native role; it exposes only a real accepted file,
        // and no invented base/result comparison or editable stage operation.
        try require(model.paneHeaderActions(.base).commands.map(\.title)==["Reveal in Finder"],"Optional Base header invented source operations")
        let unnamed=try await c.merge(unnamed:true)
        try require(!unnamed.model.paneHeaderActions(.result).commands.contains{$0.title=="Reveal in Finder"},"Unnamed result invented a filesystem target")
        model.result=originalResult
        try await wait(owner.window){model.sourceToolsAllowed && model.nativeEditorReady && headers(owner).contains {header in header.titleField.stringValue.contains("Theirs") && header.contextMenu().items.contains {$0.title=="Save this pane as…" && $0.isEnabled}}}
        // Existing source exporter owns Cancel and declines duplicate/late replies.
        var answer:((NSApplication.ModalResponse)->Void)?
        model.sourceExporter.present={_,_,reply in answer=reply};let cancelled=c.root.appendingPathComponent("cancelled header.txt")
        model.sourceExporter.selectedURL={_ in cancelled}
        guard let save=model.paneHeaderActions(.theirs).commands.first(where:{$0.title=="Save this pane as…"}) else{throw Failure(description:"Source Save As missing")}
        try require(save.invoke() && model.exportingSource,"Header Save As did not own export")
        answer?(.cancel);answer?(.OK);try await wait(owner.window){!model.exportingSource}
        try require(!FileManager.default.fileExists(atPath:cancelled.path),"Cancelled header export wrote after late reply")
        try await wait(owner.window){model.sourceToolsAllowed && headers(owner).contains {header in header.titleField.stringValue.contains("Mine") && header.contextMenu().items.contains{$0.title=="Reveal in Finder" && $0.isEnabled}}}
        let oldClassic=model.paneHeaderActions(.mine).commands.first(where:{$0.title=="Reveal in Finder"})
        try require(oldClassic?.available()==true,"Retained classic command was not current before mode change")
        let expectedTooltip=model.p4DisplayPath(.mine)+"\n"+model.paneHeaderLocation(.mine)
        func isMineHeader(_ header:MergePaneHeaderView)->Bool {
            // Result can legitimately alias Mine's filename and location. The
            // separate-diff command identifies the source role independently.
            Data((header.toolTip ?? "").utf8)==Data(expectedTooltip.utf8) && header.contextMenu().items.contains{$0.title=="Show diff separately" && $0.isEnabled}
        }
        c.prefs.set(true,forKey:"TurtleGit.Comparison.CurvedInterface");model.objectWillChange.send()
        try await wait(owner.window){model.nativeEditorReady && headers(owner).count==4 && headers(owner).contains(where:isMineHeader)}
        guard let compact=headers(owner).first(where:isMineHeader) else{throw Failure(description:"Actual compact P4 header missing")}
        try await requireAccessible(compact,in:owner.window)
        try require(Data((compact.titleField.toolTip ?? "").utf8)==Data(expectedTooltip.utf8),"Compact header lost literal title+path tooltip")
        let before=revealed.count
        try require(oldClassic?.invoke()==false,"Old classic receipt retargeted new P4 pane")
        try dispatch(try item(compact.contextMenu(),"Reveal in Finder"))
        // Reveal publishes no model state. Reopening the same actual native
        // compact menu must create a fresh visit without refreshing the old one.
        try dispatch(try item(compact.contextMenu(),"Reveal in Finder"))
        try require(revealed.count==before+2 && revealed.suffix(2).allSatisfy{$0==c.mine},"Reopened compact menu retained a consumed invocation")
        try await c.witness()
    }
    static func ownership(_ c:Context)async throws {
        let owner=try await c.pair(),model=owner.model;try await wait(owner.window){headers(owner).count==2}
        guard let header=headers(owner).first else{throw Failure(description:"Actual ownership header missing")}
        var reveals=0;model.revealPaneInFinder={_ in reveals += 1}
        let retained=try item(header.contextMenu(),"Reveal in Finder"),ax=header.accessibilityCustomActions()?.first(where:{$0.name=="Reveal in Finder"})
        model.confirmingQuit=true;model.confirmingQuit=false
        try deliverRetained(retained);try require(reveals==0 && ax?.handler?()==false,"Retained header action survived Quit epoch")
        try await wait(owner.window){model.panePresentationAvailable && header.window === owner.window && header.contextMenu().items.contains{$0.title=="Reveal in Finder" && $0.isEnabled}}
        let sheet=NSWindow(contentRect:.init(x:0,y:0,width:100,height:80),styleMask:[.titled],backing:.buffered,defer:false);sheet.isReleasedWhenClosed=false;sheet.alphaValue=0
        owner.window?.beginSheet(sheet,completionHandler:nil)
        try require(header.contextMenu().items.isEmpty && header.accessibilityCustomActions()==nil,"Attached sheet did not gate header actions")
        owner.window?.endSheet(sheet);sheet.close()
        try await wait(owner.window){owner.window?.attachedSheet==nil && sheet.sheetParent==nil && header.contextMenu().items.contains{$0.title=="Reveal in Finder" && $0.isEnabled}}
        let modal=NSWindow(contentRect:.init(x:-24000,y:-24000,width:100,height:80),styleMask:[.titled],backing:.buffered,defer:false)
        modal.isReleasedWhenClosed=false;modal.alphaValue=0
        let session=NSApp.beginModalSession(for:modal)
        let modalAccepted=model.paneHeaderActions(base:true).commands.contains{$0.available()}
        NSApp.endModalSession(session);modal.close()
        try require(!modalAccepted,"Shared header/P4 command bypassed actual app-modal session")
        try await wait(owner.window){NSApp.modalWindow==nil && header.contextMenu().items.contains{$0.title=="Reveal in Finder" && $0.isEnabled}}
        // Acquire a fresh current menu, then detach/reinsert the same native
        // header. A nil-window interval permanently invalidates old receipts.
        guard let parent=header.superview else{throw Failure(description:"Header parent missing")}
        let detached=try item(header.contextMenu(),"Reveal in Finder")
        header.removeFromSuperview();parent.addSubview(header)
        try deliverRetained(detached);try require(reveals==0,"Detached/reused header revived old menu")
        try await wait(owner.window){header.window === owner.window && header.contextMenu().items.contains{$0.title=="Reveal in Finder" && $0.isEnabled}}
        try await requireAccessible(header,in:owner.window)
        let fresh=header.accessibilityCustomActions()?.first(where:{$0.name=="Reveal in Finder"})
        try require(fresh?.handler?()==true && reveals==1 && fresh?.handler?()==false,"Actual discovered AX action missing or not one-shot")
        try await wait(owner.window){header.contextMenu().items.contains{$0.title=="Save this pane as…" && $0.isEnabled}}
        var pending:((URL?)->Void)?;model.chooseExportLocation={_,_,_ in await withCheckedContinuation {continuation in
            var answered=false
            let finish:(URL?)->Void={value in guard !answered else{return};answered=true;continuation.resume(returning:value)}
            pending=finish;c.pending.append{finish(nil)}
        }}
        try dispatch(try item(header.contextMenu(),"Save this pane as…"));try await wait(owner.window){pending != nil}
        let late=c.root.appendingPathComponent("late header save.txt")
        owner.close();pending?(late);try await wait(nil){!model.hasPendingEditorChoice && FileComparisonWindowModel.activePaneExports==0}
        try require(header.contextMenu().items.isEmpty && !FileManager.default.fileExists(atPath:late.path),"Closed header accepted late Save destination")
        try await c.witness()
    }
    static func main()async throws {
        NSApplication.shared.setActivationPolicy(.prohibited);NSApp.finishLaunching()
        guard let original=class_getInstanceMethod(NSWindow.self,#selector(NSWindow.order(_:relativeTo:))),let replacement=class_getInstanceMethod(NSWindow.self,#selector(NSWindow.headerVerificationOrder(_:relativeTo:))) else{throw Failure(description:"Private window ownership unavailable")}
        method_exchangeImplementations(original,replacement);defer{method_exchangeImplementations(original,replacement)}
        let c=try Context();try await c.seed()
        do {
            switch CommandLine.arguments[3] {case "compare":try await comparison(c);case "merge":try await merging(c);case "ownership":try await ownership(c);default:throw Failure(description:"Unknown header case")}
            try await c.cleanup()
        } catch {let failure=error;do {try await c.cleanup()}catch{throw Failure(description:"\(failure); cleanup: \(error)")};throw failure}
        print("PASS: Merge pane header "+CommandLine.arguments[3])
    }
}
