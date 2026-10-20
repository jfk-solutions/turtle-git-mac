// SPDX-License-Identifier: GPL-2.0-or-later
import AppKit
import Darwin
import SwiftUI
import TurtleGitCore

@MainActor final class PresentationRevisionWindowModel:ObservableObject {
    struct Failure:LocalizedError {let message:String;var errorDescription:String? {message}}
    let preview:PresentationComparisonPreview
    let protectedInputs:[URL]
    @Published private(set) var review:PresentationRevisionReview?
    @Published private(set) var loading=false
    @Published private(set) var exporting=false
    @Published private(set) var error:String?
    @Published private(set) var savedURL:URL?
    private var changingSelection=false
    @Published var selection:String? {didSet {
        guard !changingSelection else{return};changingSelection=true;defer{changingSelection=false}
        guard canAct else{selection=oldValue;return};onSelection(selected)
    }}
    private var savedDecisions:[String:Bool]=[:]
    private var token:OperationCancellation?
    private var exportToken:OperationCancellation?
    private var generation=UUID()
    private(set) var retired=false
    var actionsAllowed:()->Bool={true}
    var onSelection:(PresentationRevisionChange?)->Void={_ in}
    var encode:@Sendable (PresentationRevisionReview,OperationCancellation)throws->Data={snapshot,token in try snapshot.exported(cancellation:token).encoded(cancellation:token)}
    var write:@Sendable (Data,URL,OperationCancellation)throws->Void={data,url,token in try token.check();try data.write(to:url,options:.atomic)}
    var onBegin:()->Void={}
    var onEnd:()->Void={}
    var canAct:Bool {!retired && !loading && !exporting && actionsAllowed()}
    var isDirty:Bool {!retired && (review?.decisions ?? [:]) != savedDecisions}
    var changes:[PresentationRevisionChange] {review?.changes ?? []}
    var selected:PresentationRevisionChange? {changes.first{$0.id==selection}}
    var unresolvedCount:Int {review?.unresolvedCount ?? 0}
    var canSave:Bool {canAct && review != nil && unresolvedCount==0}
    var suggestedExtension:String {review?.suggestedExtension ?? "pptx"}
    var notices:[String] {review?.notices ?? []}
    var baseSlide:PresentationSlide? {guard let index=selected?.baseSlideIndex,let slides=review?.baseManifest.slides,slides.indices.contains(index) else{return nil};return slides[index]}
    var destinationSlide:PresentationSlide? {guard let index=selected?.destinationSlideIndex,let slides=review?.destinationManifest.slides,slides.indices.contains(index) else{return nil};return slides[index]}
    init(preview:PresentationComparisonPreview,protectedInputs:[URL],initialReview:PresentationRevisionReview? = nil) {self.preview=preview;self.protectedInputs=protectedInputs;review=initialReview;selection=initialReview?.changes.first?.id}
    func start(){
        guard !retired,!loading,review==nil,actionsAllowed() else{return}
        guard ["pptx","pptm"].contains(preview.base.pathExtension.lowercased()),["pptx","pptm"].contains(preview.destination.pathExtension.lowercased()) else {
            error="Editable revision review requires .pptx or .pptm packages. Legacy .ppt remains a read-only visual comparison.";return
        }
        let token=OperationCancellation(),request=UUID(),preview=preview
        self.token=token;generation=request;loading=true;error=nil;onBegin()
        Task { [self] in
            defer {onEnd()}
            do {
                let value=try await Task.detached(priority:.userInitiated){
                    let base=try PresentationPackage.read(from:preview.base,cancellation:token)
                    let destination=try PresentationPackage.read(from:preview.destination,cancellation:token)
                    return try PresentationRevisionReview(base:base,destination:destination,cancellation:token)
                }.value
                guard !retired,generation==request else{return}
                if token.isCancelled {loading=false;self.token=nil;self.error="Editable revision preparation cancelled. Retry to read the captured packages again.";return}
                review=value;loading=false;self.token=nil;selection=value.changes.first?.id
            }catch{
                guard !retired,generation==request else{return};loading=false;self.token=nil
                self.error=token.isCancelled ? "Editable revision preparation cancelled. Retry to read the captured packages again.":error.localizedDescription
            }
        }
    }
    func decide(accept:Bool){guard let selection else{return};decide(changeID:selection,accept:accept)}
    func decide(changeID:String,accept:Bool){guard canAct else{return};review?.decide(changeID:changeID,accept:accept)}
    func decideAll(accept:Bool){guard canAct else{return};review?.decideAll(accept:accept)}
    func undo(){guard canAct else{return};review?.undo()}
    func redo(){guard canAct else{return};review?.redo()}
    func cancel(){token?.cancel();exportToken?.cancel()}
    func retire(){guard !retired else{return};retired=true;generation=UUID();cancel()}
    func validateDestination(_ url:URL,requirePresentationExtension:Bool=true)throws {
        guard url.isFileURL,!requirePresentationExtension || url.pathExtension.lowercased()==suggestedExtension else {throw Failure(message:"Save the editable presentation with the .\(suggestedExtension) extension to preserve its content and macros.")}
        let candidate=url.resolvingSymlinksInPath().standardizedFileURL.path
        let privateRoot=preview.directory.resolvingSymlinksInPath().standardizedFileURL.path
        guard candidate.compare(privateRoot,options:.caseInsensitive) != .orderedSame,
              !candidate.lowercased().hasPrefix(privateRoot.lowercased()+"/") else {throw Failure(message:"Choose an output outside TurtleGit's private comparison files.")}
        var destinationInfo=stat();let exists=stat(url.path,&destinationInfo)==0
        for input in protectedInputs+[preview.base,preview.destination] {
            let path=input.resolvingSymlinksInPath().standardizedFileURL.path
            var inputInfo=stat()
            guard candidate.compare(path,options:.caseInsensitive) != .orderedSame,
                  !(exists && stat(input.path,&inputInfo)==0 && destinationInfo.st_dev==inputInfo.st_dev && destinationInfo.st_ino==inputInfo.st_ino) else {
                throw Failure(message:"Save As must use a separate output file; comparison inputs and their aliases are protected.")
            }
        }
    }
    func save(to url:URL)async throws {
        if Task.isCancelled {throw CancellationError()}
        guard canSave,let snapshot=review else{throw Failure(message:"Resolve every presentation revision before saving an editable copy.")}
        try validateDestination(url)
        let token=OperationCancellation(),request=generation
        exportToken=token;exporting=true;error=nil;onBegin()
        defer {exporting=false;exportToken=nil;onEnd()}
        let decisions=snapshot.decisions,encode=encode,write=write
        do {
            let data=try await withTaskCancellationHandler {
                try await Task.detached(priority:.userInitiated){try encode(snapshot,token)}.value
            } onCancel:{token.cancel()}
            guard !retired,generation==request else{throw CancellationError()}
            if Task.isCancelled {token.cancel()}
            try token.check();try validateDestination(url)
            // Keep the URL grant, private inputs and controller alive until the
            // atomic commit finishes, including a close/cancel racing the write.
            try await withTaskCancellationHandler {
                try await Task.detached(priority:.userInitiated){try write(data,url,token)}.value
            } onCancel:{token.cancel()}
            guard !retired,generation==request else{return}
            savedDecisions=decisions;savedURL=url
        }catch{
            if !retired {self.error=(token.isCancelled || error is CancellationError) ? "Editable presentation export cancelled.":error.localizedDescription}
            throw error
        }
    }
}

