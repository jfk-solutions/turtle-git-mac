import AppKit
import SwiftUI
import TurtleGitCore

typealias SSHCloneTransportFactory = @MainActor (GitRepository) -> SSHTransportCoordinator

@MainActor final class CloneWindowController: NSWindowController, NSWindowDelegate {
    let model: CloneWindowModel
    var onClosed: () -> Void = {}
    private(set) var progressController: CloneProgressWindowController?
    static var activeChildReleases:Int {CloneChildRelease.activeCount}
    private var closed=false,released=false
    private var release:CloneChildRelease?
    private var closedActions:[()->Void]=[]
    init(directory: URL?, access: RepositoryAccessLease?, preferences: UserDefaults = .standard, executable: URL? = nil, clipboardText:String? = nil) {
        model = CloneWindowModel(directory: directory, access: access, preferences: preferences, executable: executable,clipboardText:clipboardText)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 820, height: 420), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = "Git Clone – TurtleGit"
        window.minSize = NSSize(width: 780, height: 452)
        window.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: 452)
        window.isReleasedWhenClosed = false
        window.contentViewController = NSHostingController(rootView: CloneDialog(model: model).defaultAppStorage(preferences))
        super.init(window: window); TurtleGitHelp.attach(window, topic: .clone); window.delegate = self; model.window = window
        window.setContentSize(NSSize(width: 820, height: 420)); window.center()
        model.close = { [weak self] in
            guard let self,!self.model.confirmingQuit,!self.model.activeOperation,self.window?.attachedSheet == nil,let window=self.window else{return}
            window.close();if !self.closed,!window.isVisible{self.retireClosedWindow()}
        }
        model.workDidDrain={ [weak self] in guard let self,!self.closedActions.isEmpty,!self.closed else{return};self.model.close() }
        model.afterClose = { [weak self] action in
            guard let self,!self.model.confirmingQuit else{return}
            if self.released {action();return}
            self.closedActions.append(action)
            if !self.closed {self.model.close()}
        }
        model.onExplore = { NSWorkspace.shared.activateFileViewerSelecting([$0]) }
        model.onProgress = { [weak self] result in
            guard let self,!self.closed,!self.model.confirmingQuit,let window=self.window,window.attachedSheet == nil else{result.abandonPresentation();return}
            let controller=CloneProgressWindowController(model:result)
            controller.onClosing={ [weak model=self.model] window in model?.handoffPresentation=MergeWindowPresentation(window) }
            controller.onClosed={ [weak self,weak result] in
                guard let self,let result else{return};self.progressController=nil;self.model.finish(result)
            }
            self.progressController=controller
            if let child=controller.window{MergeWindowPresentation(window).apply(to:child);window.beginSheet(child)}
            else{self.progressController=nil;result.abandonPresentation()}
        }
        model.presentSSH = { [weak self] prompt in
            guard let self,!self.closed,!self.model.confirmingQuit,let owner=self.progressController?.window ?? self.window,owner.attachedSheet == nil,let child=prompt.window else{return false}
            MergeWindowPresentation(owner).apply(to:child);owner.makeFirstResponder(nil);owner.beginSheet(child);return true
        }
        DialogGeometry.attach(window, identifier: "CloneWindowController")
    }
    override func close(){super.close();if !closed,window?.isVisible != true{retireClosedWindow()}}
    func windowShouldClose(_ sender:NSWindow)->Bool {!model.confirmingQuit && !model.activeOperation && sender.attachedSheet == nil}
    private func retireClosedWindow(){
        guard !closed else{return};closed=true
        let progress=progressController;progressController=nil
        if let window{model.handoffPresentation=MergeWindowPresentation(window)}
        model.afterClose=nil;model.invalidate();progress?.close()
        if let window,let child=window.attachedSheet,child !== progress?.window,child !== model.openPanel{window.endSheet(child,returnCode:.abort);child.close()}
        guard let window else{released=true;onClosed();let actions=closedActions;closedActions=[];actions.forEach{$0()};return}
        let release=CloneChildRelease(window:window,parent:window.sheetParent,ready:{ [self] in !model.hasPendingWork && model.openPanel == nil && progress?.presentationClosed != false }){ [self] in
            self.release=nil;released=true;onClosed();let actions=closedActions;closedActions=[];actions.forEach{$0()}
        };self.release=release;release.start()
    }
    func windowWillClose(_ notification:Notification){guard notification.object as? NSWindow === window else{return};retireClosedWindow()}
    required init?(coder:NSCoder){fatalError("init(coder:) is not supported")}
}

