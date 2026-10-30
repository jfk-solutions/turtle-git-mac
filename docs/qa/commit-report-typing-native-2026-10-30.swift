// SPDX-License-Identifier: GPL-2.0-or-later
import AppKit
import ObjectiveC
import Vision
import TurtleGitCore

private extension NSWindow {
    @objc func quietReportTypingOrder(_ mode:NSWindow.OrderingMode,relativeTo number:Int){alphaValue=0;quietReportTypingOrder(mode,relativeTo:number)}
    @objc func quietReportTypingSheet(_ sheet:NSWindow,completionHandler:((NSApplication.ModalResponse)->Void)?){sheet.alphaValue=0;quietReportTypingSheet(sheet,completionHandler:completionHandler)}
}
@MainActor @main struct CommitReportTypingVerification {
    struct Failure:Error,CustomStringConvertible{let description:String}
    static func require(_ value:Bool,_ message:String,line:Int = #line)throws{if !value{throw Failure(description:"Commit report \(line): "+message)}}
    static func views(_ view:NSView?)->[NSView]{guard let view else{return []};return [view]+view.subviews.flatMap{views($0)}}
    static func wait(_ owner:CommitWindowController,_ predicate:()->Bool,line:Int = #line)async throws{
        for _ in 0..<2000{owner.window?.contentView?.layoutSubtreeIfNeeded();if predicate(){return};try await Task.sleep(nanoseconds:10_000_000)}
        let model=owner.model,table=model.fileListTable(key:"checkbox"),probes=views(owner.window?.contentView).compactMap{$0 as? CommitFileInteraction.Probe}
        throw Failure(description:"Commit report timeout \(line); error=\(model.error ?? "none") busy=\(model.busy) fileWorkPending=\(model.fileWorkPending) identityPrepared=\(model.commitIdentityPrepared) preparingIdentity=\(model.preparingCommitIdentity) inputsBlocked=\(model.inputsBlocked) messageFocusAvailable=\(model.messageFocusAvailable) gui=\(model.gitGuiInterface) checkboxPresent=\(table != nil) checkboxWindowMatches=\(table?.window === owner.window) mountedProbes=\(probes.count) readyProbes=\(probes.filter{$0.nativeColumnLayoutReady}.count)")
    }
    static func settle(_ owner:CommitWindowController)async throws{
        for _ in 0..<4{await Task.yield();owner.window?.contentView?.layoutSubtreeIfNeeded();try await Task.sleep(nanoseconds:10_000_000)}
    }
    static func drained()->Bool{CommitWindowModel.activeCommitPreflights==0 && CommitWindowModel.activeReloads==0 && CommitWindowModel.activeFileOperations==0 && CommitWindowModel.activeMetadataOperations==0 && CommitWindowModel.activePreferenceOperations==0 && CommitWindowModel.activeFileDrops==0 && PatchWindowModel.activeOperations==0}
    @MainActor final class FeedbackRead<Value> {
        var continuation:CheckedContinuation<Value,Never>?
        var entered:Bool {continuation != nil}
        func read()async->Value {await withCheckedContinuation{continuation=$0}}
        func release(_ value:Value) {let pending=continuation;continuation=nil;pending?.resume(returning:value)}
    }
    struct FeedbackGeometry:Equatable {let window:NSRect;let frames:[NSRect]}
    static func feedbackGeometry(_ owner:CommitWindowController)throws->FeedbackGeometry {
        guard let window=owner.window,let editor=views(window.contentView).compactMap({$0 as? CommitMessageTextView}).first,let scroll=editor.enclosingScrollView else {throw Failure(description:"No native feedback geometry owner/editor")}
        let model=owner.model,keys=model.gitGuiInterface ? ["unstaged","staged"]:["checkbox"]
        let tables=keys.compactMap{model.fileListTable(key:$0)}
        try require(tables.count==keys.count,"Feedback geometry lost native file lists")
        guard let destination=views(window.contentView).compactMap({$0 as? NSTextField}).first(where:{$0.accessibilityLabel()=="Commit destination"}) else {throw Failure(description:"Feedback geometry lost native destination label")}
        var frames=[destination.convert(destination.bounds,to:nil),scroll.convert(scroll.bounds,to:nil)]
        for table in tables {
            guard let header=table.headerView,let report=table.enclosingScrollView else {throw Failure(description:"Feedback geometry lost native report/header")}
            frames += [report.convert(report.bounds,to:nil),header.convert(header.bounds,to:nil)]
        }
        return .init(window:window.frame,frames:frames)
    }
    static func requireFeedbackGeometry(_ expected:FeedbackGeometry,_ owner:CommitWindowController,_ phase:String)async throws {
        try await settle(owner)
        let actual=try feedbackGeometry(owner)
        try require(actual==expected,"Commit feedback shifted native form/list geometry at \(phase): \(expected) -> \(actual)")
    }
    static func feedbackAccessibilitySnapshot(_ owner:CommitWindowController)->(values:[String],diagnostics:[String],hostingChildren:Int,hostingNavigation:Int) {
        var values:[String]=[],diagnostics:[String]=[],seen=Set<ObjectIdentifier>(),budget=4096
        @MainActor func property(_ object:NSObject,_ name:String)->AnyObject? {let selector=NSSelectorFromString(name);guard object.responds(to:selector) else{return nil};return object.perform(selector)?.takeUnretainedValue()}
        @MainActor func visit(_ object:Any,depth:Int) {
            guard depth<48,budget>0 else{return};budget -= 1
            let label:String?,value:String?,role:String?,children:[Any],navigation:[Any]
            if let node=object as? NSAccessibilityProtocol {
                guard seen.insert(ObjectIdentifier(node as AnyObject)).inserted else{return}
                label=node.accessibilityLabel();value=node.accessibilityValue() as? String;role=node.accessibilityRole()?.rawValue
                children=node.accessibilityChildren() ?? []
                navigation=(object as? NSObject).flatMap{property($0,"accessibilityChildrenInNavigationOrder") as? [Any]} ?? []
            } else if let node=object as? NSObject {
                guard seen.insert(ObjectIdentifier(node)).inserted else{return}
                label=property(node,"accessibilityLabel") as? String;value=property(node,"accessibilityValue") as? String;role=property(node,"accessibilityRole") as? String
                children=property(node,"accessibilityChildren") as? [Any] ?? [];navigation=property(node,"accessibilityChildrenInNavigationOrder") as? [Any] ?? []
            } else {if diagnostics.count<180 {diagnostics.append("Unvisited AX node type=\(type(of:object))")};return}
            if label=="Commit status",let value {values.append(value)}
            if diagnostics.count<180 {diagnostics.append("\(type(of:object)) role=\(role ?? "none") label=\(String(reflecting:label)) value=\(String(reflecting:value)) children=\(children.count) navigation=\(navigation.count)")}
            for child in children+navigation {visit(child,depth:depth+1)}
        }
        if let window=owner.window {visit(window,depth:0)}
        var hostingChildren=0,hostingNavigation=0
        if let root=owner.window?.contentView {
            hostingChildren=(root as NSAccessibilityProtocol).accessibilityChildren()?.count ?? 0
            hostingNavigation=(property(root,"accessibilityChildrenInNavigationOrder") as? [Any])?.count ?? 0
            visit(root,depth:0)
        }
        return (values,diagnostics,hostingChildren,hostingNavigation)
    }
    static func feedbackAccessibleValues(_ owner:CommitWindowController)->[String] {feedbackAccessibilitySnapshot(owner).values}
    static func feedbackState(_ model:CommitWindowModel)->String {
        "error=\(String(reflecting:model.error)) messages=\(model.feedbackMessages) activity=\(model.feedbackActivityVisible) reloadStatus=\(String(reflecting:model.fileListLoadingStatus)) reloadPhase=\(String(describing:model.reloadPhase)) providerBusy=\(model.issueProviderBusy) providerError=\(String(reflecting:model.issueProviderError)) busy=\(model.busy) operation=\(String(reflecting:model.fileOperationTitle)) cancelling=\(model.fileOperationCancelling) author=\(model.loadingAuthorIdentity) date=\(model.loadingAuthorDate) amend=\(model.loadingAmendMessage) imported=\(model.loadingImportedMessage) activeReloads=\(CommitWindowModel.activeReloads)"
    }
    static func acknowledgeFeedbackCancellation(_ owner:CommitWindowController)async throws {
        let model=owner.model
        try await wait(owner){model.error != nil && owner.window?.attachedSheet != nil}
        try require(model.error=="Operation cancelled. Any completed changes are retained.","Unexpected file-operation completion diagnostic: "+feedbackState(model))
        guard let sheet=owner.window?.attachedSheet else {throw Failure(description:"Source cancellation alert was not attached to its owner")}
        let buttons=views(sheet.contentView).compactMap{$0 as? NSButton}.filter{$0.title=="OK" && $0.isEnabled}
        try require(buttons.count==1,"Owned source cancellation alert has no unambiguous native OK button")
        // This is the production alert's actual acknowledgement, not a model
        // error reset. Its binding/action owns clearing the expected diagnostic.
        buttons[0].performClick(nil)
        try await wait(owner){model.error==nil && owner.window?.attachedSheet==nil}
    }
    static func verifyRenderedFeedback(_ owner:CommitWindowController,folder:URL,label:String)async throws {
        // This prohibited receiver must never activate, including when showing
        // an owned alert. Bound AX observation independently of a held Git read;
        // an entirely absent SwiftUI tree uses actual offscreen rendering below.
        for _ in 0..<20 {
            if feedbackAccessibleValues(owner).contains(where:{$0.contains("last commit message")}) {break}
            owner.window?.contentView?.layoutSubtreeIfNeeded();await Task.yield();try await Task.sleep(nanoseconds:10_000_000)
        }
        let snapshot=feedbackAccessibilitySnapshot(owner)
        let evidence=folder.appendingPathComponent("feedback-observation",isDirectory:true)
        try FileManager.default.createDirectory(at:evidence,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
        try snapshot.diagnostics.joined(separator:"\n").write(to:evidence.appendingPathComponent(label+"-accessibility.txt"),atomically:true,encoding:.utf8)
        var record:[String:Any]=["presentation":label,"hostingAXChildren":snapshot.hostingChildren,"hostingAXNavigation":snapshot.hostingNavigation,"statusAXValues":snapshot.values,"receiverActivated":NSApp.isActive,"receiverPolicy":"prohibited"]
        if snapshot.hostingChildren>0 || snapshot.hostingNavigation>0 {
            // Once SwiftUI publishes a tree, a missing status is a real failure.
            record["observer"]="public native accessibility tree"
            try JSONSerialization.data(withJSONObject:record,options:[.prettyPrinted,.sortedKeys]).write(to:evidence.appendingPathComponent(label+"-observer.json"))
            try require(snapshot.values.contains{$0.contains("last commit message")},"Populated native accessibility hierarchy omitted held Amend status: \(snapshot.diagnostics)")
        } else {
            // This host supplies no SwiftUI AX children at all. Do not fabricate
            // attributes or certify VoiceOver from the model. Inspect the actual
            // rendered toolbar via public offscreen bitmap and Vision APIs.
            guard let view=owner.window?.contentView,let bitmap=view.bitmapImageRepForCachingDisplay(in:view.bounds) else {throw Failure(description:"Cannot inspect real offscreen feedback rendering")}
            view.cacheDisplay(in:view.bounds,to:bitmap)
            guard let image=bitmap.cgImage,let full=bitmap.representation(using:.png,properties:[:]) else {throw Failure(description:"Cannot retain feedback rendering bitmap")}
            try full.write(to:evidence.appendingPathComponent(label+"-full.png"))
            let height=min(image.height,max(1,Int(ceil(80*CGFloat(image.height)/view.bounds.height))))
            guard let toolbar=image.cropping(to:CGRect(x:0,y:0,width:image.width,height:height)),let png=NSBitmapImageRep(cgImage:toolbar).representation(using:.png,properties:[:]) else {throw Failure(description:"Cannot retain toolbar rendering crop")}
            try png.write(to:evidence.appendingPathComponent(label+"-toolbar.png"))
            let request=VNRecognizeTextRequest();request.recognitionLevel = .accurate;request.usesLanguageCorrection=false;request.recognitionLanguages=["en-US"];request.minimumTextHeight=0.001
            try VNImageRequestHandler(cgImage:toolbar,options:[:]).perform([request])
            let texts=request.results?.compactMap{$0.topCandidates(1).first?.string} ?? []
            record["observer"]="public offscreen rendered toolbar plus Vision text recognition"
            record["voiceOverAcceptance"]="Unverified: this receiver publishes zero SwiftUI AX children; bitmap recognition does not establish screen-reader behavior."
            record["recognizedText"]=texts;record["recognitionRevision"]=request.revision;record["toolbarPixels"]=[image.width,height]
            try JSONSerialization.data(withJSONObject:record,options:[.prettyPrinted,.sortedKeys]).write(to:evidence.appendingPathComponent(label+"-observer.json"))
            try require(texts.joined(separator:" ").lowercased().contains("last commit message"),"Actual offscreen toolbar omitted held Amend text: OCR=\(texts); evidence=\(evidence.path)")
            print("Feedback observation "+label+": rendered toolbar text verified; SwiftUI AX/VoiceOver remains unverified on zero-child receiver host")
        }
        try require(!NSApp.isActive,"Private feedback rendering check activated receiver")
    }
    static func verifyFeedback(repository real:GitRepository,preferences prefs:UserDefaults)async throws {
        try require(NSApp.activationPolicy() == .prohibited && !NSApp.isActive,"Private feedback receiver must start prohibited and inactive")
        let repository=real
        let head=try await real.run(["rev-parse","HEAD"]).stdout,index=try await real.run(["ls-files","--stage","-z"]).stdout,status=try await real.run(["status","--porcelain=v2","-z","--untracked-files=all"]).stdout
        var owners:[CommitWindowController]=[],releases:[()->Void]=[]
        @MainActor func idle(_ owner:CommitWindowController)->Bool {
            let m=owner.model
            return !m.busy && !m.fileWorkPending && m.commitIdentityPrepared && m.changelistsLoaded && !m.loadingFileMetadata && !m.loadingAuthorIdentity && !m.loadingAuthorDate && !m.loadingAmendMessage && !m.loadingImportedMessage && !m.savingPreferences && m.guiPatch?.busy != true
        }
        @MainActor func cleanup()async {
            releases.forEach{$0()};owners.forEach{$0.model.message="";$0.close()}
            for _ in 0..<2000 {if drained(){break};try? await Task.sleep(nanoseconds:10_000_000)}
        }
        do {
            for gui in [false,true] {
                prefs.set(gui,forKey:"TurtleGit.Commit.GitGuiInterface")
                _=try await real.run(["config","tgit.commitstagingsupport",gui ? "true":"false"])
                let owner=CommitWindowController(repository:repository,access:nil,defaults:prefs),m=owner.model;owners.append(owner)
                owner.window?.setFrame(.init(x:-22000,y:-22000,width:1100,height:900),display:false);owner.showWindow(nil);m.reload(paths:["."])
                try await wait(owner){idle(owner) && m.gitGuiInterface==gui && !m.inputsBlocked}
                m.setAuthor=true;m.authorChanged();m.setAuthorDate=true;m.dateChanged()
                try await wait(owner){idle(owner)}
                if gui {m.selectGuiFiles(["alpha.txt"],staged:false);try await wait(owner){idle(owner) && m.guiPatch != nil}}
                try await settle(owner)
                let baseline=try feedbackGeometry(owner),label=gui ? "GitGui":"Classic"
                let messages=FeedbackRead<String?>();releases.append{messages.release("base\n")}
                m.queryAmendMessage={_ in await messages.read()}
                m.amend=true;m.amendChanged()
                try await wait(owner){messages.entered && m.loadingAmendMessage}
                try await requireFeedbackGeometry(baseline,owner,label+" held Amend")
                try require(m.feedbackMessages.contains{ $0.contains("last commit message") } && m.feedbackActivityVisible,"Held Amend lost visible loading feedback")
                try await verifyRenderedFeedback(owner,folder:real.root.deletingLastPathComponent(),label:label)
                messages.release("base\n");try await wait(owner){idle(owner)}
                try await requireFeedbackGeometry(baseline,owner,label+" completed Amend")

                let authors=FeedbackRead<String?>();releases.append{authors.release("Report QA <qa@example.invalid>")}
                m.queryCommitAuthor={_,_ in await authors.read()};m.authorChanged()
                try await wait(owner){authors.entered && m.loadingAuthorIdentity}
                try await requireFeedbackGeometry(baseline,owner,label+" held author")
                try require(m.feedbackMessages.contains{$0.contains("Reading author")},"Author loading feedback disappeared")
                authors.release("Report QA <qa@example.invalid>");try await wait(owner){idle(owner)};m.queryCommitAuthor=nil
                try await requireFeedbackGeometry(baseline,owner,label+" completed author")

                let dates=FeedbackRead<Date?>();releases.append{dates.release(Date(timeIntervalSince1970:0))}
                m.queryCommitAuthorDate={_ in await dates.read()};m.dateChanged()
                try await wait(owner){dates.entered && m.loadingAuthorDate}
                try await requireFeedbackGeometry(baseline,owner,label+" held date")
                try require(m.feedbackMessages.contains{$0.contains("author date")},"Date loading feedback disappeared")
                dates.release(Date(timeIntervalSince1970:0));try await wait(owner){idle(owner)};m.queryCommitAuthorDate=nil
                try await requireFeedbackGeometry(baseline,owner,label+" completed date")

                let pendingRows=m.entries,statusRead=FeedbackRead<[StatusEntry]>()
                releases.append{statusRead.release(pendingRows)}
                m.queryCommitStatus={_,_ in await statusRead.read()};m.reload()
                try await wait(owner){statusRead.entered && m.fileListLoadingStatus != nil}
                try await requireFeedbackGeometry(baseline,owner,label+" held actual status refresh")
                try require(m.feedbackMessages.contains{$0.contains("changes")},"Reload phase feedback disappeared")
                statusRead.release(pendingRows);try await wait(owner){idle(owner)}
                m.queryCommitStatus={amend,token in try await repository.commitDialogStatus(amendToParent:amend,cancellation:token,refreshIndex:false)}
                try await requireFeedbackGeometry(baseline,owner,label+" completed status refresh")

                let folder=FeedbackRead<URL?>();releases.append{folder.release(nil)}
                m.chooseExportFolder={_ in await folder.read()}
                m.fileAction(.export,snapshot:m.fileMenu(["alpha.txt"]))
                try await wait(owner){folder.entered && !m.fileOperationTitle.isEmpty}
                try await requireFeedbackGeometry(baseline,owner,label+" held actual file-operation chooser")
                try require(m.feedbackActivityVisible && m.feedbackMessages.contains{$0.contains("Exporting")},"File operation feedback disappeared")
                try require(m.cancelFileOperation(),"Active file operation lost Cancel admission")
                try await requireFeedbackGeometry(baseline,owner,label+" cancelling file operation")
                try require(m.feedbackMessages.contains{$0.contains("Cancelling")},"Cancelling feedback disappeared")
                folder.release(nil);try await wait(owner){idle(owner)}
                try await requireFeedbackGeometry(baseline,owner,label+" completed file operation")
                try await acknowledgeFeedbackCancellation(owner)
                try await requireFeedbackGeometry(baseline,owner,label+" acknowledged source cancellation alert")

                m.amend=false;m.amendChanged();try await wait(owner){idle(owner)}
                let steady=try feedbackGeometry(owner)
                if gui {
                    m.selectGuiFiles(["alpha.txt"],staged:false);try await wait(owner){idle(owner)}
                    try await requireFeedbackGeometry(steady,owner,label+" selected row")
                    m.activateGuiFiles(["alpha.txt"],snapshot:m.guiFileListSnapshot(staged:false));try await wait(owner){idle(owner) && m.guiStaged}
                    try await requireFeedbackGeometry(steady,owner,label+" staged row")
                    m.activateGuiFiles(["alpha.txt"],snapshot:m.guiFileListSnapshot(staged:true));try await wait(owner){idle(owner) && !m.guiStaged}
                    try await requireFeedbackGeometry(steady,owner,label+" unstaged row")
                }
                do {try await wait(owner){idle(owner) && m.fileListLoadingStatus==nil && !m.issueProviderBusy && m.feedbackMessages.isEmpty && !m.feedbackActivityVisible}}
                catch {throw Failure(description:"Completed feedback family did not drain: "+feedbackState(m)+"; "+String(describing:error))}
                try require(m.error==nil && m.feedbackMessages.isEmpty && !m.feedbackActivityVisible,"Completed feedback family retained an error or busy label: "+feedbackState(m))
                try require(!NSApp.isActive,"Private feedback receiver activated during checks")
                m.message="";owner.close();try await wait(owner){drained()}
                print("PASS: "+label+" fixed toolbar feedback preserves exact native editor/list/header frames through held Amend/author/date/reload/file-operation/cancellation and selected staging")
            }
            try require(try await real.run(["rev-parse","HEAD"]).stdout==head,"Feedback reads changed HEAD")
            try require(try await real.run(["ls-files","--stage","-z"]).stdout==index,"Feedback staging roundtrip changed index content")
            try require(try await real.run(["status","--porcelain=v2","-z","--untracked-files=all"]).stdout==status,"Feedback workflow changed working bytes/status")
            await cleanup();try require(drained() && owners.allSatisfy{$0.window?.isVisible != true && $0.window?.attachedSheet==nil},"Feedback geometry left owned windows/workers")
            print("PASS: Commit feedback geometry in both presentations and owned operation drain")
        }catch {await cleanup();throw error}
    }
    static func main()async throws{
        NSApp.setActivationPolicy(.prohibited)
        let order=class_getInstanceMethod(NSWindow.self,#selector(NSWindow.order(_:relativeTo:)))!,quiet=class_getInstanceMethod(NSWindow.self,#selector(NSWindow.quietReportTypingOrder(_:relativeTo:)))!
        let sheet=class_getInstanceMethod(NSWindow.self,#selector(NSWindow.beginSheet(_:completionHandler:)))!,quietSheet=class_getInstanceMethod(NSWindow.self,#selector(NSWindow.quietReportTypingSheet(_:completionHandler:)))!
        method_exchangeImplementations(order,quiet);method_exchangeImplementations(sheet,quietSheet)
        defer{method_exchangeImplementations(sheet,quietSheet);method_exchangeImplementations(order,quiet)}
        let root=URL(fileURLWithPath:CommandLine.arguments[1]),repo=GitRepository(root:root,executable:URL(fileURLWithPath:CommandLine.arguments[2]),libgit2Configuration:.init(enabled:false))
        let suite="TurtleGit.CommitReportTyping."+UUID().uuidString,prefs=UserDefaults(suiteName:suite)!
        for key in ["HintStagingMode","HintHierarchicalConfig","Commit.SkipCancelConfirmation","ShowAppContextMenuIcons","AddBeforeCommit"]{prefs.set(true,forKey:key)}
        for key in ["EnableGravatar","SelectFilesForCommit","UseLibgit2","TurtleGit.Commit.GitGuiInterface"]{prefs.set(false,forKey:key)}
        _=try await repo.run(["init","-b","main"])
        for(k,v)in[("user.name","Report QA"),("user.email","qa@example.invalid"),("core.hooksPath","/dev/null"),("commit.gpgsign","false")]{_=try await repo.run(["config",k,v])}
        for name in ["alpha.txt","long name 雪.swift"]{try Data("base\n".utf8).write(to:root.appendingPathComponent(name))}
        try await repo.stage(["."]);_=try await repo.commit(message:"base")
        try Data("working\nextra\n".utf8).write(to:root.appendingPathComponent("alpha.txt"));try Data("untracked\n".utf8).write(to:root.appendingPathComponent("new.txt"))
        if ProcessInfo.processInfo.environment["TURTLEGIT_COMMIT_REPORT_CASE"]=="feedback" {defer{prefs.removePersistentDomain(forName:suite)};try await verifyFeedback(repository:repo,preferences:prefs);return}
        let owner=CommitWindowController(repository:repo,access:nil,defaults:prefs),m=owner.model
        owner.window?.setFrameOrigin(.init(x:-22000,y:-22000));owner.showWindow(nil);m.reload(paths:["."])
        do{
            try await wait(owner){!m.busy && m.commitIdentityPrepared && m.changelistsLoaded && !m.fileWorkPending && !m.loadingFileMetadata}
            try require(m.error==nil && !m.gitGuiInterface,"Classic Commit did not load")
            try await wait(owner){m.fileListTable(key:"checkbox")?.headerView?.menu != nil}
            guard let probe=views(owner.window?.contentView).compactMap({$0 as? CommitFileInteraction.Probe}).first,let table=m.fileListTable(key:"checkbox"),let editor=views(owner.window?.contentView).compactMap({$0 as? CommitMessageTextView}).first else{throw Failure(description:"Actual Classic editor/report missing")}
            // Initial column ownership must settle from mount/layout alone;
            // no message edit or row selection is allowed to trigger binding.
            try await wait(owner){probe.nativeColumnLayoutReady}
            try require(table.enclosingScrollView?.alphaValue==1,"Initial configured report remained hidden")
            try await settle(owner)
            var visibilityTransitions=0,headerEvents=[String]()
            let visibilityObservers=table.tableColumns.map{column in
                column.observe(\.isHidden,options:[.old,.new]){_,change in
                    if change.oldValue != change.newValue{visibilityTransitions += 1;headerEvents.append("hidden \(column.title): \(String(describing:change.oldValue)) -> \(String(describing:change.newValue))")}
                }
            }
            let widthObservers=table.tableColumns.map{column in
                column.observe(\.width,options:[.old,.new]){_,change in
                    if change.oldValue != change.newValue{headerEvents.append("width \(column.title): \(String(describing:change.oldValue)) -> \(String(describing:change.newValue))")}
                }
            }
            // AppKit need not post columnDidMoveNotification for programmatic
            // moveColumn calls. Observe the actual forwarded native mutation,
            // including a transient move later restored within the same turn.
            let moveSelector=#selector(NSTableView.moveColumn(_:toColumn:))
            guard let moveClass=object_getClass(table),let moveMethod=class_getInstanceMethod(moveClass,moveSelector) else {throw Failure(description:"Native table move implementation missing")}
            let originalMove=method_getImplementation(moveMethod)
            let observedMove:@convention(block)(NSTableView,Int,Int)->Void={native,from,to in
                typealias Move=@convention(c)(AnyObject,Selector,Int,Int)->Void
                func forward(){unsafeBitCast(originalMove,to:Move.self)(native,moveSelector,from,to)}
                guard Thread.isMainThread else{forward();return}
                MainActor.assumeIsolated {
                    guard native === table else{forward();return}
                    let before=native.tableColumns.map(ObjectIdentifier.init)
                    forward()
                    let after=native.tableColumns.map(ObjectIdentifier.init)
                    if before != after{headerEvents.append("move \(from) -> \(to): \(before) -> \(after)")}
                }
            }
            let observedMoveIMP=imp_implementationWithBlock(observedMove)
            class_replaceMethod(moveClass,moveSelector,observedMoveIMP,method_getTypeEncoding(moveMethod))
            defer{
                class_replaceMethod(moveClass,moveSelector,originalMove,method_getTypeEncoding(moveMethod))
                imp_removeBlock(observedMoveIMP)
                visibilityObservers.forEach{$0.invalidate()};widthObservers.forEach{$0.invalidate()}
            }
            func type(_ suffix:String)async throws{
                try require(owner.window?.makeFirstResponder(editor)==true && editor.isEditable,"Native message editor cannot accept text")
                let tableID=ObjectIdentifier(table),header=table.headerView!,menu=table.headerView!.menu!,columns=table.tableColumns.map(ObjectIdentifier.init),frames=table.tableColumns.map{($0.width,$0.isHidden)},count=probe.configurationApplications,receipt=m.fileCheckReceipt,checked=m.checked
                let reportEpoch=m.fileReportRevision,rows=probe.rows,bounds=table.bounds,visibleRect=table.visibleRect,enabled=probe.enabled,content=probe.contentRevision,visibilityBefore=visibilityTransitions
                let rowHeight=table.rowHeight,font=probe.fileListFont?.fontName ?? "system",fontSize=probe.fileListFont?.pointSize ?? 0
                let nativeOwner=NativeListSelection.usesFullRowSelection(in:table),eventStart=headerEvents.count
                var defaultsNotifications=0,columnResizes=0,columnMoves=0
                // AppKit posts these for actual native width/order mutations, including
                // a transient reset later restored to the same final widths.
                let resizeObserver=NotificationCenter.default.addObserver(forName:NSTableView.columnDidResizeNotification,object:table,queue:.main){_ in columnResizes += 1}
                let moveObserver=NotificationCenter.default.addObserver(forName:NSTableView.columnDidMoveNotification,object:table,queue:.main){_ in columnMoves += 1}
                let defaultsObserver=NotificationCenter.default.addObserver(forName:UserDefaults.didChangeNotification,object:prefs,queue:.main){_ in defaultsNotifications += 1}
                defer{NotificationCenter.default.removeObserver(defaultsObserver);NotificationCenter.default.removeObserver(resizeObserver);NotificationCenter.default.removeObserver(moveObserver)}
                var expected=m.message
                for scalar in suffix{
                    editor.insertText(String(scalar),replacementRange:NSRange(location:(editor.string as NSString).length,length:0));expected += String(scalar)
                    try await wait(owner){m.message==expected};try await settle(owner)
                    try require(m.fileListTable(key:"checkbox").map(ObjectIdentifier.init)==tableID && table.headerView === header && table.headerView?.menu === menu,"Message-only edit replaced native report/header/menu")
                    var sameLayout=table.tableColumns.map(ObjectIdentifier.init)==columns
                    for(index,column)in table.tableColumns.enumerated(){
                        guard frames.indices.contains(index) else{sameLayout=false;continue}
                        if abs(column.width-frames[index].0)>=0.5 || column.isHidden != frames[index].1{sameLayout=false}
                    }
                    try require(sameLayout,"Message-only edit changed native column layout")
                    let delta="typed=\(String(reflecting:expected)) applications=\(count)->\(probe.configurationApplications) reportEpochChanged=\(reportEpoch != m.fileReportRevision) probeEpochChanged=\(content != probe.contentRevision) rowsChanged=\(rows != probe.rows) bounds=\(bounds)->\(table.bounds) visibleRect=\(visibleRect)->\(table.visibleRect) enabled=\(enabled)->\(probe.enabled) rowHeight=\(rowHeight)->\(table.rowHeight) font=\(font)/\(fontSize)->\(probe.fileListFont?.fontName ?? "system")/\(probe.fileListFont?.pointSize ?? 0) nativeOwner=\(String(describing:nativeOwner))->\(String(describing:NativeListSelection.usesFullRowSelection(in:table))) defaultsNotifications=\(defaultsNotifications) columnResizes=\(columnResizes) columnMoves=\(columnMoves) visibilityTransitions=\(visibilityBefore)->\(visibilityTransitions)"
                    try require(visibilityTransitions==visibilityBefore,"Message-only edit transiently hid or showed native report columns; "+delta)
                    try require(columnResizes==0 && columnMoves==0,"Message-only edit transiently resized or moved native report columns; "+delta)
                    try require(probe.configurationApplications==count,"Message-only edit reapplied native report decoration; "+delta)
                    try require(headerEvents.count==eventStart,"Message-only edit changed native header sequence: \(Array(headerEvents.dropFirst(eventStart))); blocked=\(probe.nativeColumnResetAttempts)")
                    try require(m.fileCheckReceipt==receipt && m.checked==checked,"Typing changed checkbox ownership or inclusion")
                }
                print("Commit header typing sequence: \(Array(headerEvents.dropFirst(eventStart))); blocked native resets=\(probe.rejectedColumnResets)")
            }
            try await type("Review 雪")
            guard let selectable=probe.rows.firstIndex(where:{$0.entry?.path=="alpha.txt"}) else {throw Failure(description:"Tracked selection row missing; visible rows=\(probe.rows.compactMap{$0.entry?.path})") }
            func checkbox()throws->NSButton{
                guard let cell=table.view(atColumn:0,row:selectable,makeIfNecessary:true),let button=views(cell).compactMap({$0 as? NSButton}).first(where:{$0.isEnabled}) else{throw Failure(description:"Live native inclusion checkbox missing")}
                return button
            }
            func selectRows(_ indexes:IndexSet)async throws {
                let eventStart=headerEvents.count,columns=table.tableColumns.map(ObjectIdentifier.init),layout=table.tableColumns.map{($0.width,$0.isHidden)}
                let header=table.headerView!,headerFrame=header.frame,headerBounds=header.bounds,clipBounds=table.enclosingScrollView!.contentView.bounds,columnRects=table.tableColumns.indices.map{table.rect(ofColumn:$0)}
                CommitFileInteraction.replaceSelection(in:table,with:indexes)
                try await wait(owner){table.selectedRowIndexes==indexes && m.nativeFileSelection==Set(indexes.map{GitPathRowIdentity.encode(probe.rows[$0].id)})}
                try await settle(owner)
                try require(table.tableColumns.map(ObjectIdentifier.init)==columns && zip(table.tableColumns,layout).allSatisfy{$0.0.width==$0.1.0 && $0.0.isHidden==$0.1.1},"Selecting native files changed column layout")
                try require(table.headerView === header && header.frame==headerFrame && header.bounds==headerBounds && table.enclosingScrollView!.contentView.bounds==clipBounds && table.tableColumns.indices.map{table.rect(ofColumn:$0)}==columnRects,"Selecting native files moved header, viewport or column rectangles")
                try require(headerEvents.count==eventStart,"File selection changed native header sequence: \(Array(headerEvents.dropFirst(eventStart))); blocked=\(probe.nativeColumnResetAttempts)")
                print("Commit header selection sequence: \(Array(headerEvents.dropFirst(eventStart))); blocked native resets=\(probe.rejectedColumnResets)")
            }
            guard let other=probe.rows.firstIndex(where:{$0.entry?.path=="new.txt"}) else {throw Failure(description:"Unversioned selection row missing; showUnversioned=\(m.showUnversioned) visible rows=\(probe.rows.compactMap{$0.entry?.path})") }
            try await selectRows(IndexSet(integer:selectable))
            try await selectRows(IndexSet([selectable,other]))
            try await selectRows([])
            try await selectRows(IndexSet(integer:other))
            try await selectRows(IndexSet(integer:selectable))
            let selectedIDs=m.nativeFileSelection
            try await type(" selected")
            try require(m.nativeFileSelection==selectedIDs && table.selectedRowIndexes==IndexSet(integer:selectable),"Typing lost accepted native file selection")
            let included=m.checked.contains("alpha.txt")
            try checkbox().performClick(nil);try await wait(owner){m.checked.contains("alpha.txt") != included}
            try await settle(owner);try checkbox().performClick(nil);try await wait(owner){m.checked.contains("alpha.txt")==included}
            guard let nameColumn=table.tableColumns.first(where:{$0.sortDescriptorPrototype != nil && probe.columnDefinition(atNativeIndex:table.tableColumns.firstIndex(of:$0)!) == .fileName}),let descriptor=nameColumn.sortDescriptorPrototype else{throw Failure(description:"Native filename sort missing")}
            let previous=table.sortDescriptors;table.sortDescriptors=[descriptor.reversedSortDescriptor as! NSSortDescriptor];table.dataSource?.tableView?(table,sortDescriptorsDidChange:previous)
            try await wait(owner){m.fileSortOrder.first?.column == .fileName && m.fileSortOrder.first?.order == .reverse}
            try await settle(owner);try await type(" sorted")
            guard let status=table.tableColumns.first(where:{probe.columnDefinition(atNativeIndex:table.tableColumns.firstIndex(of:$0)!) == .status}) else{throw Failure(description:"Status column missing")}
            let visibilityBeforeHide=visibilityTransitions
            m.setFileColumn(.status,visible:false);try await wait(owner){status.isHidden};try await settle(owner)
            try require(visibilityTransitions>visibilityBeforeHide,"Native column visibility observer did not detect the actual Hide command")
            try await type(" after hide")
            m.setFileColumn(.status,visible:true);try await wait(owner){!status.isHidden}
            m.setFileColumn(.fileName,visible:true);try await wait(owner){!nameColumn.isHidden};try await settle(owner)
            let layoutEventStart=headerEvents.count,original=nameColumn
            let beforeWidth=original.width,fromIndex=table.tableColumns.firstIndex(of:original)!
            let requestedWidth=min(original.maxWidth,beforeWidth+31)>beforeWidth ? min(original.maxWidth,beforeWidth+31):max(original.minWidth,beforeWidth-31)
            let toIndex=fromIndex==4 ? 3:4
            // Explicit native layout transaction; this is the same admission
            // used by saved-layout/Fit/Reset application, not a pointer claim.
            probe.withOwnedColumnLayout {native in original.width=requestedWidth;native.moveColumn(fromIndex,toColumn:toIndex)}
            let acceptedWidth=original.width,acceptedIndex=table.tableColumns.firstIndex(of:original)!
            print("Authorized filename layout: beforeWidth=\(beforeWidth) requestedWidth=\(requestedWidth) actualWidth=\(acceptedWidth) min=\(original.minWidth) max=\(original.maxWidth) from=\(fromIndex) requestedIndex=\(toIndex) actualIndex=\(acceptedIndex) events=\(Array(headerEvents.dropFirst(layoutEventStart)))")
            try require(requestedWidth != beforeWidth && acceptedWidth==requestedWidth && acceptedIndex==toIndex,"Native filename layout transaction did not accept its real width/order change")
            probe.rememberNativeColumnLayout(adjustedColumn:.fileName)
            try await settle(owner)
            try require(headerEvents.dropFirst(layoutEventStart).contains(where:{$0.hasPrefix("width ")}) && headerEvents.dropFirst(layoutEventStart).contains(where:{$0.hasPrefix("move ")}),"Native width/order observers missed the authorized layout control; events=\(Array(headerEvents.dropFirst(layoutEventStart))); blocked=\(probe.nativeColumnResetAttempts)")
            let fitIndex=table.tableColumns.firstIndex(of:original)!,expectedFit=probe.fittedWidth(original,definition:.fileName,includeHeader:false)
            try require(probe.fitColumn(atNativeIndex:fitIndex,useDefault:false),"Native header Fit command refused owned columns")
            try await settle(owner);try require(abs(original.width-expectedFit)<=0.5,"Native header Fit did not apply its measured width")
            let saved=m.fileColumns
            try await type(" after resize")
            try require(m.fileColumns==saved && StatusListColumnSettings.load(from:prefs)==saved,"Typing discarded native user column preferences")
            let contentSize=owner.window!.contentView!.bounds.size
            owner.window!.setContentSize(CGSize(width:contentSize.width+160,height:contentSize.height+80))
            try await settle(owner);try require(probe.nativeColumnLayoutReady && m.fileColumns==saved,"Window resizing discarded the saved native column layout")
            try await type(" window resized")
            owner.window!.setContentSize(contentSize);try await settle(owner)
            let beforeHeight=table.rowHeight;prefs.set(true,forKey:"LogFontForFileListCtrl");prefs.set("Menlo",forKey:"LogFontName");prefs.set(19,forKey:"LogFontSize")
            try await wait(owner){table.rowHeight>beforeHeight};try await settle(owner);try await type(" font")
            owner.window?.appearance=NSAppearance(named:.darkAqua);try await settle(owner);try await type(" dark")
            let oldReceipt=m.fileCheckReceipt,oldEntry=m.entries.first(where:{$0.path=="alpha.txt"})!,oldFiles=m.visibleEntries
            try Data("base\n".utf8).write(to:root.appendingPathComponent("alpha.txt"));m.reload(paths:["."])
            try await wait(owner){!m.busy && !m.fileWorkPending && m.commitIdentityPrepared && !m.entries.contains(where:{$0.path=="alpha.txt"})}
            try require(m.fileCheckReceipt != oldReceipt,"Real status replacement retained old check receipt")
            let current=m.checked;m.setFileChecked(oldEntry,files:oldFiles,highlighted:[oldEntry.id],checked:!current.contains(oldEntry.id),receipt:oldReceipt)
            try require(m.checked==current,"Old checkbox callback mutated replacement rows")
            try require(probe.rows.compactMap(\.entry).map(\.path)==m.sortedFiles(m.visibleEntries,statistics:m.statistics).map(\.path),"Real status rows failed to update after typing")
            let originalScroll=table.enclosingScrollView!,originalAlpha=originalScroll.alphaValue
            m.setCommitInterface(true);try await wait(owner){m.gitGuiInterface && table.window !== owner.window}
            try require(originalScroll.alphaValue==originalAlpha,"Retiring the report failed to restore its owned presentation alpha")
            // Switching interface starts a real reload/preflight. The next
            // command must wait for its normal admission, as a user control does.
            try await wait(owner){!m.busy && !m.fileWorkPending && !m.inputsBlocked && m.messageFocusAvailable}
            m.setCommitInterface(false)
            try await wait(owner){!m.gitGuiInterface && m.fileListTable(key:"checkbox")?.window === owner.window && views(owner.window?.contentView).compactMap{$0 as? CommitFileInteraction.Probe}.contains{$0.nativeColumnLayoutReady}}
            m.message="";owner.close();try await wait(owner){drained() && owner.window?.isVisible != true}
            prefs.removePersistentDomain(forName:suite)
            print("PASS: Classic Commit message typing preserves native report headers and layout; real file/column/font/theme transitions and stale checkbox receipts remain live")
        }catch{m.message="";owner.close();for _ in 0..<2000{if drained(){break};try? await Task.sleep(nanoseconds:10_000_000)};prefs.removePersistentDomain(forName:suite);throw error}
    }
}