struct PresentationRevisionReviewPanel:View {
    @ObservedObject var model:PresentationRevisionWindowModel
    let save:()->Void
    var body:some View {
        VStack(alignment:.leading,spacing:6){
            HStack {
                Text("Editable revision review").font(.headline)
                if model.loading {ProgressView().controlSize(.small);Button("Cancel preparation"){model.cancel()}}
                Spacer()
                if model.review != nil {Text("\(model.unresolvedCount) unresolved\(model.isDirty ? " · Unsaved decisions":"")").font(.caption)}
                Button{model.undo()}label:{CommandLabel(title:"Undo",icon:.mergeUndo)}.keyboardShortcut("z",modifiers:.command).disabled(!model.canAct || model.review?.canUndo != true)
                Button{model.redo()}label:{CommandLabel(title:"Redo",icon:.mergeRedo)}.keyboardShortcut("z",modifiers:[.command,.shift]).disabled(!model.canAct || model.review?.canRedo != true)
                Button{save()}label:{CommandLabel(title:"Save Editable Copy…",icon:.saveAs)}.disabled(!model.canSave)
            }
            if let error=model.error {
                HStack {Text(error).foregroundStyle(.red).textSelection(.enabled);if model.review==nil && !model.loading {Button("Retry"){model.start()}.disabled(!model.actionsAllowed())}}
            }
            if model.review != nil {
                HSplitView {
                    List(selection:$model.selection){ForEach(model.changes,id:\.id){change in
                        HStack {
                            Image(systemName:model.review?.decisions[change.id].map{$0 ? "checkmark.circle.fill":"xmark.circle.fill"} ?? "circle").foregroundStyle(model.review?.decisions[change.id].map{$0 ? Color.green:Color.red} ?? .secondary)
                            Text(change.title).lineLimit(2)
                        }.tag(change.id).contextMenu {
                            Button{model.decide(changeID:change.id,accept:true)}label:{CommandLabel(title:"Accept selected",icon:.add)}.disabled(!model.canAct)
                            Button{model.decide(changeID:change.id,accept:false)}label:{CommandLabel(title:"Reject selected",icon:.revert)}.disabled(!model.canAct)
                        }
                    }}.frame(minWidth:220,idealWidth:340).disabled(!model.canAct)
                    ScrollView {VStack(alignment:.leading,spacing:8){
                        if let change=model.selected {
                            Text(change.title).font(.headline);Text(change.detail).textSelection(.enabled)
                            if model.baseSlide != nil || model.destinationSlide != nil {
                                HStack(alignment:.top){slideDetail(model.baseSlide,title:"Base slide text and notes");Divider();slideDetail(model.destinationSlide,title:"New slide text and notes")}
                            }
                        }
                        else {Text(model.changes.isEmpty ? "No editable package differences.":"Select a revision to inspect its details.")}
                    }.frame(maxWidth:.infinity,alignment:.leading).padding(6)}.frame(minWidth:260)
                }.frame(height:135)
                HStack {
                    Button{model.decide(accept:true)}label:{CommandLabel(title:"Accept selected",icon:.add)}.disabled(!model.canAct || model.selected==nil)
                    Button{model.decide(accept:false)}label:{CommandLabel(title:"Reject selected",icon:.revert)}.disabled(!model.canAct || model.selected==nil)
                    Button{model.decideAll(accept:true)}label:{CommandLabel(title:"Accept all",icon:.add)}.disabled(!model.canAct || model.changes.isEmpty)
                    Button{model.decideAll(accept:false)}label:{CommandLabel(title:"Reject all",icon:.revert)}.disabled(!model.canAct || model.changes.isEmpty)
                    Spacer()
                    if model.exporting {ProgressView().controlSize(.small);Button("Cancel export"){model.cancel()}}
                    if let url=model.savedURL {Text("Saved: \(url.lastPathComponent)").font(.caption).help(url.path)}
                }
                ForEach(Array(model.notices.enumerated()),id:\.offset){_,notice in Text(notice).font(.caption).foregroundStyle(.secondary)}
                Text("Preview shows the original Base and New slides. Accepted and rejected revisions are written to the editable copy; a merged slide preview is not rendered.").font(.caption).foregroundStyle(.secondary)
            }
        }.padding(10)
    }
    private func slideDetail(_ slide:PresentationSlide?,title:String)->some View {
        VStack(alignment:.leading,spacing:4){Text(title).font(.caption).bold();Text(slide?.text ?? "—").textSelection(.enabled);if let notes=slide?.notes,!notes.isEmpty {Text(notes).font(.caption).textSelection(.enabled)}}.frame(maxWidth:.infinity,alignment:.leading)
    }

}