@MainActor final class CloneWindowModel: ObservableObject {
    static private(set) var activeOperations = 0
    private(set) var pendingOperations=0
    var hasPendingWork:Bool {pendingOperations>0}
    var workDidDrain:(()->Void)?
    private func beginWork(){pendingOperations += 1;Self.activeOperations += 1}
    private func endWork(){pendingOperations -= 1;Self.activeOperations -= 1;if !hasPendingWork{workDidDrain?()}}
    private var formRevision=UUID(),interactionGeneration=0
    private var submissionGeneration:Int?
    @Published var confirmingQuit=false {didSet{if oldValue != confirmingQuit{formRevision=UUID();interactionGeneration += 1};progress?.confirmingQuit=confirmingQuit}}
    var handoffPresentation:MergeWindowPresentation?
    var afterClose:((@escaping()->Void)->Void)?
    struct FormContext:Equatable {let owner:ObjectIdentifier;let revision:UUID}
    var formContext:FormContext {.init(owner:ObjectIdentifier(self),revision:formRevision)}
    var canEditForm:Bool {!invalidated && !finished && !confirmingQuit && !activeOperation && completed == nil}
    func field<Value>(_ key:ReferenceWritableKeyPath<CloneWindowModel,Value>,context:FormContext)->Binding<Value>{
        Binding(get:{self[keyPath:key]},set:{value in guard self.canEditForm,self.formContext == context else{return};self[keyPath:key]=value})
    }
    private var draft:[GitReferenceName] {[source,directory,String(recursive),String(bare),String(noCheckout),String(useDepth),depth,String(useBranch),branch,String(useOrigin),origin,String(useKey),key,String(svn),String(useTrunk),trunk,String(useTags),tags,String(useBranches),branches,String(useFrom),from,String(useUsername),username].map{GitReferenceName($0)}}
    weak var window: NSWindow?
    private(set) var openPanel: NSOpenPanel?
    private var panelReply: CheckedContinuation<URL?, Never>?
    private var panelGeneration = UUID()
    var presentOpenPanel: (NSOpenPanel, NSWindow, @escaping (NSApplication.ModalResponse) -> Void) -> Void = { panel, owner, completion in panel.beginSheetModal(for: owner, completionHandler: completion) }
    var selectedPanelURL: (NSOpenPanel) -> URL? = { $0.url }
    private func choose(_ panel:NSOpenPanel)async->URL? {
        guard !invalidated,!confirmingQuit,openPanel == nil,let window,window.attachedSheet == nil else{return nil}
        let identity=UUID(),snapshot=draft,context=formContext
        panelGeneration=identity;openPanel=panel
        MergeWindowPresentation(window).apply(to:panel)
        return await withCheckedContinuation{continuation in
            panelReply=continuation;var answered=false
            presentOpenPanel(panel,window){ [weak self,panel] response in
                guard !answered,let self,self.panelGeneration==identity,self.openPanel === panel else{return};answered=true
                let value=response == .OK ? self.selectedPanelURL(panel):nil
                let release=CloneChildRelease(window:panel,parent:window,closeWindow:true){ [self] in
                    guard self.panelGeneration==identity,self.openPanel === panel else{return}
                    self.openPanel=nil;self.panelRelease=nil;let reply=self.panelReply;self.panelReply=nil
                    reply?.resume(returning:!self.invalidated && !self.confirmingQuit && self.formContext==context && self.draft==snapshot ? value:nil)
                };self.panelRelease=release;release.start()
            }
        }
    }
    private var panelRelease:CloneChildRelease?
    private func browse(_ panel:NSOpenPanel,selected:@escaping(URL)->Void){
        guard canEditForm else{return};formRevision=UUID();granting=true;beginWork()
        Task{ [self] in
            let url=await choose(panel);granting=false;endWork()
            if let url,!invalidated,!finished,!confirmingQuit{selected(url)}
        }
    }
    @Published var source = ""
    @Published var directory: String
    @Published var recursive: Bool
    @Published var bare = false
    @Published var noCheckout = false
    @Published var useDepth = false
    @Published var depth = "1"
    @Published var useBranch = false
    @Published var branch = ""
    @Published var useOrigin = false
    @Published var origin = ""
    @Published var useKey = false
    @Published var key = ""
    @Published var svn = false
    @Published var useTrunk = false
    @Published var trunk = "trunk"
    @Published var useTags = false
    @Published var tags = "tags"
    @Published var useBranches = false
    @Published var branches = "branches"
    @Published var useFrom = false
    @Published var from = "0"
    @Published var useUsername = false
    @Published var username = ""
    @Published var busy = false
    @Published var output: String?
    @Published var completed: URL?
    @Published private(set) var completionWarning:String?
    private var pendingInspection:(CloneOutcome,CloneOptions,URL,RepositoryAccessLease,RepositoryAccessLease?)?
    var canShowLog:Bool {clonedRepository != nil}
    @Published var error: String?
    var identities = SSHIdentityAccessStore()
    var makeSSHCoordinator: SSHCloneTransportFactory?
    var presentSSH: (SSHKeyPassphraseWindowController) -> Bool = { _ in false }
    var sshAvailable: Bool { makeSSHCoordinator != nil || (try? SSHAgentRuntime.resolve())?.askpass != nil }
    private var operationCancellation: OperationCancellation?
    private let preferences: UserDefaults
    private let executable: URL?
    private var invalidated = false, finished = false
    @Published private(set) var granting = false
    @Published private(set) var progress: CloneProgressWindowModel?
    var activeOperation: Bool { busy || granting || hasPendingWork || progress != nil }
    var onProgress: ((CloneProgressWindowModel) -> Void)?
    var onExplore: (URL) -> Void = { _ in }
    func invalidate() {
        guard !invalidated else{return}
        invalidated = true; operationCancellation?.cancel(); progress?.invalidate(); keyAccess = nil
        formRevision=UUID()
        if let panel=openPanel,panelRelease == nil {
            let release=CloneChildRelease(window:panel,parent:window,closeWindow:true){ [self] in
                self.openPanel=nil;self.panelRelease=nil;let reply=self.panelReply;self.panelReply=nil;reply?.resume(returning:nil)
            };panelRelease=release;release.start()
        }
        // Running workers and a queued workspace handoff retain their captured
        // leases. A retired dialog no longer needs browsing/result permissions.
        destinationAccess = nil; sourceAccess = nil; pendingInspection = nil
        clonedRepository = nil; progress = nil
        onCloned = { _, _, _, _, _ in }; onLog = { _, _ in }
        onProgress = nil; onExplore = { _ in }; close = {}
    }
    func finish(_ result: CloneProgressWindowModel) {
        guard progress === result, !result.busy, !result.hasPendingWork, !result.confirmingCancellation else { return }
        progress = nil; result.invalidate(); busy = false
        guard !invalidated else { return }; if result.commandCompleted { finished = true; close() }
    }
    private var destinationAccess: RepositoryAccessLease?
    private var sourceAccess: RepositoryAccessLease?
    private var keyAccess: RepositoryAccessLease?
    private var automaticDirectory: String?
    @Published private(set) var urls: [String]
    @Published private(set) var keys: [String]
    var close: () -> Void = {}
    var onCloned: (GitRepository, RepositoryAccessLease, RepositoryAccessLease?, Bool, String) -> Void = { _, _, _, _, _ in }
    var onLog: (GitRepository, RepositoryAccessLease) -> Void = { _, _ in }
    private var clonedRepository: GitRepository?
    init(directory: URL?, access: RepositoryAccessLease?, preferences: UserDefaults = .standard, executable: URL? = nil, clipboardText:String? = nil) {
        self.preferences = preferences; self.executable = executable
        let defaults = preferences
        self.directory = directory?.path ?? defaults.string(forKey: "Clone.Directory") ?? FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].path
        recursive = defaults.bool(forKey: "Clone.Recursive")
        urls = FetchDialogHistory.load(defaults,key:"Clone.URLHistory",caseSensitive:true)
        keys = FetchDialogHistory.load(defaults,key:"Clone.KeyHistory",caseSensitive:true)
        source=clipboardText.flatMap(FetchClipboardInput.cloneSource) ?? urls.first ?? ""
        destinationAccess = access
        key = keys.first ?? ""; useKey = supportsKey && sshAvailable && (defaults.object(forKey: "Clone.UseSSHKey") as? Bool ?? true)
    }
    var pathCompletionPreferences: UserDefaults { preferences }
    var pathCompletionAvailable: Bool {canEditForm}
    var pathCompletionPermissions: [RepositoryAccessLease] { [destinationAccess].compactMap { $0 } }
    var supportsKey: Bool {
        let url = source.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return url.hasPrefix("svn+ssh://") || url.hasPrefix("ssh://") || (!url.contains("://") && !url.hasPrefix("/") && url.contains(":"))
    }
    func deleteURLHistory(at index:Int) {
        guard pathCompletionAvailable,let result=FetchDialogHistory.removing(index,entries:urls,preferences:preferences,key:"Clone.URLHistory") else {return}
        urls=result.entries;source=result.selection;sourceChanged()
    }
    func deleteKeyHistory(at index:Int) {
        guard pathCompletionAvailable,let result=FetchDialogHistory.removing(index,entries:keys,preferences:preferences,key:"Clone.KeyHistory") else {return}
        keys=result.entries;key=result.selection
    }
    private func recordSubmission(_ options:CloneOptions,destination:URL,keyText:String) {
        urls=FetchDialogHistory.save(options.source,entries:urls,preferences:preferences,key:"Clone.URLHistory",caseSensitive:true)
        keys=FetchDialogHistory.save(keyText,entries:keys,preferences:preferences,key:"Clone.KeyHistory",caseSensitive:true)
        preferences.set(destination.deletingLastPathComponent().path,forKey:"Clone.Directory")
        preferences.set(options.recursive,forKey:"Clone.Recursive")
        preferences.set(options.sshKey != nil,forKey:"Clone.UseSSHKey")
    }
    private(set) var exactDestination = false
    func configureLaunch(source: String?, exactPath: Bool) {
        guard canEditForm else { return }
        exactDestination = exactPath
        if let source { self.source = source; sourceChanged() }
    }
    func sourceChanged() {
        guard canEditForm else{return}
        let value = source.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "/\\"))
        var name = value.components(separatedBy: CharacterSet(charactersIn: "/\\:")).last ?? ""
        if name.lowercased().hasSuffix(".git") { name.removeLast(4) }
        if !exactDestination, !name.isEmpty, name != ".", name != "..", !name.contains("\0") {
            if let old = automaticDirectory, directory == old {
                directory = URL(fileURLWithPath: old).deletingLastPathComponent().appendingPathComponent(name).path
                automaticDirectory = directory
            } else if automaticDirectory == nil {
                directory = URL(fileURLWithPath: directory).appendingPathComponent(name).path
                automaticDirectory = directory
            }
        }
        useKey = supportsKey && sshAvailable && (preferences.object(forKey: "Clone.UseSSHKey") as? Bool ?? true)
    }
    func svnChanged() {
        guard canEditForm else{return}
        if svn {
            let hasLayout = !source.trimmingCharacters(in: CharacterSet(charactersIn: "/\\").union(.whitespacesAndNewlines)).lowercased().hasSuffix("trunk")
            useTrunk = hasLayout; useTags = hasLayout; useBranches = hasLayout
            useDepth = false; bare = false; recursive = false; useBranch = false; noCheckout = false
        }
    }
    func browseSource() {
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.prompt = "Select repository"
        browse(panel) { [weak self] url in self?.sourceAccess = RepositoryAccessLease(url: url); self?.source = url.path; self?.sourceChanged() }
    }
    func browseDirectory() {
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false
        panel.canCreateDirectories = true; panel.prompt = "Select destination"; panel.directoryURL = URL(fileURLWithPath: directory)
        browse(panel) { [weak self] url in self?.destinationAccess = RepositoryAccessLease(url: url); self?.directory = url.path; self?.automaticDirectory = "" }
    }
    func browseKey() {
        let panel = NSOpenPanel(); panel.canChooseDirectories = false; panel.canChooseFiles = true; panel.prompt = "Select OpenSSH key"
        browse(panel) { [weak self] url in self?.acceptKeySelection(url) }
    }
    func acceptKeySelection(_ url: URL) {
        guard !invalidated, !finished, !confirmingQuit, !busy, progress == nil else { return }
        do { try identities.remember(url, requireSecurityScope: GitRuntime.isAppStoreBuild); key = url.path; error = nil }
        catch { self.error = error.localizedDescription }
    }
    private func captureSSHFactory() -> SSHCloneTransportFactory {
        if let makeSSHCoordinator { return makeSSHCoordinator }
        let identities = identities, present = presentSSH
        return { repo in let value = SSHTransportCoordinator(repository: repo, identities: identities); value.present = present; return value }
    }
    private func grant(_ target: URL, current: RepositoryAccessLease?, message: String, file: Bool = false) async -> RepositoryAccessLease? {
        guard !invalidated,!confirmingQuit else { return nil }
        if let current, current.contains(target), !GitRuntime.isAppStoreBuild || current.hasSecurityScope { return current }
        if !GitRuntime.isAppStoreBuild { return RepositoryAccessLease(url: target) }
        let panel = NSOpenPanel(); panel.canChooseDirectories = !file; panel.canChooseFiles = file
        panel.message = message; panel.prompt = "Authorize"; panel.directoryURL = file ? target.deletingLastPathComponent() : target
        guard let url = await choose(panel), !invalidated else { return nil }
        let lease = RepositoryAccessLease(url: url)
        guard lease.hasSecurityScope, lease.contains(target) else { error = "The selected permission does not cover “\(target.path)”."; return nil }
        return lease
    }
    func clone() {
        guard canEditForm else{return};formRevision=UUID();submissionGeneration=interactionGeneration;granting=true
        let submittedContext=formContext
        do {
            let path = directory.trimmingCharacters(in: .whitespacesAndNewlines)
            guard path.hasPrefix("/") else { throw CloneFailure.destination }
            let destination = URL(fileURLWithPath: path, isDirectory: true)
            let cwd = try CloneOptions.workingDirectory(for: destination)
            var options = CloneOptions(); options.source = source.trimmingCharacters(in: .whitespacesAndNewlines)
            options.recursive = recursive; options.bare = bare; options.noCheckout = noCheckout; options.svn = svn
            if useDepth { guard let value = Int(depth), value > 0 else { throw CloneFailure.number }; options.depth = value }
            if useBranch { options.branch = branch.trimmingCharacters(in: .whitespacesAndNewlines) }
            if useOrigin { options.origin = origin.trimmingCharacters(in: .whitespacesAndNewlines) }
            if svn {
                options.trunk = useTrunk ? trunk : nil; options.tags = useTags ? tags : nil; options.branches = useBranches ? branches : nil
                options.username = useUsername ? username : nil
                if useFrom { guard let value = Int(from), value >= 0 else { throw CloneFailure.number }; options.fromRevision = value }
            }
            if useKey { guard key.hasPrefix("/"), supportsKey else { throw CloneFailure.value }; guard sshAvailable else { throw CloneFailure.keyRuntime }; options.sshKey = URL(fileURLWithPath: key); options.loadSSHKeyWithAgent = true }
            _ = try options.arguments(destination: destination)
            let capturedOptions = options,capturedKeyText=key,preparationToken=OperationCancellation()
            operationCancellation=preparationToken
            beginWork()
            Task { [self] in
                defer { granting = false; endWork();if operationCancellation === preparationToken {operationCancellation=nil} }
                guard !invalidated,!confirmingQuit,!finished else{return}
                do {
                    let options = capturedOptions
            guard let access = await grant(cwd, current: destinationAccess, message: "Authorize the destination or an existing parent folder so TurtleGit can create the clone.") else { return }
            guard !invalidated else { return }
            guard access.contains(destination) else { throw RepositoryAccessFailure.repositoryRootOutsidePermission(destination.path) }
            destinationAccess = access
            let localSource = options.source.hasPrefix("/") ? URL(fileURLWithPath: options.source) : URL(string: options.source).flatMap { $0.isFileURL ? $0 : nil }
            if let localSource {
                guard let lease = await grant(localSource, current: sourceAccess, message: "Authorize the local source repository.") else { return }; sourceAccess = lease
            }
            if let key = options.sshKey {
                keyAccess = try identities.acquire(path: key.path, requireSecurityScope: GitRuntime.isAppStoreBuild).permission
            }
            let executable = try self.executable ?? GitRuntime.executable(), snapshot = options
            let capturedSourceAccess = sourceAccess, capturedKeyAccess = keyAccess
            let sshFactory = options.loadSSHKeyWithAgent ? captureSSHFactory() : nil
            let preflight=GitRepository(root:cwd,executable:executable)
            try await preflight.validateClone(snapshot,to:destination,cancellation:preparationToken)
            try preparationToken.check();guard !invalidated,!confirmingQuit,!finished,formContext==submittedContext else{return}
            recordSubmission(snapshot,destination:destination,keyText:capturedKeyText)
            busy = true; output = nil; error = nil
            if let onProgress {
                let result = CloneProgressWindowModel(options: snapshot, destination: destination, executable: executable, destinationAccess: access, sourceAccess: capturedSourceAccess, keyAccess: capturedKeyAccess, preferences: preferences)
                result.makeSSHCoordinator = sshFactory
                result.onCloned = { [weak self] repo, output in self?.recordClone(repo, output: output, options: snapshot, destination: destination, access: access, keyAccess: capturedKeyAccess) }
                let generation=interactionGeneration,log=onLog,explore=onExplore
                result.onPostAction={ [self] action,repo in
                    let dispatch={ [self] in guard !confirmingQuit,interactionGeneration==generation else{return};if action == .log{log(repo,access)}else if action == .explore{explore(repo.root)}}
                    if let afterClose{afterClose(dispatch)}else{dispatch()}
                }
                result.close = { [weak self, weak result] in guard let self, let result else { return }; self.finish(result) }
                progress = result; onProgress(result); result.start()
            } else {
                let token = OperationCancellation(); operationCancellation = token
                beginWork()
                Task { [self, access, capturedSourceAccess, capturedKeyAccess] in
                    defer { endWork(); withExtendedLifetime((access, capturedSourceAccess, capturedKeyAccess)) {} }
                    defer { if operationCancellation === token { operationCancellation = nil; busy = false } }
                    do {
                        let runner = GitRepository(root: cwd, executable: executable)
                        let coordinator = sshFactory?(runner); defer { coordinator?.close() }
                        if snapshot.svn { _ = try await runner.run(["svn", "--version"], cancellation: token) }
                        let outcome = try await runner.cloneOutcome(snapshot,to:destination,cancellation:token,prepareTransport:snapshot.sshKey.flatMap {coordinator?.explicitPreparation(path:$0.path)})
                        guard !invalidated else {return}
                        output=outcome.summary;pendingInspection=(outcome,snapshot,destination,access,capturedKeyAccess)
                        try await finishDirectInspection(cancellation:token)
                    } catch { if !invalidated {
                        if pendingInspection != nil {completed=destination;completionWarning="Clone completed, but the repository could not be opened.\n" + error.localizedDescription}
                        else if !token.isCancelled {self.output=error.localizedDescription;self.error=error.localizedDescription}
                    } }
                }
            }
                } catch { if !invalidated { self.error = error.localizedDescription } }
            }
        } catch { granting = false; if !invalidated { self.error = error.localizedDescription } }
    }
    private func finishDirectInspection(cancellation token:OperationCancellation) async throws {
        guard let (outcome,options,destination,access,keyAccess)=pendingInspection else {return}
        let candidate=GitRepository(root:destination,executable:try executable ?? GitRuntime.executable())
        let repo=options.bare ? candidate:GitRepository(root:try await candidate.discoverRoot(cancellation:token),executable:candidate.executable)
        try token.check();guard !invalidated else {return}
        if GitRuntime.isAppStoreBuild && !access.contains(repo.root) {throw RepositoryAccessFailure.repositoryRootOutsidePermission(repo.root.path)}
        pendingInspection=nil;completionWarning=outcome.warnings.isEmpty ? nil:outcome.warnings.joined(separator:"\n")
        recordClone(repo,output:outcome.summary,options:options,destination:destination,access:access,keyAccess:keyAccess)
    }
    func retryOpeningRepository() {
        guard !invalidated,!confirmingQuit,!activeOperation,pendingInspection != nil else {return}
        let token=OperationCancellation();operationCancellation=token;busy=true;beginWork()
        Task { [self] in
            defer {if operationCancellation === token {operationCancellation=nil;busy=false};endWork()}
            do {try await finishDirectInspection(cancellation:token)}
            catch {if !invalidated {completionWarning="Clone completed, but the repository could not be opened.\n" + error.localizedDescription}}
        }
    }
    private func recordClone(_ repo: GitRepository, output: String, options: CloneOptions, destination: URL, access: RepositoryAccessLease, keyAccess: RepositoryAccessLease?) {
        guard !invalidated else { return }
        clonedRepository = repo; completed = repo.root; self.output = output
        if !confirmingQuit,submissionGeneration == interactionGeneration{onCloned(repo,access,options.loadSSHKeyWithAgent ? nil:keyAccess,options.bare,output)}
    }
    func showLog(){guard !invalidated,!confirmingQuit,!activeOperation,let repo=clonedRepository,let access=destinationAccess else{return};let callback=onLog,generation=interactionGeneration,dispatch={ [self] in guard !confirmingQuit,interactionGeneration==generation else{return};callback(repo,access)};if let afterClose{afterClose(dispatch)}else{close();dispatch()}}
    func explore(){guard !invalidated,!confirmingQuit,!activeOperation,let destination=completed else{return};let callback=onExplore,generation=interactionGeneration,dispatch={ [self] in guard !confirmingQuit,interactionGeneration==generation else{return};callback(destination)};if let afterClose{afterClose(dispatch)}else{close();dispatch()}}
}

