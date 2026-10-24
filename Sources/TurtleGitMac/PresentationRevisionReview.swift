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
    enum PreviewMode:String,CaseIterable {case sources="Source slides",result="Combined result"}
    enum SaveFormat:String,CaseIterable {case openXML="OpenXML presentation",legacy="PowerPoint 97–2003 (.ppt)"}
    private var changingPreviewMode=false
    @Published var previewMode=PreviewMode.sources {didSet {
        guard !changingPreviewMode else{return};changingPreviewMode=true;defer{changingPreviewMode=false}
        guard !retired,actionsAllowed() else{previewMode=oldValue;return};preferences?.set(previewMode.rawValue,forKey:"PresentationReview.PreviewMode")
    }}
    private var changingSaveFormat=false
    @Published var saveFormat=SaveFormat.openXML {didSet {
        guard !changingSaveFormat else{return};changingSaveFormat=true;defer{changingSaveFormat=false}
        if !canAct {saveFormat=oldValue}
    }}
    @Published private(set) var resultBusy=false
    @Published private(set) var resultRendering=false
    @Published private(set) var resultError:String?
    @Published private(set) var resultManifest:PresentationSlideManifest?
    @Published private(set) var resultImages:PresentationComparisonRendering.Pair?
    private var changingResultSelection=false
    @Published var resultSelection:Int? {didSet {
        guard !changingResultSelection else{return};changingResultSelection=true;defer{changingResultSelection=false}
        guard !retired,actionsAllowed() else{resultSelection=oldValue;return}
        if resultSelection != oldValue {renderResultSelection()}
    }}
    private var resultPDF:URL?
    private var resultDecisions:[String:Bool]?
    private var decisionGeneration=UUID(),resultPageGeneration=UUID()
    private var resultToken:OperationCancellation?,resultPageToken:OperationCancellation?
    private(set) var retainPrivateArtifacts=false
    private let preferences:UserDefaults?
    var renderResult:(URL,URL,OperationCancellation)async throws->PresentationSlideManifest={package,pdf,token in try await PowerPointComparisonAutomation.renderResult(package:package,pdf:pdf,cancellation:token)}
    var convertLegacyResult:(URL,URL,OperationCancellation)async throws->Void={package,output,token in try await PowerPointComparisonAutomation.convertLegacyResult(package:package,output:output,cancellation:token)}
    var hasLegacyInput:Bool {[preview.base,preview.destination].contains{$0.pathExtension.lowercased()=="ppt"}}
    var preferredSaveExtension:String {saveFormat == .legacy ? "ppt":suggestedExtension}
    var resultIsCurrent:Bool {resultManifest != nil && resultDecisions==review?.decisions}
    var canPreviewResult:Bool {canSave && !resultBusy && !resultIsCurrent}
    var resultSlide:PresentationSlide? {guard let resultSelection,let slides=resultManifest?.slides,slides.indices.contains(resultSelection) else{return nil};return slides[resultSelection]}
    enum ReviewEntries:String,CaseIterable {case all="All revisions",comments="Comments"}
    private var changingEntries=false
    @Published var reviewEntries=ReviewEntries.all {didSet {
        guard !changingEntries else{return};changingEntries=true;defer{changingEntries=false}
        guard canAct else{reviewEntries=oldValue;return}
        preferences?.set(reviewEntries.rawValue,forKey:"PresentationReview.Entries")
        if !visibleChanges.contains(where:{$0.id==selection}) {selection=visibleChanges.first?.id}
    }}
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
    var commentRows:[PresentationRevisionChange] {
        guard let review else{return []}
        let changed=Dictionary(uniqueKeysWithValues:changes.map{($0.id,$0)})
        return review.commentChanges.map {id,pair in
            if let existing=changed[id] {return existing}
            let comment=pair.destination ?? pair.base!
            return PresentationRevisionChange(id:id,title:"Slide \(comment.slideIndex+1): Comment by "+comment.author,detail:"Unchanged comment",baseSlideIndex:pair.base?.slideIndex,destinationSlideIndex:pair.destination?.slideIndex,kind:.commentChanged)
        }.sorted {a,b in
            let lhs=review.commentChanges[a.id]!,rhs=review.commentChanges[b.id]!
            let l=lhs.destination ?? lhs.base!,r=rhs.destination ?? rhs.base!
            if l.slideIndex != r.slideIndex {return l.slideIndex<r.slideIndex}
            if l.threadID != r.threadID {return l.threadID<r.threadID}
            if l.depth != r.depth {return l.depth<r.depth}
            return a.id<b.id
        }
    }
    var visibleChanges:[PresentationRevisionChange] {reviewEntries == .comments ? commentRows:changes}
    var selected:PresentationRevisionChange? {(changes+commentRows).first{$0.id==selection}}
    var selectedComment:PresentationCommentChange? {guard let selection else{return nil};return review?.commentChanges[selection]}
    var selectedCommentIsDeleted:Bool {guard let selection else{return false};return review?.commentIsDeleted(changeID:selection)==true}
    var selectedCommentCanRestore:Bool {guard let selection else{return false};return canAct && review?.commentIsDirectlyDeleted(changeID:selection)==true}
    var canDecideSelected:Bool {guard let selection else{return false};return canAct && changes.contains{$0.id==selection}}
    func decisionLabel(_ id:String)->String {
        if review?.commentIsDeleted(changeID:id)==true{return "Deleted comment"}
        if !changes.contains(where:{$0.id==id}) {return "Unchanged"}
        return PresentationRevisionChangePresentation.decision(review?.decisions[id])
    }
    private func commentDestination(_ delta:Int)->String? {
        let ordered=commentRows.map(\.id)
        guard !ordered.isEmpty else{return nil}
        guard let current=ordered.firstIndex(where:{$0==selection}) else{return delta>0 ? ordered.first:ordered.last}
        let next=current+delta;return ordered.indices.contains(next) ? ordered[next]:nil
    }
    func canNavigateComment(_ delta:Int)->Bool {canAct && commentDestination(delta) != nil}
    func navigateComment(_ delta:Int){guard canAct,let id=commentDestination(delta) else{return};reviewEntries = .comments;selection=id}
    func selectCommentRecord(_ recordID:String,destination:Bool) {
        guard canAct,let review,let id=review.commentChanges.first(where:{destination ? $0.value.destination?.id==recordID:$0.value.base?.id==recordID})?.key else{return}
        reviewEntries = .comments;selection=id
    }
    func deleteComment(_ id:String? = nil){guard canAct,let id=id ?? selection,review?.commentChanges[id] != nil else{return};let before=review?.decisions;review?.deleteComment(changeID:id);decisionsChanged(before)}
    func restoreComment(_ id:String? = nil){guard canAct,let id=id ?? selection,review?.commentIsDirectlyDeleted(changeID:id)==true else{return};let before=review?.decisions;review?.restoreComment(changeID:id);decisionsChanged(before)}
    var unresolvedCount:Int {review?.unresolvedCount ?? 0}
    var canSave:Bool {canAct && review != nil && unresolvedCount==0}
    var suggestedExtension:String {review?.suggestedExtension ?? "pptx"}
    var notices:[String] {review?.notices ?? []}
    var baseSlide:PresentationSlide? {guard let index=selected?.baseSlideIndex,let slides=review?.baseManifest.slides,slides.indices.contains(index) else{return nil};return slides[index]}
    var destinationSlide:PresentationSlide? {guard let index=selected?.destinationSlideIndex,let slides=review?.destinationManifest.slides,slides.indices.contains(index) else{return nil};return slides[index]}
    init(preview:PresentationComparisonPreview,protectedInputs:[URL],initialReview:PresentationRevisionReview? = nil,preferences:UserDefaults?=nil) {
        self.preview=preview;self.protectedInputs=protectedInputs;self.preferences=preferences;review=initialReview;selection=initialReview?.changes.first?.id
        reviewEntries=ReviewEntries(rawValue:preferences?.string(forKey:"PresentationReview.Entries") ?? "") ?? .all
        previewMode=PreviewMode(rawValue:preferences?.string(forKey:"PresentationReview.PreviewMode") ?? "") ?? .sources
        saveFormat=[preview.base,preview.destination].contains{$0.pathExtension.lowercased()=="ppt"} ? .legacy:.openXML
        selection=visibleChanges.first?.id
    }
    func start(){
        guard !retired,!loading,review==nil,actionsAllowed() else{return}
        guard FileManager.default.fileExists(atPath:preview.basePackage.path),FileManager.default.fileExists(atPath:preview.destinationPackage.path) else {
            error="Editable binary presentation review requires Microsoft PowerPoint to convert the captured inputs to private OpenXML packages.";return
        }
        let token=OperationCancellation(),request=UUID(),preview=preview
        self.token=token;generation=request;loading=true;error=nil;onBegin()
        Task { [self] in
            defer {onEnd()}
            do {
                let value=try await Task.detached(priority:.userInitiated){
                    let base=try PresentationPackage.read(from:preview.basePackage,cancellation:token)
                    let destination=try PresentationPackage.read(from:preview.destinationPackage,cancellation:token)
                    return try PresentationRevisionReview(base:base,destination:destination,cancellation:token)
                }.value
                guard !retired,generation==request else{return}
                if token.isCancelled {loading=false;self.token=nil;self.error="Editable revision preparation cancelled. Retry to read the captured packages again.";return}
                review=value;loading=false;self.token=nil;selection=visibleChanges.first?.id
            }catch{
                guard !retired,generation==request else{return};loading=false;self.token=nil
                self.error=token.isCancelled ? "Editable revision preparation cancelled. Retry to read the captured packages again.":error.localizedDescription
            }
        }
    }
    func decide(accept:Bool){guard let selection else{return};decide(changeID:selection,accept:accept)}
    func decide(changeID:String,accept:Bool){guard canAct else{return};let before=review?.decisions;review?.decide(changeID:changeID,accept:accept);decisionsChanged(before)}
    func decideAll(accept:Bool){guard canAct else{return};let before=review?.decisions;review?.decideAll(accept:accept);decisionsChanged(before)}
    func undo(){guard canAct else{return};let before=review?.decisions;review?.undo();decisionsChanged(before)}
    func redo(){guard canAct else{return};let before=review?.decisions;review?.redo();decisionsChanged(before)}
    private func decisionsChanged(_ previous:[String:Bool]?) {guard previous != review?.decisions else{return};decisionGeneration=UUID();resultToken?.cancel()}
    func cancel(){token?.cancel();exportToken?.cancel();resultToken?.cancel();resultPageToken?.cancel()}
    func retire(){guard !retired else{return};retired=true;generation=UUID();cancel()}
    func validateDestination(_ url:URL,requirePresentationExtension:Bool=true)throws {
        guard url.isFileURL,!requirePresentationExtension || [suggestedExtension,"ppt"].contains(url.pathExtension.lowercased()) else {throw Failure(message:"Save the editable presentation with the .\(suggestedExtension) extension, or choose .ppt for an explicit PowerPoint binary conversion.")}
        let candidate=url.resolvingSymlinksInPath().standardizedFileURL.path
        let privateRoot=preview.directory.resolvingSymlinksInPath().standardizedFileURL.path
        guard candidate.compare(privateRoot,options:.caseInsensitive) != .orderedSame,
              !candidate.lowercased().hasPrefix(privateRoot.lowercased()+"/") else {throw Failure(message:"Choose an output outside TurtleGit's private comparison files.")}
        var destinationInfo=stat();let exists=stat(url.path,&destinationInfo)==0
        for input in protectedInputs+[preview.base,preview.destination,preview.basePackage,preview.destinationPackage] {
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
            var data=try await withTaskCancellationHandler {
                try await Task.detached(priority:.userInitiated){try encode(snapshot,token)}.value
            } onCancel:{token.cancel()}
            if url.pathExtension.lowercased()=="ppt" {
                let folder=preview.directory.appendingPathComponent("binary-output-"+UUID().uuidString,isDirectory:true)
                var safeToDiscard=true
                defer {if safeToDiscard{try? FileManager.default.removeItem(at:folder)}}
                let package=folder.appendingPathComponent("reviewed."+snapshot.suggestedExtension),output=folder.appendingPathComponent("result.ppt")
                let packageData=data
                try await Task.detached(priority:.userInitiated){
                    try token.check()
                    try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:false,attributes:[.posixPermissions:0o700])
                    try packageData.write(to:package,options:.withoutOverwriting)
                    try FileManager.default.setAttributes([.posixPermissions:0o444],ofItemAtPath:package.path)
                }.value
                var conversionDispatched=false
                do {try token.check();conversionDispatched=true;try await withTaskCancellationHandler {try await convertLegacyResult(package,output,token)} onCancel:{token.cancel()}}
                catch {
                    if conversionDispatched && (error as? PowerPointComparisonAutomation.Failure)?.possiblyOpened != false {
                        safeToDiscard=false;retainPrivateArtifacts=true
                    }
                    throw error
                }
                data=try await Task.detached(priority:.userInitiated){try token.check();return try Data(contentsOf:output)}.value
            }
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
    func previewResult(){
        guard canPreviewResult,let snapshot=review else{return}
        let token=OperationCancellation(),request=decisionGeneration
        resultToken=token;resultBusy=true;resultError=nil;onBegin()
        let folder=preview.directory.appendingPathComponent("result-"+UUID().uuidString,isDirectory:true),encode=encode
        Task { [self] in
            var safeToDiscard=true,accepted=false
            defer {resultBusy=false;resultToken=nil;if safeToDiscard && !accepted{try? FileManager.default.removeItem(at:folder)};onEnd()}
            do {
                let package=folder.appendingPathComponent("reviewed."+snapshot.suggestedExtension),pdf=folder.appendingPathComponent("result.pdf")
                try await Task.detached(priority:.userInitiated){
                    let data=try encode(snapshot,token);try token.check()
                    try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:false,attributes:[.posixPermissions:0o700])
                    try data.write(to:package,options:.withoutOverwriting)
                    try FileManager.default.setAttributes([.posixPermissions:0o444],ofItemAtPath:package.path)
                }.value
                try token.check();guard !retired else{throw CancellationError()}
                let manifest:PresentationSlideManifest
                do {manifest=try await renderResult(package,pdf,token)}
                catch {
                    if (error as? PowerPointComparisonAutomation.Failure)?.possiblyOpened != false {safeToDiscard=false;retainPrivateArtifacts=true}
                    throw error
                }
                try manifest.validate(cancellation:token)
                _=try await Task.detached(priority:.userInitiated){try PresentationComparisonRendering.fingerprints(base:pdf,destination:pdf,baseCount:manifest.slides.count,destinationCount:manifest.slides.count,cancellation:token)}.value
                guard !retired,decisionGeneration==request,!token.isCancelled else{return}
                resultPageToken?.cancel();resultPageGeneration=UUID();resultManifest=manifest;resultPDF=pdf;resultDecisions=snapshot.decisions
                resultImages=nil;accepted=true;previewMode = .result
                changingResultSelection=true;resultSelection=manifest.slides.isEmpty ? nil:0;changingResultSelection=false
                renderResultSelection()
            }catch{
                guard !retired else{return}
                resultError=token.isCancelled || error is CancellationError ? "Result preview cancelled. The current decisions were kept.":error.localizedDescription
            }
        }
    }
    func renderResultSelection(){
        resultPageToken?.cancel();resultPageGeneration=UUID();resultImages=nil
        guard !retired,actionsAllowed(),let pdf=resultPDF,let manifest=resultManifest,let resultSelection else{resultRendering=false;return}
        let token=OperationCancellation(),request=resultPageGeneration
        resultPageToken=token;resultRendering=true;onBegin()
        Task { [self] in
            defer{onEnd()}
            do {
                let images=try await Task.detached(priority:.userInitiated){try PresentationComparisonRendering.pair(base:pdf,destination:pdf,baseCount:manifest.slides.count,destinationCount:manifest.slides.count,baseIndex:nil,destinationIndex:resultSelection,cancellation:token)}.value
                guard !retired,resultPageGeneration==request else{return};resultRendering=false;resultPageToken=nil
                if !token.isCancelled{resultImages=images}
            }catch{guard !retired,resultPageGeneration==request else{return};resultRendering=false;resultPageToken=nil;if !token.isCancelled{resultError=error.localizedDescription}}
        }
    }
    func navigateResult(_ delta:Int){guard !retired,actionsAllowed(),let slides=resultManifest?.slides,!slides.isEmpty else{return};resultSelection=max(0,min(slides.count-1,(resultSelection ?? 0)+delta))}

}

