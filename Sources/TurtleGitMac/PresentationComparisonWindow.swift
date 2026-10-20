// SPDX-License-Identifier: GPL-2.0-or-later
import AppKit
import SwiftUI
import TurtleGitCore

private enum PresentationReviewText {
    static func differs(_ a:String?,_ b:String?)->Bool {
        switch(a,b){case(nil,nil):return false;case(let a?,let b?):return !a.utf8.elementsEqual(b.utf8);default:return true}
    }
}
@MainActor final class PresentationComparisonWindowModel:ObservableObject {
    private(set) static var activeRequests=0
    let preview:PresentationComparisonPreview,manifest:PresentationComparisonManifest
    let revision:PresentationRevisionWindowModel
    let preferences:UserDefaults,baseTitle:String,destinationTitle:String
    private var permissions:[RepositoryAccessLease]
    @Published private(set) var rows:[PresentationSlideComparison]=[]
    // @Published invokes its observer again through the wrapped setter. Guard
    // each control independently so rollback/normalization cannot recurse, while
    // a filter may still legitimately update the separate selection control.
    private enum Control:Hashable {case selection,filter,mode,zoom,fit}
    private var updatingControls=Set<Control>()
    private func changeControl(_ control:Control,rollback:()->Void,apply:()->Void){
        guard !updatingControls.contains(control) else{return}
        updatingControls.insert(control);defer{updatingControls.remove(control)}
        guard canAct else{rollback();return};apply()
    }
    @Published var selection:Int? {didSet {changeControl(.selection,rollback:{selection=oldValue}){if selection != oldValue {renderSelection()}}}}
    @Published var changesOnly=false {didSet {changeControl(.filter,rollback:{changesOnly=oldValue}){
        preferences.set(changesOnly,forKey:"PresentationReview.ChangesOnly")
        if changesOnly != oldValue,!visibleIndices.contains(selection ?? -1){selection=visibleIndices.first}
    }}}
    enum Mode:String,CaseIterable {case paired="Side by side",overlay="Overlay",difference="Differences"}
    @Published var mode=Mode.paired {didSet {changeControl(.mode,rollback:{mode=oldValue}){preferences.set(mode.rawValue,forKey:"PresentationReview.Mode")}}}
    @Published var zoom:Double=1 {didSet {changeControl(.zoom,rollback:{zoom=oldValue}){
        guard zoom.isFinite else{zoom=oldValue;return}
        let normalized=min(8,max(0.1,zoom));if zoom != normalized {zoom=normalized}
        preferences.set(zoom,forKey:"PresentationReview.Zoom")
    }}}
    @Published var fit=true {didSet {changeControl(.fit,rollback:{fit=oldValue}){preferences.set(fit,forKey:"PresentationReview.Fit")}}}
    @Published var confirmingQuit=false
    @Published private(set) var busy=false
    @Published private(set) var rendering=false
    @Published private(set) var error:String?
    @Published private(set) var renderError:String?
    @Published private(set) var images:PresentationComparisonRendering.Pair?
    private var token:OperationCancellation?,renderToken:OperationCancellation?
    private var generation=UUID(),renderGeneration=UUID()
    private(set) var retired=false,pending=0
    var onDrain:()->Void={}
    var clipboard:NSPasteboard = .general
    var actionsAllowed:()->Bool={true}
    var canAct:Bool {!retired && !confirmingQuit && actionsAllowed()}
    var visibleIndices:[Int] {rows.indices.filter{!changesOnly || rows[$0].change != .unchanged || rows[$0].isMoved}}
    var current:PresentationSlideComparison? {selection.flatMap{rows.indices.contains($0) ? rows[$0]:nil}}
    var sourcePreviewsAvailable:Bool {FileManager.default.fileExists(atPath:preview.basePDF.path) && FileManager.default.fileExists(atPath:preview.destinationPDF.path)}
    var summary:String {
        let added=rows.filter{$0.change == .added}.count,deleted=rows.filter{$0.change == .deleted}.count
        let modified=rows.filter{$0.change == .modified}.count,moved=rows.filter(\.isMoved).count
        return "\(added) added · \(deleted) deleted · \(modified) modified · \(moved) moved"
    }
    init(preview:PresentationComparisonPreview,manifest:PresentationComparisonManifest,permissions:[RepositoryAccessLease],preferences:UserDefaults,baseTitle:String,destinationTitle:String,protectedInputs:[URL]=[],initialReview:PresentationRevisionReview?=nil) {
        revision=PresentationRevisionWindowModel(preview:preview,protectedInputs:protectedInputs,initialReview:initialReview)
        self.preview=preview;self.manifest=manifest;self.permissions=permissions;self.preferences=preferences;self.baseTitle=baseTitle;self.destinationTitle=destinationTitle
        mode=Mode(rawValue:preferences.string(forKey:"PresentationReview.Mode") ?? "") ?? .paired
        changesOnly=preferences.bool(forKey:"PresentationReview.ChangesOnly")
        fit=(preferences.object(forKey:"PresentationReview.Fit") as? NSNumber)?.boolValue ?? true
        let saved=preferences.double(forKey:"PresentationReview.Zoom");zoom=saved.isFinite && (0.1...8).contains(saved) ? saved:1
        revision.actionsAllowed={ [weak self] in self?.canAct==true }
        revision.onSelection={ [weak self] change in
            guard let self,let change,let index=rows.firstIndex(where:{row in
                (change.baseSlideIndex != nil && row.base?.pageIndex==change.baseSlideIndex) || (change.destinationSlideIndex != nil && row.destination?.pageIndex==change.destinationSlideIndex)
            }) else{return};selection=index
        }
        revision.onBegin={ [weak self] in self?.begin() }
        revision.onEnd={ [weak self] in self?.end() }
    }
    private func begin(){pending+=1;Self.activeRequests+=1}
    private func end(){pending-=1;Self.activeRequests-=1;if retired && pending==0 {onDrain()}}
    func start(){
        guard canAct,!busy else{return}
        revision.start()
        token?.cancel();renderToken?.cancel();let token=OperationCancellation(),request=UUID();self.token=token;generation=request
        busy=true;error=nil;rows=[];selection=nil;images=nil;begin()
        let preview=preview,manifest=manifest
        Task { [self] in
            defer {end();withExtendedLifetime(permissions){}}
            do {
                let report=try await Task.detached(priority:.userInitiated){
                    guard FileManager.default.fileExists(atPath:preview.basePDF.path),FileManager.default.fileExists(atPath:preview.destinationPDF.path) else {return try PresentationComparisonReport(base:manifest.base.slides,destination:manifest.destination.slides,cancellation:token)}
                    let fingerprints=try PresentationComparisonRendering.fingerprints(base:preview.basePDF,destination:preview.destinationPDF,baseCount:manifest.base.slides.count,destinationCount:manifest.destination.slides.count,cancellation:token)
                    func enriched(_ slides:[PresentationSlide],_ hashes:[String])->[PresentationSlide] {zip(slides,hashes).map{slide,hash in PresentationSlide(pageIndex:slide.pageIndex,stableID:slide.stableID,text:slide.text,notes:slide.notes,visualFingerprint:hash)}}
                    return try PresentationComparisonReport(base:enriched(manifest.base.slides,fingerprints.0),destination:enriched(manifest.destination.slides,fingerprints.1),cancellation:token)
                }.value
                guard !retired,generation==request else{return}
                if token.isCancelled {busy=false;self.token=nil;self.error="Review preparation cancelled. Retry to prepare the slides again.";return}
                rows=report.rows;busy=false;self.token=nil;selection=visibleIndices.first
            }catch{
                guard !retired,generation==request else{return};busy=false;self.token=nil
                if !token.isCancelled {self.error=error.localizedDescription}else{self.error="Review preparation cancelled. Retry to prepare the slides again."}
            }
        }
    }
    func cancel(){guard !retired else{return};token?.cancel();renderToken?.cancel();revision.cancel()}
    func retire(){guard !retired else{return};retired=true;revision.retire();token?.cancel();renderToken?.cancel();generation=UUID();renderGeneration=UUID();if pending==0 {onDrain()}}
    func releaseResources(){guard retired,pending==0 else{return};permissions=[];images=nil}
    func renderSelection(){
        renderToken?.cancel();renderGeneration=UUID();images=nil;renderError=nil
        guard canAct,let current else{rendering=false;return}
        guard sourcePreviewsAvailable else{rendering=false;return}
        let token=OperationCancellation(),request=renderGeneration;renderToken=token;rendering=true;begin()
        let preview=preview,baseCount=manifest.base.slides.count,destinationCount=manifest.destination.slides.count
        Task { [self] in
            defer {end();withExtendedLifetime(permissions){}}
            do {
                let pair=try await Task.detached(priority:.userInitiated){try PresentationComparisonRendering.pair(base:preview.basePDF,destination:preview.destinationPDF,baseCount:baseCount,destinationCount:destinationCount,baseIndex:current.base?.pageIndex,destinationIndex:current.destination?.pageIndex,cancellation:token)}.value
                guard !retired,renderGeneration==request else{return};rendering=false;renderToken=nil
                if token.isCancelled {renderError="Slide rendering cancelled. Retry to display this slide again.";return};images=pair
            }catch{guard !retired,renderGeneration==request else{return};rendering=false;renderToken=nil;renderError=token.isCancelled ? "Slide rendering cancelled. Retry to display this slide again.":error.localizedDescription}
        }
    }
    func navigate(_ delta:Int,changes:Bool=true){
        guard canAct,!busy else{return}
        let indices=visibleIndices.filter{!changes || rows[$0].change != .unchanged || rows[$0].isMoved}
        let current=selection ?? (delta>0 ? -1:rows.count)
        selection=delta>0 ? indices.first{$0>current} ?? selection:indices.last{$0<current} ?? selection
    }
    func copyReview(){guard canAct,!rows.isEmpty else{return};clipboard.clearContents();clipboard.setString(reviewText,forType:.string)}
    var reviewText:String {
        var result="TurtleGit presentation comparison\n\(baseTitle) → \(destinationTitle)\n\(summary)\n\n"
        for (index,row) in rows.enumerated() {
            result+="\(index+1). \(row.change)\(row.isMoved ? " (moved)":"") — Base \(row.base.map{String($0.pageIndex+1)} ?? "—") / New \(row.destination.map{String($0.pageIndex+1)} ?? "—")\n"
            if PresentationReviewText.differs(row.base?.text,row.destination?.text) {result+="Base text:\n\(row.base?.text ?? "")\nNew text:\n\(row.destination?.text ?? "")\n"}
            if PresentationReviewText.differs(row.base?.notes,row.destination?.notes) {result+="Base notes:\n\(row.base?.notes ?? "")\nNew notes:\n\(row.destination?.notes ?? "")\n"}
            result+="\n"
        }
        if let review=revision.review {
            result+="Editable revision decisions\n"
            for change in review.changes {
                let decision=review.decisions[change.id].map{$0 ? "Accepted New":"Rejected Base"} ?? "Unresolved"
                result+="\(decision): \(change.title)\n\(change.detail)\n"
            }
        }
        return result
    }
    func reserveExport(){begin()}
    func finishExport(){end()}
    func exportReview(to url:URL)throws {guard canAct,!rows.isEmpty else{return};try revision.validateDestination(url,requirePresentationExtension:false);try Data(reviewText.utf8).write(to:url,options:.atomic)}
}