struct CloneDialog: View {
    @ObservedObject var model: CloneWindowModel
    var body: some View {
        let context=model.formContext,urls=model.urls,keys=model.keys
        VStack(alignment: .leading, spacing: 14) {
            if let destination = model.completed {
                Text("Clone completed").font(.headline)
                Text(destination.path).textSelection(.enabled)
                if let warning=model.completionWarning {Label(warning,systemImage:"exclamationmark.triangle.fill").foregroundStyle(.orange).textSelection(.enabled)}
                OutputView(text: model.output ?? "").frame(maxHeight: .infinity)
                HStack {
                    Button { model.showLog() } label: { CommandLabel(title: "Show Log", icon: .log) }.disabled(!model.canShowLog)
                    if !model.canShowLog {Button("Retry opening repository") {model.retryOpeningRepository()}}
                    Button { model.explore() } label: { CommandLabel(title: "Show in Finder", icon: .explore) }
                    Spacer(); Button("Close") { model.close() }.keyboardShortcut(.defaultAction)
                }
            } else {
                GroupBox("Clone Existing Repository") {
                    VStack(spacing: 12) {
                        HStack { Text("URL:").frame(width: 70, alignment: .leading); CloneHistoryCombo(value: model.field(\.source,context:context), choices: model.urls, label: "Repository URL",onDelete:{index in guard model.formContext==context,model.urls.map({GitReferenceName($0)})==urls.map({GitReferenceName($0)}) else{return};model.deleteURLHistory(at:index)})
                            Button("Browse…") { model.browseSource() }
                            Menu {
                                Button { if let url = URL(string: model.source), ["https", "http"].contains(url.scheme ?? "") { NSWorkspace.shared.open(url) } } label: { CommandLabel(title: "Open URL", icon: .open) }
                                Button { model.browseSource() } label: { CommandLabel(title: "Browse local repository…", icon: .explore) }
                            } label: { Image(systemName: "chevron.down") }.menuStyle(.borderlessButton).frame(width: 18)
                        }
                        HStack { Text("Directory:").frame(width: 70, alignment: .leading); PathEntryField(text: model.field(\.directory,context:context), label: "Destination directory", permissions: model.pathCompletionPermissions, preferences: model.pathCompletionPreferences, mayEdit: { model.pathCompletionAvailable }).frame(height: 22); Button("Browse…") { model.browseDirectory() } }
                        HStack {
                            Toggle("Depth", isOn: model.field(\.useDepth,context:context)).disabled(model.svn); TextField("Depth", text: model.field(\.depth,context:context)).frame(width: 48).disabled(!model.useDepth || model.svn)
                            Toggle("Recursive", isOn: model.field(\.recursive,context:context)).disabled(model.svn || model.bare)
                            Toggle("Clone into Bare Repo", isOn: model.field(\.bare,context:context)).disabled(model.svn || model.recursive || model.noCheckout || model.useOrigin)
                            Toggle("No Checkout", isOn: model.field(\.noCheckout,context:context)).disabled(model.svn || model.bare)
                            Spacer(minLength: 0)
                        }
                        HStack {
                            Toggle("Branch", isOn: model.field(\.useBranch,context:context)).disabled(model.svn); TextField("Branch", text: model.field(\.branch,context:context)).disabled(!model.useBranch || model.svn)
                            Toggle("Origin Name", isOn: model.field(\.useOrigin,context:context)).disabled(model.bare); TextField("Origin name", text: model.field(\.origin,context:context)).disabled(!model.useOrigin || model.bare)
                        }
                    }.padding(8)
                }
                HStack {
                    Toggle("Auto-load SSH key", isOn: model.field(\.useKey,context:context)).disabled(!model.supportsKey || !model.sshAvailable).help(model.sshAvailable ? "Load an OpenSSH key into a private agent for this clone." : "SSH key loading is unavailable in this build.")
                    CloneHistoryCombo(value: model.field(\.key,context:context), choices: model.keys, label: "OpenSSH private key",onDelete:{index in guard model.formContext==context,model.keys.map({GitReferenceName($0)})==keys.map({GitReferenceName($0)}) else{return};model.deleteKeyHistory(at:index)}).disabled(!model.useKey || !model.supportsKey || !model.sshAvailable)
                    Button("…") { model.browseKey() }.disabled(!model.useKey || !model.supportsKey || !model.sshAvailable).help("Select an OpenSSH private key.")
                }
                GroupBox("From SVN Repository") {
                    VStack(alignment: .leading, spacing: 12) {
                        Toggle("From SVN Repository", isOn: model.field(\.svn,context:context))
                        HStack {
                            Toggle("Trunk", isOn: model.field(\.useTrunk,context:context)).disabled(!model.svn); TextField("Trunk", text: model.field(\.trunk,context:context)).disabled(!model.svn || !model.useTrunk)
                            Toggle("Tags", isOn: model.field(\.useTags,context:context)).disabled(!model.svn); TextField("Tags", text: model.field(\.tags,context:context)).disabled(!model.svn || !model.useTags)
                            Toggle("Branch", isOn: model.field(\.useBranches,context:context)).disabled(!model.svn); TextField("SVN branches", text: model.field(\.branches,context:context)).disabled(!model.svn || !model.useBranches)
                        }
                        HStack {
                            Toggle("From", isOn: model.field(\.useFrom,context:context)).disabled(!model.svn); TextField("Starting revision", text: model.field(\.from,context:context)).frame(width: 80).disabled(!model.svn || !model.useFrom)
                            Toggle("Username", isOn: model.field(\.useUsername,context:context)).disabled(!model.svn); TextField("SVN username", text: model.field(\.username,context:context)).disabled(!model.svn || !model.useUsername)
                        }
                    }.padding(8)
                }
                Spacer(minLength: 0)
                HStack {
                    if model.busy { ProgressView().controlSize(.small); Text("Cloning…") }
                    Spacer(); Button(model.output == nil ? "OK" : "Retry") { model.clone() }.keyboardShortcut(.defaultAction)
                    Button("Cancel") { model.close() }.keyboardShortcut(.cancelAction)
                    Button("Help") { TurtleGitHelp.show(.clone) }
                }
            }
        }.padding(16).textFieldStyle(.roundedBorder).toggleStyle(.checkbox).disabled(model.activeOperation || model.confirmingQuit)
        .onChange(of: model.source) { _ in guard model.formContext==context else{return};model.sourceChanged() }
        .onChange(of: model.svn) { _ in guard model.formContext==context else{return};model.svnChanged() }
        .onChange(of: model.bare) { value in if value,model.canEditForm,model.formContext==context { model.recursive = false; model.noCheckout = false; model.useOrigin = false } }
        .alert("Clone failed", isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) { Button("OK") { model.error = nil } } message: { Text(model.error ?? "") }
    }
}