struct PresentationRevisionReviewPanel:View {
    @ObservedObject var model:PresentationRevisionWindowModel
    let save:()->Void
    var body:some View {
        VStack(alignment:.leading,spacing:6){
            HStack {
                Text("Editable revision review").font(.headline)
                if model.resultBusy {ProgressView().controlSize(.small);Text("Rendering result…").font(.caption)}
                if model.loading {ProgressView().controlSize(.small);Button("Cancel preparation"){model.cancel()}}
                Spacer()
                if model.review != nil {Text("\(model.unresolvedCount) unresolved\(model.isDirty ? " · Unsaved decisions":"")").font(.caption)}
                Button{model.undo()}label:{CommandLabel(title:"Undo",icon:.mergeUndo)}.keyboardShortcut("z",modifiers:.command).disabled(!model.canAct || model.review?.canUndo != true)
                Button{model.redo()}label:{CommandLabel(title:"Redo",icon:.mergeRedo)}.keyboardShortcut("z",modifiers:[.command,.shift]).disabled(!model.canAct || model.review?.canRedo != true)
                Button{model.previewResult()}label:{CommandLabel(title:"Preview Result",icon:.compare)}.disabled(!model.canPreviewResult)
                Button{save()}label:{CommandLabel(title:"Save Editable Copy…",icon:.saveAs)}.disabled(!model.canSave)
            }
            if let error=model.error {
                HStack {Text(error).foregroundStyle(.red).textSelection(.enabled);if model.review==nil && !model.loading {Button("Retry"){model.start()}.disabled(!model.actionsAllowed())}}
            }
            if let resultError=model.resultError {Text(resultError).foregroundStyle(.red).textSelection(.enabled)}
            if model.review != nil {
                HStack {
                    Picker("Review entries",selection:$model.reviewEntries){ForEach(PresentationRevisionWindowModel.ReviewEntries.allCases,id:\.self){Text(LocalizedStringKey($0.rawValue)).tag($0)}}.frame(width:220).disabled(!model.canAct).accessibilityIdentifier("presentation-review-entries")
                    Text("\(model.commentRows.count) comments").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button{model.navigateComment(-1)}label:{CommandLabel(title:"Previous comment",icon:.mergePreviousDifference)}.disabled(!model.canNavigateComment(-1)).accessibilityIdentifier("presentation-comment-previous")
                    Button{model.navigateComment(1)}label:{CommandLabel(title:"Next comment",icon:.mergeNextDifference)}.disabled(!model.canNavigateComment(1)).accessibilityIdentifier("presentation-comment-next")
                }
                HSplitView {
                    List(selection:$model.selection){ForEach(model.visibleChanges,id:\.id){change in
                        changeRow(change)
                    }}.frame(minWidth:280,idealWidth:390).disabled(!model.canAct)
                    ScrollView {VStack(alignment:.leading,spacing:8){
                        if let change=model.selected {
                            Text(verbatim:change.title).font(.headline)
                            if !change.groupPath.isEmpty {
                                Text(verbatim:PresentationRevisionChangePresentation.breadcrumb(change)).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                            }
                            Text(verbatim:change.detail).textSelection(.enabled)
                            if let comment=model.selectedComment {
                                PresentationCommentReviewDetail(pair:comment,baseInventory:model.review?.baseComments ?? [],destinationInventory:model.review?.destinationComments ?? [],canSelect:model.canAct,select:model.selectCommentRecord)
                                if model.selectedCommentIsDeleted {Text(model.selectedCommentCanRestore ? "Deleted from editable output":"Deleted with its parent comment. Select that parent or use Undo to restore the thread.").font(.caption).foregroundStyle(.orange)}
                            } else if model.baseSlide != nil || model.destinationSlide != nil {
                                HStack(alignment:.top){slideDetail(model.baseSlide,title:"Base slide text and notes");Divider();slideDetail(model.destinationSlide,title:"New slide text and notes")}
                            }
                        }
                        else {Text(model.changes.isEmpty ? "No editable package differences.":"Select a revision to inspect its details.")}
                    }.frame(maxWidth:.infinity,alignment:.leading).padding(6)}.frame(minWidth:260)
                }.frame(minHeight:155,idealHeight:model.selectedComment == nil ? 220:300,maxHeight:model.selectedComment == nil ? 220:320)
                HStack {
                    Button{model.decide(accept:true)}label:{CommandLabel(title:"Accept selected",icon:.add)}.fixedSize().disabled(!model.canDecideSelected)
                    Button{model.decide(accept:false)}label:{CommandLabel(title:"Reject selected",icon:.revert)}.fixedSize().disabled(!model.canDecideSelected)
                    Button{model.decideAll(accept:true)}label:{CommandLabel(title:"Accept all",icon:.add)}.fixedSize().disabled(!model.canAct || model.changes.isEmpty)
                    Button{model.decideAll(accept:false)}label:{CommandLabel(title:"Reject all",icon:.revert)}.fixedSize().disabled(!model.canAct || model.changes.isEmpty)
                    if model.selectedComment != nil {
                        if model.selectedCommentIsDeleted {
                            Button{model.restoreComment()}label:{CommandLabel(title:"Restore comment",icon:.restore)}.fixedSize().disabled(!model.selectedCommentCanRestore).accessibilityIdentifier("presentation-comment-restore")
                        } else {
                            Button{model.deleteComment()}label:{CommandLabel(title:"Delete comment",icon:.remove)}.fixedSize().disabled(!model.canAct).accessibilityIdentifier("presentation-comment-delete")
                        }
                    }
                    Spacer(minLength:0)
                }
                HStack {
                    Picker("Save format",selection:$model.saveFormat){ForEach(PresentationRevisionWindowModel.SaveFormat.allCases,id:\.self){Text($0.rawValue).tag($0)}}.frame(width:300).disabled(!model.canAct)
                    if model.exporting {ProgressView().controlSize(.small);Button("Cancel export"){model.cancel()}.fixedSize()}
                    if let url=model.savedURL {Text("Saved: \(url.lastPathComponent)").font(.caption).lineLimit(1).truncationMode(.middle).help(url.path)}
                    Spacer(minLength:0)
                }
                ForEach(Array(model.notices.enumerated()),id:\.offset){_,notice in Text(notice).font(.caption).foregroundStyle(.secondary)}
                Text("Preview Result renders the chosen revisions with Microsoft PowerPoint. Source slides remain available for comparison.").font(.caption).foregroundStyle(.secondary)
            }
        }.padding(10)
    }
    private func changeRow(_ change:PresentationRevisionChange)->some View {
        HStack(alignment:.top,spacing:6) {
            Image(systemName:model.review?.commentIsDeleted(changeID:change.id)==true ? "trash.circle.fill":model.review?.decisions[change.id].map{$0 ? "checkmark.circle.fill":"xmark.circle.fill"} ?? "circle").foregroundStyle(model.review?.commentIsDeleted(changeID:change.id)==true ? Color.orange:model.review?.decisions[change.id].map{$0 ? Color.green:Color.red} ?? .secondary)
            if let image=(model.changes.contains{$0.id==change.id} ? PresentationRevisionChangePresentation.icon(change):MenuIcon.status).image() {
                Image(nsImage:image).renderingMode(image.isTemplate ? .template:.original).resizable().frame(width:16,height:16)
            }
            VStack(alignment:.leading,spacing:2) {
                Text(verbatim:change.title).lineLimit(2)
                if !change.groupPath.isEmpty {
                    Text(verbatim:PresentationRevisionChangePresentation.breadcrumb(change)).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                }
            }
        }.padding(.leading,CGFloat(min(change.groupPath.count,6))*8)
        .help(PresentationRevisionChangePresentation.location(change))
        .accessibilityElement(children:.ignore)
        .accessibilityLabel(Text(verbatim:PresentationRevisionChangePresentation.location(change)))
        .accessibilityValue(Text(LocalizedStringKey(model.decisionLabel(change.id))))
        .accessibilityIdentifier("presentation-revision-"+change.id)
        .accessibilityAction(named:Text("Accept selected")){if model.canAct && model.changes.contains(where:{$0.id==change.id}){model.decide(changeID:change.id,accept:true)}}
        .accessibilityAction(named:Text("Reject selected")){if model.canAct && model.changes.contains(where:{$0.id==change.id}){model.decide(changeID:change.id,accept:false)}}
        .tag(change.id).contextMenu {
            Button{model.decide(changeID:change.id,accept:true)}label:{CommandLabel(title:"Accept selected",icon:.add)}.disabled(!model.canAct || !model.changes.contains{$0.id==change.id})
            Button{model.decide(changeID:change.id,accept:false)}label:{CommandLabel(title:"Reject selected",icon:.revert)}.disabled(!model.canAct || !model.changes.contains{$0.id==change.id})
            if model.review?.commentChanges[change.id] != nil {
                if model.review?.commentIsDeleted(changeID:change.id)==true {
                    Button{model.restoreComment(change.id)}label:{CommandLabel(title:"Restore comment",icon:.restore)}.disabled(!model.canAct || model.review?.commentIsDirectlyDeleted(changeID:change.id) != true)
                } else {
                    Button{model.deleteComment(change.id)}label:{CommandLabel(title:"Delete comment",icon:.remove)}.disabled(!model.canAct)
                }
            }
        }
    }
    private func slideDetail(_ slide:PresentationSlide?,title:String)->some View {
        VStack(alignment:.leading,spacing:4){Text(title).font(.caption).bold();Text(slide?.text ?? "—").textSelection(.enabled);if let notes=slide?.notes,!notes.isEmpty {Text(notes).font(.caption).textSelection(.enabled)}}.frame(maxWidth:.infinity,alignment:.leading)
    }

}