@MainActor final class PresentationComparisonWindowController:NSWindowController,NSWindowDelegate {
    let model:PresentationComparisonWindowModel
    var onClosed:()->Void={}
    private var closing=false,released=false
    private var retirementOwner:PresentationComparisonWindowController?
    private var panel:NSSavePanel?
    private var exportError:NSAlert?
    private var exportErrorReply:(()->Void)?
    var presentExport:(NSSavePanel,NSWindow,@escaping(NSApplication.ModalResponse)->Void)->Void = {panel,window,reply in panel.beginSheetModal(for:window,completionHandler:reply)}
    var selectedExportURL:(NSSavePanel)->URL? = {$0.url}
    var exportErrorWindow:NSWindow? {exportError?.window}
    private var exporting=false
    private var closeAfterExport=false
    private var discardAlert:NSAlert?
    private var discardReply:((Bool)->Void)?
    var presentDiscard:(NSAlert,NSWindow,@escaping(Bool)->Void)->Void={alert,window,reply in alert.beginSheetModal(for:window){reply($0 == .alertFirstButtonReturn)}}
    init(preview:PresentationComparisonPreview,manifest:PresentationComparisonManifest,permissions:[RepositoryAccessLease],preferences:UserDefaults,baseTitle:String,destinationTitle:String,protectedInputs:[URL]=[],initialReview:PresentationRevisionReview?=nil) {
        model=PresentationComparisonWindowModel(preview:preview,manifest:manifest,permissions:permissions,preferences:preferences,baseTitle:baseTitle,destinationTitle:destinationTitle,protectedInputs:protectedInputs,initialReview:initialReview)
        let window=NSWindow(contentRect:NSRect(x:0,y:0,width:1240,height:1000),styleMask:[.titled,.closable,.resizable,.miniaturizable],backing:.buffered,defer:false)
        window.title="\(baseTitle) → \(destinationTitle) — Presentation comparison — TurtleGit";window.isReleasedWhenClosed=false;window.minSize=NSSize(width:950,height:760)
        super.init(window:window);window.delegate=self
        window.contentViewController=NSHostingController(rootView:PresentationComparisonDialog(model:model,saveEditable:{ [weak self] in self?.chooseEditableExport() },export:{ [weak self] in self?.chooseExport() },close:{ [weak self] in self?.close() }))
        model.actionsAllowed={ [weak self,weak window] in self?.closing==false && self?.exportError==nil && window?.attachedSheet==nil }
        model.onDrain={ [weak self] in self?.finishClose() }
        window.center();DialogGeometry.attach(window,identifier:"PresentationComparison");TurtleGitHelp.attach(window,topic:.presentations);model.start()
    }
    required init?(coder:NSCoder){fatalError("init(coder:) is not supported")}
    override func close(){
        guard !closing else{finishClose();return}
        guard discardAlert==nil else{return}
        if exporting {closeAfterExport=true;model.revision.cancel();panel?.cancel(nil);return}
        if model.revision.isDirty {
            guard let window,window.attachedSheet==nil,!exporting else{return}
            let alert=NSAlert();alert.messageText="Discard presentation review decisions?"
            alert.informativeText="Save an editable copy before closing to keep your accepted and rejected revisions."
            alert.addButton(withTitle:"Discard");alert.addButton(withTitle:"Cancel");alert.buttons[1].keyEquivalent="\r"
            alert.window.appearance=window.appearance;alert.window.alphaValue=window.alphaValue
            discardAlert=alert;model.confirmingQuit=true;model.reserveExport()
            var answered=false
            let reply:(Bool)->Void={ [self] discard in
                guard !answered else{return};answered=true
                Task { @MainActor [self] in
                    while window.attachedSheet===alert.window {try? await Task.sleep(nanoseconds:5_000_000)}
                    discardAlert=nil;discardReply=nil;model.confirmingQuit=false;model.finishExport()
                    if discard {closeConfirmed()}
                }
            }
            discardReply=reply;presentDiscard(alert,window,reply);return
        }
        closeConfirmed()
    }
    func confirmQuit()async->Bool {
        guard model.revision.isDirty else{return true}
        guard !closing,discardAlert==nil,let window,window.attachedSheet==nil else{return false}
        let alert=NSAlert();alert.messageText="Discard presentation review decisions before quitting?"
        alert.informativeText="Save an editable copy before quitting to keep your accepted and rejected revisions."
        alert.addButton(withTitle:"Discard");alert.addButton(withTitle:"Cancel");alert.buttons[1].keyEquivalent="\r"
        alert.window.appearance=window.appearance;alert.window.alphaValue=window.alphaValue
        discardAlert=alert;model.reserveExport()
        return await withCheckedContinuation {continuation in
            var answered=false
            let reply:(Bool)->Void={ [self] discard in
                guard !answered else{return};answered=true
                Task { @MainActor [self] in
                    while window.attachedSheet===alert.window {try? await Task.sleep(nanoseconds:5_000_000)}
                    discardAlert=nil;discardReply=nil;model.finishExport();continuation.resume(returning:discard)
                }
            }
            discardReply=reply;presentDiscard(alert,window,reply)
        }
    }
    func discardAfterApprovedQuit(){closeConfirmed()}
    private func closeConfirmed(){
        guard !closing else{return};retirementOwner=self;closing=true;model.retire();panel?.cancel(nil);cancelExportError()
        window?.orderOut(nil);super.close();finishClose()
    }
    func windowShouldClose(_ sender:NSWindow)->Bool {guard !exporting,sender.attachedSheet==nil else{return false};close();return false}
    func windowWillClose(_ notification:Notification){retirementOwner=self;closing=true;model.retire();panel?.cancel(nil);cancelExportError();finishClose()}
    private func finishClose(){
        guard closing,!released,model.pending==0,!exporting,exportError==nil,window?.attachedSheet==nil else{return}
        released=true;model.onDrain={};model.releaseResources();model.preview.discard();onClosed();retirementOwner=nil
    }
    private func cancelExportError(){
        guard let alert=exportError else{return}
        if let parent=alert.window.sheetParent {parent.endSheet(alert.window,returnCode:.abort)}
        alert.window.orderOut(nil);exportErrorReply?()
    }
    private func showExportError(_ error:Error){
        guard !closing,exportError==nil,let window,window.attachedSheet==nil else{return}
        let alert=NSAlert(error:error);alert.window.appearance=window.appearance;alert.window.alphaValue=window.alphaValue
        exportError=alert;model.reserveExport();var answered=false
        let reply:()->Void={ [self] in
            guard !answered else{return};answered=true
            Task { @MainActor [self] in
                while alert.window.sheetParent != nil || window.attachedSheet===alert.window {try? await Task.sleep(nanoseconds:5_000_000)}
                if exportError===alert {exportError=nil;exportErrorReply=nil}
                model.finishExport();finishClose()
            }
        }
        exportErrorReply=reply
        alert.beginSheetModal(for:window,completionHandler:{_ in reply()})
    }
    func chooseEditableExport(){
        guard model.canAct,model.revision.canSave,!exporting,let window,window.attachedSheet==nil else{return}
        let panel=NSSavePanel();panel.nameFieldStringValue="Reviewed presentation."+model.revision.suggestedExtension;panel.title="Save Editable Copy"
        self.panel=panel;exporting=true;model.reserveExport()
        presentExport(panel,window){ [self] response in
            Task { @MainActor [self] in
                while window.attachedSheet===panel {try? await Task.sleep(nanoseconds:5_000_000)}
                defer {exporting=false;self.panel=nil;model.finishExport();finishClose();if closeAfterExport {closeAfterExport=false;close()}}
                guard !closing,response == .OK,let url=selectedExportURL(panel) else{return}
                let granted=url.startAccessingSecurityScopedResource();defer {if granted{url.stopAccessingSecurityScopedResource()}}
                do {try await model.revision.save(to:url)}catch{if !closing && !(error is OperationCancellationFailure) && !(error is CancellationError){showExportError(error)}}
            }
        }
    }
    func chooseExport(){
        guard model.canAct,!model.rows.isEmpty,!exporting,let window,window.attachedSheet==nil else{return}
        let panel=NSSavePanel();panel.nameFieldStringValue="Presentation comparison.txt";panel.title="Export Review";self.panel=panel;exporting=true;model.reserveExport()
        presentExport(panel,window){ [self] response in
            Task { @MainActor [self] in
                // Release the sheet before allowing another request or close.
                while window.attachedSheet===panel {try? await Task.sleep(nanoseconds:5_000_000)}
                defer {exporting=false;self.panel=nil;model.finishExport();finishClose();if closeAfterExport {closeAfterExport=false;close()}}
                guard !closing,response == .OK,let url=selectedExportURL(panel) else{return}
                let granted=url.startAccessingSecurityScopedResource();defer {if granted{url.stopAccessingSecurityScopedResource()}}
                do {try model.exportReview(to:url)}catch{showExportError(error)}
            }
        }
    }
}
private struct PresentationComparisonDialog:View {
    @ObservedObject var model:PresentationComparisonWindowModel
    let saveEditable:()->Void,export:()->Void,close:()->Void
    private func status(_ row:PresentationSlideComparison)->Color {
        switch row.change {case .added:return .green;case .deleted:return .red;case .modified:return .orange;case .unchanged:return row.isMoved ? .blue:.secondary}
    }
    private func icon(_ row:PresentationSlideComparison)->MenuIcon {switch row.change {case .added:return .add;case .deleted:return .revert;case .modified:return .compare;case .unchanged:return row.isMoved ? .mergeMoved:.status}}
    var body:some View {
        VStack(spacing:0){
            HStack {
                Button{model.navigate(-1)}label:{CommandLabel(title:"Previous change",icon:.mergePreviousDifference)}
                Button{model.navigate(1)}label:{CommandLabel(title:"Next change",icon:.mergeNextDifference)}
                Toggle("Changes only",isOn:$model.changesOnly).toggleStyle(.checkbox)
                Spacer();Picker("View",selection:$model.mode){ForEach(PresentationComparisonWindowModel.Mode.allCases,id:\.self){Text($0.rawValue).tag($0)}}.frame(width:220).disabled(!model.sourcePreviewsAvailable)
                Button("−"){model.fit=false;model.zoom=max(0.1,model.zoom/1.25)}.disabled(!model.sourcePreviewsAvailable)
                Text(model.fit ? "Fit":"\(Int(model.zoom*100))%").frame(width:45)
                Button("+"){model.fit=false;model.zoom=min(8,model.zoom*1.25)}.disabled(!model.sourcePreviewsAvailable)
                Button("Fit"){model.fit=true}.disabled(!model.sourcePreviewsAvailable)
            }.padding(10).disabled(!model.canAct || model.busy)
            Divider()
            HSplitView {
                List(selection:$model.selection){ForEach(model.visibleIndices,id:\.self){index in
                    let row=model.rows[index]
                    HStack(alignment:.top){Image(nsImage:icon(row).contextImage(defaults:model.preferences) ?? NSImage()).frame(width:16,height:16)
                        VStack(alignment:.leading){Text("\(row.base.map{String($0.pageIndex+1)} ?? "—") → \(row.destination.map{String($0.pageIndex+1)} ?? "—")").font(.headline)
                            Text(String(describing:row.change).capitalized+(row.isMoved ? " · Moved":"")).foregroundStyle(status(row))
                            Text((row.destination?.text ?? row.base?.text ?? "").prefix(90)).lineLimit(2).font(.caption)
                        }
                    }.tag(index)
                }}.frame(minWidth:180,idealWidth:210,maxWidth:300).disabled(!model.canAct || model.busy)
                VStack(spacing:4){
                    if model.busy {ProgressView("Preparing slide comparison…").frame(maxWidth:.infinity,maxHeight:.infinity)}
                    else if let error=model.error {Text(error).foregroundStyle(.red).textSelection(.enabled);Button("Retry"){model.start()}.disabled(!model.canAct)}
                    else if model.rows.isEmpty {Text("No slides in either presentation.").frame(maxWidth:.infinity,maxHeight:.infinity)}
                    else if model.visibleIndices.isEmpty {Text("No changed slides.").frame(maxWidth:.infinity,maxHeight:.infinity)}
                    else {
                        HStack {Text(model.baseTitle).lineLimit(1).help(model.baseTitle);Spacer();Text(model.destinationTitle).lineLimit(1).help(model.destinationTitle)}.font(.caption).padding(.horizontal,8)
                        if model.sourcePreviewsAvailable {
                            PresentationSlideCanvas(images:model.images,mode:model.mode,fit:model.fit,zoom:model.zoom).overlay{if model.rendering{ProgressView()}}
                            if let error=model.renderError {HStack{Text(error).foregroundStyle(.red);Button("Retry"){model.renderSelection()}}.padding(6)}
                        } else {
                            VStack(spacing:12){
                                Image(systemName:"doc.text.magnifyingglass").font(.system(size:36)).foregroundStyle(.secondary)
                                Text("Source slide previews require Microsoft PowerPoint.").font(.headline)
                                Text("Review the package revisions below. Accept or reject changes and save an editable copy.").font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
                            }.padding(24).frame(maxWidth:.infinity,maxHeight:.infinity).frame(minHeight:230).background(Color(nsColor:.controlBackgroundColor))
                        }
                        if let row=model.current {DisclosureGroup("Text and notes") {
                            HStack(alignment:.top){details(row.base,changedText:PresentationReviewText.differs(row.base?.text,row.destination?.text),changedNotes:PresentationReviewText.differs(row.base?.notes,row.destination?.notes));Divider();details(row.destination,changedText:PresentationReviewText.differs(row.base?.text,row.destination?.text),changedNotes:PresentationReviewText.differs(row.base?.notes,row.destination?.notes))}.frame(height:150)
                        }.padding(8)}
                    }
                }.frame(minWidth:570,maxWidth:.infinity,maxHeight:.infinity)
            }
            Divider()
            PresentationRevisionReviewPanel(model:model.revision,save:saveEditable)
            Divider()
            HStack {Text(model.summary).font(.caption);Spacer();if model.busy || model.rendering{Button("Cancel"){model.cancel()}};Button{model.copyReview()}label:{CommandLabel(title:"Copy Review",icon:.copy)}.disabled(!model.canAct || model.rows.isEmpty);Button{export()}label:{CommandLabel(title:"Export Review…",icon:.saveAs)}.disabled(!model.canAct || model.rows.isEmpty);Button("Close",action:close).keyboardShortcut(.cancelAction);Button("Help"){if model.canAct{TurtleGitHelp.show(.presentations)}}.disabled(!model.canAct)}.padding(10)
            Text("Source visual comparison and editable package revision review. Animations and macro execution are not previewed.").font(.caption).foregroundStyle(.secondary).padding(.bottom,8)
        }
    }
    private func details(_ slide:PresentationSlide?,changedText:Bool,changedNotes:Bool)->some View {
        ScrollView{VStack(alignment:.leading,spacing:6){Text("Slide text").font(.headline).foregroundStyle(changedText ? Color.orange:.primary);Text(slide?.text ?? "—");Text("Notes").font(.headline).foregroundStyle(changedNotes ? Color.orange:.primary);Text(slide?.notes ?? "—")}.frame(maxWidth:.infinity,alignment:.leading).textSelection(.enabled)}.frame(maxWidth:.infinity)
    }
}
private struct PresentationSlideCanvas:View {
    let images:PresentationComparisonRendering.Pair?,mode:PresentationComparisonWindowModel.Mode,fit:Bool,zoom:Double
    var body:some View {
        GeometryReader{geometry in
            ScrollView([.horizontal,.vertical]){
                let paired=mode == .paired,width=max(100,(geometry.size.width-(paired ? 18:8))/(paired ? 2:1))
                HStack(alignment:.top,spacing:10){
                    if paired {page(images?.base,width:width,height:geometry.size.height-8);page(images?.destination,width:width,height:geometry.size.height-8)}
                    else if mode == .difference {page(images?.difference,width:width,height:geometry.size.height-8)}
                    else {ZStack{page(images?.base,width:width,height:geometry.size.height-8);page(images?.destination,width:width,height:geometry.size.height-8).opacity(0.5)}}
                }.padding(4)
            }.background(Color(nsColor:.underPageBackgroundColor))
        }.frame(minHeight:230)
    }
    @ViewBuilder private func page(_ raster:PresentationComparisonRendering.Raster?,width:CGFloat,height:CGFloat)->some View {
        if let raster,let image=raster.image {
            let scale=fit ? min(width/CGFloat(raster.width),max(1,height)/CGFloat(raster.height)):zoom
            Image(nsImage:image).resizable().interpolation(.high).frame(width:CGFloat(raster.width)*scale,height:CGFloat(raster.height)*scale).background(.white).border(Color.secondary)
        }else{Text("No slide").foregroundStyle(.secondary).frame(width:width,height:max(100,height))}
    }
}