struct CloneHistoryCombo: NSViewRepresentable {
    @Binding var value: String
    let choices: [String]
    let label: String
    var onEndEditing: () -> Void = {}
    var onDelete: ((Int)->Void)? = nil
    @AppStorage("UseCustomWordBreak") private var wordBreakMode=2
    @Environment(\.isEnabled) private var enabled
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> NSComboBox {
        let combo: NSComboBox = onDelete == nil ? NSComboBox():EditableHistoryCombo(); combo.delegate = context.coordinator; combo.completes = true
        combo.setContentHuggingPriority(.defaultLow, for: .horizontal); return combo
    }
    func updateNSView(_ combo: NSComboBox, context: Context) {
        context.coordinator.wordCommands.policy=GitInputWordBreak(mode:UInt32(truncatingIfNeeded:wordBreakMode))
        let coordinator = context.coordinator; coordinator.updating = true; defer { coordinator.updating = false }
        coordinator.change = { value = $0 }; coordinator.endEditing = onEndEditing
        (combo as? EditableHistoryCombo)?.deleteHistory=onDelete
        if !coordinator.choices.elementsEqual(choices,by:{$0.utf16.elementsEqual($1.utf16)}) {
            if let editable=combo as? EditableHistoryCombo {editable.replaceHistory(choices)} else {combo.removeAllItems();combo.addItems(withObjectValues:choices)}
            coordinator.choices=choices
        }
        if !GitReferenceName.equal(combo.stringValue,value) { combo.stringValue = value }
        combo.isEnabled = enabled; combo.setAccessibilityLabel(label)
    }
    static func dismantleNSView(_ combo:NSComboBox,coordinator:Coordinator) {combo.delegate=nil;(combo as? EditableHistoryCombo)?.deleteHistory=nil}
    @MainActor final class Coordinator: NSObject, NSComboBoxDelegate {
        let wordCommands=GitInputWordCommands()
        func control(_ control:NSControl,textView:NSTextView,doCommandBy commandSelector:Selector)->Bool {
            wordCommands.handle(control,text:textView,selector:commandSelector,combo:true,owner:self)
        }
        func comboBoxWillPopUp(_ notification:Notification) {(notification.object as? EditableHistoryCombo)?.historyPopupOpen=true}
        func comboBoxWillDismiss(_ notification:Notification) {(notification.object as? EditableHistoryCombo)?.historyPopupOpen=false}
        var endEditing: () -> Void = {}
        func controlTextDidEndEditing(_ notification: Notification) { guard !updating else { return }; endEditing() }
        var choices: [String] = []; var updating = false; var change: (String) -> Void = { _ in }
        func controlTextDidChange(_ notification: Notification) { guard !updating, let combo = notification.object as? NSComboBox else { return }; change(combo.stringValue) }
        func comboBoxSelectionDidChange(_ notification: Notification) { guard !updating, let combo = notification.object as? NSComboBox, choices.indices.contains(combo.indexOfSelectedItem) else { return }; change(choices[combo.indexOfSelectedItem]) }
    }
}