struct PresentationCommentReviewDetail:View {
    let pair:PresentationCommentChange
    let baseInventory:[PresentationComment],destinationInventory:[PresentationComment]
    let canSelect:Bool
    let select:(String,Bool)->Void
    var body:some View {
        HStack(alignment:.top,spacing:12) {
            side(pair.base,inventory:baseInventory,title:"Base comments",destination:false)
            Divider()
            side(pair.destination,inventory:destinationInventory,title:"New comments",destination:true)
        }.accessibilityIdentifier("presentation-comments-detail")
    }
    private func thread(_ selected:PresentationComment,inventory:[PresentationComment])->[PresentationComment] {
        let records=inventory.filter{$0.threadID==selected.threadID}
        let ids=Set(records.map(\.id))
        func ordered(_ items:[PresentationComment])->[PresentationComment] {items.sorted {if $0.created != $1.created{return $0.created<$1.created};return $0.id<$1.id}}
        var children:[String:[PresentationComment]]=[:]
        for record in records {if let parent=record.parentID {children[parent,default:[]].append(record)}}
        var stack=Array(ordered(records.filter{$0.parentID==nil || !ids.contains($0.parentID!)}).reversed()),result:[PresentationComment]=[],seen=Set<String>()
        while let comment=stack.popLast() {
            guard seen.insert(comment.id).inserted else{continue};result.append(comment)
            stack.append(contentsOf:ordered(children[comment.id] ?? []).reversed())
        }
        return result
    }
    @ViewBuilder private func side(_ selected:PresentationComment?,inventory:[PresentationComment],title:String,destination:Bool)->some View {
        VStack(alignment:.leading,spacing:8) {
            Text(LocalizedStringKey(title)).font(.caption).bold()
            if let selected {
                Text(selected.isModern ? "Modern threaded comment":"Classic comment").font(.caption).foregroundStyle(.secondary)
                ForEach(thread(selected,inventory:inventory),id:\.id) {comment in
                    VStack(alignment:.leading,spacing:5) {
                        HStack(alignment:.top,spacing:6) {
                            Text(verbatim:comment.initials.isEmpty ? "?":comment.initials).font(.caption.bold()).padding(5).background(Color.accentColor.opacity(0.15)).clipShape(Circle())
                            VStack(alignment:.leading,spacing:2) {
                                Button{select(comment.id,destination)}label:{Text(verbatim:comment.author).font(.callout.bold())}.buttonStyle(.plain).foregroundStyle(Color.accentColor).disabled(!canSelect)
                                Text("Slide \(comment.slideIndex+1)").font(.caption).foregroundStyle(.secondary)
                                if !comment.created.isEmpty {Text(verbatim:comment.created).font(.caption).foregroundStyle(.secondary)}
                            }
                            Spacer(minLength:0)
                            if !comment.status.isEmpty {Text(verbatim:comment.status).font(.caption).foregroundStyle(comment.status.lowercased()=="active" ? Color.blue:Color.green)}
                        }
                        if comment.parentID != nil {Text("Reply").font(.caption).foregroundStyle(.secondary)}
                        Text(verbatim:comment.text).textSelection(.enabled).fixedSize(horizontal:false,vertical:true)
                        if !comment.anchor.isEmpty {DisclosureGroup("Anchor") {Text(verbatim:comment.anchor).font(.system(.caption,design:.monospaced)).textSelection(.enabled)}}
                    }.padding(7).frame(maxWidth:.infinity,alignment:.leading)
                    .background(comment.id==selected.id ? Color.accentColor.opacity(0.10):Color.clear).cornerRadius(5)
                    .padding(.leading,CGFloat(min(comment.depth,6))*10)
                    .accessibilityElement(children:.contain).accessibilityIdentifier("presentation-comment-"+comment.id)
                }
            } else {Text("Comment not present").foregroundStyle(.secondary)}
        }.frame(maxWidth:.infinity,alignment:.leading)
    }
}

