// Native adaptation of TortoiseGit ExportDlg.cpp and IDD_EXPORT.
import AppKit
import SwiftUI
import Combine
import UniformTypeIdentifiers
import TurtleGitCore

enum ExportArchiveChoice:Int,CaseIterable {
    case zip,tar,tarGzip,allFiles
    var title:String {switch self{case .zip:return "ZIP archive (*.zip)";case .tar:return "TAR archive (*.tar)";case .tarGzip:return "TAR GZIP archive (*.tar.gz)";case .allFiles:return "All Files (*.*)"}}
    var suffix:String {switch self{case .tar:return "tar";case .tarGzip:return "tar.gz";default:return "zip"}}
    var contentTypes:[UTType] {switch self{case .zip:return [.zip];case .tar:return UTType(filenameExtension:"tar").map{[$0]} ?? [];case .tarGzip:return [.gzip];case .allFiles:return []}}
    func filename(_ name:String)->String {
        // PathFindExtension treats leading/trailing dots as explicit extensions.
        // Preserve dotfiles and custom suffixes for Git's own format inference.
        name.contains(".") ? name:name+"."+suffix
    }
    static func matching(_ name:String)->Self {
        let value=name.lowercased()
        if value.hasSuffix(".tar.gz"){return .tarGzip};if value.hasSuffix(".tar"){return .tar};if value.hasSuffix(".zip"){return .zip}
        return name.contains(".") ? .allFiles:.zip
    }
}
@MainActor final class ExportWindowController: NSWindowController, NSWindowDelegate,NSOpenSavePanelDelegate {
    let model: ExportWindowModel
    var onClosed: () -> Void = {}
    private var retired=false
    var canReuse:Bool {!retired && !model.retired}
    private var release:ExportChildRelease?
    private var retiredReferences:[ReferenceBrowserWindowController]=[]
    private var retiredLogs:[LogWindowController]=[]
    private var pickerDrains:[UUID:Task<Void,Never>]=[:]
    private(set) var savePanel:NSSavePanel?
    private(set) var archiveFormatPopup:NSPopUpButton?
    private var saveReceipt:ExportWindowModel.FormContext?
    private var saveAnswered=false
    private var saveAnswer:((NSApplication.ModalResponse)->Void)?
    private(set) var overwriteAlert:NSAlert?
    private var overwriteAnswer:((NSApplication.ModalResponse)->Void)?
    var presentSavePanel:(NSSavePanel,NSWindow,@escaping(NSApplication.ModalResponse)->Void)->Void={panel,owner,reply in panel.beginSheetModal(for:owner,completionHandler:reply)}
    var selectedSaveURL:(NSSavePanel)->URL?={$0.url}
    var presentOverwrite:(NSAlert,NSWindow,@escaping(NSApplication.ModalResponse)->Void)->Void={alert,owner,reply in alert.beginSheetModal(for:owner,completionHandler:reply)}
    static var activeReleases:Int {ExportChildRelease.activeCount}
    var hasPendingWork:Bool {release != nil || model.hasPendingWork || !pickerDrains.isEmpty || savePanel != nil || overwriteAlert != nil || progressController?.hasPendingWork == true || window?.attachedSheet != nil || window?.sheetParent != nil}
    private var pickers: VersionPickerCoordinator!
    var referencePicker: ReferenceBrowserWindowController? { pickers.referencePicker }
    var commitPicker: LogWindowController? { pickers.commitPicker }
    var configureReferencePicker: (ReferenceBrowserWindowModel) -> Void = {_ in}
    var configureCommitPicker: (LogWindowModel) -> Void = {_ in}
    private(set) var progressController: ExportProgressWindowController?
    init(repository: GitRepository, access: RepositoryAccessLease?, revision: String, directory: String = "", preferences: UserDefaults = .standard) {
        model = ExportWindowModel(repository: repository, access: access, directory: directory, preferences: preferences)
        let window = ReferenceFormNativeWindow(contentRect: NSRect(x: 0, y: 0, width: 620, height: 430), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        RepositoryWindowTitles.set(window, repository: repository.root, dialog: "Export", preferences: preferences)
        window.isReleasedWhenClosed = false
        let content = NSHostingController(rootView: ExportDialog(model: model).defaultAppStorage(preferences))
        content.sizingOptions=[];window.referenceMinimumContentSize=NSSize(width:600,height:430)
        window.contentViewController = content
        super.init(window: window); window.delegate = self
        NSLayoutConstraint.activate([content.view.widthAnchor.constraint(greaterThanOrEqualToConstant:600),content.view.heightAnchor.constraint(greaterThanOrEqualToConstant:430)])
        window.setContentSize(NSSize(width:620,height:430)); window.center()
        model.close = { [weak self] in
            guard let self,!self.model.confirmingQuit, !self.model.busy,!self.model.hasPendingWork, self.model.progress == nil, self.model.pickerTarget == nil, self.window?.attachedSheet == nil, let window = self.window else { return }
            window.sheetParent?.endSheet(window);window.close()
            if !self.retired,!window.isVisible{self.retireClosedWindow()}
        }
        model.onProgress = { [weak self] result in
            guard let self,!self.retired,!self.model.retired,!self.model.confirmingQuit, let window = self.window, window.attachedSheet == nil else { result.invalidate(); return }
            // A presented result releases options through the controller's actual
            // native detach, rather than the model-only abandonment callback.
            result.onAbandonedCompletion = {}
            let controller = ExportProgressWindowController(model: result)
            controller.onClosed = { [weak self, weak result] in guard let self, let result else { return }; self.progressController = nil; self.model.finish(result) }
            self.progressController = controller
            guard !self.retired,!self.model.retired,!self.model.confirmingQuit else{controller.closeForOwnerRetirement();return}
            if let child = controller.window {MergeWindowPresentation(window).apply(to:child);window.beginSheet(child)} else {result.abandonPresentation()}
        }
        model.chooseDestination = { [weak self] in self?.chooseDestination() }
        pickers = VersionPickerCoordinator(window: window, model: model, access: access, preferences: preferences)
        pickers.presentPicker={ [weak self,weak window] owner,child in
            guard let self,owner===window,owner===self.window,!self.retired,!self.model.retired,!self.model.confirmingQuit,owner.attachedSheet==nil else{return false}
            owner.beginSheet(child);return true
        }
        pickers.contextualDraft={ [weak model] in [GitReferenceName(model?.formContext.epoch.uuidString ?? "")] }
        pickers.configureReferencePicker={ [weak self] value in guard let self else{return};if let child=self.referencePicker{self.track(reference:child)};self.configureReferencePicker(value) }
        pickers.configureCommitPicker={ [weak self] value in guard let self else{return};if let child=self.commitPicker{self.track(log:child)};self.configureCommitPicker(value) }
        model.chooseCommit = { [weak model] in model?.onBrowsePicker?(.commit) }
        model.confirmOverwrite={ [weak self] path in await self?.confirmOverwrite(path) ?? false }
        model.presentationAvailable={ [weak self,weak window] in self?.retired==false && window != nil && window?.attachedSheet==nil && self?.savePanel==nil }
        model.quitStateChanged={ [weak self] value in if value{self?.savePanel?.cancel(nil);self?.saveAnswer?(.abort);self?.overwriteAnswer?(.abort)};self?.referencePicker?.model.confirmingQuit=value;self?.commitPicker?.model.confirmingQuit=value }
        model.load(revision: revision)

        DialogGeometry.attach(window, identifier: "ExportDialog", legacyName: "ExportDialog")
    }
    private func chooseDestination() {
        guard !retired,model.canEditForm,let window,window.attachedSheet==nil,savePanel==nil else{return}
        let panel=NSSavePanel();panel.title="Export Archive";panel.allowsOtherFileTypes=true;panel.isExtensionHidden=false;panel.canCreateDirectories=true;panel.delegate=self
        let popup=NSPopUpButton(frame:NSRect(x:0,y:0,width:300,height:26));popup.addItems(withTitles:ExportArchiveChoice.allCases.map{NSLocalizedString($0.title,comment:"")});popup.target=self;popup.action=#selector(archiveFormatChanged(_:));popup.identifier = .init("Export archive format");popup.setAccessibilityLabel(NSLocalizedString("Archive format",comment:""))
        panel.accessoryView=popup
        if model.destination.isEmpty {panel.nameFieldStringValue=URL(fileURLWithPath:model.revision).lastPathComponent}
        else{let target=URL(fileURLWithPath:model.destination);panel.nameFieldStringValue=target.lastPathComponent;panel.directoryURL=target.deletingLastPathComponent()}
        let initialChoice=ExportArchiveChoice.matching(panel.nameFieldStringValue);popup.selectItem(at:initialChoice.rawValue);panel.allowedContentTypes=initialChoice.contentTypes
        if panel.directoryURL==nil,let last=model.presentationPreferences.string(forKey:"Export.LastDirectory"){panel.directoryURL=URL(fileURLWithPath:last)}
        saveReceipt=model.formContext;savePanel=panel;archiveFormatPopup=popup;saveAnswered=false;model.choosingDestination=true
        MergeWindowPresentation(window).apply(to:panel)
        let answer:(NSApplication.ModalResponse)->Void={ [weak self,weak panel] response in
            guard let self,let panel,self.savePanel===panel,!self.saveAnswered else{return};self.saveAnswered=true
            let context=self.saveReceipt,choice=ExportArchiveChoice(rawValue:popup.indexOfSelectedItem) ?? .zip
            let selected=response == .OK ? self.selectedSaveURL(panel):nil
            let release=ExportChildRelease(window:panel,parent:window,closeWindow:true){ [self] in
                guard self.savePanel===panel else{return}
                self.savePanel=nil;self.archiveFormatPopup=nil;self.saveReceipt=nil;self.saveAnswer=nil;self.model.choosingDestination=false
                guard !self.retired,!self.model.confirmingQuit,context==self.model.formContext,let selected else{return}
                let filename=choice.filename(selected.lastPathComponent)
                guard !GitRuntime.isAppStoreBuild || filename==selected.lastPathComponent else{self.model.error="Choose the archive filename, including its extension, in the save dialog.";return}
                // Keep the panel's actual security-scoped URL when its delegate
                // has already normalized the filename. A file grant must never
                // be silently transferred to a different sibling leaf.
                let url=filename==selected.lastPathComponent ? selected:selected.deletingLastPathComponent().appendingPathComponent(filename)
                let lease=RepositoryAccessLease(url:url)
                guard !GitRuntime.isAppStoreBuild || lease.hasSecurityScope else{self.model.error=RepositoryAccessFailure.securityScopeUnavailable.localizedDescription;return}
                self.model.outputAccess=lease;self.model.destination=url.path
                self.model.presentationPreferences.set(url.deletingLastPathComponent().path,forKey:"Export.LastDirectory")
            };release.start()
        }
        saveAnswer=answer;presentSavePanel(panel,window,answer)
    }
    @objc private func archiveFormatChanged(_ sender:NSPopUpButton){
        guard !retired,!model.confirmingQuit,sender===archiveFormatPopup,let panel=savePanel,!saveAnswered,let choice=ExportArchiveChoice(rawValue:sender.indexOfSelectedItem) else{return}
        let name=panel.nameFieldStringValue,old=ExportArchiveChoice.matching(name)
        if choice != .allFiles,old != .allFiles,name.lowercased().hasSuffix("."+old.suffix){panel.nameFieldStringValue=String(name.dropLast(old.suffix.count))+choice.suffix}
        panel.allowedContentTypes=choice.contentTypes
    }
    func panel(_ sender:Any,userEnteredFilename filename:String,confirmed:Bool)->String? {guard sender as? NSSavePanel === savePanel,!saveAnswered else{return filename};return (ExportArchiveChoice(rawValue:archiveFormatPopup?.indexOfSelectedItem ?? 0) ?? .zip).filename(filename)}
    private func confirmOverwrite(_ path:String)async->Bool {
        guard !retired,!model.confirmingQuit,overwriteAlert==nil,let window,window.attachedSheet==nil else{return false}
        let context=model.formContext,alert=NSAlert();alert.messageText="Replace existing archive?";alert.informativeText=path;alert.addButton(withTitle:"Cancel");alert.addButton(withTitle:"Replace")
        MergeWindowPresentation(window).apply(to:alert.window);overwriteAlert=alert
        return await withCheckedContinuation{reply in
            var answered=false
            let answer:(NSApplication.ModalResponse)->Void={ [self] response in
                guard !answered else{return};answered=true
                let release=ExportChildRelease(window:alert.window,parent:window,closeWindow:true){ [self] in
                    guard overwriteAlert===alert else{return};overwriteAlert=nil;overwriteAnswer=nil
                    reply.resume(returning:!retired && !model.confirmingQuit && model.formContext==context && response == .alertSecondButtonReturn)
                };release.start()
            };overwriteAnswer=answer;presentOverwrite(alert,window,answer)
        }
    }
    private func track(reference:ReferenceBrowserWindowController){
        retiredReferences.append(reference);trackPicker(reference){reference.model.pendingReferenceReads>0}
    }
    private func track(log:LogWindowController){retiredLogs.append(log);trackPicker(log){log.model.pendingHistoryLoads>0 || log.model.noteWorkPending}}
    private func trackPicker(_ child:NSWindowController,work:@escaping()->Bool){
        let id=UUID();model.pendingPickerOwners += 1
        pickerDrains[id]=Task{@MainActor [self,child] in
            await Task.yield()
            while child.window?.isVisible==true || child.window?.sheetParent != nil || child.window?.attachedSheet != nil || work(){try? await Task.sleep(nanoseconds:5_000_000)}
            pickerDrains.removeValue(forKey:id);model.pendingPickerOwners -= 1
        }
    }
    var activeOperation: Bool { hasPendingWork || model.busy || model.progress != nil || model.pickerTarget != nil }
    func windowShouldClose(_ sender: NSWindow) -> Bool { !model.confirmingQuit && !activeOperation }
    override func close(){super.close();if !retired,window?.isVisible != true{retireClosedWindow()}}
    func windowWillClose(_ notification: Notification) {guard notification.object as? NSWindow === window else{return};retireClosedWindow()}
    private func retireClosedWindow(){
        guard !retired else{return};retired=true
        model.invalidate();savePanel?.cancel(nil);saveAnswer?(.abort);overwriteAnswer?(.abort)
        if let sheet=window?.attachedSheet,sheet !== progressController?.window{window?.endSheet(sheet,returnCode:.abort);sheet.close()}
        pickers.invalidate()
        progressController?.closeForOwnerRetirement()
        guard let window else{let done=onClosed;onClosed={};done();return}
        let release=ExportChildRelease(window:window,parent:window.sheetParent,ready:{[self] in !model.hasPendingWork && pickerDrains.isEmpty && savePanel==nil && overwriteAlert==nil && progressController==nil}){[self] in
            self.release=nil;retiredReferences=[];retiredLogs=[];let done=onClosed;onClosed={};done()
        };self.release=release;release.start()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
}

@MainActor final class ExportWindowModel: ObservableObject, VersionPickerModel {
    private(set) static var activeReads = 0
    private(set) static var activeOperations=0
    struct FormContext:Equatable {let epoch:UUID;let draft:[GitReferenceName]}
    private var formEpoch=UUID()
    var formContext:FormContext {.init(epoch:formEpoch,draft:versionPickerDraft)}
    var retired:Bool {invalidated}
    @Published private(set) var pendingOperations=0
    @Published var pendingPickerOwners=0 {didSet{finishRequestedClose()}}
    @Published var choosingDestination=false {didSet{finishRequestedClose()}}
    var hasPendingWork:Bool {pendingOperations>0 || pendingPickerOwners>0 || choosingDestination || progress?.hasPendingWork==true}
    var canEditForm:Bool {!invalidated && !confirmingQuit && !busy && !hasPendingWork && progress==nil && pickerTarget==nil}
    var presentationAvailable:()->Bool={true}
    var quitStateChanged:(Bool)->Void={_ in}
    private var closeWhenDrained=false
    private func beginWork(){pendingOperations += 1;Self.activeOperations += 1}
    private func endWork(){pendingOperations -= 1;Self.activeOperations -= 1;finishRequestedClose()}
    private func finishRequestedClose(){if closeWhenDrained,!hasPendingWork,!busy,progress==nil{closeWhenDrained=false;close()}}
    @Published var confirmingQuit=false {didSet{if oldValue != confirmingQuit{formEpoch=UUID()};progress?.confirmingQuit=confirmingQuit;quitStateChanged(confirmingQuit)}}
    var versionPickerDraft: [GitReferenceName] { [String(describing: target), branch, tag, commit, destination, String(wholeProject)].map { GitReferenceName($0) } }
    enum Target { case head, branch, tag, commit }
    let repository: GitRepository
    let access: RepositoryAccessLease?
    let directory: String
    var pathCompletionAvailable: Bool { canEditForm }
    var outputAccess: RepositoryAccessLease?
    @Published var destination = "" {didSet{if !GitReferenceName.equal(oldValue,destination){formEpoch=UUID()}}}
    @Published var target = Target.head {didSet{if oldValue != target{formEpoch=UUID()}}}
    @Published var branch = "" {didSet{if !GitReferenceName.equal(oldValue,branch){formEpoch=UUID()}}}
    @Published var tag = "" {didSet{if !GitReferenceName.equal(oldValue,tag){formEpoch=UUID()}}}
    @Published private(set) var commitChoices: [String] = []
    @Published var commit = "HEAD" {didSet{if !GitReferenceName.equal(oldValue,commit){formEpoch=UUID()}}}
    @Published var currentBranch = ""
    @Published var references: [CheckoutReference] = []
    @Published var wholeProject: Bool {didSet{if oldValue != wholeProject{formEpoch=UUID()}}}
    @Published var busy = false
    @Published var error: String?
    @Published var output = ""
    @Published var exported: URL?
    @Published private(set) var pickerTarget: CheckoutTarget?
    var onBrowsePicker: ((CheckoutTarget) -> Void)?
    var commitRevision: String { commit }
    private var referenceSelectionToken: OperationCancellation?
    private var referenceSelectionTask: Task<Void, Never>?
    func beginPicker(_ choice: CheckoutTarget) -> Bool {
        guard canEditForm,presentationAvailable(),
              (choice == .branch && target == .branch) || (choice == .commit && target == .commit) else { return false }
        pickerTarget = choice; return true
    }
    func finishPicker() {
        if referenceSelectionToken != nil { referenceSelectionToken?.cancel(); referenceSelectionTask?.cancel() }
        pickerTarget = nil
    }
    func acceptReferenceSelection(_ name: String?, completion: @escaping () -> Void) {
        guard !invalidated,!confirmingQuit, pickerTarget == .branch else { return }
        let requested = name ?? revision, draft = commit, request = OperationCancellation(), repository = repository, selectionDraft = versionPickerDraft,epoch=formContext.epoch
        referenceSelectionToken = request; busy = true
        Self.activeReads += 1;beginWork()
        referenceSelectionTask = Task { [self, access] in
            defer {
                Self.activeReads -= 1; withExtendedLifetime(access) {}
                if referenceSelectionToken === request { referenceSelectionToken = nil; referenceSelectionTask = nil; busy = false; pickerTarget = nil; completion() }
                endWork()
            }
            do {
                if GitRuntime.isAppStoreBuild && (access?.hasSecurityScope != true || access?.contains(repository.root) != true) { throw RepositoryAccessFailure.securityScopeUnavailable }
                let catalog = try await repository.checkoutReferences(includeFetchHead: preferences.includesFetchHead, localBranchesFirst: AdvancedListBehavior(defaults: preferences).localBranchesFirst, cancellation: request)
                guard !invalidated,!confirmingQuit,formContext.epoch==epoch, referenceSelectionToken === request, !request.isCancelled, !Task.isCancelled, versionPickerDraft == selectionDraft else { return }
                self.references = catalog
                if let reference = catalog.first(where: { GitReferenceName.equal($0.name, requested) }), let kind = reference.target {
                    if kind == .branch { self.target = .branch; self.branch = requested }
                    else { self.target = .tag; self.tag = requested }
                    self.commit = draft
                } else if requested == "HEAD" { self.target = .head }
                else { self.target = .commit; self.selectCustomRevision(requested) }
            } catch {
                guard !invalidated,!confirmingQuit,formContext.epoch==epoch, referenceSelectionToken === request, !request.isCancelled else { return }
                self.error = error.localizedDescription
            }
        }
    }
    func selectCustomRevision(_ value: String) {
        guard !invalidated,!confirmingQuit, let selected = RevisionSessionChoices.select(value, choices: &commitChoices) else { return }
        commit = selected
    }
    func acceptCommitSelection(_ entry: LogEntry?) {
        guard !invalidated,!confirmingQuit, pickerTarget == .commit else { return }
        if let entry { selectCustomRevision(entry.hash) }; finishPicker()
    }
    var presentationPreferences: UserDefaults { preferences }
    private let preferences: UserDefaults
    private var invalidated = false
    private var loadTask: Task<Void, Never>?
    private var loadCancellation: OperationCancellation?
    func invalidate() {
        invalidated = true;formEpoch=UUID(); cancellation?.cancel(); progress?.invalidate(); finishPicker()
        loadCancellation?.cancel(); loadTask?.cancel()
    }
    @Published private(set) var progress: ExportProgressWindowModel?
    var onProgress: ((ExportProgressWindowModel) -> Void)?
    func finish(_ result: ExportProgressWindowModel) {
        guard progress === result, !result.busy, !result.confirmingCancellation else { return }
        progress = nil; result.invalidate(); busy = false
        guard !invalidated else{return}
        output = result.output; error = nil
        if result.success { destination = result.destination.path; exported = result.destination; close() }
    }
    private var cancellation: OperationCancellation?
    var close: () -> Void = {}
    var chooseDestination: () -> Void = {}
    var chooseCommit: () -> Void = {}
    var confirmOverwrite: (String) async -> Bool = { _ in false }
    var showInFinder:(URL)->Void={NSWorkspace.shared.activateFileViewerSelecting([$0])}
    private var explored=false
    func exploreExported(context:FormContext){guard canEditForm,context==formContext,!explored,let exported else{return};explored=true;let callback=showInFinder;close();callback(exported)}
    var branches: [CheckoutReference] { references.filter { ($0.name.hasPrefix("refs/heads/") || $0.remote || $0.isFetchHead) && $0.symbolicTarget == nil } }
    var tags: [CheckoutReference] { let values = references.filter { $0.name.hasPrefix("refs/tags/") }; return preferences.bool(forKey: "SortTagsReversed") ? Array(values.reversed()) : values }
    var revision: String { switch target { case .head: return "HEAD"; case .branch: return branch; case .tag: return tag; case .commit: return commit } }
    func canReuseForRevision(_ requestedRevision: String, directory requestedDirectory: String) -> Bool {
        canEditForm && revision == requestedRevision && directory == requestedDirectory && destination.isEmpty && exported == nil && wholeProject == requestedDirectory.isEmpty
    }
    static func directoryScope(root: URL, paths: [String]) -> String {
        guard paths.count == 1, paths[0] != ".", !paths[0].isEmpty,
              (try? root.appendingPathComponent(paths[0]).resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { return "" }
        return paths[0]
    }
    init(repository: GitRepository, access: RepositoryAccessLease?, directory: String = "", preferences: UserDefaults = .standard) {
        self.repository = repository; self.access = access; self.directory = directory; self.preferences = preferences; wholeProject = directory.isEmpty
    }
    func load(revision preset: String) {
        guard canEditForm else { return }; busy = true
        let repository = repository, request = OperationCancellation(),epoch=formContext.epoch
        loadCancellation = request
        Self.activeReads += 1;beginWork()
        loadTask = Task { [self, access] in
            defer {
                Self.activeReads -= 1; withExtendedLifetime(access) {}
                if loadCancellation === request { loadCancellation = nil; loadTask = nil; busy = false }
                endWork()
            }
            do {
                if GitRuntime.isAppStoreBuild && (access?.hasSecurityScope != true || access?.contains(repository.root) != true) { throw RepositoryAccessFailure.securityScopeUnavailable }
                let references = try await repository.checkoutReferences(includeFetchHead: preferences.includesFetchHead, localBranchesFirst: AdvancedListBehavior(defaults: preferences).localBranchesFirst, cancellation: request)
                let currentBranch = try await repository.branch(cancellation: request)
                guard !invalidated,!confirmingQuit,formContext.epoch==epoch, loadCancellation === request, !request.isCancelled, !Task.isCancelled else { return }
                self.references = references; self.currentBranch = currentBranch
                self.branch = self.branches.first?.name ?? ""; self.tag = self.tags.first?.name ?? ""
                if preset == "HEAD" || preset.isEmpty { self.target = .head }
                else if self.tags.contains(where: { $0.name == preset }) { self.target = .tag; self.tag = preset }
                else if self.branches.contains(where: { $0.name == preset }) { self.target = .branch; self.branch = preset }
                else { self.target = .commit; self.selectCustomRevision(preset) }
            } catch {
                guard !invalidated,!confirmingQuit,formContext.epoch==epoch, loadCancellation === request, !request.isCancelled else { return }
                self.error = error.localizedDescription
            }
        }
    }
    func export() {
        guard canEditForm,presentationAvailable(), !destination.isEmpty, !revision.isEmpty else { return }
        let context=formContext,grantedOutput=outputAccess
        var url = URL(fileURLWithPath: destination)
        if !url.lastPathComponent.contains(".") { url.appendPathExtension("zip") }
        if GitRuntime.isAppStoreBuild {
            guard access?.hasSecurityScope == true, access?.contains(repository.root) == true, let outputAccess, outputAccess.hasSecurityScope,
                  outputAccess.url.standardizedFileURL == url.standardizedFileURL else { error = RepositoryAccessFailure.securityScopeUnavailable.localizedDescription; return }
        }
        let chosen = revision, scope = wholeProject ? "" : directory
        let token = OperationCancellation(); cancellation = token; busy = true; error = nil; exported = nil; output = "";explored=false
        beginWork()
        Task { [self,access,grantedOutput] in
            defer { if progress == nil { busy = false }; cancellation = nil;withExtendedLifetime(access){};withExtendedLifetime(grantedOutput){};endWork() }
            do {
                var isDirectory: ObjCBool = false
                if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) {
                    if isDirectory.boolValue { self.error = "You selected a folder.\nChoose an archive file instead."; return }
                    guard await confirmOverwrite(url.path) else { return }
                }
                guard !invalidated,!confirmingQuit,!token.isCancelled,context==formContext else{return}
                if let onProgress {
                    let result = ExportProgressWindowModel(repository: repository, access: access, outputAccess: grantedOutput, revision: chosen, directory: scope, destination: url, preferences: preferences)
                    result.close = { [weak self, weak result] in guard let result else { return }; self?.finish(result) }
                    result.onAbandonedCompletion = { [weak self, weak result] in guard let result else { return }; self?.finish(result) }
                    progress = result; onProgress(result); result.start(); return
                }
                output = try await repository.archiveRevision(chosen, directory: scope, to: url, cancellation: token)
                guard !invalidated,!confirmingQuit,context==formContext else{return}
                destination = url.path; exported = url
            } catch { if !invalidated,!confirmingQuit,!token.isCancelled,context==formContext { self.error = error.localizedDescription } }
        }
    }
    func cancel() {
        guard !confirmingQuit else{return}
        if let progress { progress.cancel() }
        else if referenceSelectionToken != nil { closeWhenDrained=true;finishPicker() }
        else if let request = loadCancellation {
            closeWhenDrained=true;request.cancel(); loadTask?.cancel()
        } else if cancellation != nil { cancellation?.cancel() }
        else if canEditForm {close()}
    }
}

struct ExportDialog: View {
    @ObservedObject var model: ExportWindowModel
    private func binding<Value>(_ path:ReferenceWritableKeyPath<ExportWindowModel,Value>)->Binding<Value>{let context=model.formContext;return Binding(get:{model[keyPath:path]},set:{if model.canEditForm,model.formContext==context{model[keyPath:path]=$0}})}
    private func radio(_ title: String, _ target: ExportWindowModel.Target) -> some View {
        ExportRadio(title: title, value: target, selection: binding(\.target))
    }
    var body: some View {
        let context=model.formContext
        VStack(alignment: .leading, spacing: 12) {
            GroupBox("Export Archive") {
                VStack(alignment: .leading) { Text("Archive file")
                    HStack { PathEntryField(text: binding(\.destination), label: "Archive file", permissions: [model.access, model.outputAccess].compactMap { $0 }, preferences: model.presentationPreferences, mayEdit: { model.pathCompletionAvailable }).frame(height: 22); Button("…") { if model.formContext==context{model.chooseDestination()} }.accessibilityLabel("Choose archive file") }
                }.padding(8)
            }
            .disabled(!model.canEditForm)
            GroupBox("Revision") {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {radio("HEAD", .head).frame(width:100,alignment:.leading);Text(model.currentBranch).lineLimit(1).truncationMode(.middle).textSelection(.enabled).help(model.currentBranch).frame(maxWidth:.infinity,alignment:.leading)}
                    HStack { radio("Branch", .branch).frame(width: 100, alignment: .leading); ReferencePopup(references: model.branches, selection: binding(\.branch)).disabled(model.target != .branch); Button("…") { if model.formContext==context{model.onBrowsePicker?(.branch)} }.disabled(model.target != .branch).accessibilityLabel("Browse references") }
                    HStack { radio("Tag", .tag).frame(width: 100, alignment: .leading); ReferencePopup(references: model.tags, selection: binding(\.tag)).disabled(model.target != .tag); Color.clear.frame(width: 29) }
                    HStack { radio("Commit", .commit).frame(width: 100, alignment: .leading); VersionRevisionField(text: binding(\.commit), choices: model.commitChoices, accessibilityLabel: "Export commit revision", focusRequest: 0, onFocus: { _ in }).disabled(model.target != .commit); Button("…") { if model.formContext==context{model.chooseCommit()} }.disabled(model.target != .commit).accessibilityLabel("Choose commit") }
                }.padding(8)
            }
            .disabled(!model.canEditForm)
            Toggle("Whole Project", isOn: binding(\.wholeProject)).toggleStyle(.checkbox).disabled(model.directory.isEmpty || !model.canEditForm)
            if model.exported != nil { let context=model.formContext;HStack { Text("Export completed").foregroundStyle(.green); Button("Show in Finder") { model.exploreExported(context:context) } } }
            HStack {
                if model.busy { ProgressView().controlSize(.small) }
                Spacer()
                Button("OK") { if model.formContext==context{model.export()} }.disabled(!model.canEditForm || model.destination.isEmpty || model.revision.isEmpty).keyboardShortcut(.defaultAction)
                Button(model.busy ? "Cancel export" : (model.exported == nil ? "Cancel" : "Done")) { if model.busy { model.cancel() } else { model.close() } }.keyboardShortcut(.cancelAction)
                Button("Help") { TurtleGitHelp.show(.export) }
            }
        }.padding(16)
        .alert("Export failed", isPresented: Binding(get: { model.error != nil }, set: { if !$0,!model.retired,!model.confirmingQuit { model.error = nil } })) { Button("OK") { if !model.retired,!model.confirmingQuit{model.error = nil} } } message: { Text(model.error ?? "") }

    }
}

@MainActor final class ExportProgressWindowModel: ObservableObject {
    struct ActionReceipt:Equatable {let owner:ObjectIdentifier;let generation:Int}
    var actionReceipt:ActionReceipt {.init(owner:ObjectIdentifier(self),generation:interactionGeneration)}
    var canExplore:Bool {!busy && !hasPendingWork && success && !invalidated && !confirmingQuit && !confirmingCancellation && !dispatched}
    static private(set) var activeOperations=0
    @Published private(set) var pendingOperations=0
    var hasPendingWork:Bool {pendingOperations>0}
    var active:Bool {!invalidated}
    var workDidDrain:(()->Void)?
    private func beginWork(){pendingOperations += 1;Self.activeOperations += 1}
    private func endWork(){pendingOperations -= 1;Self.activeOperations -= 1;if !hasPendingWork {busy=false;workDidDrain?()}}
    var beforeFinalization:(@Sendable()throws->Void)?
    var runArchive:((OperationCancellation,@escaping @Sendable(GitOutputChunk)->Void,@escaping @Sendable(GitCommandInvocation)->Void,@escaping @Sendable(RevisionArchiveCommandCompletion)->Void) async throws->String)?
    private var interactionGeneration=0
    @Published var confirmingQuit=false {didSet{if oldValue != confirmingQuit{interactionGeneration += 1};if !confirmingQuit{finishAutomatically()}}}
    var closeForHandoff:((@escaping()->Void)->Void)?
    let repository: GitRepository
    let destination: URL
    private let access: RepositoryAccessLease?, outputAccess: RepositoryAccessLease?
    private let revision: String, directory: String
    var presentationPreferences: UserDefaults { preferences }
    private let preferences: UserDefaults
    private let autoClosePolicy: GitProgressAutoClose
    private let cancellation = OperationCancellation()
    private var outputState: GitProgressOutputState
    private var hasProcessOutput=false
    var progressPresentation: GitCommandPresentation { outputState.presentation }
    var outputPreferences:UserDefaults {preferences}
    var outputClipboard:NSPasteboard = .general
    var actionLogEligible: Bool { started && !hasPendingWork }
    private(set) var rawOutput=""
    var onAbandonedCompletion: () -> Void = {}
    private var started = false, invalidated = false, dispatched = false, abandoned = false
    @Published private(set) var busy = true
    @Published private(set) var success = false
    @Published private(set) var cancelled = false
    @Published private(set) var cancelling = false
    @Published private(set) var confirmingCancellation = false
    @Published private(set) var output = ""
    @Published private(set) var currentWork = ""
    @Published private(set) var percentage: Int?
    @Published private(set) var completionRange: NSRange?
    @Published private(set) var commandFinished=false
    @Published private(set) var commandSucceeded=false
    var close: () -> Void = {}
    var showInFinder: (URL) -> Void = { NSWorkspace.shared.activateFileViewerSelecting([$0]) }
    var confirmCancellation: (@escaping (Bool) -> Void) -> Void = { $0(false) }
    var canCancel: Bool { busy && !commandFinished && !confirmingQuit && !cancelling && !confirmingCancellation && !invalidated }
    init(repository: GitRepository, access: RepositoryAccessLease?, outputAccess: RepositoryAccessLease?, revision: String, directory: String, destination: URL, preferences: UserDefaults = .standard) {
        self.repository = repository; self.access = access; self.outputAccess = outputAccess; self.revision = revision; self.directory = directory; self.destination = destination; self.preferences = preferences; autoClosePolicy = GitProgressAutoClose(preferences: preferences); outputState = GitProgressOutputState(preferences: preferences)
    }
    func invalidate() {
        guard !invalidated else { return }; invalidated = true; confirmingCancellation = false
        if busy {cancellation.cancel();cancelled=true};close={}
        if !started,!hasPendingWork {
            busy=false
            let done=onAbandonedCompletion;onAbandonedCompletion={};done()
        }
    }
    func abandonPresentation() { abandoned = true; cancellation.cancel() }
    func start(){guard !started,!invalidated,!confirmingQuit else{return};started=true;beginWork();Task{await execute()}}
    func run()async{guard !started,!invalidated,!confirmingQuit else{return};started=true;beginWork();await execute()}
    private enum StreamEvent:Sendable {case output(Bool),finished(RevisionArchiveCommandCompletion)}
    private func complete(_ receipt:RevisionArchiveCommandCompletion){
        guard !invalidated,!commandFinished else{return}
        let footer=SubmoduleProgressCompletion(success:receipt.success,cancelled:receipt.cancelled && receipt.exitCode==nil,exitCode:receipt.exitCode,elapsed:receipt.elapsed,finished:receipt.finished,preferences:preferences)
        output=bounded(output,bytes:outputState.limit-footer.text.utf8.count)
        completionRange=footer.append(to:&output);currentWork=footer.currentWork;percentage=100
        commandFinished=true;commandSucceeded=receipt.success
    }
    private func bounded(_ text:String,bytes limit:Int)->String{
        let bytes=Data(text.utf8),limit=max(0,limit)
        guard bytes.count>limit else{return text}
        let marker="\n[Output truncated at about \(outputState.limit/1024) KiB]\n"
        var count=max(0,limit-marker.utf8.count)
        while count>0,bytes[count]&0xc0==0x80{count -= 1}
        return String(decoding:bytes.prefix(count),as:UTF8.self)+String(decoding:marker.utf8.prefix(limit-count),as:UTF8.self)
    }
    private func appendDiagnostic(_ text:String){
        guard let range=completionRange else{output=GitProgressFailureOutput.renderDetails(text,existing:output,limit:outputState.limit);return}
        let old=output as NSString
        guard NSMaxRange(range)<=old.length else{return}
        let footer=old.substring(with:range)
        let suffix=GitProgressFailureOutput.renderDetails(text,existing:old.substring(from:NSMaxRange(range)),limit:max(256,outputState.limit-footer.utf8.count))
        let prefix=bounded(old.substring(to:range.location),bytes:outputState.limit-footer.utf8.count-suffix.utf8.count)
        output=prefix+footer+suffix;completionRange=NSRange(location:(prefix as NSString).length,length:(footer as NSString).length)
    }
    private func execute()async{
        defer{endWork();withExtendedLifetime(access){};withExtendedLifetime(outputAccess){};if invalidated{let done=onAbandonedCompletion;onAbandonedCompletion={};done()}else{cancelling=false;finishAutomatically()}}
        guard !invalidated else{return}
        let startedAt=ProcessInfo.processInfo.systemUptime
        do {
            if cancellation.isCancelled { throw OperationCancellationFailure.cancelled }
            if GitRuntime.isAppStoreBuild && (access?.hasSecurityScope != true || access?.contains(repository.root) != true || outputAccess?.hasSecurityScope != true || outputAccess?.url.standardizedFileURL != destination.standardizedFileURL) { throw RepositoryAccessFailure.securityScopeUnavailable }
            let parser = GitCliOutputParser(limit: outputState.limit)
            let (updates,continuation)=AsyncStream<StreamEvent>.makeStream()
            let operation = Task { [self] in
                defer { continuation.finish() }
                let output:@Sendable(GitOutputChunk)->Void={chunk in parser.appendChunk(chunk.data);continuation.yield(.output(!chunk.data.isEmpty))}
                let command:@Sendable(GitCommandInvocation)->Void={invocation in parser.appendChunk(invocation.preamble);continuation.yield(.output(false))}
                let finished:@Sendable(RevisionArchiveCommandCompletion)->Void={continuation.yield(.finished($0))}
                if let runArchive{return try await runArchive(cancellation,output,command,finished)}
                return try await repository.archiveRevision(revision,directory:directory,to:destination,cancellation:cancellation,onOutput:output,onCommand:command,onCommandFinished:finished,beforeFinalization:beforeFinalization)
            }
            for await event in updates{
                if case .output(true)=event{hasProcessOutput=true}
                consume(parser.processPending(),parser:parser)
                if case .finished(let receipt)=event{consume(parser.finish(),parser:parser);complete(receipt)}
            }
            consume(parser.processPending(), parser: parser); consume(parser.finish(), parser: parser)
            rawOutput=try await operation.value
            guard !invalidated else{return}
            success=true
            if !commandFinished{complete(.init(success:true,cancelled:false,exitCode:0,elapsed:ProcessInfo.processInfo.systemUptime-startedAt))}
        } catch {
            // A failed archive's stdout/stderr has already been drained. Keep
            // non-command errors (validation, destination rename) as diagnostics.
            let commandFailure = error is GitCommandCancellationFailure || (error as? GitFailure)?.arguments.contains("--verbose") == true
            let alreadyStreamed = hasProcessOutput && commandFailure
            guard !invalidated else{return}
            rawOutput=(error as? GitCommandCancellationFailure)?.result.text ?? error.localizedDescription
            cancelled=cancellation.isCancelled || error is OperationCancellationFailure || error is CancellationError || error is GitCommandCancellationFailure
            if !alreadyStreamed{appendDiagnostic(error.localizedDescription)}
            if !commandFinished{complete(.init(success:false,cancelled:cancelled,exitCode:(error as? GitCommandCancellationFailure)?.result.exitCode ?? (error as? GitFailure)?.code,elapsed:ProcessInfo.processInfo.systemUptime-startedAt))}
            if commandSucceeded {currentWork=cancelled ? "User cancelled":"Operation failed"}
        }
    }
    private func consume(_ emission: GitCliOutputParser.Emission, parser: GitCliOutputParser) {
        guard !invalidated,!commandFinished else { return }
        outputState.consume(emission, parser: parser); output = outputState.output
        currentWork = outputState.currentWork; percentage = outputState.percentage
    }
    private func finishAutomatically() { if !busy,!hasPendingWork,!confirmingQuit,!confirmingCancellation,!invalidated,abandoned || autoClosePolicy.shouldClose(success:success,postActionCount:success ? 1:0){close()} }
    func cancel() {
        guard canCancel else { return }
        if preferences.bool(forKey: "ConfirmKillProcess") {
            confirmingCancellation = true
            let generation=interactionGeneration
            var answered=false
            confirmCancellation { [weak self] accepted in
                guard !answered,let self,self.confirmingCancellation,!self.invalidated else{return};answered=true;self.confirmingCancellation=false
                if self.busy && !self.commandFinished && accepted && !self.confirmingQuit && self.interactionGeneration==generation{self.cancelling=true;self.cancellation.cancel()}
                self.finishAutomatically()
            }
        } else { cancelling = true; cancellation.cancel() }
    }
    func explore(receipt:ActionReceipt?=nil) {
        guard canExplore,receipt==nil || receipt==actionReceipt else{return};dispatched=true
        let callback=showInFinder,destination=destination,generation=interactionGeneration
        let dispatch={ [weak self] in guard let self,!self.confirmingQuit,self.interactionGeneration==generation else{return};callback(destination) }
        if let closeForHandoff{closeForHandoff(dispatch)}else{close();dispatch()}
    }
}
@MainActor final class ExportProgressWindowController: NSWindowController, NSWindowDelegate {
    static var activeReleases:Int {ExportChildRelease.activeCount}
    var hasPendingWork:Bool {release != nil || model.hasPendingWork || cancellationAlert != nil || window?.attachedSheet != nil || window?.sheetParent != nil}
    let model: ExportProgressWindowModel
    var onClosed: () -> Void = {}
    private var finished=false,closingForHandoff=false,ownerRetired=false
    private var presentationParent:NSWindow?
    private var pendingHandoff:(()->Void)?
    private var release:ExportChildRelease?
    private(set) var cancellationAlert:NSAlert?
    var questionWindow:NSWindow? {cancellationAlert?.window}
    private var cancellationAnswer:((NSApplication.ModalResponse)->Void)?
    var presentCancellation:((NSAlert,NSWindow,@escaping(NSApplication.ModalResponse)->Void)->Void)?
    init(model: ExportProgressWindowModel) {
        self.model = model
        let window = SubmoduleProgressNativeWindow(contentRect: NSRect(x:0,y:0,width:760,height:430), styleMask:[.titled,.closable,.resizable], backing:.buffered, defer:false)
        RepositoryWindowTitles.set(window, repository: model.repository.root, dialog: "Export", preferences: model.presentationPreferences); window.minSize = NSSize(width:650,height:320); window.isReleasedWhenClosed = false
        let hosting=NSHostingController(rootView:ExportProgressDialog(model:model).defaultAppStorage(model.presentationPreferences));hosting.sizingOptions=[]
        window.contentViewController = hosting; super.init(window:window); window.delegate = self
        NSLayoutConstraint.activate([hosting.view.widthAnchor.constraint(greaterThanOrEqualToConstant:650),hosting.view.heightAnchor.constraint(greaterThanOrEqualToConstant:320)])
        model.close = { [weak self] in self?.closeIfReady() }
        model.workDidDrain={ [weak self] in if self?.pendingHandoff != nil{self?.closeIfReady()} }
        model.closeForHandoff={ [weak self] action in guard let self,!self.finished,self.pendingHandoff==nil,!self.model.confirmingQuit else{return};self.pendingHandoff=action;self.closeIfReady() }
        window.escapeAction = { [weak model] in guard let model else { return }; if model.busy { model.cancel() } else { model.close() } }
        model.confirmCancellation = { [weak self] choose in
            guard let self,!self.finished,self.model.active,!self.model.confirmingQuit,self.cancellationAlert==nil,let window=self.window,window.attachedSheet==nil else{choose(false);return}
            window.makeFirstResponder(nil)
            let alert = NSAlert(); alert.alertStyle = .informational; alert.messageText = "The process is still running."; alert.informativeText = "Are you sure to abort?"
            let yes = alert.addButton(withTitle:"Yes"); alert.addButton(withTitle:"No"); yes.keyEquivalent = "\r"; alert.window.defaultButtonCell = yes.cell as? NSButtonCell
            alert.window.alphaValue=window.alphaValue;alert.window.appearance=window.effectiveAppearance
            self.cancellationAlert=alert;var answered=false
            let answer:(NSApplication.ModalResponse)->Void={ [weak self] response in
                guard let self,!answered else{return};answered=true
                let release=ExportChildRelease(window:alert.window,parent:window,closeWindow:true){ [self] in
                    let accepted = !self.finished && self.model.active && !self.model.confirmingQuit && self.cancellationAlert===alert
                    if self.cancellationAlert===alert{self.cancellationAlert=nil}
                    self.cancellationAnswer=nil;choose(accepted && response == .alertFirstButtonReturn)
                    if self.pendingHandoff != nil{self.closeIfReady()}
                }
                release.start()
            }
            self.cancellationAnswer=answer
            if let presentCancellation=self.presentCancellation{presentCancellation(alert,window,answer)}else{alert.beginSheetModal(for:window,completionHandler:answer)}
        }

        DialogGeometry.attach(window, identifier: "ProgressDlg")
    }
    private func closeIfReady(){
        guard !finished,model.active,!model.confirmingQuit,!model.busy,!model.hasPendingWork,!model.confirmingCancellation,cancellationAlert==nil,let window,window.attachedSheet==nil else{return}
        presentationParent=window.sheetParent;closingForHandoff=pendingHandoff != nil;window.close()
        if !finished,!window.isVisible{retireClosedWindow()}
    }
    func windowShouldClose(_ sender:NSWindow)->Bool{
        guard !model.confirmingQuit,cancellationAlert==nil,!model.confirmingCancellation else{return false}
        if model.busy{model.cancel();return false}
        return !model.hasPendingWork && sender.attachedSheet==nil
    }
    func windowWillClose(_ notification:Notification){guard notification.object as? NSWindow === window else{return};retireClosedWindow()}
    func closeForOwnerRetirement(){ownerRetired=true;pendingHandoff=nil;window?.close();if !finished{retireClosedWindow()}}
    private func retireClosedWindow(){
        guard !finished else{return};finished=true
        model.invalidate();model.closeForHandoff=nil;model.workDidDrain=nil;cancellationAnswer?(.abort)
        if let window,let sheet=window.attachedSheet,sheet !== questionWindow{window.endSheet(sheet,returnCode:.abort);sheet.close()}
        let action=closingForHandoff ? pendingHandoff:nil;pendingHandoff=nil
        guard let window else{onClosed();return}
        let release=ExportChildRelease(window:window,parent:presentationParent ?? window.sheetParent,ready:{ [self] in !model.hasPendingWork && cancellationAlert==nil }){ [self] in
            self.release=nil;model.saveActionLog();onClosed();if !model.confirmingQuit && !ownerRetired{action?()}
        }
        self.release=release;release.start()
    }
    required init?(coder:NSCoder) { fatalError("init(coder:) is not supported") }
}
struct ExportProgressDialog: View {
    @ObservedObject var model: ExportProgressWindowModel
    var body: some View {
        VStack(alignment:.leading,spacing:12) {
            Text(model.repository.root.path).font(.caption).lineLimit(1).truncationMode(.middle).textSelection(.enabled).help(model.repository.root.path)
            Text(model.currentWork.isEmpty ? " " : model.currentWork).font(.caption).lineLimit(1).help(model.currentWork)
            ProgressView(value:Double(model.commandFinished ? 100:model.percentage ?? 0),total:100)
                .tint(model.commandFinished ? model.commandSucceeded && (model.busy || model.success) ? .blue:.red:.accentColor).accessibilityLabel("Git command progress")
            SubmoduleProgressOutputView(text:model.output,completed:model.commandFinished,completionRange:model.completionRange,success:model.commandSucceeded,preferences:model.outputPreferences,clipboard:model.outputClipboard)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            HStack { if model.busy { GitCommandActivity(animate: model.progressPresentation.animateActivity) }; Text(model.busy ? model.cancelling ? "Cancelling…" : "Exporting…" : model.cancelled ? "Cancelled" : model.success ? "Finished" : "Export failed").foregroundStyle(model.busy ? Color.primary : model.success ? Color.green : Color.red); Spacer() }
            HStack {
                if model.success { ExportCompletionControl(model:model).fixedSize() }
                Spacer()
                Button("Close") { model.close() }.keyboardShortcut(.defaultAction).disabled(model.busy || model.confirmingCancellation)
                Button("Abort") { if model.busy { model.cancel() } else { model.close() } }.keyboardShortcut(.cancelAction)
                    .disabled(model.success || model.confirmingCancellation || model.busy && !model.canCancel)
            }.disabled(model.confirmingCancellation || model.confirmingQuit || model.hasPendingWork && !model.busy)
        }.padding(12)
    }
}

@MainActor private final class ExportChildRelease {
    static private(set) var activeCount=0
    private let window:NSWindow,parent:NSWindow?
    private let closeWindow:Bool,ready:()->Bool
    private var completion:()->Void
    private var observer:NSObjectProtocol?,waiter:Task<Void,Never>?
    private var started=false,finished=false
    init(window:NSWindow,parent:NSWindow?,closeWindow:Bool=false,ready:@escaping()->Bool={true},completion:@escaping()->Void){self.window=window;self.parent=parent;self.closeWindow=closeWindow;self.ready=ready;self.completion=completion}
    func start(){
        guard !started else{return};started=true;Self.activeCount += 1
        if window.sheetParent != nil || parent?.attachedSheet===window{
            observer=NotificationCenter.default.addObserver(forName:NSWindow.didEndSheetNotification,object:nil,queue:.main){ [self] _ in DispatchQueue.main.async{self.drain()} }
            (window.sheetParent ?? parent)?.endSheet(window);window.orderOut(nil)
        }
        drain()
        if !finished{waiter=Task{ @MainActor [self] in while !finished{try? await Task.sleep(nanoseconds:5_000_000);drain()} }}
    }
    private func drain(){
        guard !finished,window.attachedSheet==nil,window.sheetParent==nil,parent?.attachedSheet !== window,ready() else{return};finished=true
        waiter?.cancel();waiter=nil
        if let observer{NotificationCenter.default.removeObserver(observer);self.observer=nil}
        Self.activeCount -= 1;if closeWindow{window.close()};let done=completion;completion={};done()
    }
}

private struct ExportRadio: NSViewRepresentable {
    let title: String
    let value: ExportWindowModel.Target
    @Binding var selection: ExportWindowModel.Target
    @Environment(\.isEnabled) private var enabled
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> NSButton { NSButton(radioButtonWithTitle: title, target: context.coordinator, action: #selector(Coordinator.clicked)) }
    func updateNSView(_ button: NSButton, context: Context) { button.title = title; button.state = selection == value ? .on : .off; button.isEnabled = enabled; context.coordinator.select = { selection = value } }
    static func dismantleNSView(_ button:NSButton,coordinator:Coordinator){coordinator.select={};button.target=nil;button.action=nil;button.isEnabled=false}
    final class Coordinator: NSObject { var select: () -> Void = {}; @objc func clicked(_ sender: NSButton) { guard sender.isEnabled,sender.window?.attachedSheet==nil else{return};select() } }
}