enum ClonePostAction: String, Hashable {
    case retry, inspect, log, explore
    var title: String { switch self { case .retry: return "Retry"; case .inspect: return "Retry opening repository"; case .log: return "Show Log"; case .explore: return "Show in Finder" } }
    var icon: MenuIcon { switch self { case .retry,.inspect: return .refresh; case .log: return .log; case .explore: return .explore } }
}
@MainActor final class CloneProgressWindowModel: ObservableObject {
    static var activeOperations = 0
    private final class CommandReceipt:@unchecked Sendable {
        private let lock=NSLock()
        private var receipt:CloneCommandCompletion?
        private var observer:(@Sendable()->Void)?
        func observe(_ observer:(@Sendable()->Void)?){lock.lock();self.observer=observer;lock.unlock()}
        func reset(){lock.lock();receipt=nil;lock.unlock()}
        func record(_ value:CloneCommandCompletion){lock.lock();guard receipt == nil else{lock.unlock();return};receipt=value;let observer=observer;lock.unlock();observer?()}
        func read()->CloneCommandCompletion? {lock.lock();defer{lock.unlock()};return receipt}
    }
    private let commandReceipt=CommandReceipt()
    @Published private(set) var pendingOperations=0
    var hasPendingWork:Bool {pendingOperations > 0}
    var active:Bool {!invalidated}
    var workDidDrain:(()->Void)?
    private func beginWork(){pendingOperations += 1;Self.activeOperations += 1;LocalGitCommandProgress.begin()}
    private func endWork(){pendingOperations -= 1;Self.activeOperations -= 1;LocalGitCommandProgress.end();if !hasPendingWork {busy=false;workDidDrain?()}}
    let progressPresentation: GitCommandPresentation
    let options: CloneOptions
    let destination: URL
    private let executable: URL
    private let destinationAccess: RepositoryAccessLease
    private let sourceAccess: RepositoryAccessLease?, keyAccess: RepositoryAccessLease?
    private let preferences: UserDefaults, autoClosePolicy: GitProgressAutoClose
    var presentationPreferences:UserDefaults {preferences}
    var outputPreferences:UserDefaults {preferences}
    var outputClipboard:NSPasteboard = .general
    var handoffPresentation:MergeWindowPresentation?
    private var interactionGeneration=0
    @Published var confirmingQuit=false {didSet {if oldValue != confirmingQuit {interactionGeneration += 1}}}
    var finishAndPerform:((@escaping ()->Void)->Void)?
    var presentationAvailable:()->Bool = {true}
    private var cancellation = OperationCancellation()
    private var started = false, invalidated = false, dispatched = false, abandoned = false
    private var repository: GitRepository?
    @Published private(set) var busy = true
    @Published private(set) var success = false
    @Published private(set) var commandCompleted=false
    @Published private(set) var commandFinished=false
    @Published private(set) var commandSucceeded=false
    @Published private(set) var completionRange:NSRange?
    @Published private(set) var warnings:[String]=[]
    private var completedOutcome:CloneOutcome?
    private var adopted=false
    var inspectRepository:(GitRepository,Bool,OperationCancellation) async throws -> GitRepository = {candidate,bare,token in
        try token.check()
        return bare ? candidate:GitRepository(root:try await candidate.discoverRoot(cancellation:token),executable:candidate.executable)
    }
    var statusText:String {busy ? cancelling ? "Cancelling…":commandCompleted ? "Opening cloned repository…":commandFinished ? "Finishing clone configuration…":"Cloning…" : success ? warnings.isEmpty ? "Finished":"Clone completed with warnings" : commandCompleted ? "Clone completed; repository could not be opened" : cancelled ? "Cancelled":"Clone failed"}
    @Published private(set) var cancelled = false
    @Published private(set) var cancelling = false
    @Published private(set) var confirmingCancellation = false
    @Published private(set) var percentage: Int?
    @Published private(set) var currentWork = ""
    private let outputLimit: Int
    private var outputState:GitProgressOutputState
    @Published private(set) var output = ""
    @Published private(set) var postActions: [ClonePostAction] = []
    var close: () -> Void = {}
    var onCloned: (GitRepository, String) -> Void = { _,_ in }
    var onPostAction: ((ClonePostAction, GitRepository) -> Void)?
    var confirmCancellation: (@escaping (Bool) -> Void) -> Void = { $0(false) }
    var canCancel: Bool { active && !confirmingQuit && busy && !commandFinished && !cancelling && !confirmingCancellation }
    init(options: CloneOptions, destination: URL, executable: URL, destinationAccess: RepositoryAccessLease, sourceAccess: RepositoryAccessLease?, keyAccess: RepositoryAccessLease?, preferences: UserDefaults = .standard) {
        self.options = options; self.destination = destination; self.executable = executable; self.destinationAccess = destinationAccess; self.sourceAccess = sourceAccess; self.keyAccess = keyAccess; self.preferences = preferences; autoClosePolicy = GitProgressAutoClose(preferences: preferences); progressPresentation = GitCommandPresentation(defaults: preferences); outputLimit = progressPresentation.outputLimit;outputState=GitProgressOutputState(preferences:preferences)
    }
    var makeSSHCoordinator: SSHCloneTransportFactory?
    func invalidate() { invalidated = true; cancellation.cancel();confirmingCancellation=false;if !hasPendingWork {busy=false} }
    func abandonPresentation() { abandoned = true; cancellation.cancel() }
    private func resetAttempt(){busy=true;success=false;commandCompleted=false;commandFinished=false;commandSucceeded=false;completionRange=nil;completedOutcome=nil;warnings=[];adopted=false;cancelled=false;cancelling=false;output="";outputState.reset();percentage=nil;currentWork="";postActions=[];repository=nil;commandReceipt.reset()}
    func start() {guard !started,!invalidated,!confirmingQuit else{return};started=true;resetAttempt();beginWork();Task {await execute()}}
    func run() async {guard !started,!invalidated,!confirmingQuit else{return};started=true;resetAttempt();beginWork();await execute()}
    private func execute() async {
        defer {endWork();withExtendedLifetime((destinationAccess,sourceAccess,keyAccess)) {};if !invalidated,!hasPendingWork {cancelling=false;finishAutomaticClose()}}
        guard !invalidated,!abandoned else{return}
        let startedAt=ProcessInfo.processInfo.systemUptime
        do {
            if cancellation.isCancelled { throw OperationCancellationFailure.cancelled }
            let cwd = try CloneOptions.workingDirectory(for: destination)
            if GitRuntime.isAppStoreBuild {
                guard destinationAccess.hasSecurityScope, destinationAccess.contains(cwd), destinationAccess.contains(destination) else { throw RepositoryAccessFailure.securityScopeUnavailable }
                let source = options.source.hasPrefix("/") ? URL(fileURLWithPath: options.source) : URL(string: options.source).flatMap { $0.isFileURL ? $0 : nil }
                if let source { guard sourceAccess?.hasSecurityScope == true, sourceAccess?.contains(source) == true else { throw RepositoryAccessFailure.securityScopeUnavailable } }
                if let key = options.sshKey { guard keyAccess?.hasSecurityScope == true, keyAccess?.contains(key) == true else { throw RepositoryAccessFailure.securityScopeUnavailable } }
            }
            let runner = GitRepository(root: cwd, executable: executable)
            let coordinator = makeSSHCoordinator?(runner); defer { coordinator?.close() }
            let preparation = options.sshKey.flatMap { coordinator?.explicitPreparation(path: $0.path) }
            if options.svn { _ = try await runner.run(["svn", "--version"], cancellation: cancellation) }
            guard !invalidated,!abandoned else{return}
            let parser = GitCliOutputParser(limit: outputLimit)
            let (updates, continuation) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
            commandReceipt.observe {continuation.yield(())};defer {commandReceipt.observe(nil)}
            let receipt=commandReceipt
            var parserFinished=false
            func finishParser(){guard !parserFinished else{return};parserFinished=true;consume(parser.processPending(),parser:parser);consume(parser.finish(),parser:parser)}
            let operation = Task {
                defer { continuation.finish() }
                let emit:@Sendable(GitOutputChunk)->Void={chunk in parser.appendChunk(chunk.data);continuation.yield(())}
                return try await runner.cloneOutcome(options,to:destination,cancellation:cancellation,onOutput:emit,prepareTransport:preparation,
                    onCommand:{emit(GitOutputChunk(stream:.stdout,data:$0.preamble))},onCommandFinished:{receipt.record($0)})
            }
            for await _ in updates {
                consume(parser.processPending(),parser:parser)
                if let receipt=commandReceipt.read(){finishParser();completeOutput(succeeded:receipt.success,startedAt:startedAt)}
            }
            finishParser()
            let outcome=try await operation.value
            guard !invalidated,!abandoned else {return}
            completedOutcome=outcome;commandCompleted=true;warnings=outcome.warnings
            completeOutput(succeeded:true,startedAt:startedAt)
            for warning in warnings {appendDiagnostic(warning)}
            try await inspectCompletedRepository(outcome)
        } catch {
            guard !invalidated else {return}
            if commandFinished {if commandSucceeded || !outputState.hasOutput {appendDiagnostic(error.localizedDescription)}}
            else {output=GitProgressFailureOutput.render(error,existing:output,limit:outputLimit);completeOutput(succeeded:false,error:error,startedAt:startedAt)}
            postActions=commandCompleted ? [.inspect,.explore]:[.retry]
        }
        cancelled=cancelled || cancellation.isCancelled
    }
    private func inspectCompletedRepository(_ outcome:CloneOutcome) async throws {
        let repo=try await inspectRepository(GitRepository(root:destination,executable:executable),options.bare,cancellation)
        try cancellation.check()
        if GitRuntime.isAppStoreBuild && !destinationAccess.contains(repo.root) {throw RepositoryAccessFailure.repositoryRootOutsidePermission(repo.root.path)}
        guard !invalidated,!abandoned else {return}
        repository=repo;success=true;postActions=[.log,.explore]
        if !adopted {adopted=true;onCloned(repo,outcome.summary)}
    }
    private func retryInspection() {
        guard let outcome=completedOutcome,!busy,!hasPendingWork,!confirmingQuit,!invalidated else {return}
        cancellation=OperationCancellation();busy=true;cancelled=false;cancelling=false;postActions=[]
        beginWork()
        Task { [self] in
            defer {endWork();withExtendedLifetime((destinationAccess,sourceAccess,keyAccess)) {};if !invalidated,!hasPendingWork {cancelling=false;finishAutomaticClose()}}
            do {try await inspectCompletedRepository(outcome)}
            catch {if !invalidated {appendDiagnostic(error.localizedDescription);postActions=[.inspect,.explore]}}
            guard !invalidated else {return}
            cancelled=cancellation.isCancelled
        }
    }
    private func consume(_ emission: GitCliOutputParser.Emission, parser: GitCliOutputParser) {
        guard !invalidated,!commandFinished else{return}
        outputState.consume(emission,parser:parser);output=outputState.output;currentWork=outputState.currentWork;percentage=outputState.percentage
    }
    private func bounded(_ text:String,bytes limit:Int)->String {
        let bytes=Data(text.utf8),limit=max(0,limit)
        guard bytes.count > limit else{return text}
        let marker="\n[Output truncated at about \(outputLimit / 1024) KiB]\n"
        var count=max(0,limit-marker.utf8.count)
        while count > 0,bytes[count] & 0xc0 == 0x80 {count -= 1}
        return String(decoding:bytes.prefix(count),as:UTF8.self)+String(decoding:marker.utf8.prefix(limit-count),as:UTF8.self)
    }
    private func completeOutput(succeeded:Bool,error:Error?=nil,startedAt:TimeInterval) {
        guard !invalidated,!commandFinished else{return}
        let receipt=commandReceipt.read(),killed=error as? GitCommandCancellationFailure
        let succeeded=receipt?.success ?? succeeded
        let wasCancelled=receipt?.cancelled ?? (cancellation.isCancelled || killed != nil || error is OperationCancellationFailure || error is CancellationError)
        let code=receipt == nil ? killed?.result.exitCode ?? (error as? GitFailure)?.code:receipt?.exitCode
        let completion=SubmoduleProgressCompletion(success:succeeded,cancelled:wasCancelled && code == nil,exitCode:code,
            elapsed:receipt?.elapsed ?? (ProcessInfo.processInfo.systemUptime-startedAt),finished:receipt?.finished ?? Date(),preferences:preferences)
        output=bounded(output,bytes:outputLimit-completion.text.utf8.count)
        completionRange=completion.append(to:&output);currentWork=completion.currentWork;percentage=100
        commandSucceeded=succeeded;commandFinished=true;cancelled=wasCancelled;OperationSounds.report(failed:!succeeded,preferences:preferences)
    }
    private func appendDiagnostic(_ text:String) {
        guard !text.isEmpty else{return}
        guard let range=completionRange else{output=GitProgressFailureOutput.renderDetails(text,existing:output,limit:outputLimit);return}
        let previous=output as NSString
        guard NSMaxRange(range) <= previous.length else{return}
        let footer=previous.substring(with:range)
        let suffix=GitProgressFailureOutput.renderDetails(text,existing:previous.substring(from:NSMaxRange(range)),limit:max(256,outputLimit-footer.utf8.count))
        let prefix=bounded(previous.substring(to:range.location),bytes:outputLimit-footer.utf8.count-suffix.utf8.count)
        output=prefix+footer+suffix;completionRange=NSRange(location:(prefix as NSString).length,length:(footer as NSString).length)
    }
    private func finishAutomaticClose() { if !busy,!hasPendingWork,!confirmingQuit, !confirmingCancellation, !invalidated, abandoned || warnings.isEmpty && autoClosePolicy.shouldClose(success: success, postActionCount: postActions.count) { close() } }
    func cancel() {
        guard canCancel, !invalidated else { return }; let token = cancellation,generation=interactionGeneration
        if preferences.bool(forKey: "ConfirmKillProcess") {
            confirmingCancellation = true; var answered = false
            confirmCancellation { [weak self] accepted in
                guard !answered, let self, !self.invalidated, self.cancellation === token else { return }; answered = true; self.confirmingCancellation = false
                if self.busy && !self.commandFinished && accepted && !self.confirmingQuit && self.interactionGeneration == generation { self.cancelling = true; token.cancel() }
                self.finishAutomaticClose()
            }
        } else { cancelling = true; token.cancel() }
    }
    func perform(_ action: ClonePostAction) {
        guard !busy,!hasPendingWork,!confirmingQuit,presentationAvailable(), !confirmingCancellation, !invalidated, !dispatched, postActions.contains(action) else { return }
        if action == .inspect {retryInspection();return}
        if action == .retry {
            ProgressActionLog.nextAttempt(self);
            cancellation=OperationCancellation();resetAttempt();beginWork()
            Task { await execute() }; return
        }
        guard let target=repository ?? (action == .explore && commandCompleted ? GitRepository(root:destination,executable:executable):nil),let onPostAction else {return}
        dispatched=true;let generation=interactionGeneration
        let dispatch={ [self] in guard !confirmingQuit,interactionGeneration == generation else{return};onPostAction(action,target)}
        if let finishAndPerform {finishAndPerform(dispatch)}else{close();dispatch()}
    }
}
@MainActor final class CloneProgressWindowController: NSWindowController, NSWindowDelegate {
    let model: CloneProgressWindowModel
    static var activeReleases:Int {CloneChildRelease.activeCount}
    var onClosed:()->Void = {}
    var onClosing:(NSWindow)->Void = {_ in}
    private var closed=false,retiring=false,finishing=false,closingForHandoff=false
    var presentationClosed:Bool {closed}
    private var pendingAction:(()->Void)?
    private var presentationParent:NSWindow?
    private var release:CloneChildRelease?
    private var cancellationRelease:CloneChildRelease?
    private(set) var cancellationAlert:NSAlert?
    var questionWindow:NSWindow? {cancellationAlert?.window}
    var presentCancellation:((NSAlert,NSWindow,@escaping(NSApplication.ModalResponse)->Void)->Void)?
    private var cancellationAnswer:((NSApplication.ModalResponse)->Void)?
    init(model: CloneProgressWindowModel) {
        self.model = model
        let window = NSWindow(contentRect: NSRect(x:0,y:0,width:760,height:430), styleMask: [.titled,.closable,.resizable], backing:.buffered, defer:false)
        window.title = "Clone – TurtleGit"; window.contentMinSize = NSSize(width:600,height:320); window.isReleasedWhenClosed = false
        window.contentViewController = NSHostingController(rootView:CloneProgressDialog(model:model)); super.init(window:window); window.delegate = self
        model.close = { [weak self] in self?.finishResult({}) }
        model.finishAndPerform = { [weak self] action in self?.finishResult(action) }
        model.workDidDrain = { [weak self] in guard let self,self.finishing else{return};self.closeIfReady() }
        model.presentationAvailable = { [weak self] in guard let self else{return false};return !self.closed && !self.retiring && !self.finishing && self.cancellationAlert == nil && self.window?.attachedSheet == nil }
        model.confirmCancellation = { [weak self] choose in
            guard let self,!self.closed,!self.retiring,self.model.active,!self.model.confirmingQuit,self.cancellationAlert == nil,let window=self.window,window.attachedSheet == nil else { choose(false); return }
            let alert = NSAlert(); alert.alertStyle = .informational; alert.messageText = "The process is still running."; alert.informativeText = "Are you sure to abort?"
            let yes=alert.addButton(withTitle:"Yes"),no=alert.addButton(withTitle:"No")
            alert.layout();yes.keyEquivalent="\r";no.keyEquivalent="\u{1b}";alert.window.defaultButtonCell=yes.cell as? NSButtonCell
            alert.window.appearance=window.effectiveAppearance;alert.window.alphaValue=window.alphaValue
            self.cancellationAlert=alert;var answered=false
            let answer:(NSApplication.ModalResponse)->Void = { [weak self] response in
                guard !answered,let self,self.cancellationAlert === alert else{return};answered=true
                let release=CloneChildRelease(window:alert.window,parent:window,closeWindow:true) { [self] in
                    let accepted = !self.retiring && !self.closed && self.model.active && !self.model.confirmingQuit && self.cancellationAlert === alert
                    self.cancellationAlert=nil;self.cancellationAnswer=nil;self.cancellationRelease=nil
                    choose(accepted && response == .alertFirstButtonReturn)
                    if self.finishing {self.closeIfReady()}
                }
                self.cancellationRelease=release;release.start()
            }
            self.cancellationAnswer=answer
            if let presentCancellation=self.presentCancellation {presentCancellation(alert,window,answer)}
            else {alert.beginSheetModal(for:window,completionHandler:answer)}
        }

        DialogGeometry.attach(window, identifier: "ProgressDlg")
    }
    private func finishResult(_ action:@escaping()->Void) {
        guard !closed,!retiring,!finishing,model.active,!model.confirmingQuit else{return}
        finishing=true;pendingAction=action;closeIfReady()
    }
    private func closeIfReady() {
        guard !closed,!retiring,finishing,model.active,!model.confirmingQuit,!model.busy,!model.hasPendingWork,!model.confirmingCancellation,cancellationAlert == nil,let window,window.attachedSheet == nil else{return}
        presentationParent=window.sheetParent;closingForHandoff=true;window.close()
        if !retiring,!window.isVisible {retireClosedWindow()}
    }
    func windowShouldClose(_ sender:NSWindow)->Bool {
        guard !model.confirmingQuit,!finishing,!retiring else{return false}
        if model.busy {model.cancel();return false}
        guard !model.hasPendingWork,!model.confirmingCancellation,cancellationAlert == nil,sender.attachedSheet == nil else{return false}
        finishResult({});return false
    }
    private func retireClosedWindow() {
        guard !closed,!retiring else{return};retiring=true
        if let window {model.handoffPresentation=MergeWindowPresentation(window);onClosing(window)}
        model.invalidate();model.finishAndPerform=nil;model.workDidDrain=nil;model.close={}
        cancellationAnswer?(.abort)
        let action=closingForHandoff ? pendingAction:nil;pendingAction=nil
        guard let window else{closed=true;model.saveActionLog();onClosed();action?();return}
        if let sheet=window.attachedSheet,sheet !== questionWindow {window.endSheet(sheet,returnCode:.abort);sheet.close()}
        let release=CloneChildRelease(window:window,parent:presentationParent ?? window.sheetParent,ready:{ [self] in !model.hasPendingWork && cancellationAlert == nil}) { [self] in
            self.release=nil;closed=true;model.saveActionLog();onClosed();action?()
        }
        self.release=release;release.start()
    }
    func windowWillClose(_ notification:Notification){guard notification.object as? NSWindow === window else{return};retireClosedWindow()}
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
}
struct CloneProgressDialog: View {
    @ObservedObject var model: CloneProgressWindowModel
    var body: some View {
        VStack(alignment:.leading,spacing:12) {
            Text("Clone to \(model.destination.path)").font(.headline).textSelection(.enabled)
            SubmoduleProgressOutputView(text:model.output,completed:model.commandFinished,completionRange:model.completionRange,success:model.commandSucceeded,preferences:model.outputPreferences,clipboard:model.outputClipboard).frame(maxWidth:.infinity,maxHeight:.infinity)
            ForEach(Array(model.warnings.enumerated()),id:\.offset) { _,warning in Label(warning,systemImage:"exclamationmark.triangle.fill").foregroundStyle(.orange).textSelection(.enabled) }
            if model.commandFinished {ProgressView(value:100,total:100).tint(model.commandSucceeded ? Color.accentColor:Color.red)}
            else {GitCommandProgressBar(percentage:model.percentage,animate:model.progressPresentation.animateActivity)}
            if !model.currentWork.isEmpty { Text(model.currentWork).font(.caption).lineLimit(2) }
            HStack {Text(model.statusText).foregroundStyle(model.busy ? Color.primary : model.success ? model.warnings.isEmpty ? Color.green:Color.orange : model.commandCompleted ? Color.orange:Color.red); Spacer() }
            HStack { if let first = model.postActions.first { Button { model.perform(first) } label: { CommandLabel(title:first.title,icon:first.icon) }; Menu { ForEach(model.postActions,id:\.self) { action in Button { model.perform(action) } label: { CommandLabel(title:action.title,icon:action.icon) } } } label: { Image(systemName:"chevron.down").accessibilityLabel("Clone post-actions") }.menuStyle(.borderlessButton).fixedSize() }; Spacer()
                if model.busy { Button(model.cancelling ? "Cancelling…" : "Cancel") { model.cancel() }.keyboardShortcut(.cancelAction).disabled(!model.canCancel) }
                else { Button("Close") { model.close() }.keyboardShortcut(.defaultAction) }
            }.disabled(model.confirmingCancellation || model.confirmingQuit || !model.busy && model.hasPendingWork || !model.presentationAvailable())
        }.padding(12)
        .gitDockProgress(.command(busy:model.busy && !model.commandFinished,success:model.commandSucceeded,waiting:model.confirmingCancellation,percentage:model.percentage))
    }
}