enum PresentationRevisionChangePresentation {
    static func breadcrumb(_ change:PresentationRevisionChange)->String {change.groupPath.joined(separator:" › ")}
    static func location(_ change:PresentationRevisionChange)->String {
        let path=breadcrumb(change)
        return path.isEmpty ? change.title:change.title+"\n"+path
    }
    static func decision(_ value:Bool?)->String {
        guard let value else{return "Unresolved"};return value ? "Accepted New":"Rejected Base"
    }
    static func icon(_ change:PresentationRevisionChange)->MenuIcon {
        switch change.kind {
        case .slideAdded,.shapeAdded,.commentAdded:return .actionAdded
        case .slideDeleted,.shapeDeleted,.commentDeleted:return .actionDeleted
        case .slideMoved,.shapeOrder:return .mergeMoved
        case .slideEnvironment,.presentation:return .settings
        case .shapeChanged,.commentChanged:return .actionModified
        }
    }
}

struct PresentationResultCanvas:View {
    @ObservedObject var model:PresentationRevisionWindowModel
    let fit:Bool,zoom:Double
    var body:some View {
        VStack(spacing:8){
            HStack {
                Text(model.resultManifest == nil ? "Combined result":model.resultIsCurrent ? "Combined result — current decisions":"Combined result — outdated decisions").font(.headline).foregroundStyle(model.resultIsCurrent ? Color.primary:Color.orange)
                Spacer()
                Button{model.previewResult()}label:{CommandLabel(title:"Preview Result",icon:.compare)}.disabled(!model.canPreviewResult)
            }.padding(.horizontal,10)
            if let manifest=model.resultManifest {
                HSplitView {
                    List(selection:$model.resultSelection){ForEach(manifest.slides,id:\.pageIndex){slide in
                        VStack(alignment:.leading){Text("Slide \(slide.pageIndex+1)").font(.headline);Text(slide.text.prefix(100)).font(.caption).lineLimit(3)}.tag(slide.pageIndex)
                    }}.frame(minWidth:180,idealWidth:210,maxWidth:300).disabled(!model.actionsAllowed() || model.retired)
                    VStack {
                        GeometryReader{geometry in
                            ScrollView([.horizontal,.vertical]){
                                if let raster=model.resultImages?.destination,let image=raster.image {
                                    let scale=fit ? min(max(100,geometry.size.width-8)/CGFloat(raster.width),max(100,geometry.size.height-8)/CGFloat(raster.height)):zoom
                                    Image(nsImage:image).resizable().interpolation(.high).frame(width:CGFloat(raster.width)*scale,height:CGFloat(raster.height)*scale).background(.white).padding(4)
                                }else if model.resultRendering {ProgressView("Rendering result slide…")}
                                else {Text("No result slide selected.").foregroundStyle(.secondary).padding()}
                            }.background(Color(nsColor:.underPageBackgroundColor))
                        }.frame(minHeight:230)
                        if let slide=model.resultSlide {DisclosureGroup("Result text and notes") {ScrollView{VStack(alignment:.leading){Text(slide.text);Text(slide.notes).font(.caption)}.textSelection(.enabled).frame(maxWidth:.infinity,alignment:.leading)}.frame(height:100)}.padding(8)}
                    }
                }
                if !model.resultIsCurrent {Text("Decisions changed after this render. Preview Result again to see the current combined presentation.").foregroundStyle(.orange).font(.caption).padding(.bottom,6)}
            }else {
                VStack(spacing:12){Image(systemName:"doc.richtext").font(.system(size:36)).foregroundStyle(.secondary);Text("Resolve the revisions, then choose Preview Result.").font(.headline);Text("Microsoft PowerPoint renders a private copy of the chosen revisions. Source files stay unchanged.").foregroundStyle(.secondary)}.multilineTextAlignment(.center).frame(maxWidth:.infinity,maxHeight:.infinity).padding(24)
            }
        }.overlay{if model.resultBusy {ProgressView("Preparing combined result…").padding(12).background(.regularMaterial).cornerRadius(8)}}
    }
}