@MainActor final class CloneChildRelease {
    static private(set) var activeCount=0
    private let window:NSWindow,parent:NSWindow?
    private let closeWindow:Bool
    private let ready:()->Bool
    private var completion:()->Void
    private var observer:NSObjectProtocol?
    private var waiter:Task<Void,Never>?
    private var started=false,finished=false
    init(window:NSWindow,parent:NSWindow?,closeWindow:Bool=false,ready:@escaping()->Bool={true},completion:@escaping()->Void){self.window=window;self.parent=parent;self.closeWindow=closeWindow;self.ready=ready;self.completion=completion}
    func start(){
        guard !started else{return};started=true;Self.activeCount += 1
        if window.sheetParent != nil || parent?.attachedSheet === window {
            observer=NotificationCenter.default.addObserver(forName:NSWindow.didEndSheetNotification,object:parent,queue:.main){ [self] _ in DispatchQueue.main.async {self.drain()} }
            (window.sheetParent ?? parent)?.endSheet(window);window.orderOut(nil)
        }
        drain()
        if !finished {waiter=Task { @MainActor [self] in while !finished {try? await Task.sleep(nanoseconds:5_000_000);drain()}}}
    }
    private func drain(){
        guard !finished,window.attachedSheet == nil,window.sheetParent == nil,parent?.attachedSheet !== window,ready() else{return};finished=true
        waiter?.cancel();waiter=nil;if let observer {NotificationCenter.default.removeObserver(observer);self.observer=nil}
        Self.activeCount -= 1;if closeWindow {window.close()};let done=completion;completion={};done()
    }
}
