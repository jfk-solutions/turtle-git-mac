import AppKit
import SwiftUI
import Combine
import UniformTypeIdentifiers
import TurtleGitCore

@MainActor final class BlameWindowController: NSWindowController, NSWindowDelegate {
    private(set) var model: BlameWindowModel
    var onClosed: () -> Void = {}
    private(set) var goToWindow: BlameGoToLineWindowController?
    var commandKeyWindow: () -> NSWindow? = { NSApp.keyWindow }
    private var focusGeneration = 0
    private(set) var findWindow: BlameFindWindowController?
    private(set) var findAlert:NSAlert?
    private var feedbackGeneration=0
    private(set) var columnAlert:NSAlert?
    private var columnResetReply:((NSApplication.ModalResponse)->Void)?
    private var columnResetRelease:Task<Void,Never>?
    private var closing=false
    var presentHistoryColumnReset:(NSWindow,NSAlert,@escaping(NSApplication.ModalResponse)->Void)->Void={window,alert,reply in alert.beginSheetModal(for:window,completionHandler:reply)}
    private(set) var historyUnifiedWindows:[UUID:PatchWindowController]=[:]
    private var historyUnifiedObservations:[UUID:AnyCancellable]=[:]
    private(set) var containingReferences:[UUID:CommitContainingReferencesWindowController]=[:]
    var configureContainingReferences:(CommitContainingReferencesWindowController)->Void = { _ in }
    private let preferences:UserDefaults
    private var floatingPanes:[BlamePane:BlameFloatingPaneController]=[:]
    func floatingPaneWindow(_ pane:BlamePane)->NSWindow? { floatingPanes[pane]?.window }
    let recentDocuments:BlameRecentDocuments?
    private let documentOpener:BlameDocumentOpener
    private(set) var openPanel:NSOpenPanel?
    private var openingGeneration=0
    private var recentID:UUID?
    var onDocumentChanged:()->Void={}
    var chooseFile:(NSOpenPanel,NSWindow,@escaping (URL?)->Void)->Void = { panel,owner,reply in panel.beginSheetModal(for:owner) { reply($0 == .OK ? panel.url : nil) } }
    var chooseScope:(NSOpenPanel,NSWindow,@escaping (URL?)->Void)->Void = { panel,owner,reply in panel.beginSheetModal(for:owner) { reply($0 == .OK ? panel.url : nil) } }

    init(repository: GitRepository, access: RepositoryAccessLease?, path: String, revision: String, options: GitBlameOptions = GitBlamePreferences.load(), preferences: UserDefaults = .standard, regexExecutable:URL? = nil, recentDocuments:BlameRecentDocuments? = nil, requireScope:Bool = GitRuntime.isAppStoreBuild, provider:any RepositoryBookmarkProvider = SystemRepositoryBookmarkProvider(),gravatar:LogGravatar? = nil) {
        self.preferences=preferences;self.recentDocuments=recentDocuments
        documentOpener=BlameDocumentOpener(requireScope:requireScope,provider:provider,factory:{ GitRepository(root:$0,executable:repository.executable) });self.requireScope=requireScope;self.scopeProvider=provider
        model = BlameWindowModel(repository: repository, access: access, path: path, revision: revision, options:options,labelDefaults:preferences,historyRegexExecutable:regexExecutable,gravatar:gravatar)
        let window = BlameCommandWindow(contentRect: NSRect(x: 0, y: 0, width: 1120, height: 700), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "\(path) at \(revision.prefix(7)) – Blame – TurtleGit"
        window.minSize = NSSize(width: 820, height: 400); window.isReleasedWhenClosed = false
        window.acceptsMouseMovedEvents = true
        window.contentViewController = NSHostingController(rootView: BlameDialog(model: model))
        super.init(window: window); window.delegate = self; TurtleGitHelp.attach(window, topic: .blame); window.setContentSize(NSSize(width: 1120, height: 700)); window.center(); model.onGoTo = { [weak self] in self?.showGoToLine() }; model.onFind = { [weak self] in self?.showFind() }; model.onFindFeedback = { [weak self] in self?.feedback($0) };model.onOpenDocument={ [weak self] in self?.openDocument() };model.onCancelDocumentOpen={ [weak self] in self?.cancelOpenDocument() };model.onOpenRecent={ [weak self] in self?.openRecent($0) };model.recentDocuments=recentDocuments;model.onLoaded={ [weak self] in
            guard let self,revision=="HEAD",let recentDocuments=self.recentDocuments else { return }
            let lease=self.model.repositoryAccess ?? RepositoryAccessLease(url:self.model.repository.root,provider:self.scopeProvider)
            do { try recentDocuments.remember(root:self.model.repository.root,path:self.model.path,lease:lease) } catch { self.model.error=error.localizedDescription }
        };model.reload()

        configureHistoryActions()
        configurePaneLayout()
        applyWindowAppearance()
        DialogGeometry.attach(window, identifier: "BlameWindowController")
    }
    private let requireScope:Bool
    private let scopeProvider:any RepositoryBookmarkProvider
    func openDocument() {
        guard model.canFind,!model.openingDocument,!hasBlockingHistoryChild,let window,window.attachedSheet==nil else { return }
        let panel=NSOpenPanel();panel.canChooseFiles=true;panel.canChooseDirectories=false;panel.allowsMultipleSelection=false;panel.resolvesAliases=false;panel.prompt="Blame File"
        panel.directoryURL=model.repository.root;panel.appearance=window.appearance
        recentID=nil;openPanel=panel;model.openingDocument=true;openingGeneration += 1;let identity=openingGeneration
        chooseFile(panel,window) { [weak self] file in
            guard let self,self.openingGeneration==identity,!self.model.retired,self.openPanel===panel else { return };self.openPanel=nil
            guard let file else { self.model.openingDocument=false;return }
            self.authorizeAndOpen(file)
        }
    }
    func cancelOpenDocument() {
        guard model.openingDocument,!model.cancellingDocument else { return }
        let old=model;old.cancellingDocument=true;openingGeneration += 1;documentOpener.cancel()
        if let panel=openPanel { panel.sheetParent?.endSheet(panel,returnCode:.cancel);panel.close();openPanel=nil }
        Task {
            while documentOpener.isReading { try? await Task.sleep(nanoseconds:10_000_000) }
            guard !old.retired,model===old else { return };old.openingDocument=false;old.cancellingDocument=false
        }
    }
    private func authorizeAndOpen(_ file:URL) {
        if let access=model.repositoryAccess,access.contains(file.standardizedFileURL.deletingLastPathComponent()),(!requireScope || access.hasSecurityScope) { prepare(file,scope:access);return }
        guard requireScope else { prepare(file,scope:nil);return }
        guard let window else { model.openingDocument=false;return }
        let panel=NSOpenPanel();panel.canChooseDirectories=true;panel.canChooseFiles=false;panel.allowsMultipleSelection=false;panel.prompt="Allow Repository"
        panel.message="Allow access to the repository root containing this file.";panel.directoryURL=file.deletingLastPathComponent()
        panel.appearance=window.appearance;openPanel=panel;let identity=openingGeneration
        chooseScope(panel,window) { [weak self] folder in
            guard let self,self.openingGeneration==identity,!self.model.retired,self.openPanel===panel else { return };self.openPanel=nil
            guard let folder else { self.model.openingDocument=false;return }
            self.prepare(file,scope:RepositoryAccessLease(url:folder,provider:self.scopeProvider))
        }
    }
    func openRecent(_ entry:BlameRecentDocument) {
        guard model.canFind,!model.openingDocument,!hasBlockingHistoryChild,let recentDocuments else { return }
        recentID=entry.id;model.openingDocument=true;openingGeneration += 1
        do { let (_,file,lease)=try recentDocuments.acquire(entry,requireScope:requireScope);prepare(file,scope:lease) }
        catch { model.openingDocument=false;model.error=error.localizedDescription }
    }
    private func prepare(_ file:URL,scope:RepositoryAccessLease?) {
        let old=model,identity=openingGeneration,options=GitBlamePreferences.load(from:preferences)
        Task {
            do {
                let document=try await documentOpener.prepare(file:file,scope:scope,options:options,regexExecutable:old.historyRegexExecutable)
                guard openingGeneration==identity,!old.retired else { return }
                cancelGoToLine();focusGeneration += 1
                old.retireSourceView?();old.onFind=nil;old.onFindFeedback=nil;old.retire()
                let replacement=BlameWindowModel(repository:document.repository,access:document.access,path:document.snapshot.path,revision:"HEAD",options:document.options,labelDefaults:preferences,historyRegexExecutable:old.historyRegexExecutable)
                replacement.install(document.snapshot,history:document.history,options:document.options,details:document.details);replacement.recentHistoryError=old.recentHistoryError
                retireFloatingPanes();model=replacement;replacement.onGoTo={ [weak self] in self?.showGoToLine() };replacement.onFind={ [weak self] in self?.showFind() };replacement.onFindFeedback={ [weak self] in self?.feedback($0) };replacement.onOpenDocument={ [weak self] in self?.openDocument() };replacement.onCancelDocumentOpen={ [weak self] in self?.cancelOpenDocument() };replacement.onOpenRecent={ [weak self] in self?.openRecent($0) };replacement.recentDocuments=recentDocuments
                window?.contentViewController=NSHostingController(rootView:BlameDialog(model:replacement))
                Array(containingReferences.values).forEach { $0.close() };containingReferences=[:]
                Array(historyUnifiedWindows.values).forEach { $0.close() };historyUnifiedWindows=[:];historyUnifiedObservations=[:]
                configureHistoryActions();configurePaneLayout();findWindow?.rebind(replacement);applyWindowAppearance()
                NotificationCenter.default.post(name:NSNotification.Name("TurtleGit.BlameDocumentChanged"),object:window)
                window?.title="\(document.snapshot.path) at HEAD – Blame – TurtleGit";replacement.goToLine(1)
                do { try recentDocuments?.remember(root:document.repository.root,path:document.snapshot.path,lease:document.access,replacing:recentID) }
                catch { replacement.error="Opened file; recent-file access could not be saved: "+error.localizedDescription }
                onDocumentChanged()
            } catch {
                guard openingGeneration==identity,!old.retired else { return };old.openingDocument=false
                if !(error is OperationCancellationFailure) { old.error=error.localizedDescription }
            }
        }
    }
    var hasBlockingHistoryChild:Bool { containingReferences.values.contains { $0.hasBlockingChild } || historyUnifiedWindows.values.contains { $0.model.busy || $0.window?.attachedSheet != nil } }
    private func refreshHistoryChildBlocking() {
        let blocked = hasBlockingHistoryChild
        if model.historyChildBlocked != blocked { model.historyChildBlocked = blocked }
    }
    @objc private func historyChildSheetChanged(_ notification: Notification) {
        guard let changed = notification.object as? NSWindow, historyUnifiedWindows.values.contains(where: { $0.window === changed }) else { return }
        DispatchQueue.main.async { [weak self] in self?.refreshHistoryChildBlocking() }
    }
    private func configureHistoryActions() {
        let current = model
        model.presentationCommandsAvailable = { [weak self, weak current] in
            guard let self, let current, self.model === current else { return false }
            return self.commandsAvailable && NSApp.modalWindow == nil
        }
        model.copyWindowAvailable = { [weak self, weak current] candidate in
            guard let self, let current, self.model === current, let candidate else { return false }
            return self.commandsAvailable && self.commandKeyWindow() === candidate && NSApp.modalWindow == nil
        }
        NotificationCenter.default.removeObserver(self, name: NSWindow.willBeginSheetNotification, object: nil)
        NotificationCenter.default.removeObserver(self, name: NSWindow.didEndSheetNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(historyChildSheetChanged(_:)), name: NSWindow.willBeginSheetNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(historyChildSheetChanged(_:)), name: NSWindow.didEndSheetNotification, object: nil)
        model.onOwnedHistoryUnified={ [weak self] bytes,title,alternate,token in
            guard let self,self.model.canFind,!token.isCancelled else { return };let original=self.model
            if try await !UnifiedDiffApplication.openExternal(bytes,alternate:alternate,preferences:self.preferences,title:title,permissions:original.repositoryAccess.map { [$0] } ?? [],cancellation:token) {
                guard self.model===original,original.canFind,!token.isCancelled else { return };let id=UUID()
                let prepared=PatchWindowController(repository:original.repository,access:original.repositoryAccess,preferences:self.preferences)
                prepared.window?.alphaValue=self.window?.alphaValue ?? 1;prepared.window?.appearance=self.window?.appearance
                let child=UnifiedDiffApplication.presentBuiltin(bytes,repository:original.repository,access:original.repositoryAccess,existing:prepared,title:title,preferences:self.preferences,onClosed:{ [weak self] in self?.historyUnifiedWindows.removeValue(forKey:id);self?.historyUnifiedObservations.removeValue(forKey:id);self?.refreshHistoryChildBlocking() })
                self.historyUnifiedWindows[id]=child
                self.historyUnifiedObservations[id]=child.model.objectWillChange.sink { [weak self] _ in DispatchQueue.main.async { self?.refreshHistoryChildBlocking() } }
                self.refreshHistoryChildBlocking()
            }
        }

        model.confirmHistoryReset={ [weak self,weak current] in
            guard let self,let current,self.model === current,!self.closing,let window=self.window,window.attachedSheet==nil,!current.retired else{return false}
            let alert=NSAlert();alert.messageText="Reset Blame Log columns?";alert.informativeText="Restore the default columns, order and widths?";alert.addButton(withTitle:"No");alert.addButton(withTitle:"Yes")
            alert.window.alphaValue=window.alphaValue;alert.window.appearance=window.appearance;self.columnAlert=alert
            return await withCheckedContinuation {continuation in
                var answered=false
                let reply:(NSApplication.ModalResponse)->Void={ [weak self,weak current] response in
                    guard !answered else{return};answered=true
                    self?.columnResetReply=nil
                    Task { @MainActor in
                        while alert.window.sheetParent != nil {try? await Task.sleep(nanoseconds:10_000_000)}
                        let accepted=self?.closing==false && self?.model === current && current?.retired==false && current?.confirmingQuit==false && response == .alertSecondButtonReturn
                        if self?.columnAlert === alert {self?.columnAlert=nil}
                        continuation.resume(returning:accepted)
                    }
                }
                self.columnResetReply=reply;self.presentHistoryColumnReset(window,alert,reply)
            }
        }
        model.onContainingReferences={ [weak self] hash in
            guard let self,self.model.canFind,let parent=self.window,parent.attachedSheet==nil else { return }
            let id=UUID(),child=CommitContainingReferencesWindowController(repository:self.model.repository,access:self.model.repositoryAccess,revision:hash,preferences:self.preferences)
            self.configureContainingReferences(child)
            child.externalAvailability={ [weak self,weak child] in guard let self,let child else { return false };return self.model.canFindIgnoringHistoryChild && !self.historyUnifiedWindows.values.contains { $0.model.busy || $0.window?.attachedSheet != nil } && !self.containingReferences.values.contains { $0 !== child && $0.hasBlockingChild } }
            child.blockingStateChanged={ [weak self] in self?.refreshHistoryChildBlocking() }
            child.onClosed={ [weak self,weak child,weak parent] in if let window=child?.window { parent?.removeChildWindow(window) };self?.containingReferences.removeValue(forKey:id);self?.refreshHistoryChildBlocking() }
            self.containingReferences[id]=child
            if let window=child.window { window.alphaValue=parent.alphaValue;window.appearance=parent.appearance;parent.addChildWindow(window,ordered:.above);window.center();window.orderFront(nil) };child.refresh()
        }
    }
    override func showWindow(_ sender:Any?) { super.showWindow(sender);refreshPaneLayout() }
    private func configurePaneLayout() {
        let current=model
        model.onPaneLayoutChanged={ [weak self,weak current] in
            guard let self,let current,self.model === current,!current.retired else { return }
            self.refreshPaneLayout()
        }
        model.onPaneFloatRequested={ [weak self,weak current] pane,point in
            guard let self,let current,self.model === current,!current.retired else { return }
            self.floatingPanes[pane]?.position(at:point)
        }
        refreshPaneLayout()
    }
    func refreshPaneLayout() {
        guard !model.retired,let window else { return }
        let vertical=BlamePane.allCases.filter { model.paneVisible($0) && !model.paneAutoHidden($0) && [.top,.bottom].contains(model.paneLayout.placement($0)) }.count
        window.minSize=NSSize(width:820,height:vertical>1 ? 520 : 400)
        for pane in BlamePane.allCases {
            if model.paneVisible(pane),model.paneLayout.placement(pane) == .floating {
                guard window.isVisible else { continue }
                if floatingPanes[pane] == nil { floatingPanes[pane]=BlameFloatingPaneController(owner:self,pane:pane,preferences:preferences) }
                floatingPanes[pane]?.window?.appearance=window.appearance
                floatingPanes[pane]?.window?.order(.above,relativeTo:window.windowNumber)
            } else if let child=floatingPanes.removeValue(forKey:pane) { child.retire() }
        }
    }
    fileprivate func floatingPaneClosed(_ pane:BlamePane) {
        floatingPanes.removeValue(forKey:pane)
        model.setPaneVisible(pane,false)
    }
    private func retireFloatingPanes() {
        let children=Array(floatingPanes.values);floatingPanes=[:]
        children.forEach { $0.retire() }
    }
    func windowDidBecomeKey(_ notification:Notification) { refreshPaneLayout() }
    private func applyWindowAppearance() {
        window?.appearance=model.darkOverride.map { NSAppearance(named:$0 ? .darkAqua : .aqua)! }
        findWindow?.window?.appearance=window?.appearance
        floatingPanes.values.forEach { $0.window?.appearance=window?.appearance }
        findAlert?.window.appearance=window?.appearance
        historyUnifiedWindows.values.forEach { $0.window?.appearance=window?.appearance }
    }
    func setDarkMode(_ value:Bool) { guard model.canFind else { return };model.setDarkOverride(value);applyWindowAppearance() }
    func followSystemAppearance() { guard model.canFind else { return };model.setDarkOverride(nil);applyWindowAppearance() }
    static func focusedOwner(_ initial:NSWindow?)->BlameWindowController? {
        var candidate=initial,seen=Set<ObjectIdentifier>()
        while let window=candidate,seen.insert(ObjectIdentifier(window)).inserted {
            if let owner=window.delegate as? BlameWindowController { return owner }
            candidate=window.sheetParent ?? window.parent
        }
        return nil
    }
    static func openFocused(_ window:NSWindow?,fallback:()->Void) {
        if let owner=focusedOwner(window) { owner.openDocument() } else { fallback() }
    }
    private func showFind() {
        guard commandsAvailable else { return }
        if let findWindow,findWindow.window?.isVisible==true { findWindow.showWindow(nil);findWindow.window?.makeKeyAndOrderFront(nil);return }
        let selected=model.selectedSourceText?()
        let draft=BlameFindDraft(text:selected?.isEmpty==false ? selected! : model.find,matchCase:model.matchCase)
        let controller=BlameFindWindowController(model:model,draft:draft)
        findWindow=controller;controller.window?.appearance=window?.appearance
        controller.onClosed={ [weak self,weak controller] in
            guard let self,self.findWindow===controller else { return };self.findWindow=nil
        }
        if let window,let panel=controller.window { window.addChildWindow(panel,ordered:.above);panel.center() }
        controller.showWindow(nil);controller.window?.makeKeyAndOrderFront(nil)
    }
    private func feedback(_ result:BlameFindFeedback) {
        switch result {
        case .wrapped:findWindow?.flash()
        case .notFound(let text):
            guard findAlert==nil,let owner=findWindow?.window ?? window,owner.attachedSheet==nil else { return }
            let alert=NSAlert();alert.alertStyle = .informational;alert.messageText="TurtleGit Blame";alert.informativeText="\"\(text)\" was not found.";alert.addButton(withTitle:"OK")
            alert.window.appearance=owner.appearance;findAlert=alert;model.searchFeedbackBusy=true;feedbackGeneration += 1;let identity=feedbackGeneration
            alert.beginSheetModal(for:owner) { [weak self] _ in
                guard let self,self.feedbackGeneration==identity else { return };self.findAlert=nil;self.model.searchFeedbackBusy=false
            }
        }
    }
    func windowShouldClose(_ sender:NSWindow) -> Bool { !model.searchFeedbackBusy && !model.openingDocument && !model.resettingHistoryColumns && !hasBlockingHistoryChild }
    func windowWillClose(_ notification:Notification) {
        guard !closing else{return};closing=true
        let pendingColumnAlert=columnAlert
        cancelGoToLine();focusGeneration += 1
        model.onPaneLayoutChanged={};model.onPaneFloatRequested={_,_ in};retireFloatingPanes()
        feedbackGeneration += 1;openingGeneration += 1;documentOpener.cancel()
        if let alert=columnAlert { alert.window.sheetParent?.endSheet(alert.window,returnCode:.cancel);alert.window.close() };columnResetReply?(.cancel)
        Array(historyUnifiedWindows.values).forEach { $0.close() };historyUnifiedWindows=[:];historyUnifiedObservations=[:]
        Array(containingReferences.values).forEach { $0.close() };containingReferences=[:]
        if let panel=openPanel { panel.sheetParent?.endSheet(panel,returnCode:.cancel);panel.close();openPanel=nil };model.openingDocument=false
        if let alert=findAlert {
            alert.window.sheetParent?.endSheet(alert.window,returnCode:.cancel);alert.window.close();findAlert=nil
        }
        model.searchFeedbackBusy=false
        findWindow?.close();findWindow=nil
        model.retireSourceView?();model.retireSourceView=nil;model.onFind=nil;model.onFindFeedback=nil;model.retire()
        if model.resettingHistoryColumns || pendingColumnAlert?.window.sheetParent != nil {
            columnResetRelease=Task { [self] in
                while model.resettingHistoryColumns || pendingColumnAlert?.window.sheetParent != nil {try? await Task.sleep(nanoseconds:10_000_000)}
                columnResetRelease=nil;onClosed()
            }
        } else {onClosed()}
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
}

enum BlameFindFeedback { case wrapped(line:Int),notFound(text:String) }

@MainActor final class BlameWindowModel: ObservableObject {
    private(set) static var activeSyntaxRequests = 0
    let repository: GitRepository, path: String
    var fullCommitMessageOnLogLine:Bool {labelDefaults.bool(forKey:"FullCommitMessageOnLogLine")}
    private let access: RepositoryAccessLease?
    var repositoryAccess:RepositoryAccessLease? { access }
    let labelDefaults: UserDefaults
    let revisionDetails: BlameRevisionDetails
    let gravatar: LogGravatar
    @Published private(set) var showGravatar = false
    private var avatarIdentity: Data?
    private var avatarHash: String?
    private func refreshRevisionDetails() {
        guard !retired else { return }
        revisionDetails.update(selectedHistoryEntry, history: historyEntries)
        refreshAuthorImage()
    }
    private func refreshAuthorImage(force: Bool = false) {
        let email = !retired && !busy && showLog && showGravatar ? historyEntries.first { $0.hash == avatarHash }?.email : nil
        let identity = email.map { $0 + "\n" + (labelDefaults.string(forKey: "GravatarUrl") ?? LogGravatarRequest.defaultTemplate) + "\n" + String(labelDefaults.bool(forKey: "GravatarUseMD5")) }.map { Data($0.utf8) }
        guard force || avatarIdentity != identity else { return }
        avatarIdentity = identity
        gravatar.clear();if let email { gravatar.load(email: email) }
    }
    func refreshAuthorPreferences() {
        let enabled=labelDefaults.bool(forKey: "EnableGravatar");if showGravatar != enabled {showGravatar=enabled}
        refreshAuthorImage();objectWillChange.send()
    }
    private var attributionDates: [Date: String] = [:]
    private var attributionDateSettings: HistoryDateSettings?
    private var attributionDateTick: Int?
    private var attributionDateEnvironment = ""
    private var dateEnvironmentKey: String { Locale.current.identifier + ":" + TimeZone.current.identifier + ":" + String(TimeZone.current.secondsFromGMT()) }
    var attributionDateKey: String {
        let settings=HistoryDateSettings.load(defaults:labelDefaults)
        return "\(settings.shortDate):\(settings.relative):\(settings.useSystemLocale):" + dateEnvironmentKey + ":" + (settings.relative ? String(Int(Date().timeIntervalSince1970)) : "absolute")
    }
    func attributionDate(_ date: Date, now: Date = Date()) -> String {
        let settings = HistoryDateSettings.load(defaults: labelDefaults)
        let tick = settings.relative ? Int(now.timeIntervalSince1970) : nil
        let environment=dateEnvironmentKey
        if attributionDateSettings != settings || attributionDateTick != tick || attributionDateEnvironment != environment {
            attributionDates = [:]; attributionDateSettings = settings; attributionDateTick = tick; attributionDateEnvironment=environment
        }
        if let cached = attributionDates[date] { return cached }
        let value = settings.format(ISO8601DateFormatter().string(from: date),now:now)
        attributionDates[date] = value; return value
    }
    @Published private(set) var syntaxEnabled = true
    @Published private(set) var wrapLongLines = false
    func setWrapLongLines(_ value: Bool) { guard !busy else { return }; wrapLongLines = value; labelDefaults.set(value,forKey:"Blame.WrapLongLines") }
    @Published var syntaxWorking = false
    @Published var syntaxError: String?
    var syntaxExecutable: URL? = BlameSyntax.executable()
    var syntaxOperation: (String,String,Int,URL?,OperationCancellation) async throws -> BlameSyntaxResult = { text,path,tabs,helper,token in
        try await Task.detached(priority:.userInitiated) {
            try BlameSyntax.highlight(text,filename:path,tabSize:tabs,executable:helper,cancellation:token)
        }.value
    }
    func setSyntaxEnabled(_ value: Bool) { guard !busy else { return }; syntaxEnabled = value; labelDefaults.set(value,forKey:"Blame.EnableLexer") }
    static func syntaxStarted() { activeSyntaxRequests += 1 }
    static func syntaxFinished() { activeSyntaxRequests -= 1 }
    @Published private(set) var marginFields = Set<BlameMarginField>()
    func setMargin(_ field: BlameMarginField, visible: Bool) {
        guard !busy else { return }
        if visible { marginFields.insert(field) } else { marginFields.remove(field) }
        labelDefaults.set(visible, forKey:"Blame." + field.rawValue)
    }
    func marginText(_ id: String, row: Int) -> String {
        guard lines.indices.contains(row) else { return "" }; let line = lines[row]
        let repeated = row > 0 && lines[row - 1].hash == line.hash
        switch id {
        case "revision":
            if repeated { return "" }
            if marginFields.contains(.logID) { return ranks[line.hash].map { String(historyCount - $0) } ?? "0" }
            return String(line.hash.prefix(8))
        case "author": return repeated ? "" : line.author
        case "date": return repeated ? "" : attributionDate(line.date)
        case "filename": return repeated && lines[row - 1].filename == line.filename ? "" : line.filename
        case "original": return String(line.originalLine)
        default: return String(line.number)
        }
    }
    private var revision: String
    private var generation = 0
    private var pendingLine: Int?
    private var clipboardGeneration = 0
    let historyRegexExecutable:URL?
    private var loadCancellation:OperationCancellation?
    @Published private(set) var cancellingReload=false
    @Published private(set) var issueProperties=IssueTrackerProperties()
    @Published private(set) var hasGitSVN=false
    @Published private(set) var svnRevisions:[String:String]=[:]
    func cancelReload() { guard let loadCancellation,!cancellingReload else { return };cancellingReload=true;loadCancellation.cancel() }

    private var historyClipboardCancellation:OperationCancellation?
    private(set) static var activeHistoryOperations=0
    @Published var historyContextMenuPolicy = HistoryContextMenuPolicy.blame {
        didSet { if historyContextMenuPolicy != oldValue { historyMenuGeneration = UUID(); historyParentToken?.cancel(); cancelHistoryComparisons() } }
    }
    private var historyMenuGeneration = UUID()
    private(set) var historyHasWorkingTree = false
    private(set) var historyHead:String?
    private(set) var historyReferencesByHash:[String:[RevisionReference]]=[:]
    private(set) var historyCurrentBranch:String?
    private(set) var historyReferenceContext=HistoryReferenceContext()
    private(set) var historyControlEpoch=UUID()
    @Published private(set) var historyColumns:BlameHistoryColumns {didSet {historyControlEpoch=UUID()}}
    @Published private(set) var resettingHistoryColumns=false { didSet { if resettingHistoryColumns { cancelHistoryComparisons() } } }
    var confirmHistoryReset:() async -> Bool = { false }
    var onHistoryExport:((String)->Void)?
    var onHistoryReference:((Bool,String)->Void)?
    var onHistorySwitch:((String)->Void)?
    var onHistoryBrowse:((String)->Void)?
    var onContainingReferences:((String)->Void)?
    var onHistoryUnified:((Data,String,Bool) async throws -> Void)?
    var onOwnedHistoryUnified:((Data,String,Bool,OperationCancellation) async throws -> Void)?
    var onOwnedChanges: (([RevisionComparisonSnapshot], Bool, OperationCancellation) async throws -> Void)?
    var hasHistoryComparisonAction: Bool { onOwnedChanges != nil || onChanges != nil }
    var hasHistoryUnifiedAction:Bool { onHistoryUnified != nil || onOwnedHistoryUnified != nil }
    var readHistoryParents:((GitBlameSnapshot,String,OperationCancellation) async throws -> [GitBlameParentComparison])?
    var readSourceParents:((String,String,OperationCancellation) async throws -> [GitBlameParentComparison])?
    var readHistoryPatch:((RevisionComparisonSnapshot,OperationCancellation) async throws -> Data)?
    private var historyParentCache:[String:[GitBlameParentComparison]]=[:]
    private var historyParentBackendIdentity:NativeDiffBackendIdentity?
    private var historyParentToken:OperationCancellation?
    private var historyParentRequest=UUID()
    private var sourceParentToken:OperationCancellation?
    @Published private(set) var readingHistoryParents=false
    func cachedHistoryParents(_ target:HistoryTarget)->[GitBlameParentComparison] {
        guard acceptsHistory(target),target.entries.count==1,historyParentBackendIdentity == NativeDiffBackendIdentity(repository.capturingDiffBackend(preferences:labelDefaults).libgit2Configuration) else { return [] };return historyParentCache[target.entries[0].hash] ?? []
    }
    private var unifiedReadTokens:[UUID:OperationCancellation]=[:]
    private var comparisonRequestTokens:[UUID:OperationCancellation]=[:]
    var hasPendingHistoryComparisons: Bool { !comparisonRequestTokens.isEmpty }
    private func cancelHistoryComparisons() { comparisonRequestTokens.values.forEach { $0.cancel() } }
    func prepareHistoryParents(_ target:HistoryTarget,completion:@escaping ([GitBlameParentComparison])->Void) {
        let repository=self.repository.capturingDiffBackend(preferences:labelDefaults)
        guard acceptsHistory(target),target.entries.count==1,let snapshot else { completion([]);return }
        let hash=target.entries[0].hash
        let backendIdentity=NativeDiffBackendIdentity(repository.libgit2Configuration)
        if historyParentBackendIdentity != backendIdentity {historyParentCache=[:];historyParentBackendIdentity=backendIdentity}
        historyParentToken?.cancel();historyParentToken=nil;historyParentRequest=UUID();let request=historyParentRequest
        readingHistoryParents=false
        if let choices=historyParentCache[hash] { completion(choices);return }
        let token=OperationCancellation();historyParentToken=token;readingHistoryParents=true;Self.activeHistoryOperations += 1
        Task { [self,access] in
            defer { Self.activeHistoryOperations -= 1;withExtendedLifetime(access) {};if historyParentToken===token { historyParentToken=nil;readingHistoryParents=false } }
            do {
                if GitRuntime.isAppStoreBuild && (access?.hasSecurityScope != true || access?.contains(repository.root) != true) { throw RepositoryAccessFailure.securityScopeUnavailable }
                let choices: [GitBlameParentComparison]
                if let readHistoryParents { choices=try await readHistoryParents(snapshot,hash,token) }
                else { choices=try await repository.blameHistoryParentComparisons(snapshot,revision:hash,cancellation:token) }
                guard request==historyParentRequest,acceptsHistory(target),!token.isCancelled else { return };historyParentCache[hash]=choices;completion(choices)
            } catch { if request==historyParentRequest,acceptsHistory(target),!token.isCancelled { self.error=error.localizedDescription;completion([]) } }
        }
    }
    enum ParentAction { case previous,compare,unified }
    func performHistoryParent(_ target:HistoryTarget,choices:[GitBlameParentComparison],action:ParentAction,alternate:Bool = false,originalLine:Int = 1) {
        let repository=self.repository.capturingDiffBackend(preferences:labelDefaults)
        guard acceptsHistory(target),target.entries.count==1,!choices.isEmpty,
              choices.allSatisfy({ choice in
                  choice.parentNumber>0 && choice.comparison.root==repository.root && choice.comparison.from == .revision(choice.revision) && choice.comparison.to == .revision(target.entries[0].hash) && choice.comparison.files.count==1 && choice.comparison.files.first.map { GitReferenceName.equal(choice.path,$0.oldPath ?? $0.path) } == true
              }) else { return }
        if action == .previous { for choice in choices { guard acceptsHistory(target) else { return };onPrevious?(choice.path,choice.revision,originalLine,appliedOptions) };return }
        if action == .compare {
            guard let onOwnedChanges else {
                // Compatibility for independent consumers of the original
                // synchronous callback; the workspace installs the owned batch.
                ComparisonToolInvocation.$alternate.withValue(alternate) { for choice in choices { guard acceptsHistory(target) else { return };onChanges?(choice.comparison) } }
                return
            }
            let snapshots = choices.map(\.comparison), id = UUID(), token = OperationCancellation()
            comparisonRequestTokens[id] = token; Self.activeHistoryOperations += 1
            Task { [self, access] in
                defer { comparisonRequestTokens.removeValue(forKey: id); Self.activeHistoryOperations -= 1; withExtendedLifetime(access) {} }
                do {
                    guard acceptsHistory(target), !token.isCancelled else { return }
                    if GitRuntime.isAppStoreBuild && (access?.hasSecurityScope != true || access?.contains(repository.root) != true) { throw RepositoryAccessFailure.securityScopeUnavailable }
                    try await onOwnedChanges(snapshots, alternate, token)
                    guard acceptsHistory(target), !token.isCancelled else { return }
                } catch {
                    if acceptsHistory(target), !token.isCancelled { self.error = error.localizedDescription }
                }
            }
            return
        }
        let id=UUID(),token=OperationCancellation();unifiedReadTokens[id]=token;Self.activeHistoryOperations += 1
        Task { [self,access] in
            defer { unifiedReadTokens.removeValue(forKey:id);Self.activeHistoryOperations -= 1;withExtendedLifetime(access) {} }
            do {
                if GitRuntime.isAppStoreBuild && (access?.hasSecurityScope != true || access?.contains(repository.root) != true) { throw RepositoryAccessFailure.securityScopeUnavailable }
                for choice in choices {
                    let bytes:Data
                    if let readHistoryPatch { bytes=try await readHistoryPatch(choice.comparison,token) }
                    else { bytes=try await repository.revisionComparisonPatchData(choice.comparison,paths:choice.comparison.files.map(\.path),cancellation:token) }
                    guard acceptsHistory(target),!token.isCancelled else { return }
                    let title="Parent \(choice.parentNumber) → \(target.entries[0].hash.prefix(8)) — \(choice.path)"
                    if let onHistoryUnified { try await onHistoryUnified(bytes,title,alternate) }
                    else { try await onOwnedHistoryUnified?(bytes,title,alternate,token) }
                }
            } catch { if acceptsHistory(target),!token.isCancelled { self.error=error.localizedDescription } }
        }
    }
    private func cancelHistoryParentReads() {
        cancelHistoryComparisons()
        sourceParentToken?.cancel();sourceParentToken=nil;readingHistoryParents=false
        historyParentRequest=UUID();historyParentToken?.cancel();historyParentToken=nil;unifiedReadTokens.values.forEach { $0.cancel() };historyParentCache=[:]
    }

    func saveHistoryColumns(_ value:BlameHistoryColumns) { guard canFind else { return };historyColumns=value;value.save(labelDefaults) }
    func resetHistoryColumns(layout:BlameHistoryColumns?=nil,available:@escaping()->Bool={true}) {
        guard canFind,available() else { return };let request=generation,epoch=historyControlEpoch;resettingHistoryColumns=true;Self.activeHistoryOperations += 1
        Task { [self] in
            defer { resettingHistoryColumns=false;Self.activeHistoryOperations -= 1 }
            let accepted=await confirmHistoryReset()
            guard !retired,!busy,!confirmingQuit,!openingDocument,!navigationSheetPresented,!searchFeedbackBusy,!historyChildBlocked,request==generation,epoch==historyControlEpoch,available(),accepted else { return };historyColumns=layout ?? BlameHistoryColumns();historyColumns.save(labelDefaults)
        }
    }
    struct SourceTarget {
        let owner:ObjectIdentifier,generation:Int,line:GitBlameLine,selectionText:String
    }
    var presentSourceMenu:((NSMenu,NSPoint,NSView)->Void)?
    func sourceTarget(number:Int,selectionText:String = "") -> SourceTarget? {
        guard canFind,number>0,lines.indices.contains(number-1) else {return nil};let line=lines[number-1]
        return SourceTarget(owner:ObjectIdentifier(self),generation:generation,line:line,selectionText:selectionText)
    }
    func acceptsSource(_ target:SourceTarget) -> Bool {
        guard canFind,target.owner==ObjectIdentifier(self),target.generation==generation,target.line.number>0,
              lines.indices.contains(target.line.number-1) else {return false}
        let line=lines[target.line.number-1]
        return line.hash==target.line.hash && line.originalLine==target.line.originalLine && line.filename.utf8.elementsEqual(target.line.filename.utf8) && line.sourceBytes==target.line.sourceBytes
    }
    struct HistoryTarget { let owner:ObjectIdentifier,generation:Int;let entries:[LogEntry];var sourceOrigin=false;let menuGeneration:UUID }
    func sourceParentTarget(_ hash:String)->HistoryTarget? {
        guard canFind,let line=lines.first(where:{ $0.hash==hash }) else { return nil }
        let entry=tooltipEntries[hash] ?? LogEntry(hash:hash,author:line.author,date:ISO8601DateFormatter().string(from:line.date),subject:line.summary,email:line.email)
        return HistoryTarget(owner:ObjectIdentifier(self),generation:generation,entries:[entry],sourceOrigin:true,menuGeneration:historyMenuGeneration)
    }
    func historyTarget(_ entries:[LogEntry])->HistoryTarget? {
        guard canFind,!entries.isEmpty,entries.allSatisfy({ item in historyEntries.contains { $0.hash==item.hash } }) else { return nil }
        return HistoryTarget(owner:ObjectIdentifier(self),generation:generation,entries:entries,menuGeneration:historyMenuGeneration)
    }
    func acceptsHistory(_ target:HistoryTarget)->Bool { canFind && target.owner==ObjectIdentifier(self) && target.generation==generation && target.menuGeneration==historyMenuGeneration && target.entries.allSatisfy { item in target.sourceOrigin ? lines.contains { $0.hash==item.hash } : historyEntries.contains { $0.hash==item.hash } } }

    @Published var copyingLog = false
    @Published var snapshot: GitBlameSnapshot?
    @Published var busy = false { didSet { if busy != oldValue {historyControlEpoch=UUID();historyMenuGeneration=UUID();if busy {cancelHistoryComparisons()}};refreshAuthorImage() } }
    @Published var error: String?
    @Published var ignoreWhitespace = false
    @Published var onlyFirstParent = false
    @Published var showCompleteLog = true
    @Published var followRenames = false
    @Published var historyEntries: [LogEntry] = [] { didSet {
        historyVersion += 1;historyControlEpoch=UUID()
        tooltipEntries = Dictionary(historyEntries.map { ($0.hash, $0) }, uniquingKeysWith: { first, _ in first });refreshRevisionDetails()
    } }
    private var tooltipEntries: [String: LogEntry] = [:]
    private var tooltipOtherFilenames = false
    private(set) var historyVersion=0
    @Published var selectedLogHashes: Set<String> = [] { didSet {
        if let added = historyEntries.first(where: { selectedLogHashes.contains($0.hash) && !oldValue.contains($0.hash) }) { avatarHash = added.hash }
        else if selectedLogHashes.count == 1 { avatarHash = selectedLogHashes.first }
        refreshRevisionDetails()
    } }
    @Published var showProperties=true { didSet { guard !retired else { return };labelDefaults.set(showProperties,forKey:"Blame.ShowProperties");onPaneLayoutChanged() } }
    @Published var showToolbar=true { didSet { labelDefaults.set(showToolbar,forKey:"Blame.ShowToolbar") } }
    @Published var showLog=true { didSet { guard !retired else { return };labelDefaults.set(showLog,forKey:"Blame.ShowLog");refreshAuthorImage();onPaneLayoutChanged() } }
    @Published private(set) var paneLayout=BlamePaneLayout() { didSet { guard !retired else { return };if let data=try? JSONEncoder().encode(paneLayout) { labelDefaults.set(data,forKey:"Blame.PaneLayout") };onPaneLayoutChanged() } }
    @Published var paneDropPreview:BlamePanePlacement?
    var onPaneLayoutChanged:()->Void={}
    var onPaneFloatRequested:(BlamePane,CGPoint)->Void={_,_ in}
    var panesAreTabbed:Bool { paneLayout.tabbed == true && paneLayout.log == paneLayout.properties && paneLayout.log != .floating }
    func tabPane(_ pane:BlamePane,joined:Bool) {
        guard canFind else { return };var next=paneLayout
        if joined {
            let other:BlamePane=pane == .log ? .properties : .log
            let edge=next.placement(other) == .floating ? next.lastDock(other) : next.placement(other)
            next.place(pane,edge);next.place(other,edge);next.setAutoHidden(pane,false);next.setAutoHidden(other,false)
            showLog=true;showProperties=true;next.activeTab=pane
        }
        next.tabbed=joined;paneLayout=next
    }
    func selectPaneTab(_ pane:BlamePane) {
        guard canFind,panesAreTabbed,paneVisible(pane),paneLayout.activeTab != pane else { return }
        var next=paneLayout;next.activeTab=pane;paneLayout=next
    }
    private let paneDragID=UUID()
    func paneVisible(_ pane:BlamePane)->Bool { pane == .log ? showLog : showProperties }
    func paneAutoHidden(_ pane:BlamePane)->Bool { paneLayout.autoHidden(pane) && paneLayout.placement(pane) != .floating }
    func setPaneVisible(_ pane:BlamePane,_ value:Bool) { guard !retired else { return };if pane == .log { showLog=value } else { showProperties=value } }
    func setPanePlacement(_ pane:BlamePane,_ value:BlamePanePlacement) {
        guard canFind else { return };var next=paneLayout;next.place(pane,value);paneLayout=next
    }
    func togglePaneFloating(_ pane:BlamePane) { setPanePlacement(pane,paneLayout.placement(pane) == .floating ? paneLayout.lastDock(pane) : .floating) }
    func setPaneAutoHidden(_ pane:BlamePane,_ value:Bool) {
        guard canFind,paneLayout.placement(pane) != .floating else { return };var next=paneLayout;next.setAutoHidden(pane,value)
        if panesAreTabbed { next.setAutoHidden(pane == .log ? .properties : .log,value);next.activeTab=pane }
        paneLayout=next
    }
    @Published private(set) var paneLayoutRevision=0
    func restorePaneLayout() {
        guard canFind else { return }
        for edge in BlamePanePlacement.allCases where edge != .floating { labelDefaults.removeObject(forKey:"Blame.Pane.Dock."+edge.rawValue+".Extent") }
        paneLayoutRevision += 1;paneLayout=BlamePaneLayout();showLog=true;showProperties=true
    }
    func paneDragProvider(_ pane:BlamePane)->NSItemProvider {
        let provider=NSItemProvider(),data=paneDragData(pane)
        provider.registerDataRepresentation(forTypeIdentifier:BlamePane.dragType,visibility:.ownProcess) { reply in reply(data,nil);return nil }
        return provider
    }
    @discardableResult func receivePaneDrop(_ providers:[NSItemProvider],placement:BlamePanePlacement)->Bool {
        guard canFind,placement != .floating,providers.count==1,let provider=providers.first,provider.hasItemConformingToTypeIdentifier(BlamePane.dragType) else { return false }
        let identity=paneDragID
        provider.loadDataRepresentation(forTypeIdentifier:BlamePane.dragType) { [weak self] data,_ in
            Task { @MainActor in
                guard let self,self.canFind,self.paneDragID==identity,let data else { return }
                _ = self.applyPaneDropData(data,placement:placement)
            }
        }
        return true
    }
    func paneDragData(_ pane:BlamePane)->Data { Data((paneDragID.uuidString+"\n"+pane.rawValue).utf8) }
    private func draggedPane(_ data:Data)->BlamePane? {
        guard canFind else { return nil }
        let pieces=String(decoding:data,as:UTF8.self).split(separator:"\n")
        guard pieces.count==2,pieces[0]==paneDragID.uuidString,let pane=BlamePane(rawValue:String(pieces[1])),paneVisible(pane) else { return nil }
        return pane
    }
    @discardableResult func applyPaneDropData(_ data:Data,placement:BlamePanePlacement)->Bool {
        guard placement != .floating,let pane=draggedPane(data) else { return false }
        setPanePlacement(pane,placement);return true
    }
    @discardableResult func finishPaneDrag(_ data:Data,at point:CGPoint,outsideWorkspace:Bool,cancelled:Bool,operation:NSDragOperation)->Bool {
        paneDropPreview=nil
        guard operation.isEmpty,!cancelled,outsideWorkspace,point.x.isFinite,point.y.isFinite,let pane=draggedPane(data) else { return false }
        setPanePlacement(pane,.floating);onPaneFloatRequested(pane,point);return true
    }
    @Published var showStatusBar=true { didSet { labelDefaults.set(showStatusBar,forKey:"Blame.ShowStatusBar") } }
    @Published private(set) var darkOverride:Bool?
    func setDarkOverride(_ value:Bool?) { darkOverride=value;if let value { labelDefaults.set(value,forKey:"Blame.DarkMode") } else { labelDefaults.removeObject(forKey:"Blame.DarkMode") } }
    var historyGraph: [CommitGraphRow] { CommitGraph.layout(historyEntries) }
    var showHistoryGraph: Bool { appliedOptions.usesCompleteLog && !appliedOptions.usesFollowRenames }
    var canShowCompleteLog: Bool { !detectionMode.betweenFiles && !onlyFirstParent }
    var selectedHistoryEntry: LogEntry? { selectedLogHashes.count == 1 ? historyEntries.first { selectedLogHashes.contains($0.hash) } : nil }
    @Published var detectionMode = GitBlameDetectionMode.disabled
    @Published var withinFileCharacters = "20"
    @Published var betweenFileCharacters = "40"
    @Published var colorAge=true { didSet { labelDefaults.set(colorAge,forKey:"Blame.ColorAge") } }
    @Published var presentation = GitBlamePresentation.load()
    @Published private(set) var zoom = GitBlameZoom()
    var zoomLevel: Int { zoom.offset }
    var effectiveFontSize: Int { zoom.effectiveFontSize(base: presentation.fontSize) }
    var presentationCommandsAvailable: () -> Bool = { true }
    var copyWindowAvailable: (NSWindow?) -> Bool = { _ in true }
    private var canZoom: Bool { canFind && snapshot != nil && presentationCommandsAvailable() }
    var canZoomIn: Bool { canZoom && zoom.canIncrease }
    var canZoomOut: Bool { canZoom && zoom.canDecrease }
    var canResetZoom: Bool { canZoom && zoomLevel != 0 }
    func zoomIn() { if canZoomIn { zoom = zoom.stepping(1) } }
    func zoomOut() { if canZoomOut { zoom = zoom.stepping(-1) } }
    func resetZoom() { if canResetZoom { zoom = GitBlameZoom() } }
    func revisionToolTip(for row: Int) -> String? {
        guard canFind, lines.indices.contains(row) else { return nil }
        let line = lines[row]
        let filename = tooltipOtherFilenames || appliedOptions.detectionMode.betweenFiles ||
            (appliedOptions.usesCompleteLog && appliedOptions.usesFollowRenames && !appliedOptions.onlyFirstParent)
        return GitBlameTooltip.text(line: line, entry: tooltipEntries[line.hash], showFilename: filename,
                                   dateSettings: .load(defaults: labelDefaults))
    }
    private var cachedSourceFont: (String, Int, NSFont)?
    var sourceFont: NSFont {
        if let cachedSourceFont, cachedSourceFont.0 == presentation.fontName, cachedSourceFont.1 == effectiveFontSize { return cachedSourceFont.2 }
        let font = NSFontManager.shared.font(withFamily: presentation.fontName, traits: [], weight: 5, size: CGFloat(effectiveFontSize)) ?? .monospacedSystemFont(ofSize: CGFloat(effectiveFontSize), weight: .regular)
        cachedSourceFont = (presentation.fontName, effectiveFontSize, font)
        return font
    }
    var sourceLineHeight: CGFloat { max(8,ceil(sourceFont.ascender-sourceFont.descender+sourceFont.leading)+6) }
    func displayedSource(_ line: GitBlameLine) -> NSAttributedString {
        var source = line.source
        while source.hasSuffix("\r") { source.removeLast() }
        if line.number == 1, source.hasPrefix("\u{feff}") { source.removeFirst() }
        let style = NSMutableParagraphStyle(); style.tabStops = []; style.defaultTabInterval = (" " as NSString).size(withAttributes: [.font: sourceFont]).width * CGFloat(presentation.tabSize)
        style.lineBreakMode = .byClipping
        return NSAttributedString(string: source, attributes: [.font: sourceFont, .paragraphStyle: style])
    }
    @Published var sourceEncoding: GitBlameEncoding?
    @Published var selection: Int?
    @Published var parentChoices: [GitBlameParentComparison] = []
    @Published var loadingParents = false
    private var parentGeneration = 0
    private var parentCache: [Data: [GitBlameParentComparison]] = [:]
    @Published var highlightedHash: String?
    @Published var hoveredLine: Int?
    @Published var find = ""
    @Published var matchCase = false
    @Published var navigationMessage = ""
    @Published var recentHistoryError:String?
    @Published var openingDocument=false {didSet {if openingDocument != oldValue {historyControlEpoch=UUID();historyMenuGeneration=UUID();if openingDocument {cancelHistoryComparisons()}}}}
    @Published var cancellingDocument=false
    var onCancelDocumentOpen:(()->Void)?
    var onLoaded:(()->Void)?
    var onOpenDocument:(()->Void)?
    var onOpenRecent:((BlameRecentDocument)->Void)?
    var recentDocuments:BlameRecentDocuments?
    @Published var searchFeedbackBusy=false {didSet {if searchFeedbackBusy != oldValue {historyControlEpoch=UUID();historyMenuGeneration=UUID();if searchFeedbackBusy {cancelHistoryComparisons()}}}}
    private(set) var retired=false
    @Published var navigationSheetPresented=false {didSet {if navigationSheetPresented != oldValue {historyControlEpoch=UUID();historyMenuGeneration=UUID();if navigationSheetPresented {cancelHistoryComparisons()}}}}
    @Published var historyChildBlocked=false {didSet {if historyChildBlocked != oldValue {historyControlEpoch=UUID();historyMenuGeneration=UUID();if historyChildBlocked {cancelHistoryComparisons()}}}}
    @Published var confirmingQuit=false {didSet {if confirmingQuit != oldValue {historyControlEpoch=UUID();historyMenuGeneration=UUID();if confirmingQuit {cancelHistoryComparisons()}}}}
    var canFindIgnoringHistoryChild:Bool { !retired && !busy && !confirmingQuit && !navigationSheetPresented && !searchFeedbackBusy && !openingDocument && !resettingHistoryColumns }
    var canFind:Bool { !historyChildBlocked && canFindIgnoringHistoryChild }
    func showSettings() {
        guard canFind, presentationCommandsAvailable() else { return }
        SettingsPresentationService.shared.show(globalOnly:true,initialPage:.blame)
    }
    var onFindFeedback:((BlameFindFeedback)->Void)?
    var ranks: [String: Int] = [:]
    private var origins: [String: GitBlameLine] = [:]
    var historyCount = 0
    var onFind: (() -> Void)?
    var onGoTo: (() -> Void)?
    var onLog: ((String, String) -> Void)?
    var onChanges: ((RevisionComparisonSnapshot) -> Void)?
    var onPrevious: ((String, String, Int, GitBlameOptions) -> Void)?
    var firstVisibleSourceRow: (() -> Int?)?
    var scrollSourceRowToTop: ((Int) -> Void)?
    var selectedSourceText: (() -> String)?
    var retireSourceView: (() -> Void)?
    @Published private(set) var sourceNavigationSerial = 0
    private(set) var sourceNavigation: (line: Int, wholeLine: Bool, includeBreak: Bool)?
    func requestSourceNavigation(line: Int, wholeLine: Bool, includeBreak: Bool = false) {
        sourceNavigation = (line, wholeLine, includeBreak); sourceNavigationSerial += 1
    }
    private(set) var appliedOptions = GitBlameOptions()
    var lines: [GitBlameLine] { snapshot?.lines ?? [] }
    private func line(_ number: Int?) -> GitBlameLine? {
        guard let number, number > 0, lines.indices.contains(number - 1) else { return nil }; return lines[number - 1]
    }
    var selectedLine: GitBlameLine? { line(selection) }
    var highlightedLine: GitBlameLine? { highlightedHash.flatMap { origins[$0] } }
    var hoverLine: GitBlameLine? { line(hoveredLine) }
    func highlight(_ row: Int, additive: Bool) {
        guard lines.indices.contains(row) else { return }
        selection = lines[row].number
        selectedLogHashes = GitBlameSelection.selecting(lines[row].hash, in: selectedLogHashes, additive: additive)
        highlightedHash = selectedLogHashes.count == 1 ? selectedLogHashes.first : nil
    }
    func focusHistory(_ hashes: Set<String>, focus: String?) {
        let old = selectedLogHashes; selectedLogHashes = hashes; highlightedHash = nil
        if let focus, hashes.contains(focus), !old.contains(focus) { avatarHash=focus;refreshAuthorImage();if let line = lines.first(where: { $0.hash == focus }) { selection = line.number } }
    }
    func highlightKind(_ line: GitBlameLine) -> Int {
        if selectedLogHashes.contains(line.hash) { return 1 }
        if let entry = selectedHistoryEntry, entry.author == line.author { return 2 }
        if let selected = highlightedLine {
            if line.hash == selected.hash { return 1 }
            if line.author == selected.author { return 2 }
        }
        if let hovered = hoverLine {
            if line.hash == hovered.hash { return 3 }
            if line.author == hovered.author { return 4 }
        }
        return 0
    }
    init(repository: GitRepository, access: RepositoryAccessLease?, path: String, revision: String, options: GitBlameOptions = GitBlameOptions(), labelDefaults: UserDefaults = .standard,historyRegexExecutable:URL? = nil,gravatar:LogGravatar? = nil) {
        self.repository = repository; self.access = access; self.path = path; self.revision = revision; self.labelDefaults = labelDefaults;self.historyColumns = .load(labelDefaults);self.historyRegexExecutable=historyRegexExecutable
        self.revisionDetails=BlameRevisionDetails(preferences:labelDefaults)
        self.gravatar=gravatar ?? LogGravatar(defaults:labelDefaults);showGravatar=labelDefaults.bool(forKey:"EnableGravatar")
        paneLayout=BlamePaneLayout.load(labelDefaults)
        showProperties=labelDefaults.object(forKey:"Blame.ShowProperties") as? Bool ?? true
        showToolbar=labelDefaults.object(forKey:"Blame.ShowToolbar") as? Bool ?? true
        showLog=labelDefaults.object(forKey:"Blame.ShowLog") as? Bool ?? true
        showStatusBar=labelDefaults.object(forKey:"Blame.ShowStatusBar") as? Bool ?? true
        colorAge=labelDefaults.object(forKey:"Blame.ColorAge") as? Bool ?? true
        darkOverride=labelDefaults.object(forKey:"Blame.DarkMode") as? Bool
        marginFields = Set(BlameMarginField.allCases.filter { labelDefaults.object(forKey:"Blame." + $0.rawValue) as? Bool ?? ($0 == .author) })
        syntaxEnabled = labelDefaults.object(forKey:"Blame.EnableLexer") as? Bool ?? !NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
        wrapLongLines = labelDefaults.bool(forKey:"Blame.WrapLongLines")
        presentation = .load(from:labelDefaults)
        let search = GitBlameFindPreferences.load(from:labelDefaults); find = search.text; matchCase = search.matchCase
        setControls(options); appliedOptions = options
    }
    private var currentOptions: GitBlameOptions {
        var options = GitBlameOptions()
        options.useMailmap = GitIdentityDisplay(defaults: labelDefaults).useMailmap
        options.ignoreWhitespace = ignoreWhitespace; options.detectionMode = detectionMode; options.encoding = sourceEncoding
        options.onlyFirstParent = onlyFirstParent
        options.showCompleteLog = showCompleteLog; options.followRenames = followRenames
        options.withinFileCharacters = UInt32(withinFileCharacters) ?? appliedOptions.withinFileCharacters
        options.betweenFileCharacters = UInt32(betweenFileCharacters) ?? appliedOptions.betweenFileCharacters
        return options
    }
    private func sameOptions(_ a: GitBlameOptions, _ b: GitBlameOptions) -> Bool {
        a == b
    }
    private func setControls(_ options: GitBlameOptions) {
        ignoreWhitespace = options.ignoreWhitespace; detectionMode = options.detectionMode; sourceEncoding = options.encoding
        onlyFirstParent = options.onlyFirstParent
        showCompleteLog = options.showCompleteLog; followRenames = options.followRenames
        withinFileCharacters = String(options.withinFileCharacters); betweenFileCharacters = String(options.betweenFileCharacters)
    }
    func configure(options: GitBlameOptions, line: Int?) {
        let needsReload = !sameOptions(currentOptions, options) || (!busy && (snapshot == nil || !sameOptions(appliedOptions, options)))
        setControls(options)
        if needsReload {
            invalidate(); busy = false; reload()
        }
        if let line { selectOriginalLine(line) }
    }
    func setEncoding(_ encoding: GitBlameEncoding?) {
        guard !busy, sourceEncoding != encoding else { return }
        sourceEncoding = encoding; reload(saveThresholds: true)
    }
    func setDetectionMode(_ mode: GitBlameDetectionMode) {
        guard !busy, detectionMode != mode else { return }
        detectionMode = mode; GitBlamePreferences.update(in:labelDefaults) { $0.detectionMode = mode }; reload(saveThresholds: true)
    }
    func setOnlyFirstParent(_ enabled: Bool) {
        guard !busy, onlyFirstParent != enabled else { return }
        onlyFirstParent = enabled; GitBlamePreferences.update(in:labelDefaults) { $0.onlyFirstParent = enabled }; reload(saveThresholds: true)
    }
    func setIgnoreWhitespace(_ enabled: Bool) {
        guard !busy, ignoreWhitespace != enabled else { return }
        ignoreWhitespace = enabled; GitBlamePreferences.update(in:labelDefaults) { $0.ignoreWhitespace = enabled }; reload(saveThresholds: true)
    }
    func applyPreferences() {
        refreshAuthorPreferences()
        presentation = .load(from:labelDefaults)
        var options = GitBlamePreferences.load(from:labelDefaults); options.encoding = sourceEncoding
        configure(options: options, line: selection)
    }
    func setShowCompleteLog(_ enabled: Bool) {
        guard !busy, canShowCompleteLog, showCompleteLog != enabled else { return }
        showCompleteLog = enabled; GitBlamePreferences.update(in:labelDefaults) { $0.showCompleteLog = enabled }; reload(saveThresholds: true)
    }
    func setFollowRenames(_ enabled: Bool) {
        guard !busy, canShowCompleteLog, showCompleteLog, followRenames != enabled else { return }
        followRenames = enabled; GitBlamePreferences.update(in:labelDefaults) { $0.followRenames = enabled }; reload(saveThresholds: true)
    }
    func retire() {
        retired=true;gravatar.clear();avatarIdentity=nil;avatarHash=nil;revisionDetails.update(nil,history:[]);hoveredLine=nil;tooltipEntries=[:];presentationCommandsAvailable={false};presentSourceMenu=nil;onPaneLayoutChanged={};onPaneFloatRequested={_,_ in};paneDropPreview=nil;onFind=nil;onFindFeedback=nil;onGoTo=nil;onOpenDocument=nil;onCancelDocumentOpen=nil;onOpenRecent=nil;onLoaded=nil;onLog=nil;onChanges=nil;onOwnedChanges=nil;onPrevious=nil;recentDocuments=nil;invalidate()
    }
    func invalidate() { historyControlEpoch=UUID();loadCancellation?.cancel();loadCancellation=nil;cancellingReload=false;busy=false;cancelHistoryParentReads();historyClipboardCancellation?.cancel();historyClipboardCancellation=nil;generation += 1; parentGeneration += 1; clipboardGeneration += 1; copyingLog = false; firstVisibleSourceRow = nil; scrollSourceRowToTop = nil; selectedSourceText = nil; sourceNavigation = nil }
    func prepareParentMenu(number: Int, completion: @escaping () -> Void) {
        guard canFind,lines.contains(where:{$0.number==number}) else {return}
        selection=number;loadParents(completion:completion)
    }
    private func loadParents(completion: @escaping () -> Void) {
        sourceParentToken?.cancel()
        parentGeneration += 1; let request = parentGeneration
        guard let line = selectedLine else { parentChoices = []; loadingParents = false; return }
        let key = Data((line.hash + "\0" + line.filename).utf8)
        if let cached = parentCache[key] { parentChoices = cached; loadingParents = false; completion(); return }
        sourceParentToken?.cancel();let token=OperationCancellation();sourceParentToken=token
        parentChoices = []; loadingParents = true;Self.activeHistoryOperations += 1
        Task { [self,access] in
            defer { Self.activeHistoryOperations -= 1;withExtendedLifetime(access) {};if sourceParentToken===token { sourceParentToken=nil;loadingParents=false } }
            do {
                if GitRuntime.isAppStoreBuild && (access?.hasSecurityScope != true || access?.contains(repository.root) != true) { throw RepositoryAccessFailure.securityScopeUnavailable }
                let choices:[GitBlameParentComparison]
                if let readSourceParents { choices=try await readSourceParents(line.hash,line.filename,token) }
                else { choices=try await repository.blameParentComparisons(revision:line.hash,path:line.filename,cancellation:token) }
                guard request == parentGeneration,canFind,!token.isCancelled else { return }
                parentCache[key] = choices; parentChoices = choices; loadingParents = false
                if selectedLine?.number == line.number, selectedLine?.hash == line.hash, selectedLine?.filename == line.filename { completion() }
            } catch { if request == parentGeneration,canFind,!token.isCancelled { self.error = error.localizedDescription;parentChoices=[];loadingParents = false;completion() } }
        }
    }
    func reload(saveThresholds: Bool = false) {
        guard !historyChildBlocked,!confirmingQuit,!retired,!busy,!openingDocument,!searchFeedbackBusy,!resettingHistoryColumns else { return }
        let required = detectionMode == .withinFile ? withinFileCharacters : detectionMode.betweenFiles ? betweenFileCharacters : nil
        if let required, required.isEmpty || !required.utf8.allSatisfy({ (48...57).contains($0) }) || UInt32(required) == nil {
            error = "Enter a character count from 0 to 4294967295."; return
        }
        cancelHistoryParentReads()
        parentGeneration += 1; parentChoices = []; loadingParents = false
        historyClipboardCancellation?.cancel();historyClipboardCancellation=nil
        clipboardGeneration += 1; copyingLog = false
        generation += 1; let request = generation
        let options = currentOptions
        if saveThresholds {
            let changedWithin = UInt32(withinFileCharacters).flatMap { $0 == appliedOptions.withinFileCharacters ? nil : $0 }
            let changedBetween = UInt32(betweenFileCharacters).flatMap { $0 == appliedOptions.betweenFileCharacters ? nil : $0 }
            if changedWithin != nil || changedBetween != nil {
                GitBlamePreferences.update(in:labelDefaults) {
                    if let changedWithin { $0.withinFileCharacters = changedWithin }
                    if let changedBetween { $0.betweenFileCharacters = changedBetween }
                }
            }
        }
        let token=OperationCancellation();loadCancellation=token;cancellingReload=false
        hoveredLine=nil;busy = true; error = nil;Self.activeHistoryOperations += 1
        Task { [self,access] in
            defer { Self.activeHistoryOperations -= 1;withExtendedLifetime(access) {};if request==generation { loadCancellation=nil;cancellingReload=false;busy=false } }
            do {
                if GitRuntime.isAppStoreBuild && (access?.hasSecurityScope != true || access?.contains(repository.root) != true) { throw RepositoryAccessFailure.securityScopeUnavailable }
                let result=try await repository.blame(path:path,revision:revision,options:options,cancellation:token)
                let details=try await repository.blameHistoryDetails(result,options:options,cancellation:token,regexExecutable:historyRegexExecutable)
                guard request==generation,!retired,!token.isCancelled else { return }
                install(result,history:details.entries,options:options,details:details)
                busy=false;applyPendingLine();onLoaded?()
            } catch {
                guard request==generation,!retired,!token.isCancelled else { return }
                snapshot=nil;selection=nil;highlightedHash=nil;hoveredLine=nil;origins=[:];ranks=[:]
                historyCount=0;navigationMessage="";historyEntries=[];selectedLogHashes=[]
                issueProperties=IssueTrackerProperties();hasGitSVN=false;svnRevisions=[:];historyHasWorkingTree=false;historyHead=nil;historyReferencesByHash=[:];historyCurrentBranch=nil;historyReferenceContext=HistoryReferenceContext();self.error=error.localizedDescription
            }
        }
    }
    func install(_ result:GitBlameSnapshot,history entries:[LogEntry],options:GitBlameOptions,details:GitBlameHistoryDetails? = nil) {
        let decorated=Dictionary((details?.entries ?? []).map {($0.hash,$0)},uniquingKeysWith:{first,_ in first})
        let entries=entries.map {decorated[$0.hash] ?? $0}
        let result=result.applyingDisplayIdentities(entries + (details?.tooltipEntries ?? []))
        hoveredLine=nil;tooltipOtherFilenames=result.lines.contains { $0.filename != result.path }
        issueProperties=details?.issueProperties ?? IssueTrackerProperties();hasGitSVN=details?.hasGitSVN ?? false;svnRevisions=details?.svnRevisions ?? [:]
        historyHasWorkingTree=details?.hasWorkingTree ?? false;historyHead=details?.head;historyReferencesByHash=details?.referencesByHash ?? [:];historyCurrentBranch=details?.currentBranch;historyReferenceContext=details?.referenceContext ?? HistoryReferenceContext();historyMenuGeneration=UUID();historyControlEpoch=UUID()
        let hashes=entries.map(\.hash)
        ranks=Dictionary(hashes.enumerated().map { ($0.element,$0.offset) },uniquingKeysWith:min)
        origins=Dictionary(result.lines.map { ($0.hash,$0) },uniquingKeysWith:{ first,_ in first })
        historyCount=hashes.count;appliedOptions=options;snapshot=result;historyEntries=entries
        for entry in details?.tooltipEntries ?? [] {tooltipEntries[entry.hash]=entry}
        selectedLogHashes.formIntersection(Set(hashes))
        if let selection,!result.lines.contains(where:{ $0.number==selection }) { self.selection=nil }
    }
    func selectOriginalLine(_ number: Int) {
        pendingLine = max(1, number)
        if !busy, snapshot != nil { applyPendingLine() }
    }
    private func applyPendingLine() {
        guard let number = pendingLine else { return }
        pendingLine = nil
        guard !lines.isEmpty else { selection = nil; navigationMessage = "The previous file has no lines."; return }
        let selected = min(number, lines.count)
        goToLine(selected)
    }
    func showLog(_ line: GitBlameLine) { onLog?(line.filename, line.hash) }
    func copyLogMessage(_ hash:String) { copyHistoryDetails([hash],includePaths:true) }
    func copyHistoryDetails(_ hashes:[String],includePaths:Bool,available:@escaping () -> Bool = { true }) {
        guard canFind,available(),!hashes.isEmpty else { return }
        historyClipboardCancellation?.cancel();let token=OperationCancellation();historyClipboardCancellation=token
        let request=generation;clipboardGeneration += 1;let clipboardRequest=clipboardGeneration
        copyingLog=true;error=nil;Self.activeHistoryOperations += 1
        let dates=HistoryDateSettings.load(defaults:labelDefaults),useMailmap=GitIdentityDisplay(defaults:labelDefaults).useMailmap
        Task { [self,access] in
            defer { Self.activeHistoryOperations -= 1;withExtendedLifetime(access) {} }
            do {
                if GitRuntime.isAppStoreBuild && (access?.hasSecurityScope != true || access?.contains(repository.root) != true) { throw RepositoryAccessFailure.securityScopeUnavailable }
                var text=""
                for hash in hashes { text += try await repository.commitLogText(revision:hash,includePaths:includePaths,cancellation:token,dateSettings:dates,useMailmap:useMailmap) }
                guard request==generation,clipboardRequest==clipboardGeneration,!retired,!token.isCancelled else { return }
                guard available() else { copyingLog=false;historyClipboardCancellation=nil;return };copy(text)
            } catch { if request==generation,clipboardRequest==clipboardGeneration,!retired { if !token.isCancelled { self.error=error.localizedDescription };copyingLog=false;historyClipboardCancellation=nil } }
        }
    }
    var writeClipboard: (String) -> Void = { text in NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text, forType: .string) }
    func copy(_ text: String) {
        historyClipboardCancellation?.cancel();historyClipboardCancellation=nil
        clipboardGeneration += 1; copyingLog = false
        writeClipboard(text)
    }
    func findLine(previous: Bool) {
        guard canFind,!find.isEmpty,!lines.isEmpty else { return }
        guard let result = GitBlameSearch.find(fields: lines.map { [$0.author, $0.source] }, text: find,
            fromRow: selection.map { $0 - 1 }, previous: previous, matchCase: matchCase) else {
            navigationMessage = "\"\(find)\" was not found.";onFindFeedback?(.notFound(text:find));return
        }
        selection = lines[result.row].number
        let number = lines[result.row].number
        requestSourceNavigation(line: number, wholeLine: true, includeBreak: true)
        navigationMessage = result.wrapped ? "Wrapped to line \(number)." : "Line \(number)"
        if result.wrapped { onFindFeedback?(.wrapped(line:number)) }
    }
    func applyFind(text: String, matchCase: Bool, previous: Bool) {
        guard canFind else { return }
        find = text; self.matchCase = matchCase
        GitBlameFindPreferences(text:text,matchCase:matchCase).save(to:labelDefaults)
        findLine(previous: previous)
    }
    func goToLine(_ requested: Int) {
        guard canFind,let number = GitBlameNavigation.targetLine(requested, lineCount: lines.count) else { return }
        selection = number; requestSourceNavigation(line: number, wholeLine: true); navigationMessage = "Line \(number)"
    }
    func navigateChange(previous: Bool) {
        guard !busy, let start = firstVisibleSourceRow?(), let scrollSourceRowToTop else { return }
        guard let target = GitBlameNavigation.change(hashes: lines.map(\.hash), selected: selectedLogHashes, start: start, previous: previous) else { return }
        scrollSourceRowToTop(target)
    }
}

private struct BlameDialog: View {
    @ObservedObject var model: BlameWindowModel
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if model.showToolbar { HStack(spacing:8) {
                Button { model.reload(saveThresholds:true) } label: { CommandLabel(title:"Reload",icon:.refresh) }
                Button { model.navigateChange(previous:true) } label: { CommandLabel(title:"Previous change",icon:.jumpUp) }.disabled(model.selectedLogHashes.isEmpty)
                Button { model.navigateChange(previous:false) } label: { CommandLabel(title:"Next change",icon:.jumpDown) }.disabled(model.selectedLogHashes.isEmpty)
                Button { model.onFind?() } label: { CommandLabel(title:"Find…",icon:.mergeFind) }.keyboardShortcut("f",modifiers:.command)
                Spacer()
                Menu("File") {
                    Button { model.onOpenDocument?() } label: { CommandLabel(title:"Open…",icon:.open) }.keyboardShortcut("o",modifiers:.command)
                    if let recent=model.recentDocuments { BlameRecentFileMenu(store:recent,open:{ model.onOpenRecent?($0) }) }
                    Divider()
                    Button { model.showSettings() } label: { CommandLabel(title:"Settings…",icon:.settings) }
                    Button("Close") { NSApp.sendAction(#selector(NSWindow.performClose(_:)),to:nil,from:nil) }.keyboardShortcut("w",modifiers:.command)
                }
                Menu("Edit") {
                    Button { NSApp.sendAction(Selector(("copy:")),to:nil,from:nil) } label: { CommandLabel(title:"Copy",icon:.copy) }
                    Button { model.onFind?() } label: { CommandLabel(title:"Find…",icon:.mergeFind) }
                    Button { model.findLine(previous:false) } label: { CommandLabel(title:"Find Next",icon:.jumpDown) }.keyboardShortcut("g",modifiers:.command)
                    Button { model.findLine(previous:true) } label: { CommandLabel(title:"Find Previous",icon:.jumpUp) }.keyboardShortcut("g",modifiers:[.command,.shift])
                    Button { model.onGoTo?() } label: { CommandLabel(title:"Go To Line…",icon:.log) }.keyboardShortcut("l",modifiers:.command)
                    Divider()
                    BlameEncodingMenu(selection: Binding(get: { model.sourceEncoding }, set: { model.setEncoding($0) }))
                }
                Menu("View") {
                    Button("Next") { model.navigateChange(previous:false) }.disabled(model.selectedLogHashes.isEmpty)
                    Button("Previous") { model.navigateChange(previous:true) }.disabled(model.selectedLogHashes.isEmpty)
                    Divider()
                    Button { model.zoomIn() } label: { CommandLabel(title:"Zoom In",icon:.imageZoomIn) }.disabled(!model.canZoomIn)
                    Button { model.zoomOut() } label: { CommandLabel(title:"Zoom Out",icon:.imageZoomOut) }.disabled(!model.canZoomOut)
                    Button { model.resetZoom() } label: { CommandLabel(title:"Actual Size",icon:.imageOriginal) }.disabled(!model.canResetZoom)
                    Divider()
                    ForEach(BlameMarginField.allCases,id:\.self) { field in
                        Toggle(field.title,isOn:Binding(get:{model.marginFields.contains(field)},set:{model.setMargin(field,visible:$0)}))
                    }
                    Divider()
                    Picker("Detect moved or copied lines",selection:Binding(get:{model.detectionMode},set:{model.setDetectionMode($0)})) {
                        ForEach(GitBlameDetectionMode.allCases) { mode in Text(mode.title).tag(mode) }
                    }
                    Toggle("Ignore whitespace",isOn:Binding(get:{model.ignoreWhitespace},set:{model.setIgnoreWhitespace($0)}))
                    Divider()
                    Toggle("Show complete log",isOn:Binding(get:{model.canShowCompleteLog && model.showCompleteLog},set:{model.setShowCompleteLog($0)})).disabled(!model.canShowCompleteLog)
                    Toggle("Follow renames",isOn:Binding(get:{model.canShowCompleteLog && model.showCompleteLog && model.followRenames},set:{model.setFollowRenames($0)})).disabled(!model.canShowCompleteLog || !model.showCompleteLog)
                    Toggle("Only consider first parents on blame",isOn:Binding(get:{model.onlyFirstParent},set:{model.setOnlyFirstParent($0)}))
                    Divider()
                    Toggle("Color by age, continuous",isOn:$model.colorAge)
                    Toggle("Enable syntax highlighting",isOn:Binding(get:{model.syntaxEnabled},set:{model.setSyntaxEnabled($0)}))
                    Toggle("Log",isOn:$model.showLog)
                    Toggle("Properties",isOn:$model.showProperties)
                    Divider();BlamePaneLayoutMenu(model:model)
                    Toggle("Status Bar",isOn:$model.showStatusBar)
                    Toggle("Toolbar",isOn:$model.showToolbar)
                    Divider()
                    Toggle("Wrap long lines",isOn:Binding(get:{model.wrapLongLines},set:{model.setWrapLongLines($0)}))
                }
                Button { model.showSettings() } label: { CommandLabel(title:"Settings…",icon:.settings) }
            }.disabled(model.busy || model.openingDocument || model.searchFeedbackBusy) }
            if let error=model.recentHistoryError { Text(error).font(.caption).foregroundStyle(.orange).textSelection(.enabled) }
            if model.openingDocument { HStack { ProgressView(model.cancellingDocument ? "Cancelling…" : "Opening file…").controlSize(.small);Button("Cancel") { model.onCancelDocumentOpen?() }.disabled(model.cancellingDocument) } }
            if model.busy { HStack {
                ProgressView(model.cancellingReload ? "Cancelling…" : "Reading annotations…").controlSize(.small)
                Button("Cancel") { model.cancelReload() }.disabled(model.cancellingReload)
            } }
            if model.syntaxWorking { ProgressView("Coloring source…").controlSize(.small) }
            if let error = model.syntaxError { Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled) }
            if model.loadingParents || model.readingHistoryParents { ProgressView("Reading previous revisions…").controlSize(.small) }
            if model.copyingLog { ProgressView("Reading log message for clipboard…").controlSize(.small) }
            if let error = model.error { Text(error).foregroundStyle(.red).textSelection(.enabled) }
            BlamePaneWorkspace(model:model).frame(maxWidth:.infinity,maxHeight:.infinity)
            if model.showStatusBar { if let line = model.selectedLine {
                Text("\(line.hash) • \(line.author) <\(line.email)>").font(.system(size: 11)).textSelection(.enabled)
                Text("\(line.summary)\nOrigin: \(line.filename), line \(line.originalLine)").font(.system(size: 11)).textSelection(.enabled)
            }
            Text("\(model.lines.count) lines • \(model.snapshot?.encoding.rawValue ?? "") • \(model.navigationMessage)").font(.system(size: 11)).foregroundStyle(.secondary) }
        }.padding(12).disabled(model.historyChildBlocked || model.confirmingQuit).onReceive(NotificationCenter.default.publisher(for: .blamePreferencesChanged)) { _ in model.applyPreferences() }.onReceive(NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)) { _ in model.refreshAuthorPreferences() }
    }
}

@MainActor final class BlameFindDraft:ObservableObject {
    @Published var text:String
    @Published var matchCase:Bool
    @Published var previous=false
    init(text:String,matchCase:Bool) { self.text=text;self.matchCase=matchCase }
}
@MainActor final class BlameFindWindowController:NSWindowController,NSWindowDelegate {
    let draft:BlameFindDraft
    private(set) var model:BlameWindowModel
    var onClosed:()->Void={}
    private var flashGeneration=0
    private(set) var flashCount=0
    init(model:BlameWindowModel,draft:BlameFindDraft) {
        self.model=model;self.draft=draft
        let panel=NSPanel(contentRect:NSRect(x:0,y:0,width:460,height:180),styleMask:[.titled,.closable,.utilityWindow],backing:.buffered,defer:false)
        panel.title="Find – TurtleGit Blame";panel.isReleasedWhenClosed=false;panel.isFloatingPanel=true;panel.hidesOnDeactivate=true
        super.init(window:panel);panel.delegate=self
        panel.contentViewController=NSHostingController(rootView:BlameFindDialog(model:model,draft:draft,close:{ [weak self] in self?.window?.performClose(nil) }))
        DialogGeometry.attach(panel,identifier:"BlameFindWindowController")
    }
    func rebind(_ model:BlameWindowModel) {
        flashGeneration += 1;window?.contentView?.layer?.borderWidth=0;self.model=model
        window?.contentViewController=NSHostingController(rootView:BlameFindDialog(model:model,draft:draft,close:{ [weak self] in self?.window?.performClose(nil) }))
    }
    func search() { guard !draft.text.isEmpty,model.canFind else { return };model.applyFind(text:draft.text,matchCase:draft.matchCase,previous:draft.previous) }
    func flash() {
        guard let view=window?.contentView else { return };flashGeneration += 1;let identity=flashGeneration;flashCount += 1
        view.wantsLayer=true
        for step in 0..<4 {
            DispatchQueue.main.asyncAfter(deadline:.now()+Double(step)*0.1) { [weak self,weak view] in
                guard let self,self.flashGeneration==identity,let view else { return }
                view.layer?.borderWidth=step%2==0 ? 2 : 0;view.layer?.borderColor=NSColor.controlAccentColor.cgColor
            }
        }
    }
    func windowShouldClose(_ sender:NSWindow) -> Bool { !model.searchFeedbackBusy }
    func windowWillClose(_ notification:Notification) {
        flashGeneration += 1;window?.contentView?.layer?.borderWidth=0
        if let panel=window { panel.parent?.removeChildWindow(panel) };onClosed()
    }
    required init?(coder:NSCoder) { fatalError("init(coder:) is not supported") }
}
private struct BlameFindDialog:View {
    @ObservedObject var model:BlameWindowModel
    @ObservedObject var draft:BlameFindDraft
    let close:()->Void
    @FocusState private var focused:Bool
    private func search() { guard !draft.text.isEmpty,model.canFind else { return };model.applyFind(text:draft.text,matchCase:draft.matchCase,previous:draft.previous) }
    var body:some View {
        HStack(alignment:.top,spacing:18) {
            VStack(alignment:.leading,spacing:14) {
                HStack { Text("Find what:");TextField("Search text",text:$draft.text).focused($focused).onSubmit { search() }.accessibilityLabel("Blame search text") }
                HStack {
                    Toggle("Match case",isOn:$draft.matchCase)
                    GroupBox("Direction") {
                        Picker("Direction",selection:$draft.previous) { Text("Up").tag(true);Text("Down").tag(false) }.pickerStyle(.radioGroup).labelsHidden().horizontalRadioGroupLayout()
                    }
                }
                Text(model.navigationMessage).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true)
            }.disabled(!model.canFind)
            VStack(spacing:10) {
                Button("Find Next") { search() }.keyboardShortcut(.defaultAction).disabled(draft.text.isEmpty || !model.canFind)
                Button("Cancel") { close() }.keyboardShortcut(.cancelAction).disabled(model.searchFeedbackBusy)
            }
        }.padding(16).frame(width:460).task { await Task.yield();focused=true }
    }
}

/// Source EditGotoDlg validation with a native, owner-scoped sheet.
@MainActor final class BlameGoToLineWindowController: NSWindowController {
    let line = NSTextField(string: "0")
    let validation = NSTextField(wrappingLabelWithString: "")
    private(set) var requested: Int?
    private(set) var retired = false
    private var submitted = false
    let ok = NSButton(title: "OK", target: nil, action: nil)
    init() {
        let panel = NSPanel(contentRect: NSRect(x:0,y:0,width:340,height:160),styleMask:[.titled],backing:.buffered,defer:false)
        panel.title = "Go to line"; panel.isReleasedWhenClosed = false
        super.init(window:panel)
        line.setAccessibilityLabel("Blame line number")
        let label = NSTextField(labelWithString:"Line number:")
        let row = NSStackView(views:[label,line]); row.orientation = .horizontal; row.spacing = 10
        validation.textColor = .systemRed; validation.setAccessibilityLabel("Line number validation")
        ok.target = self; ok.action = #selector(accept); ok.keyEquivalent = "\r"
        let cancel = NSButton(title:"Cancel",target:self,action:#selector(Self.cancel));cancel.keyEquivalent = "\u{1b}"
        let spacer = NSView()
        let buttons = NSStackView(views:[spacer,ok,cancel]);buttons.orientation = .horizontal;buttons.spacing = 10
        let content = NSStackView(views:[row,validation,buttons]);content.orientation = .vertical;content.alignment = .leading;content.spacing = 14
        panel.contentView!.addSubview(content);content.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([content.leadingAnchor.constraint(equalTo:panel.contentView!.leadingAnchor,constant:20),content.trailingAnchor.constraint(equalTo:panel.contentView!.trailingAnchor,constant:-20),content.topAnchor.constraint(equalTo:panel.contentView!.topAnchor,constant:20),row.widthAnchor.constraint(equalTo:content.widthAnchor),validation.widthAnchor.constraint(equalTo:content.widthAnchor),buttons.widthAnchor.constraint(equalTo:content.widthAnchor),line.widthAnchor.constraint(greaterThanOrEqualToConstant:150)])
        panel.defaultButtonCell = ok.cell as? NSButtonCell;panel.initialFirstResponder = line
    }
    @objc func accept() {
        guard !retired,!submitted,let window,let parent = window.sheetParent else {return}
        guard let value = GitBlameNavigation.requestedLine(line.stringValue) else {
            validation.stringValue = "Enter a whole number from 0 to \(GitBlameNavigation.maximumGoToLine)."
            window.makeFirstResponder(line);return
        }
        requested = value;submitted = true;parent.endSheet(window,returnCode:.OK)
    }
    @objc func cancel() { guard !retired,let window else {return};submitted = true;requested = nil;window.sheetParent?.endSheet(window,returnCode:.cancel) }
    func retire() { guard !retired else {return};retired = true;requested = nil;if let window { window.sheetParent?.endSheet(window,returnCode:.cancel);window.close() } }
    required init?(coder:NSCoder) {fatalError("init(coder:) is not supported")}
}

/// Read-only source Properties grid. Parent values are subjects, while their
/// descriptions retain the full hash and ordinal; Copy always uses the value.
@MainActor final class BlameRevisionDetails: ObservableObject {
    struct Row: Equatable {
        let id: String, name: String, value: String, description: String
        var localizedName: String { id.hasPrefix("parent.") ? name : NSLocalizedString(name, comment: "") }
        static func == (lhs: Self, rhs: Self) -> Bool {
            [lhs.id,lhs.name,lhs.value,lhs.description].map { Data($0.utf8) } == [rhs.id,rhs.name,rhs.value,rhs.description].map { Data($0.utf8) }
        }
    }
    @Published private(set) var basic: [Row] = []
    @Published private(set) var parents: [Row] = []
    @Published var selection: String? { didSet { if oldValue != selection { selectionGeneration &+= 1 } } }
    private(set) var selectionGeneration: UInt64 = 0
    @Published private(set) var propertyColumnWidth: Double
    private let preferences: UserDefaults
    init(preferences: UserDefaults = .standard) {
        self.preferences = preferences
        let saved = preferences.object(forKey: "Blame.Properties.PropertyColumnWidth") as? Double ?? 128
        propertyColumnWidth = saved.isFinite ? min(10000, max(60, saved)) : 128
    }
    func setPropertyColumnWidth(_ width: Double) {
        guard width.isFinite else { return }
        propertyColumnWidth = min(10000, max(60, width))
        preferences.set(propertyColumnWidth, forKey: "Blame.Properties.PropertyColumnWidth")
    }
    @Published var basicExpanded = true
    @Published var parentsExpanded = false
    private var revision: String?
    var selected: Row? { (basic + parents).first { $0.id == selection } }
    func update(_ entry: LogEntry?, history: [LogEntry]) {
        let changed = revision != entry?.hash; revision = entry?.hash
        let properties = entry.map { GitBlameRevisionProperties(entry: $0) }
        let values: [(String, String)] = [
            ("SHA-1", entry?.hash ?? ""), ("Author", entry?.author ?? ""),
            ("Author date", properties?.authorDate ?? ""), ("Author email", entry?.email ?? ""),
            ("Committer", entry?.committer ?? ""), ("Committer email", entry?.committerEmail ?? ""),
            ("Committer date", properties?.committerDate ?? ""),
            ("Subject", properties?.subject ?? ""), ("Body", properties?.body ?? "")]
        basic = values.enumerated().map { Row(id: "basic.\($0.offset)", name: $0.element.0, value: $0.element.1, description: $0.element.1) }
        parents = (entry?.parents ?? []).enumerated().map { index, hash in
            let subject = history.first { $0.hash == hash }.map { GitBlameRevisionProperties(entry: $0).subject } ?? ""
            return Row(id: "parent.\(index).\(hash)", name: String(hash.prefix(8)), value: subject, description: "\(index) - \(hash)\n\(subject)")
        }
        if changed { parentsExpanded = entry != nil }
        if entry == nil { parentsExpanded = false }
        if selected == nil { selection = nil }
    }
}

struct BlamePropertiesPane: View {
    @ObservedObject var model: BlameWindowModel
    @ObservedObject var details: BlameRevisionDetails
    init(model: BlameWindowModel) { self.model = model; details = model.revisionDetails }
    var body: some View {
        VSplitView {
            BlamePropertyGrid(model: model, details: details).frame(minHeight: 120)
            ScrollView {
                VStack(alignment: .leading, spacing: 5) {
                    Text(details.selected?.localizedName ?? "").font(.headline)
                    Text(details.selected?.description ?? "").textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }.font(.system(size: 11)).padding(8)
            }.frame(minHeight: 64, idealHeight: 100, maxHeight: 150)
        }.background(Color(nsColor: .controlBackgroundColor)).accessibilityLabel("Blame Properties")
    }
}

struct BlamePropertyGrid: NSViewRepresentable {
    @ObservedObject var model: BlameWindowModel
    @ObservedObject var details: BlameRevisionDetails
    func makeCoordinator() -> Coordinator { Coordinator(model, details) }
    func makeNSView(context: Context) -> NSScrollView { context.coordinator.makeView() }
    func updateNSView(_ view: NSScrollView, context: Context) { context.coordinator.update() }
    static func dismantleNSView(_ view: NSScrollView, coordinator: Coordinator) { coordinator.retire() }
    @MainActor final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSMenuDelegate {
        let model: BlameWindowModel, details: BlameRevisionDetails
        weak var table: BlamePropertiesTable?
        private(set) var rows: [BlameRevisionDetails.Row] = []
        private var updating = false, retired = false
        init(_ model: BlameWindowModel, _ details: BlameRevisionDetails) { self.model = model; self.details = details }
        var available: Bool { !retired && model.canFind && table?.window?.attachedSheet == nil }
        func makeView() -> NSScrollView {
            let table = BlamePropertiesTable(); self.table = table
            table.setAccessibilityLabel("Blame revision properties");table.headerView = nil
            table.rowHeight = 22;table.intercellSpacing = NSSize(width: 1, height: 1)
            table.style = .plain;table.allowsEmptySelection = true;table.allowsMultipleSelection = false
            for (id, width) in [("property", CGFloat(128)), ("value", CGFloat(220))] {
                let column = NSTableColumn(identifier: .init(id));column.width = width;column.minWidth = 60;column.maxWidth = 10000;table.addTableColumn(column)
            }
            table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
            table.dataSource = self;table.delegate = self
            table.copySelection = { [weak self] in self?.copyValue() }
            table.contextAvailable = { [weak self] in self?.available == true }
            table.copyAvailable = { [weak self] in guard let self else { return false };return self.available && self.model.copyWindowAvailable(self.table?.window) && self.details.selected?.value.isEmpty == false }
            table.navigateGroup = { [weak self] key in self?.navigateGroup(key) == true }
            table.resizeDivider = { [weak self] width in self?.setPropertyColumnWidth(Double(width)) }
            table.target=self;table.doubleAction = #selector(doubleClickGroup)
            table.prepareMenu = { [weak self,weak table] in if let menu=table?.menu {self?.menuNeedsUpdate(menu)} }
            table.menu = NSMenu();table.menu?.autoenablesItems = false;table.menu?.delegate = self
            let scroll = NSScrollView();scroll.documentView = table;scroll.hasVerticalScroller = true
            scroll.hasHorizontalScroller = true;scroll.borderType = .bezelBorder
            update();return scroll
        }
        func update() {
            guard !retired, let table else { return }; updating = true;defer { updating = false }
            let basic = BlameRevisionDetails.Row(id: "group.basic", name: "Basic information", value: "", description: "")
            let parents = BlameRevisionDetails.Row(id: "group.parents", name: "Parents", value: "", description: "")
            let next = [basic] + (details.basicExpanded ? details.basic : []) + [parents] + (details.parentsExpanded ? details.parents : [])
            if next != rows { rows = next;table.reloadData() }
            if abs(table.tableColumns[0].width - details.propertyColumnWidth) > 0.5 { table.tableColumns[0].width = details.propertyColumnWidth }
            let selected = rows.firstIndex { $0.id == details.selection }
            if table.selectedRow != (selected ?? -1) { table.selectRowIndexes(selected.map { IndexSet(integer: $0) } ?? [], byExtendingSelection: false) }
            table.isEnabled = available
            for row in rows.indices {
                if let stack = table.view(atColumn:0,row:row,makeIfNecessary:false) as? NSStackView {
                    stack.views.compactMap { $0 as? NSButton }.forEach { $0.isEnabled = available }
                }
            }
        }
        func setPropertyColumnWidth(_ width: Double) {
            guard available else { return };details.setPropertyColumnWidth(width);update()
        }
        func navigateGroup(_ key: UInt16) -> Bool {
            guard available, let table, table.window?.firstResponder === table else { return false }
            guard [UInt16(123),124,49,36,76,115,119].contains(key) else { return false }
            if key == 115 || key == 119 {
                details.selection = (key == 115 ? rows.first : rows.last)?.id
            } else {
                guard rows.indices.contains(table.selectedRow) else { return false }
                let id = rows[table.selectedRow].id, group = id.hasPrefix("group.")
                let basic = id == "group.basic" || id.hasPrefix("basic.")
                let groupID = basic ? "group.basic" : "group.parents"
                let expanded = basic ? details.basicExpanded : details.parentsExpanded
                if key == 123 {
                    if group { if basic { details.basicExpanded = false } else { details.parentsExpanded = false } }
                    details.selection = groupID
                } else if key == 124 {
                    if group && !expanded { if basic { details.basicExpanded = true } else { details.parentsExpanded = true } }
                    else if group { details.selection = (basic ? details.basic.first : details.parents.first)?.id ?? groupID }
                } else if group {
                    if basic { details.basicExpanded.toggle() } else { details.parentsExpanded.toggle() }
                } else { return false }
            }
            update();if table.selectedRow >= 0 { table.scrollRowToVisible(table.selectedRow) };return true
        }
        @objc func doubleClickGroup() {
            guard let table, rows.indices.contains(table.clickedRow), rows[table.clickedRow].id.hasPrefix("group.") else { return }
            table.window?.makeFirstResponder(table);_ = navigateGroup(49)
        }
        func numberOfRows(in tableView: NSTableView) -> Int { rows.count }
        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            guard rows.indices.contains(row), let column = tableColumn else { return nil }
            let value = rows[row], group = value.id.hasPrefix("group.")
            if group && column.identifier.rawValue == "property" {
                let button = NSButton(title: NSLocalizedString(value.name, comment: ""), target: self, action: #selector(toggleGroup(_:)))
                button.setButtonType(.pushOnPushOff);button.bezelStyle = .disclosure
                button.state = (value.id == "group.basic" ? details.basicExpanded : details.parentsExpanded) ? .on : .off
                button.refusesFirstResponder=true;button.isEnabled=available
                button.title="";button.identifier = NSUserInterfaceItemIdentifier(value.id);button.setAccessibilityLabel(NSLocalizedString(value.name, comment: ""))
                let label=NSTextField(labelWithString:NSLocalizedString(value.name,comment:""));label.font = .boldSystemFont(ofSize:11)
                label.lineBreakMode = .byTruncatingTail
                let stack=NSStackView(views:[button,label]);stack.orientation = .horizontal;stack.spacing=3
                button.widthAnchor.constraint(equalToConstant:14).isActive=true
                return stack
            }
            let text = NSTextField(labelWithString: column.identifier.rawValue == "property" ? (group ? "" : value.localizedName) : value.value)
            text.font = .systemFont(ofSize: 11);text.lineBreakMode = .byTruncatingTail;text.toolTip = value.description
            text.setAccessibilityLabel(column.identifier.rawValue == "property" ? value.name : value.description)
            return text
        }
        func tableViewSelectionDidChange(_ notification: Notification) {
            guard !updating, available, let table else { return }
            details.selection = rows.indices.contains(table.selectedRow) ? rows[table.selectedRow].id : nil
        }
        @objc func toggleGroup(_ sender: NSButton) {
            guard available else { return }
            if sender.identifier?.rawValue == "group.basic" {
                details.basicExpanded.toggle();if !details.basicExpanded && details.selection?.hasPrefix("basic.")==true {details.selection="group.basic"}
            } else {
                details.parentsExpanded.toggle();if !details.parentsExpanded && details.selection?.hasPrefix("parent.")==true {details.selection="group.parents"}
            }
            update();table?.window?.makeFirstResponder(table)
        }
        func menuNeedsUpdate(_ menu: NSMenu) {
            menu.removeAllItems();guard available, let selected = details.selected, !selected.id.hasPrefix("group.") else { return }
            let item = NSMenuItem(title: NSLocalizedString("Copy", comment: ""), action: #selector(copyMenu(_:)), keyEquivalent: "")
            item.target = self;item.image = MenuIcon.copy.contextImage(defaults: model.labelDefaults)
            // Fence the menu value to the selected revision/property; a late action
            // after selection or a new document must not copy a different value.
            item.representedObject = [selected.id, selected.value, selected.description, model.selectedHistoryEntry?.hash ?? "", String(details.selectionGeneration)].map { Data($0.utf8) }
            menu.addItem(item)
        }
        @objc func copyMenu(_ sender: NSMenuItem) {
            guard available, let captured = sender.representedObject as? [Data], let selected = details.selected,
                  captured == [selected.id, selected.value, selected.description, model.selectedHistoryEntry?.hash ?? "", String(details.selectionGeneration)].map({ Data($0.utf8) }) else { return }
            sender.representedObject = nil;model.copy(selected.value)
        }
        func copyValue() { guard available, model.copyWindowAvailable(table?.window), table?.window?.firstResponder === table, let selected = details.selected, !selected.value.isEmpty else { return };model.copy(selected.value) }
        func retire() { retired = true;table?.menu?.cancelTracking();table?.menu?.delegate = nil;table?.menu = nil;table?.copySelection = {};table?.prepareMenu = {};table?.contextAvailable = { false };table?.copyAvailable = { false };table?.navigateGroup = { _ in false };table?.resizeDivider = { _ in };table?.delegate = nil;table?.dataSource = nil;table = nil }
    }
}

@MainActor final class BlamePropertiesTable: NSTableView {
    var copySelection: () -> Void = {}
    var copyAvailable: () -> Bool = { false }
    var contextAvailable: () -> Bool = { false }
    var prepareMenu: () -> Void = {}
    var navigateGroup: (UInt16) -> Bool = { _ in false }
    var resizeDivider: (CGFloat) -> Void = { _ in }
    var presentContextMenu: (NSMenu, NSPoint, NSView) -> Void = { menu, point, view in menu.popUp(positioning:nil,at:point,in:view) }
    private var draggingDivider = false
    private var dividerOffset: CGFloat = 0
    private var ownsCopy: Bool { window?.firstResponder === self && copyAvailable() }
    private func nearDivider(_ event: NSEvent) -> Bool {
        guard tableColumns.count == 2 else { return false }
        return abs(convert(event.locationInWindow,from:nil).x - rect(ofColumn:0).maxX) <= 4
    }
    func resizePropertyDivider(to width: CGFloat) { if contextAvailable(), width.isFinite { resizeDivider(width) } }
    override func resetCursorRects() {
        super.resetCursorRects()
        guard contextAvailable(), tableColumns.count == 2 else { return }
        addCursorRect(NSRect(x:rect(ofColumn:0).maxX-4,y:visibleRect.minY,width:8,height:visibleRect.height),cursor:.resizeLeftRight)
    }
    override func mouseDown(with event:NSEvent) {
        if contextAvailable(), nearDivider(event) {
            window?.makeFirstResponder(self);draggingDivider=true
            dividerOffset=convert(event.locationInWindow,from:nil).x-tableColumns[0].width
            return
        }
        super.mouseDown(with:event)
    }
    override func mouseDragged(with event:NSEvent) {
        guard draggingDivider else { super.mouseDragged(with:event);return }
        resizePropertyDivider(to:convert(event.locationInWindow,from:nil).x-dividerOffset)
    }
    override func mouseUp(with event:NSEvent) {
        guard draggingDivider else { super.mouseUp(with:event);return }
        mouseDragged(with:event);draggingDivider=false;window?.invalidateCursorRects(for:self)
    }
    override func menu(for event: NSEvent) -> NSMenu? {
        guard contextAvailable() else { return nil }
        let row = row(at: convert(event.locationInWindow, from: nil));guard row >= 0 else { return nil }
        window?.makeFirstResponder(self)
        selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false);prepareMenu();return menu?.items.isEmpty == false ? menu : nil
    }
    @objc func copy(_ sender: Any?) { if ownsCopy { copySelection() } }
    override func validateUserInterfaceItem(_ item: NSValidatedUserInterfaceItem) -> Bool {
        item.action == #selector(copy(_:)) && ownsCopy
    }
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if ownsCopy, event.modifierFlags.intersection([.command, .option, .control]) == .command, event.charactersIgnoringModifiers?.lowercased() == "c" { copySelection();return true }
        return super.performKeyEquivalent(with: event)
    }
    override func accessibilityPerformShowMenu() -> Bool {
        guard contextAvailable(), selectedRow >= 0, let menu else { return false };prepareMenu();guard !menu.items.isEmpty else { return false }
        window?.makeFirstResponder(self);scrollRowToVisible(selectedRow)
        let point = NSPoint(x: 20, y: rect(ofRow: selectedRow).midY);presentContextMenu(menu,point,self);return true
    }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 109, event.modifierFlags.intersection([.command, .shift, .control, .option]) == .shift, accessibilityPerformShowMenu() { return }
        if event.modifierFlags.intersection([.command,.option,.control]).isEmpty, navigateGroup(event.keyCode) { return }
        super.keyDown(with: event)
    }
}

/// CGitBlameLogList uses the shared column manager with ID replacing Actions.
struct BlameHistoryColumns:Equatable {
    static let definitions:[(String,String,Double,Bool)]=[("graph","Graph",65,true),("id","ID",55,true),("hash","SHA-1",92,true),("message","Message",420,true),("author","Author",140,true),("date","Date",170,true),("email","Email",200,false),("committer","Commit Name",140,false),("committerEmail","Commit Email",200,false),("committerDate","Commit Date",170,false),("bugs","Bug-ID",110,true),("svn","SVN Rev",100,true)]
    static let names=definitions.map { $0.0 }
    var visible:Set<String>,order:[String],widths:[String:Double]
    init(visible:Set<String> = Set(definitions.filter { $0.3 }.map { $0.0 }),order:[String] = names,widths:[String:Double] = [:]) {
        self.visible=visible.intersection(Self.names).union(["graph"])
        var seen=Set<String>();self.order=(["graph"]+order+Self.names).filter { Self.names.contains($0) && seen.insert($0).inserted }
        self.widths=widths.filter { Self.names.contains($0.key) && $0.value.isFinite && $0.value>=24 }.mapValues { min(10000,$0) }
    }
    static func load(_ preferences:UserDefaults)->Self {
        let key="Blame.LogColumns"
        guard [6,7].contains(preferences.integer(forKey:key+".Version")) else { return Self() }
        let widths=(preferences.dictionary(forKey:key+".Widths") ?? [:]).compactMapValues { ($0 as? NSNumber)?.doubleValue }
        let saved=Set(preferences.stringArray(forKey:key) ?? names)
        let prior=preferences.stringArray(forKey:key+".Order") ?? names
        let introduced=Set(["bugs","svn"].filter { !prior.contains($0) })
        return Self(visible:saved.union(introduced),order:preferences.stringArray(forKey:key+".Order") ?? names,widths:widths)
    }
    func save(_ preferences:UserDefaults) {
        let key="Blame.LogColumns";preferences.set(7,forKey:key+".Version");preferences.set(Self.names.filter { visible.contains($0) },forKey:key)
        preferences.set(order,forKey:key+".Order");preferences.set(widths,forKey:key+".Widths")
    }
}

struct BlameHistoryTable:NSViewRepresentable {
    @ObservedObject var model:BlameWindowModel
    func makeCoordinator()->Coordinator { Coordinator(model) }
    func makeNSView(context:Context)->NSScrollView { context.coordinator.makeView() }
    func updateNSView(_ view:NSScrollView,context:Context) { context.coordinator.bind(model);context.coordinator.update() }
    static func dismantleNSView(_ view:NSScrollView,coordinator:Coordinator) { coordinator.retire() }
    @MainActor final class Coordinator:NSObject,NSTableViewDataSource,NSTableViewDelegate,NSMenuDelegate {
        var model:BlameWindowModel
        weak var table:NSTableView?
        var updating=false,retired=false
        private var entries:[LogEntry]=[],graph:[CommitGraphRow]=[]
        private var historyVersion = -1
        private var layout:BlameHistoryColumns?
        private var showGraph=false
        private var lifetime=UUID(),headerEpoch=UUID()
        private var sheetObservers:[NSObjectProtocol]=[]
        private var lastFont:NSFont?,lastContext=HistoryReferenceContext(),lastStyle=""
        private var lastColors:LogColorPreferences?,lastDates:HistoryDateSettings?
        private var styleKey:String {
            ["FullCommitMessageOnLogLine","SymbolizeRefNames","DrawTagsBranchesOnRightSide","LogDateFormat","RelativeTimes","UseSystemLocaleForDates","DateFormat","LogFontForLogCtrl","LogFontName","LogFontSize"].map {String(describing:model.labelDefaults.object(forKey:$0))}.joined(separator:"\0")
        }
        var available:Bool { !retired && model.canFind && NSApp.modalWindow==nil && table?.window?.attachedSheet==nil }
        func bind(_ next:BlameWindowModel) {
            guard model !== next else{return}
            table?.menu?.cancelTracking();contextRequest=UUID();contextTarget=nil;headerEpoch=UUID();lifetime=UUID()
            model=next;entries=[];graph=[];historyVersion = -1;layout=nil;lastFont=nil
        }
        func retire() {
            guard !retired else{return};retired=true;headerEpoch=UUID();lifetime=UUID();contextRequest=UUID();contextTarget=nil
            sheetObservers.forEach {NotificationCenter.default.removeObserver($0)};sheetObservers=[]
            table?.menu?.cancelTracking();table?.menu?.delegate=nil;table?.menu=nil
            (table?.headerView as? BlameHistoryColumnHeader)?.buildMenu={nil}
            if let table=table as? BlameHistoryNativeTable {table.copySelection={};table.copyAvailable={false};table.openSelection={false};table.showContext={_ in}}
            table?.isEnabled=false;table?.target=nil;table?.doubleAction=nil;table?.action=nil;table?.delegate=nil;table?.dataSource=nil;table=nil
        }
        init(_ model:BlameWindowModel) { self.model=model }
        func makeView()->NSScrollView {
            let table=BlameHistoryNativeTable();table.style = .plain;table.setAccessibilityLabel("Blame Log")
            table.rowHeight=24;table.intercellSpacing=NSSize(width:4,height:0);table.allowsMultipleSelection=true;table.columnAutoresizingStyle = .noColumnAutoresizing
            for (id,title,width,_) in BlameHistoryColumns.definitions {
                let column=NSTableColumn(identifier:.init(id));column.title=title;column.width=width;column.minWidth=24;column.maxWidth=10000;table.addTableColumn(column)
            }
            table.delegate=self;table.dataSource=self;table.target=self;table.doubleAction=#selector(openHistory)
            table.menu=NSMenu();table.menu?.delegate=self
            let header=BlameHistoryColumnHeader(frame:NSRect(x:0,y:0,width:1000,height:24));header.buildMenu={ [weak self] in self?.columnMenu() };table.headerView=header
            table.copySelection={ [weak self] in self?.copyHistory() };table.copyAvailable={ [weak self] in guard let self else { return false };return self.available && self.model.copyWindowAvailable(self.table?.window) };table.openSelection={ [weak self] in self?.activateHistory() ?? false };table.showContext={ [weak self] event in self?.showContext(event) }
            self.table=table
            for name in [NSWindow.willBeginSheetNotification,NSWindow.didEndSheetNotification] {
                sheetObservers.append(NotificationCenter.default.addObserver(forName:name,object:nil,queue:.main) { [weak self] notification in
                    MainActor.assumeIsolated {guard let self,let owner=notification.object as? NSWindow,owner === self.table?.window else{return};self.headerEpoch=UUID()}
                })
            }
            let scroll=NSScrollView();scroll.borderType = .bezelBorder;scroll.hasVerticalScroller=true;scroll.hasHorizontalScroller=true;scroll.documentView=table
            update();return scroll
        }
        func update() {
            guard !retired,let table else { return };updating=true;defer { updating=false }
            let font=BlameHistoryPresentation.font(preferences:model.labelDefaults)
            let colors=LogColorPreferences.load(model.labelDefaults),dates=HistoryDateSettings.load(defaults:model.labelDefaults)
            let appearanceChanged=lastFont != font || lastContext != model.historyReferenceContext || lastStyle != styleKey || lastColors != colors || lastDates != dates
            if appearanceChanged {headerEpoch=UUID()}
            let preserveViewport=historyVersion==model.historyVersion && appearanceChanged
            let oldOrigin=table.enclosingScrollView?.contentView.bounds.origin
            lastFont=font;lastContext=model.historyReferenceContext;lastStyle=styleKey;lastColors=colors;lastDates=dates
            table.rowHeight=BlameHistoryPresentation.rowHeight(preferences:model.labelDefaults)
            if historyVersion != model.historyVersion || showGraph != model.showHistoryGraph || appearanceChanged {
                historyVersion=model.historyVersion;entries=model.historyEntries;showGraph=model.showHistoryGraph;graph=model.historyGraph;layout=nil;table.reloadData()
            }
            if layout != model.historyColumns || table.tableColumns.first(where:{ $0.identifier.rawValue=="graph" })?.isHidden == showGraph {
                let value=model.historyColumns
                for (index,id) in value.order.enumerated() { if let old=table.tableColumns.firstIndex(where:{ $0.identifier.rawValue==id }),old != index { table.moveColumn(old,toColumn:index) } }
                for column in table.tableColumns {
                    let id=column.identifier.rawValue
                    column.isHidden = !value.visible.contains(id) || id=="graph" && !showGraph || id=="bugs" && !model.issueProperties.showsBugIDColumn || id=="svn" && !model.hasGitSVN
                    let fallback=BlameHistoryColumns.definitions.first { $0.0==id }!.2
                    column.width=CGFloat(value.widths[id] ?? (id=="graph" ? Double(max(65,min(240,(graph.map(\.width).max() ?? 1)*14+24))) : fallback))
                };layout=value
            }
            let selected=IndexSet(entries.enumerated().compactMap { model.selectedLogHashes.contains($0.element.hash) ? $0.offset : nil })
            if selected != table.selectedRowIndexes {
                let horizontal=table.enclosingScrollView?.contentView.bounds.minX ?? 0
                table.selectRowIndexes(selected,byExtendingSelection:false);if let first=selected.first { table.scrollRowToVisible(first) }
                if let scroll=table.enclosingScrollView { var origin=scroll.contentView.bounds.origin;origin.x=horizontal;scroll.contentView.scroll(to:origin);scroll.reflectScrolledClipView(scroll.contentView) }
            }
            table.isEnabled = !retired && model.canFind;table.allowsColumnReordering=available;table.allowsColumnResizing=available
            if preserveViewport,let oldOrigin,let scroll=table.enclosingScrollView {scroll.contentView.scroll(to:oldOrigin);scroll.reflectScrolledClipView(scroll.contentView)}
        }
        func numberOfRows(in tableView:NSTableView)->Int { entries.count }
        func text(_ id:String,_ row:Int)->String {
            guard entries.indices.contains(row) else { return "" };let entry=entries[row],dates=HistoryDateSettings.load(defaults:model.labelDefaults)
            switch id {
            case "id":return String(entries.count-row)
            case "hash":return entry.hash
            case "author":return entry.author
            case "date":return dates.format(entry.date)
            case "email":return entry.email
            case "committer":return entry.committer
            case "committerEmail":return entry.committerEmail
            case "committerDate":return dates.format(entry.committerDate)
            case "bugs":return entry.issueIDs
            case "svn":return model.svnRevisions[entry.hash] ?? ""
            case "graph":return ""
            default:return entry.logLine(fullMessage:model.fullCommitMessageOnLogLine)
            }
        }
        func tableView(_ tableView:NSTableView,viewFor column:NSTableColumn?,row:Int)->NSView? {
            guard entries.indices.contains(row),let column else { return nil };let entry=entries[row],id=column.identifier.rawValue
            if id=="graph",graph.indices.contains(row) { let cell=GraphCell();cell.graph=graph[row];cell.setAccessibilityLabel("\(entry.parents.count) parents, graph lane \(graph[row].column+1)");return cell }
            let font=BlameHistoryPresentation.font(preferences:model.labelDefaults,head:entry.isHead)
            let value=attributedText(id,row)
            let tooltip=id=="message" ? ([entry.message,entry.hash]+entry.references.map(\.name)).joined(separator:"\n") : text(id,row)
            return BlameHistoryPresentation.cell(value:value,tooltip:tooltip,font:font,message:id=="message",alignment:id=="id" ? .right:.left)
        }
        private func attributedText(_ id:String,_ row:Int)->NSAttributedString {
            guard entries.indices.contains(row) else{return NSAttributedString(string:"")}
            if id=="message" {return BlameHistoryPresentation.attributedMessage(entry:entries[row],context:model.historyReferenceContext,preferences:model.labelDefaults)}
            return BlameHistoryPresentation.attributedCaption(text(id,row),preferences:model.labelDefaults,head:entries[row].isHead)
        }

        func tableViewSelectionDidChange(_ notification:Notification) {
            guard !updating,available,let table else { return }
            let hashes=Set(table.selectedRowIndexes.compactMap { entries.indices.contains($0) ? entries[$0].hash : nil }),row=table.selectedRow
            model.focusHistory(hashes,focus:entries.indices.contains(row) ? entries[row].hash : nil)
        }
        func tableView(_ tableView:NSTableView,shouldReorderColumn column:Int,toColumn newColumn:Int)->Bool {available && column != 0 && newColumn != 0}
        func tableViewColumnDidMove(_ notification:Notification) { saveLayout() }
        func tableViewColumnDidResize(_ notification:Notification) { saveLayout() }
        func saveLayout() {
            guard !updating,available,let table else { return }
            model.saveHistoryColumns(BlameHistoryColumns(visible:model.historyColumns.visible,order:table.tableColumns.map { $0.identifier.rawValue },widths:Dictionary(uniqueKeysWithValues:table.tableColumns.map { ($0.identifier.rawValue,Double($0.width)) })))
        }
        private func width(_ column:NSTableColumn,includeHeader:Bool)->CGFloat {
            let id=column.identifier.rawValue
            let graphWidth:CGFloat=id=="graph" ? CGFloat(max(65,(graph.map(\.width).max() ?? 1)*14+24)):0
            return BlameHistoryPresentation.fittingWidth(values:entries.indices.map {attributedText(id,$0)},header:column.title,includeHeader:includeHeader,graphWidth:graphWidth,headerFont:column.headerCell.font)
        }
        func tableView(_ tableView:NSTableView,sizeToFitWidthOfColumn column:Int)->CGFloat {
            guard tableView.tableColumns.indices.contains(column) else{return 24}
            return width(tableView.tableColumns[column],includeHeader:NSEvent.modifierFlags.contains(.shift))
        }
        @MainActor private final class HeaderInvocation:NSObject {
            let owner:ObjectIdentifier,epoch:UUID,header:UUID,lifetime:UUID,version:Int,id:String,style:String
            var used=false
            init(_ model:BlameWindowModel,header:UUID,lifetime:UUID,id:String,style:String) {owner=ObjectIdentifier(model);epoch=model.historyControlEpoch;version=model.historyVersion;self.header=header;self.lifetime=lifetime;self.id=id;self.style=style}
        }
        func columnMenu()->NSMenu {
            headerEpoch=UUID()
            let menu=NSMenu();menu.autoenablesItems=false
            func item(_ id:String,_ title:String,_ selector:Selector)->NSMenuItem {
                let item=NSMenuItem(title:title,action:selector,keyEquivalent:"");item.target=self
                item.representedObject=HeaderInvocation(model,header:headerEpoch,lifetime:lifetime,id:id,style:styleKey);item.isEnabled=available;return item
            }
            menu.addItem(item("reset","Reset columns",#selector(resetHeader(_:))));menu.addItem(.separator())
            for (id,title,_,_) in BlameHistoryColumns.definitions where id != "graph" {
                if id=="bugs" && !model.issueProperties.showsBugIDColumn || id=="svn" && !model.hasGitSVN {continue}
                let entry=item(id,title,#selector(toggle(_:)));entry.state=model.historyColumns.visible.contains(id) ? .on:.off;menu.addItem(entry)
            };return menu
        }
        private func claimHeader(_ sender:NSMenuItem)->HeaderInvocation? {
            guard available,let value=sender.representedObject as? HeaderInvocation,!value.used,value.owner==ObjectIdentifier(model),value.epoch==model.historyControlEpoch,value.version==model.historyVersion,value.header==headerEpoch,value.lifetime==lifetime,value.style==styleKey else{return nil}
            value.used=true;return value
        }
        @objc func toggle(_ sender:NSMenuItem) {
            guard let value=claimHeader(sender),value.id != "graph",BlameHistoryColumns.names.contains(value.id),!(value.id=="bugs" && !model.issueProperties.showsBugIDColumn),!(value.id=="svn" && !model.hasGitSVN) else{return}
            var columns=model.historyColumns
            if columns.visible.contains(value.id) {columns.visible.remove(value.id)} else {columns.visible.insert(value.id)}
            model.saveHistoryColumns(columns)
        }
        @objc func resetHeader(_ sender:NSMenuItem) {guard claimHeader(sender) != nil else{return};reset()}
        @objc func reset() {
            guard available,let table else{return}
            let owner=model,life=lifetime,style=styleKey
            var value=BlameHistoryColumns()
            value.widths=Dictionary(uniqueKeysWithValues:table.tableColumns.map {($0.identifier.rawValue,Double(width($0,includeHeader:true)))})
            model.resetHistoryColumns(layout:value,available:{[weak self,weak owner] in guard let self,let owner else{return false};return !self.retired && self.model === owner && self.lifetime==life && self.styleKey==style})
        }
        private var contextTarget:BlameWindowModel.HistoryTarget?
        private var contextRequest=UUID()
        func showContext(_ event:NSEvent) {
            contextRequest=UUID();let request=contextRequest
            guard available,let table,let window=table.window else { return }
            let row=event.type == .keyDown ? table.selectedRow : table.row(at:table.convert(event.locationInWindow,from:nil))
            guard row>=0 else { return }
            if !table.selectedRowIndexes.contains(row) { table.selectRowIndexes(IndexSet(integer:row),byExtendingSelection:false) }
            guard let target=model.historyTarget(selected) else { return }
            model.prepareHistoryParents(target) { [weak self,weak table,weak window] _ in
                guard let self,self.contextRequest==request,let table,let window,table.window===window,window.isVisible,self.available,self.model.acceptsHistory(target),Set(self.selected.map(\.hash))==Set(target.entries.map(\.hash)),let menu=table.menu else { return }
                self.contextTarget=target;defer { self.contextTarget=nil }
                NSMenu.popUpContextMenu(menu,with:event,for:table)
            }
        }
        private class Invocation:NSObject { var used=false;let target:BlameWindowModel.HistoryTarget,command:String;init(_ target:BlameWindowModel.HistoryTarget,_ command:String) { self.target=target;self.command=command } }
        private final class ParentInvocation:NSObject {
            var used=false
            let target:BlameWindowModel.HistoryTarget,choices:[GitBlameParentComparison],action:BlameWindowModel.ParentAction
            init(_ target:BlameWindowModel.HistoryTarget,_ choices:[GitBlameParentComparison],_ action:BlameWindowModel.ParentAction) { self.target=target;self.choices=choices;self.action=action }
        }
        @objc func invokeParent(_ sender:NSMenuItem) {
            guard available,let value=sender.representedObject as? ParentInvocation,!value.used,model.acceptsHistory(value.target) else {return}
            value.used=true
            model.performHistoryParent(value.target,choices:value.choices,action:value.action,alternate:NSEvent.modifierFlags.contains(.shift))
        }
        var selected:[LogEntry] { entries.filter { model.selectedLogHashes.contains($0.hash) } }
        func menuNeedsUpdate(_ menu:NSMenu) {
            menu.removeAllItems();menu.autoenablesItems=false
            guard available,let target=contextTarget ?? model.historyTarget(selected),model.acceptsHistory(target) else { return }
            let policy=model.historyContextMenuPolicy
            func item(_ title:String,_ command:String,_ icon:MenuIcon,enabled:Bool=true,into parent:NSMenu? = nil) {
                let source:HistoryContextCommand = ["log":.showLog,"export":.export,"branch":.createBranch,"tag":.createTag,"switch":.checkout,"browse":.repositoryBrowser,"refs":.showBranches][command] ?? .copyClipboard
                guard policy.contains(source) else { return }
                let item=NSMenuItem(title:title,action:#selector(invoke(_:)),keyEquivalent:"");item.target=self;item.image=icon.contextImage(defaults:model.labelDefaults);item.representedObject=Invocation(target,command);item.isEnabled=enabled;(parent ?? menu).addItem(item)
            }
            if target.entries.count==1 {
                let choices=model.cachedHistoryParents(target),parents=Dictionary(grouping:choices,by: \.parentNumber)
                for (title,action,icon,enabled) in [("Blame previous revision",BlameWindowModel.ParentAction.previous,MenuIcon.blame,model.onPrevious != nil),("Show changes as unified diff",.unified,.unifiedDiff,model.hasHistoryUnifiedAction && model.historyHasWorkingTree),("Compare with previous revision",.compare,.compare,model.hasHistoryComparisonAction)] where !parents.isEmpty {
                    let source:HistoryContextCommand = action == .previous ? .blamePrevious : action == .compare ? .comparePrevious : .unifiedDiff
                    guard policy.contains(source), action != .unified || model.historyHasWorkingTree else { continue }
                    func command(_ number:Int,_ title:String)->NSMenuItem {
                        let result=NSMenuItem(title:title,action:#selector(invokeParent(_:)),keyEquivalent:"");result.target=self;result.image=icon.contextImage(defaults:model.labelDefaults);result.isEnabled=enabled;result.representedObject=ParentInvocation(target,parents[number]!,action)
                        if action == .compare && model.labelDefaults.bool(forKey:"DiffByDoubleClickInLog") && number==parents.keys.min() { result.attributedTitle=NSAttributedString(string:title,attributes:[.font:NSFont.boldSystemFont(ofSize:NSFont.systemFontSize)]) };return result
                    }
                    if parents.count==1,let number=parents.keys.first { menu.addItem(command(number,title)) }
                    else {
                        let item=NSMenuItem(title:title,action:nil,keyEquivalent:"");item.image=icon.contextImage(defaults:model.labelDefaults);let sub=NSMenu();sub.autoenablesItems=false
                        for (ordinal,number) in parents.keys.sorted().enumerated() { sub.addItem(command(number,parents[number]![0].historyMenuTitle(ordinal:ordinal+1))) };item.submenu=sub
                        if action == .compare && model.labelDefaults.bool(forKey:"DiffByDoubleClickInLog") { item.attributedTitle=NSAttributedString(string:title,attributes:[.font:NSFont.boldSystemFont(ofSize:NSFont.systemFontSize)]) };menu.addItem(item)
                    }
                }
                if !parents.isEmpty { menu.addItem(.separator()) }
            }
            if target.entries.count==1 {
                item("Show log","log",.log,enabled:model.onLog != nil);menu.addItem(.separator())
                item("Browse repository","browse",.repositoryBrowser,enabled:model.onHistoryBrowse != nil)
                if model.historyHasWorkingTree && target.entries[0].hash != model.historyHead { item("Switch/Checkout to this…","switch",.checkout,enabled:model.onHistorySwitch != nil) }
                item("Create branch at this version…","branch",.branch,enabled:model.onHistoryReference != nil)
                item("Create tag at this version…","tag",.tag,enabled:model.onHistoryReference != nil)
                item("Export this version…","export",.export,enabled:model.onHistoryExport != nil)
                menu.addItem(.separator())
            }
            if policy.contains(.copyClipboard) {
            let parent=NSMenuItem(title:"Copy to clipboard",action:nil,keyEquivalent:"");parent.image=MenuIcon.copy.contextImage(defaults:model.labelDefaults);let sub=NSMenu();sub.autoenablesItems=false;parent.submenu=sub;menu.addItem(parent)
            for (title,command) in [("Full log messages","details"),("Full log messages without changed paths","detailsNoPaths"),("SHA-1","hash"),("Author names and emails","authors"),("Author names","names"),("Author emails","emails"),("Subjects","subjects"),("Messages","messages")] { item(title,command,.copy,into:sub) }
            }
            if target.entries.count==1 { item("Show branches this commit is on","refs",.showBranches,enabled:model.onContainingReferences != nil) }
            var priorSeparator=true
            for value in Array(menu.items) { if value.isSeparatorItem { if priorSeparator { menu.removeItem(value) };priorSeparator=true } else { priorSeparator=false } }
            if menu.items.last?.isSeparatorItem==true { menu.removeItem(at:menu.items.count-1) }
        }
        @objc func invoke(_ sender:NSMenuItem) {
            guard available,let action=sender.representedObject as? Invocation,!action.used,model.acceptsHistory(action.target) else {return}
            action.used=true
            let entries=action.target.entries
            switch action.command {
            case "hash":model.copy(entries.map(\.hash).joined(separator:"\n"))
            case "details","detailsNoPaths":model.copyHistoryDetails(entries.map(\.hash),includePaths:action.command=="details")
            case "authors":model.copy(entries.map { "\($0.author) <\($0.email)>" }.joined(separator:"\n"))
            case "names":model.copy(entries.map(\.author).joined(separator:"\n"))
            case "emails":model.copy(entries.map(\.email).joined(separator:"\n"))
            case "subjects","messages":model.copy(LogEntry.historyClipboard(entries,subjectsOnly:action.command=="subjects"))
            default:
                guard entries.count==1,let entry=entries.first else { return }
                switch action.command {
                case "log":model.onLog?(model.path,entry.hash)
                case "export":model.onHistoryExport?(entry.hash)
                case "branch","tag":model.onHistoryReference?(action.command=="tag",entry.hash)
                case "switch":model.onHistorySwitch?(entry.hash)
                case "browse":model.onHistoryBrowse?(entry.hash)
                case "refs":model.onContainingReferences?(entry.hash)
                default:break
                }
            }
        }
        @objc func openHistory() {_ = activateHistory()}
        @discardableResult func activateHistory()->Bool {
            let selectedHashes=selected.map(\.hash)
            guard available,model.labelDefaults.bool(forKey:"DiffByDoubleClickInLog"),let first=selected.first,let target=model.historyTarget([first]),model.historyContextMenuPolicy.contains(.comparePrevious) else{return false}
            let alternate=ComparisonToolInvocation.capture,life=lifetime
            model.prepareHistoryParents(target) { [weak self] choices in
                guard let self,self.available,self.lifetime==life,self.model.acceptsHistory(target),self.selected.map(\.hash)==selectedHashes,let first=choices.map(\.parentNumber).min() else{return}
                self.model.performHistoryParent(target,choices:choices.filter {$0.parentNumber==first},action:.compare,alternate:alternate)
            }
            return true
        }
        @objc func showLog() { guard available,selected.count==1,let entry=selected.first else { return };model.onLog?(model.path,entry.hash) }
        @objc func copyHistory() {
            guard available,!selected.isEmpty,let table=table as? BlameHistoryNativeTable,table.ownsCopyFocus else{return}
            let hashes=selected.map(\.hash),identity=selected.map { Data($0.hash.utf8) }
            model.copyHistoryDetails(hashes,includePaths:true,available:{ [weak self,weak table] in
                guard let self,self.available,table?.ownsCopyFocus==true else { return false }
                return self.selected.map { Data($0.hash.utf8) } == identity
            })
        }
    }
}
@MainActor final class BlameHistoryNativeTable:NSTableView,NSMenuItemValidation {
    var copySelection:()->Void = {}
    var openSelection:()->Bool = {false}
    var copyAvailable:()->Bool = {false}
    var ownsCopyFocus:Bool {isEnabled && copyAvailable() && window?.firstResponder === self}
    private var canCopy:Bool {ownsCopyFocus && !selectedRowIndexes.isEmpty}
    var showContext:(NSEvent)->Void = { _ in }
    override func rightMouseDown(with event:NSEvent) { if isEnabled { showContext(event) } }
    override func mouseDown(with event:NSEvent) { if event.modifierFlags.contains(.control) { if isEnabled { showContext(event) };return };super.mouseDown(with:event) }
    override func menu(for event:NSEvent)->NSMenu? {
        guard isEnabled else { return nil };let row=row(at:convert(event.locationInWindow,from:nil));guard row>=0 else { return nil }
        if !selectedRowIndexes.contains(row) { selectRowIndexes(IndexSet(integer:row),byExtendingSelection:false) };menu?.update();return menu
    }
    override func keyDown(with event:NSEvent) { if BlameWindowController.routeCommandKey(event,from:window) {return};if isEnabled,event.keyCode==109,event.modifierFlags.contains(.shift) { showContext(event);return };if isEnabled,(event.keyCode==36 || event.keyCode==76),!event.modifierFlags.contains(.control),ComparisonToolInvocation.$alternate.withValue(event.modifierFlags.contains(.shift),operation:{openSelection()}) {return};super.keyDown(with:event) }
    override func performKeyEquivalent(with event:NSEvent)->Bool {
        if ownsCopyFocus,event.modifierFlags.intersection([.command,.control,.option]) == .command,event.charactersIgnoringModifiers?.lowercased()=="c" { if canCopy{copySelection()};return true };return super.performKeyEquivalent(with:event)
    }
    @objc func copy(_ sender:Any?){guard canCopy else{return};copySelection()}
    func validateMenuItem(_ item:NSMenuItem)->Bool{item.action == NSSelectorFromString("copy:") ? canCopy:isEnabled}
}
@MainActor final class BlameHistoryColumnHeader:NSTableHeaderView {
    var buildMenu:()->NSMenu? = { nil }
    override func menu(for event:NSEvent)->NSMenu? { buildMenu() }
}

enum BlameMarginField: String, CaseIterable {
    case logID = "ShowLogID", author = "ShowAuthor", date = "ShowDate", filename = "ShowFilename", original = "ShowOriginalLineNumber"
    var title: String {
        switch self { case .logID: return "Show log ID"; case .author: return "Show author"; case .date: return "Show date"; case .filename: return "Show filename"; case .original: return "Show original line number" }
    }
}

private struct BlameTable: NSViewRepresentable {
    @ObservedObject var model: BlameWindowModel
    @Environment(\.colorScheme) private var colorScheme
    func makeCoordinator() -> Coordinator { Coordinator(model) }
    func makeNSView(context: Context) -> BlameSourceContainer {
        let table = BlameTableView(); table.style = .plain; table.delegate = context.coordinator; table.dataSource = context.coordinator
        table.onMarginClick = { [weak coordinator = context.coordinator] row, additive in coordinator?.model.highlight(row, additive: additive) }
        table.contextMenuAvailable={ [weak model] in model?.canFind==true }
        table.onContextMenu={ [weak coordinator=context.coordinator,weak table] row,event in
            guard let table else {return};coordinator?.showContext(row:row,event:event,in:table)
        }
        table.onHover = { [weak coordinator = context.coordinator] row in
            guard let model = coordinator?.model else { return }
            let number = row.map { $0 + 1 }
            if model.hoveredLine != number { model.hoveredLine = number }
        }
        table.rowHeight = 22; table.intercellSpacing = .zero
        table.headerView = nil
        table.columnAutoresizingStyle = .noColumnAutoresizing; table.allowsMultipleSelection = false
        table.target = context.coordinator; table.doubleAction = #selector(Coordinator.showLog)
        for (id, title, width) in [("revision", "Revision", 90.0), ("author", "Author", 130), ("date", "Date", 145), ("filename", "Filename", 180), ("original", "Original line", 65), ("line", "Line", 45)] {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(id)); column.title = title; column.width = width; column.minWidth = 40; table.addTableColumn(column)
        }
        table.setAccessibilityLabel("Annotated source");table.setAccessibilityIdentifier("BlameAttributionTable")
        let menu = NSMenu(); menu.delegate = context.coordinator; table.menu = menu
        context.coordinator.table = table
        let container = BlameSourceContainer()
        container.editor.delegate = context.coordinator
        container.editor.contextMenuAvailable={ [weak model] in model?.canFind==true }
        container.editor.onContextMenu={ [weak coordinator=context.coordinator,weak editor=container.editor] row,event in
            guard let editor else {return};coordinator?.showContext(row:row,event:event,in:editor)
        }
        context.coordinator.container = container
        let scroll = container.scroll
        scroll.hasVerticalScroller = false; scroll.hasHorizontalScroller = true; scroll.autohidesScrollers = true; scroll.documentView = table
        container.locator.table = table
        container.installNavigation(model)
        model.firstVisibleSourceRow = { [weak table] in
            guard let table else { return nil }
            let rows = table.rows(in: visibleBlameSourceRect(table))
            return rows.location == NSNotFound || rows.length == 0 ? nil : rows.location
        }
        model.scrollSourceRowToTop = { [weak table, weak scroll] row in
            guard let table, let scroll, row >= 0, row < table.numberOfRows else { return }
            let obscuredHeight = visibleBlameSourceRect(table).minY - table.visibleRect.minY
            var origin = scroll.contentView.bounds.origin
            origin.y = max(0, table.rect(ofRow: row).minY - obscuredHeight)
            scroll.contentView.scroll(to: origin); scroll.reflectScrolledClipView(scroll.contentView)
        }
        return container
    }
    func updateNSView(_ container: BlameSourceContainer, context: Context) {
        let coordinator = context.coordinator
        // Closing and SwiftUI detachment are separate events. A queued update
        // must not measure/reload the old table after the owner has retired.
        guard !model.retired, !container.retired, let table = coordinator.table else { return }
        coordinator.model = model; coordinator.updating = true
        for column in table.tableColumns {
            switch column.identifier.rawValue {
            case "author": column.isHidden = !model.marginFields.contains(.author)
            case "date": column.isHidden = !model.marginFields.contains(.date)
            case "filename": column.isHidden = !model.marginFields.contains(.filename)
            case "original": column.isHidden = !model.marginFields.contains(.original)
            default: break
            }
        }
        if coordinator.revision != model.snapshot?.revision || coordinator.presentation != model.presentation || coordinator.zoomLevel != model.zoomLevel {
            coordinator.revision = model.snapshot?.revision
            coordinator.presentation = model.presentation
            coordinator.zoomLevel = model.zoomLevel
            table.rowHeight = model.sourceLineHeight
        }
        coordinator.updateColumnMetrics(table)
        container.installNavigation(model)
        let changedRows = container.updateSource(model)
        let dataKey = "\(model.historyVersion):\(model.sourceFont.fontName):\(model.effectiveFontSize):\(model.attributionDateKey):" + model.marginFields.map(\.rawValue).sorted().joined(separator:",")
        let viewportOrigin = container.scroll.contentView.bounds.origin
        if coordinator.attributionKey != dataKey {
            coordinator.attributionKey = dataKey; table.reloadData(); container.attributionReloaded()
        } else {
            // Repaint existing visible cells only. Offscreen rows obtain current
            // metadata and colors from the delegate when AppKit creates them.
            let dark = table.effectiveAppearance.bestMatch(from:[.aqua,.darkAqua]) == .darkAqua
            for row in changedRows where model.lines.indices.contains(row) {
                if let rowView = table.rowView(atRow:row,makeIfNecessary:false) as? BlameRowView {
                    let line=model.lines[row], selected=[1,2].contains(model.highlightKind(line))
                    rowView.ageColor=blameSourceBackground(model,line:line,dark:dark);rowView.revisionHighlighted=selected;rowView.needsDisplay=true
                    for column in table.tableColumns.indices {
                        if let cell=table.view(atColumn:column,row:row,makeIfNecessary:false) as? BlameMetadataCell {
                            cell.label.textColor=selected ? .alternateSelectedControlTextColor:.labelColor
                        }
                    }
                }
            }
        }
        table.setFrameSize(NSSize(width:table.tableColumns.filter { !$0.isHidden }.reduce(CGFloat(0)) { $0 + $1.width },height:table.frame.height))
        container.scroll.contentView.scroll(to: viewportOrigin)
        container.scroll.reflectScrolledClipView(container.scroll.contentView)
        if let number = model.selection {
            let row = number - 1
            if table.selectedRow != row { table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false); table.scrollRowToVisible(row) }
        } else { table.deselectAll(nil) }
        if coordinator.navigationSerial != model.sourceNavigationSerial, let request = model.sourceNavigation {
            coordinator.navigationSerial = model.sourceNavigationSerial
            container.selectSourceLine(request.line, wholeLine: request.wholeLine, includeBreak: request.includeBreak)
        }
        container.locator.presentation = model.presentation
        if coordinator.locatorHistoryVersion != model.historyVersion {
            coordinator.locatorHistoryVersion=model.historyVersion
            container.locator.ranks = model.lines.map { model.ranks[$0.hash] }
        }
        container.locator.historyCount = model.historyCount
        container.locator.colorAge = model.colorAge
        container.locator.refreshViewport()
        coordinator.updating = false
    }
    static func dismantleNSView(_ container: BlameSourceContainer, coordinator: Coordinator) {
        container.retire(); coordinator.model.selectedSourceText = nil
        coordinator.model.firstVisibleSourceRow = nil; coordinator.model.scrollSourceRowToTop = nil
    }
    @MainActor final class Coordinator: NSObject, NSTableViewDelegate, NSTableViewDataSource, NSMenuDelegate, NSTextViewDelegate {
        var model: BlameWindowModel
        weak var table: NSTableView?
        weak var container: BlameSourceContainer?
        var navigationSerial = 0
        var updating = false
        var revision: String?
        var presentation: GitBlamePresentation?
        var zoomLevel: Int?
        private var metricsKey = ""
        var attributionKey = "", locatorHistoryVersion = -1
        init(_ model: BlameWindowModel) { self.model = model }
        func updateColumnMetrics(_ table: NSTableView) {
            let key = "\(model.historyVersion):\(model.sourceFont.fontName):\(model.effectiveFontSize):\(model.attributionDateKey):" + model.marginFields.map(\.rawValue).sorted().joined(separator:",")
            guard metricsKey != key else { return };metricsKey = key
            let font = model.sourceFont
            func width(_ values: Set<String>) -> CGFloat {
                values.reduce(CGFloat(0)) { max($0, ($1 as NSString).size(withAttributes:[.font:font]).width) } + 12
            }
            for column in table.tableColumns {
                guard !column.isHidden else {continue}
                let id = column.identifier.rawValue
                let measured: CGFloat
                switch id {
                case "line":
                    let digits = max(2,String(max(1,model.lines.count)).count + 1)
                    measured = width([String(repeating:"8",count:digits)])
                case "revision": measured = width([model.marginFields.contains(.logID) ? String(max(1,model.historyCount)) : "ffffffff"])
                case "author": measured = width(Set(model.lines.map(\.author)))
                case "filename": measured = width(Set(model.lines.map(\.filename)))
                case "original": measured = width([String(model.lines.map(\.originalLine).max() ?? 1)])
                case "date": measured = width(Set(Set(model.lines.map(\.date)).map { model.attributionDate($0) }))
                default: continue
                }
                column.minWidth=24;column.maxWidth=1_000_000
                column.width=max(24,measured)
            }
        }
        func numberOfRows(in tableView: NSTableView) -> Int { model.lines.count }
        func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
            guard let rectangles = container?.editor.rowRectangles, rectangles.indices.contains(row) else { return tableView.rowHeight }
            return rectangles[row].height
        }
        func tableViewSelectionDidChange(_ notification: Notification) {
            guard !updating, let table else { return }; model.selection = table.selectedRow >= 0 ? table.selectedRow + 1 : nil
            if table.selectedRow >= 0 { container?.selectSourceLine(table.selectedRow + 1, wholeLine: true) }
        }
        func textViewDidChangeSelection(_ notification: Notification) {
            guard !updating, let container, !container.settingSelection,
                  let row = container.sourceRow(at: container.editor.selectedRange().location) else { return }
            if model.selection != row + 1 { model.selection = row + 1 }
        }
        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            guard row < model.lines.count else { return nil }; let line = model.lines[row]
            let id = tableColumn?.identifier.rawValue ?? "source"
            let value = model.marginText(id, row:row)
            let label = NSTextField(labelWithString: value); label.font = model.sourceFont
            if id == "source" { label.attributedStringValue = model.displayedSource(line) }
            label.lineBreakMode = .byClipping; label.maximumNumberOfLines = 1
            label.toolTip = model.revisionToolTip(for:row)
            label.textColor = [1, 2].contains(model.highlightKind(line)) ? .alternateSelectedControlTextColor : .labelColor
            let cell = BlameMetadataCell(label:label, lineHeight:tableView.rowHeight)
            return cell
        }
        func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
            let view = BlameRowView()
            guard row < model.lines.count else { return view }
            let dark = tableView.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            view.ageColor = blameSourceBackground(model, line:model.lines[row], dark:dark)
            view.revisionHighlighted = [1, 2].contains(model.highlightKind(model.lines[row]))
            return view
        }
        private var contextTarget:BlameWindowModel.SourceTarget?
        private var contextParents:[GitBlameParentComparison]=[]
        private var contextRequest=UUID()
        private final class SourceInvocation:NSObject {
            let target:BlameWindowModel.SourceTarget,command:String,choice:GitBlameParentComparison?
            var used=false
            init(_ target:BlameWindowModel.SourceTarget,_ command:String,_ choice:GitBlameParentComparison? = nil) {self.target=target;self.command=command;self.choice=choice}
        }
        private func selectedText() -> String {
            guard let editor=container?.editor else {return ""};let text=editor.string as NSString
            return editor.selectedRanges.map(\.rangeValue).filter{$0.location != NSNotFound && $0.length>0 && NSMaxRange($0)<=text.length}.map{text.substring(with:$0)}.joined(separator:"\n")
        }
        func showContext(row:Int,event:NSEvent,in view:NSView) {
            contextRequest=UUID();let request=contextRequest
            guard let target=model.sourceTarget(number:row+1,selectionText:selectedText()) else {return}
            model.prepareParentMenu(number:row+1) { [weak self,weak view] in
                guard let self,self.contextRequest==request,let view,view.window?.isVisible==true,self.model.acceptsSource(target),self.model.selection==target.line.number,let menu=self.table?.menu else {return}
                self.contextTarget=target;self.contextParents=self.model.parentChoices;self.menuNeedsUpdate(menu)
                let rectangle=(view as? NSTableView)?.rect(ofRow:row) ?? self.container.flatMap { $0.editor.rowRectangles.indices.contains(row) ? $0.editor.rowRectangles[row]:nil } ?? .zero
                let point=event.type == .keyDown ? NSPoint(x:max(view.visibleRect.minX+8,rectangle.minX),y:rectangle.maxY):view.convert(event.locationInWindow,from:nil)
                if let present=self.model.presentSourceMenu {present(menu,point,view)}
                else if event.type == .keyDown {menu.popUp(positioning:nil,at:point,in:view)}
                else {NSMenu.popUpContextMenu(menu,with:event,for:view)}
            }
        }
        func menuDidClose(_ menu:NSMenu) {contextTarget=nil;contextParents=[]}
        func menuNeedsUpdate(_ menu:NSMenu) {
            menu.removeAllItems();menu.autoenablesItems=false
            guard let target=contextTarget ?? model.selection.flatMap({model.sourceTarget(number:$0,selectionText:selectedText())}),model.acceptsSource(target) else {return}
            let choices=contextTarget == nil ? model.parentChoices:contextParents
            func item(_ title:String,_ command:String,_ icon:MenuIcon?,choice:GitBlameParentComparison? = nil,enabled:Bool=true,into parent:NSMenu? = nil) {
                let value=NSMenuItem(title:title,action:#selector(invokeSource(_:)),keyEquivalent:"");value.target=self
                value.image=icon?.contextImage(defaults:model.labelDefaults);value.representedObject=SourceInvocation(target,command,choice);value.isEnabled=enabled;(parent ?? menu).addItem(value)
                if command=="compare",model.labelDefaults.bool(forKey:"DiffByDoubleClickInLog"),choice?.id==choices.first?.id { value.attributedTitle=NSAttributedString(string:title,attributes:[.font:NSFont.boldSystemFont(ofSize:NSFont.systemFontSize)]) }
            }
            if contextTarget==nil && model.loadingParents {let value=NSMenuItem(title:"Reading previous revisions…",action:nil,keyEquivalent:"");value.isEnabled=false;menu.addItem(value)}
            else if !choices.isEmpty {
                for (title,command,icon,enabled) in [("Blame previous revision","previous",MenuIcon.blame,model.onPrevious != nil),("Compare with previous revision","compare",.compare,model.hasHistoryComparisonAction),("Show changes as unified diff","unified",.unifiedDiff,model.hasHistoryUnifiedAction)] {
                    if choices.count==1 {item(title,command,icon,choice:choices[0],enabled:enabled)}
                    else {
                        let parent=NSMenuItem(title:title,action:nil,keyEquivalent:"");parent.image=icon.contextImage(defaults:model.labelDefaults);parent.isEnabled=enabled
                        if command=="compare",model.labelDefaults.bool(forKey:"DiffByDoubleClickInLog") { parent.attributedTitle=NSAttributedString(string:title,attributes:[.font:NSFont.boldSystemFont(ofSize:NSFont.systemFontSize)]) }
                        let sub=NSMenu();sub.autoenablesItems=false;parent.submenu=sub;menu.addItem(parent)
                        for (ordinal,choice) in choices.enumerated() {item("Parent \(ordinal+1)",command,icon,choice:choice,enabled:enabled,into:sub)}
                    }
                }
            }
            item("Show log","log",.log,enabled:model.onLog != nil);menu.addItem(.separator())
            item("Copy SHA-1 to clipboard","hash",.copy);item("Copy log to clipboard","details",.copy)
            menu.addItem(.separator());item("Copy source line","line",.copy)
            item("Copy","selection",.copy,enabled:!target.selectionText.isEmpty);item("Select All","all",nil,enabled:!model.lines.isEmpty)
        }
        @objc func invokeSource(_ sender:NSMenuItem) {
            guard sender.isEnabled,let action=sender.representedObject as? SourceInvocation,!action.used,model.acceptsSource(action.target) else {return}
            action.used=true;let line=action.target.line
            switch action.command {
            case "log":model.onLog?(line.filename,line.hash)
            case "hash":model.copy(line.hash)
            case "details":model.copyLogMessage(line.hash)
            case "line":model.copy(line.source)
            case "selection":model.copy(action.target.selectionText)
            case "all":container?.editor.selectAll(nil)
            default:
                guard let choice=action.choice,let history=model.sourceParentTarget(line.hash) else {return}
                let kind:BlameWindowModel.ParentAction=action.command=="previous" ? .previous:action.command=="compare" ? .compare:.unified
                model.performHistoryParent(history,choices:[choice],action:kind,alternate:ComparisonToolInvocation.capture,originalLine:line.originalLine)
            }
        }
        @objc func showLog() {guard model.canFind,let line=model.selectedLine else {return};model.showLog(line)}

    }
}

private func blameKeyboardContextEvent(_ view:NSView)->NSEvent? {
    NSEvent.keyEvent(with:.keyDown,location:.zero,modifierFlags:.shift,timestamp:ProcessInfo.processInfo.systemUptime,windowNumber:view.window?.windowNumber ?? 0,context:nil,characters:"",charactersIgnoringModifiers:"",isARepeat:false,keyCode:109)
}
private final class BlameTableView: NSTableView {
    var contextMenuAvailable:()->Bool = {true}
    @discardableResult private func showKeyboardContext() -> Bool {
        guard window?.isVisible==true,contextMenuAvailable(),selectedRow>=0,selectedRow<numberOfRows,let event=blameKeyboardContextEvent(self) else {return false}
        scrollRowToVisible(selectedRow);onContextMenu(selectedRow,event);return true
    }
    override func accessibilityPerformShowMenu()->Bool {showKeyboardContext()}
    override func keyDown(with event:NSEvent) {
        if BlameWindowController.routeCommandKey(event,from:window) {return}
        if event.keyCode==109,event.modifierFlags.intersection([.shift,.command,.control,.option]) == .shift,showKeyboardContext() {return}
        super.keyDown(with:event)
    }
    var onMarginClick: (Int, Bool) -> Void = { _, _ in }
    var onContextMenu: (Int, NSEvent) -> Void = { _, _ in }
    var onHover: (Int?) -> Void = { _ in }
    private var hoverTracking: NSTrackingArea?
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverTracking { removeTrackingArea(hoverTracking) }
        let tracking = NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self)
        addTrackingArea(tracking); hoverTracking = tracking
    }
    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil), row = row(at: point), column = column(at: point)
        if event.modifierFlags.contains(.control) { onContextMenu(row, event); return }
        super.mouseDown(with: event)
        if event.clickCount == 1, row >= 0, tableColumns.indices.contains(column), tableColumns[column].identifier.rawValue != "line" { onMarginClick(row, event.modifierFlags.contains(.command)) }
    }
    override func rightMouseDown(with event: NSEvent) {
        onContextMenu(row(at: convert(event.locationInWindow, from: nil)), event)
    }
    override func mouseMoved(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil), row = row(at: point), column = column(at: point)
        onHover(row >= 0 && tableColumns.indices.contains(column) && tableColumns[column].identifier.rawValue != "line" ? row : nil)
        super.mouseMoved(with: event)
    }
    override func mouseExited(with event: NSEvent) { onHover(nil); super.mouseExited(with: event) }
}

private final class BlameMetadataCell: NSView {
    let label: NSTextField
    let lineHeight: CGFloat
    init(label: NSTextField, lineHeight: CGFloat) {
        self.label = label; self.lineHeight = lineHeight
        super.init(frame:.zero); addSubview(label)
    }
    required init?(coder:NSCoder) { fatalError("init(coder:) is not supported") }
    override func layout() {
        super.layout()
        // Attribution appears on the first visual line of a wrapped source row.
        label.frame = NSRect(x:0,y:max(0,bounds.height-lineHeight),width:bounds.width,height:lineHeight)
    }
}

private func visibleBlameSourceRect(_ table: NSTableView) -> NSRect {
    var viewport = table.visibleRect
    if let header = table.headerView {
        let headerRect = table.convert(header.bounds, from: header)
        let overlap = viewport.intersection(headerRect)
        if !overlap.isNull, overlap.height > 0 {
            let bottom = viewport.maxY
            viewport.origin.y = max(viewport.minY, headerRect.maxY)
            viewport.size.height = max(0, bottom - viewport.minY)
        }
    }
    return viewport
}

private final class BlameSourceScrollView: NSScrollView {
    var onScroll: () -> Void = {}
    var onZoom: (Int) -> Void = { _ in }
    private var wheelRemainder: CGFloat = 0, pinchRemainder: CGFloat = 0
    override func scrollWheel(with event: NSEvent) {
        let flags = event.modifierFlags.intersection([.command,.control,.option,.shift])
        guard flags == .command || flags == .control else {wheelRemainder=0;super.scrollWheel(with:event);return}
        guard event.momentumPhase.isEmpty else {wheelRemainder=0;return}
        if event.phase == .began || event.phase == .cancelled {wheelRemainder=0}
        let delta = event.scrollingDeltaY
        guard delta.isFinite else {return}
        if event.hasPreciseScrollingDeltas {
            wheelRemainder = max(-120,min(120,wheelRemainder + delta))
            let steps = Int(wheelRemainder / 20)
            if steps != 0 {wheelRemainder -= CGFloat(steps)*20;onZoom(steps)}
        } else if delta != 0 {onZoom(delta > 0 ? 1 : -1)}
        if event.phase == .ended || event.phase == .cancelled {wheelRemainder=0}
    }
    override func magnify(with event: NSEvent) {
        if event.phase == .began || event.phase == .cancelled {pinchRemainder=0}
        guard event.magnification.isFinite else {return}
        pinchRemainder = max(-0.6,min(0.6,pinchRemainder + event.magnification))
        let steps=Int(pinchRemainder / 0.1)
        if steps != 0 {pinchRemainder -= CGFloat(steps)*0.1;onZoom(steps)}
        if event.phase == .ended || event.phase == .cancelled {pinchRemainder=0}
    }
    override func reflectScrolledClipView(_ clipView: NSClipView) {
        super.reflectScrolledClipView(clipView); onScroll()
    }
}

struct BlameRenderWork: Equatable {
    var documentRebuilds = 0, baseStylePasses = 0, geometryRebuilds = 0
    var highlightRowsPainted = 0, foregroundRowsStyled = 0, attributionReloads = 0
}
@MainActor protocol BlameRenderWorkProviding {
    var renderWork: BlameRenderWork { get }
    func renderedRowBackground(_ row: Int) -> NSColor?
    var locatorDrawingCount: Int { get }
}

private final class BlameSourceContainer: NSView, BlameRenderWorkProviding {
    let scroll = BlameSourceScrollView()
    let locator = BlameLocatorView()
    let sourceScroll = BlameSourceScrollView()
    let editor = BlameSourceTextView()
    private let sourceHeading = NSTextField(labelWithString: "Source")
    private let annotationHeading = NSView()
    private var ranges: [NSRange] = []
    private var lineLengths: [Int] = []
    private var synchronizing = false
    private(set) var settingSelection = false
    private(set) var retired = false
    private var renderedRevision: String?
    private var renderedEncoding: GitBlameEncoding?
    private var renderedPresentation: GitBlamePresentation?
    private var renderedZoomLevel: Int?
    private var renderedContents: Data?
    private var renderedLineCount = -1
    private(set) var renderWork = BlameRenderWork()
    var locatorDrawingCount: Int { locator.drawingCount }
    func attributionReloaded() { if !retired { renderWork.attributionReloads += 1 } }
    func renderedRowBackground(_ row: Int) -> NSColor? { editor.rowColors.indices.contains(row) ? editor.rowColors[row] : nil }
    private var geometryGeneration = 0, measuredGeneration = -1
    private var measuredWidth: CGFloat?
    private var baseStyle: NSAttributedString?
    private var paintedSyntaxGeneration = -1, paintedSyntaxRevision = -1
    private var syntaxRevision = 0
    private var paintedDark: Bool?, paintedPalette: GitBlamePresentation?, paintedAge: Bool?
    private var paintedHistoryVersion = -1
    private struct Highlights: Equatable {
        var selected: Set<String>, selectedAuthor: String?, stickyHash: String?, stickyAuthor: String?
        var hoverHash: String?, hoverAuthor: String?
    }
    private var paintedHighlights: Highlights?
    private var hashRows: [String: IndexSet] = [:], authorRows: [String: IndexSet] = [:]
    private var paintedKinds: [Int] = []
    private var headingColumns: [String] = []
    private var gutterWidth: CGFloat = 270
    private var syntaxText: String?
    private var syntaxPath = ""
    private var syntaxTabs = 0
    private var syntaxResult: BlameSyntaxResult?
    private var syntaxToken: OperationCancellation?
    private var syntaxTask: Task<Void,Never>?
    private var syntaxGeneration = 0
    private var wrapped = false
    private var reflowing = false
    private var desiredSourceWidth: CGFloat = 300
    private struct ViewportAnchor {let row:Int,within:CGFloat,x:CGFloat}
    private var pendingReflowAnchor: ViewportAnchor?
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        addSubview(locator); addSubview(scroll); addSubview(sourceScroll)
        addSubview(annotationHeading); addSubview(sourceHeading)
        sourceHeading.font = .systemFont(ofSize: 11)
        annotationHeading.wantsLayer = true; annotationHeading.layer?.masksToBounds = true
        editor.isEditable = false; editor.isSelectable = true; editor.isRichText = false
        editor.isAutomaticQuoteSubstitutionEnabled = false; editor.isAutomaticDashSubstitutionEnabled = false
        editor.isAutomaticTextReplacementEnabled = false; editor.isAutomaticSpellingCorrectionEnabled = false
        editor.isContinuousSpellCheckingEnabled = false; editor.isGrammarCheckingEnabled = false
        editor.isHorizontallyResizable = true; editor.isVerticallyResizable = true
        editor.autoresizingMask = []
        editor.textContainerInset = NSSize(width: 6, height: 0)
        editor.textContainer?.widthTracksTextView = false; editor.textContainer?.heightTracksTextView = false
        editor.textContainer?.containerSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        editor.layoutManager?.usesFontLeading = false
        editor.setAccessibilityLabel("Blame source text")
        sourceScroll.hasVerticalScroller = true; sourceScroll.hasHorizontalScroller = true
        sourceScroll.autohidesScrollers = true; sourceScroll.documentView = editor
        sourceScroll.setAccessibilityIdentifier("BlameSourceScroll")
        scroll.setAccessibilityIdentifier("BlameAttributionScroll")
        locator.scroll = scroll
        scroll.onScroll = { [weak self] in self?.synchronize(fromSource: false) }
        sourceScroll.onScroll = { [weak self] in self?.synchronize(fromSource: true) }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    func retire() {
        retired = true; editor.delegate = nil; editor.onContextMenu = { _,_ in }
        syntaxGeneration += 1; syntaxToken?.cancel(); syntaxTask?.cancel()
        editor.retired = true; editor.isSelectable = false
        baseStyle=nil;hashRows=[:];authorRows=[:]
        editor.keyboardContextRow=nil;editor.contextMenuAvailable={false};editor.copyAvailable={false};editor.publishCopy={_ in};editor.onOpen = {};editor.onFind = {}; editor.onFindNext = { _ in }; editor.onGoTo = {}
        editor.tooltipForRow={_ in nil};editor.removeAllToolTips()
        scroll.onZoom={_ in};sourceScroll.onZoom={_ in}
        scroll.onScroll = {}; sourceScroll.onScroll = {}
    }
    func installNavigation(_ model: BlameWindowModel) {
        guard !retired else { return }
        editor.tooltipForRow={ [weak model] row in model?.revisionToolTip(for:row) }
        let zoom: (Int)->Void = { [weak self,weak model] steps in
            guard let self,let model,!self.retired,let window=self.window,
                  let owner=BlameWindowController.focusedOwner(window),owner.model === model,
                  owner.commandKeyWindow() === window else {return}
            for _ in 0..<abs(steps) {if steps>0 {model.zoomIn()}else{model.zoomOut()}}
        }
        scroll.onZoom=zoom;sourceScroll.onZoom=zoom
        model.selectedSourceText = { [weak self] in
            guard let self, !self.retired else { return "" }
            let range = self.editor.selectedRange(), text = self.editor.string as NSString
            guard range.location != NSNotFound, NSMaxRange(range) <= text.length else { return "" }
            return text.substring(with: range)
        }
        editor.keyboardContextRow={ [weak self] in guard let self,!self.retired else {return nil};return self.sourceRow(at:self.editor.selectedRange().location) }
        model.retireSourceView = { [weak self] in self?.retire() }
        editor.onOpen = { [weak model] in model?.onOpenDocument?() }
        editor.onFind = { [weak model] in model?.onFind?() }
        editor.onFindNext = { [weak model] previous in model?.findLine(previous: previous) }
        editor.onGoTo = { [weak model] in model?.onGoTo?() }
        editor.copyAvailable={ [weak model,weak editor=editor] in model?.canFind==true && model?.copyWindowAvailable(editor?.window)==true }
        editor.publishCopy={ [weak model] text in model?.copy(text) }
        model.firstVisibleSourceRow = { [weak self] in
            guard let self, !self.ranges.isEmpty, !self.retired else { return nil }
            return self.editor.sourceRow(atY:self.sourceScroll.contentView.bounds.minY)
        }
        model.scrollSourceRowToTop = { [weak self] row in
            guard let self, !self.retired, self.ranges.indices.contains(row) else { return }
            var origin = self.sourceScroll.contentView.bounds.origin
            guard self.editor.rowRectangles.indices.contains(row) else { return }
            origin.y = self.editor.rowRectangles[row].minY
            self.sourceScroll.contentView.scroll(to: self.sourceScroll.contentView.constrainBoundsRect(NSRect(origin: origin, size: self.sourceScroll.contentView.bounds.size)).origin)
            self.sourceScroll.reflectScrolledClipView(self.sourceScroll.contentView)
        }
    }
    func sourceRow(at offset: Int) -> Int? {
        guard !retired, !ranges.isEmpty, offset >= 0, offset <= (editor.string as NSString).length else { return nil }
        var low = 0, high = ranges.count
        while low < high {
            let middle = (low + high) / 2
            if ranges[middle].location <= offset { low = middle + 1 } else { high = middle }
        }
        return max(0, low - 1)
    }
    func selectSourceLine(_ number: Int, wholeLine: Bool, includeBreak: Bool = false) {
        let row = number - 1
        guard !retired, ranges.indices.contains(row) else { return }
        let range = NSRange(location: ranges[row].location, length: wholeLine ? (includeBreak ? ranges[row].length : lineLengths[row]) : 0)
        settingSelection = true; editor.setSelectedRange(range); settingSelection = false
        editor.window?.makeFirstResponder(editor)
        editor.scrollRangeToVisible(range)
    }
    @discardableResult func updateSource(_ model: BlameWindowModel) -> IndexSet {
        guard !retired else { return [] }
        if let table = scroll.documentView as? NSTableView {
            gutterWidth = table.tableColumns.filter { !$0.isHidden }.reduce(CGFloat(0)) { $0 + $1.width }
            let columns = table.tableColumns.filter { !$0.isHidden }.map { $0.identifier.rawValue + ":" + String(Double($0.width)) + ":" + (model.marginFields.contains(.logID) ? "id" : "hash") }
            if columns != headingColumns {
                headingColumns = columns
                annotationHeading.subviews.forEach { $0.removeFromSuperview() }
                for column in table.tableColumns where !column.isHidden {
                    let label = NSTextField(labelWithString:column.identifier.rawValue == "revision" && model.marginFields.contains(.logID) ? "Log ID" : column.title)
                    label.font = .systemFont(ofSize:11); label.maximumNumberOfLines = 1
                    label.frame.size = NSSize(width:column.width,height:22); annotationHeading.addSubview(label)
                }
                layoutAnnotationHeading(); needsLayout = true
            }
        }
        let changed = renderedRevision != model.snapshot?.revision || renderedEncoding != model.snapshot?.encoding ||
            renderedPresentation?.fontName != model.presentation.fontName || renderedPresentation?.fontSize != model.presentation.fontSize || renderedPresentation?.tabSize != model.presentation.tabSize || renderedZoomLevel != model.zoomLevel || renderedContents != model.snapshot?.contents ||
            renderedLineCount != model.lines.count || wrapped != model.wrapLongLines
        if changed,let row=editor.sourceRow(atY:sourceScroll.contentView.bounds.minY),editor.rowRectangles.indices.contains(row) {
            let origin=sourceScroll.contentView.bounds.origin
            pendingReflowAnchor=ViewportAnchor(row:row,within:origin.y-editor.rowRectangles[row].minY,x:origin.x)
        }
        wrapped = model.wrapLongLines
        sourceScroll.hasHorizontalScroller = !wrapped
        editor.isHorizontallyResizable = !wrapped
        editor.textContainer?.widthTracksTextView = wrapped
        let selected = editor.selectedRange()
        if changed {
            renderWork.documentRebuilds += 1
            renderedRevision = model.snapshot?.revision; renderedEncoding = model.snapshot?.encoding
            renderedPresentation = model.presentation; renderedLineCount = model.lines.count
            renderedZoomLevel=model.zoomLevel;renderedContents=model.snapshot?.contents
            editor.lineHeight = model.sourceLineHeight
            var contents = ""; ranges = []; lineLengths = []
            let decoded = model.snapshot.flatMap { $0.encoding.decodeText($0.contents) }
            let trailingBreak = decoded?.hasSuffix("\n") == true
            var location = 0
            for (row, line) in model.lines.enumerated() {
                let text = model.displayedSource(line).string
                let count = (text as NSString).length
                let separator = row < model.lines.count - 1 || trailingBreak ? "\n" : ""
                ranges.append(NSRange(location: location, length: count + separator.utf16.count)); lineLengths.append(count)
                contents += text + separator; location += count + separator.utf16.count
            }
            let sameText = editor.string == contents
            let paragraph = NSMutableParagraphStyle()
            paragraph.minimumLineHeight = editor.lineHeight; paragraph.maximumLineHeight = editor.lineHeight
            paragraph.tabStops = []
            paragraph.defaultTabInterval = (" " as NSString).size(withAttributes: [.font:model.sourceFont]).width * CGFloat(model.presentation.tabSize)
            paragraph.lineBreakMode = wrapped ? .byWordWrapping : .byClipping
            settingSelection = true
            editor.textStorage?.setAttributedString(NSAttributedString(string:contents, attributes:[.font:model.sourceFont, .paragraphStyle:paragraph, .foregroundColor:NSColor.labelColor]))
            if sameText, selected.location != NSNotFound, NSMaxRange(selected) <= location { editor.setSelectedRange(selected) }
            else { editor.setSelectedRange(NSRange(location:0,length:0)) }
            settingSelection = false
        }
        requestSyntax(model)
        let dark = effectiveAppearance.bestMatch(from:[.aqua,.darkAqua]) == .darkAqua
        let historyChanged = paintedHistoryVersion != model.historyVersion || paintedKinds.count != model.lines.count
        if historyChanged {
            paintedHistoryVersion = model.historyVersion; hashRows = [:]; authorRows = [:]
            for (row, line) in model.lines.enumerated() {
                hashRows[line.hash, default: []].insert(row); authorRows[line.author, default: []].insert(row)
            }
            paintedKinds = Array(repeating: -1, count: model.lines.count)
        }
        let selectedEntry = model.selectedHistoryEntry, sticky = model.highlightedLine, hover = model.hoverLine
        let highlights = Highlights(selected: model.selectedLogHashes, selectedAuthor: selectedEntry?.author,
                                    stickyHash: sticky?.hash, stickyAuthor: sticky?.author, hoverHash: hover?.hash, hoverAuthor: hover?.author)
        let syntaxChanged = paintedSyntaxGeneration != syntaxGeneration || paintedSyntaxRevision != syntaxRevision
        let styleChanged = changed || syntaxChanged || paintedDark != dark
        let paletteChanged = historyChanged || paintedDark != dark || paintedPalette != model.presentation || paintedAge != model.colorAge
        var dirty = IndexSet()
        if historyChanged || paletteChanged || styleChanged { dirty = IndexSet(integersIn: 0..<model.lines.count) }
        else if let prior = paintedHighlights, prior != highlights {
            func hashes(_ values: Set<String>) { for value in values { dirty.formUnion(hashRows[value] ?? []) } }
            func authors(_ old: String?, _ new: String?) {
                guard old != new else { return }
                for value in [old,new].compactMap({ $0 }) { dirty.formUnion(authorRows[value] ?? []) }
            }
            hashes(prior.selected.symmetricDifference(highlights.selected))
            if prior.stickyHash != highlights.stickyHash { hashes(Set([prior.stickyHash,highlights.stickyHash].compactMap { $0 })) }
            if prior.hoverHash != highlights.hoverHash { hashes(Set([prior.hoverHash,highlights.hoverHash].compactMap { $0 })) }
            authors(prior.selectedAuthor,highlights.selectedAuthor); authors(prior.stickyAuthor,highlights.stickyAuthor); authors(prior.hoverAuthor,highlights.hoverAuthor)
        }
        if styleChanged, let storage = editor.textStorage {
            renderWork.baseStylePasses += 1
            storage.beginEditing()
            let all = NSRange(location: 0, length: storage.length)
            storage.addAttribute(.foregroundColor, value: NSColor.labelColor, range: all)
            storage.removeAttribute(.backgroundColor, range: all)
            storage.removeAttribute(NSAttributedString.Key("TurtleGitBlameEOLFill"), range: all)
            storage.addAttribute(.font, value: model.sourceFont, range: all)
            if model.syntaxEnabled, let result = syntaxResult {
                for item in result.ranges where NSMaxRange(item.range) <= storage.length {
                    guard let style = result.styles[String(item.style)] else { continue }
                    if let rgb = style.foreground, let color = blameSyntaxColor(rgb,dark:dark) { storage.addAttribute(.foregroundColor,value:color,range:item.range) }
                    if let rgb = style.background, let color = blameSyntaxColor(rgb,dark:dark) { storage.addAttribute(.backgroundColor,value:color,range:item.range) }
                    var font=model.sourceFont
                    if let family=style.font { font=NSFont(name:family,size:model.sourceFont.pointSize) ?? NSFont(name:"Menlo",size:model.sourceFont.pointSize) ?? .monospacedSystemFont(ofSize:model.sourceFont.pointSize,weight:.regular) }
                    if style.bold == true { font=NSFontManager.shared.convert(font,toHaveTrait:.boldFontMask) }
                    storage.addAttribute(.font,value:font,range:item.range)
                    if style.eolFilled == true,let rgb=style.background,let color=blameSyntaxColor(rgb,dark:dark) { storage.addAttribute(NSAttributedString.Key("TurtleGitBlameEOLFill"),value:color,range:item.range) }
                }
            }
            storage.endEditing(); baseStyle = NSAttributedString(attributedString: storage)
            if changed || syntaxChanged {
                geometryGeneration += 1
                desiredSourceWidth=max(300,ceil(storage.size().width)+editor.textContainerInset.width*2+24)
            }
        }
        if editor.rowColors.count != model.lines.count { editor.rowColors = Array(repeating: .clear, count: model.lines.count) }
        editor.textStorage?.beginEditing()
        for row in dirty where model.lines.indices.contains(row) && ranges.indices.contains(row) {
            let line = model.lines[row]
            let kind: Int
            if highlights.selected.contains(line.hash) { kind = 1 }
            else if highlights.selectedAuthor == line.author { kind = 2 }
            else if highlights.stickyHash == line.hash { kind = 1 }
            else if highlights.stickyAuthor == line.author { kind = 2 }
            else if highlights.hoverHash == line.hash { kind = 3 }
            else if highlights.hoverAuthor == line.author { kind = 4 }
            else { kind = 0 }
            let wasSelected = [1,2].contains(paintedKinds[row]), isSelected = [1,2].contains(kind)
            // A new annotation history can remove the selected revision while
            // retaining identical source bytes. Its old kind has been discarded
            // with the row indexes, so explicitly restore cached syntax colors.
            if styleChanged || historyChanged || wasSelected != isSelected, let storage = editor.textStorage, let baseStyle {
                renderWork.foregroundRowsStyled += 1
                let range = ranges[row]
                if isSelected {
                    storage.addAttribute(.foregroundColor,value:NSColor.alternateSelectedControlTextColor,range:range)
                    storage.removeAttribute(NSAttributedString.Key("TurtleGitBlameEOLFill"),range:range)
                } else {
                    for key in [NSAttributedString.Key.foregroundColor, NSAttributedString.Key("TurtleGitBlameEOLFill")] {
                        storage.removeAttribute(key,range:range)
                        baseStyle.enumerateAttribute(key,in:range) { value,subrange,_ in
                            if let value { storage.addAttribute(key,value:value,range:subrange) }
                        }
                    }
                }
            }
            if paletteChanged || paintedKinds[row] != kind {
                editor.rowColors[row] = blameSourceBackground(model,line:line,dark:dark,highlightKind:kind)
                if editor.rowRectangles.indices.contains(row) { editor.setNeedsDisplay(editor.rowRectangles[row]) }
            }
            paintedKinds[row] = kind
        }
        editor.textStorage?.endEditing()
        renderWork.highlightRowsPainted += dirty.count
        paintedHighlights = highlights; paintedDark = dark; paintedPalette = model.presentation; paintedAge = model.colorAge
        paintedSyntaxGeneration = syntaxGeneration; paintedSyntaxRevision = syntaxRevision
        reflowSource()
        return dirty
    }
    private func reflowSource() {
        guard !retired, !reflowing, let manager=editor.layoutManager, let textContainer=editor.textContainer else { return }
        let width=wrapped ? max(30,sourceScroll.contentSize.width) : max(desiredSourceWidth,sourceScroll.contentSize.width)
        guard measuredGeneration != geometryGeneration || measuredWidth != width else {
            editor.frame.size.height=max(editor.rowRectangles.last?.maxY ?? 0,sourceScroll.contentSize.height)
            return
        }
        measuredGeneration=geometryGeneration; measuredWidth=width; renderWork.geometryRebuilds += 1
        reflowing=true; defer { reflowing=false }
        let origin=sourceScroll.contentView.bounds.origin
        let first=pendingReflowAnchor?.row ?? editor.sourceRow(atY:origin.y)
        let within=pendingReflowAnchor?.within ?? first.flatMap { editor.rowRectangles.indices.contains($0) ? origin.y-editor.rowRectangles[$0].minY : nil } ?? 0
        editor.frame.size.width=width
        textContainer.containerSize=NSSize(width:wrapped ? max(1,width-editor.textContainerInset.width*2) : CGFloat.greatestFiniteMagnitude,height:CGFloat.greatestFiniteMagnitude)
        manager.ensureLayout(for:textContainer)
        var rectangles:[NSRect]=[]
        for range in ranges {
            let glyphs=manager.glyphRange(forCharacterRange:range,actualCharacterRange:nil)
            let rectangle:NSRect
            if glyphs.length > 0 {
                let begin=manager.lineFragmentRect(forGlyphAt:glyphs.location,effectiveRange:nil)
                let end=manager.lineFragmentRect(forGlyphAt:NSMaxRange(glyphs)-1,effectiveRange:nil)
                rectangle=NSRect(x:0,y:begin.minY,width:width,height:max(editor.lineHeight,end.maxY-begin.minY))
            } else {
                let fragment=manager.extraLineFragmentRect
                rectangle=NSRect(x:0,y:fragment.minY,width:width,height:max(editor.lineHeight,fragment.height))
            }
            rectangles.append(rectangle)
        }
        let changed=rectangles != editor.rowRectangles
        editor.rowRectangles=rectangles
        editor.frame.size.height=max(rectangles.last?.maxY ?? 0,sourceScroll.contentSize.height)
        if changed, let table=scroll.documentView as? NSTableView {
            table.noteHeightOfRows(withIndexesChanged:IndexSet(integersIn:0..<table.numberOfRows))
            table.needsLayout=true
        }
        if let first, rectangles.indices.contains(first) {
            var next=origin;next.x=pendingReflowAnchor?.x ?? origin.x;next.y=rectangles[first].minY+min(within,max(0,rectangles[first].height-1))
            if wrapped { next.x=0 }
            sourceScroll.contentView.scroll(to:sourceScroll.contentView.constrainBoundsRect(NSRect(origin:next,size:sourceScroll.contentView.bounds.size)).origin)
        }
        sourceScroll.reflectScrolledClipView(sourceScroll.contentView)
        pendingReflowAnchor=nil; editor.refreshRevisionTooltips()
    }
    private func requestSyntax(_ model: BlameWindowModel) {
        if !model.syntaxEnabled {
            if syntaxText != nil {
                syntaxGeneration += 1; syntaxToken?.cancel(); syntaxTask?.cancel()
                syntaxText = nil; syntaxResult = nil; model.syntaxWorking = false; model.syntaxError = nil
            }
            return
        }
        guard syntaxText != editor.string || syntaxPath != model.path || syntaxTabs != model.presentation.tabSize else { return }
        syntaxGeneration += 1; let generation = syntaxGeneration
        syntaxToken?.cancel(); syntaxTask?.cancel(); syntaxResult = nil
        syntaxText = editor.string; syntaxPath = model.path; syntaxTabs = model.presentation.tabSize
        let text = editor.string, path = model.path, tabs = model.presentation.tabSize, helper = model.syntaxExecutable
        let token = OperationCancellation(); syntaxToken = token
        model.syntaxWorking = true; model.syntaxError = nil; BlameWindowModel.syntaxStarted()
        syntaxTask = Task { @MainActor [weak self] in
            defer { BlameWindowModel.syntaxFinished() }
            do {
                let result = try await model.syntaxOperation(text,path,tabs,helper,token)
                guard let self, !self.retired, self.syntaxGeneration == generation, !token.isCancelled, !Task.isCancelled else { return }
                self.syntaxResult = result; self.syntaxRevision += 1; model.syntaxWorking = false; self.updateSource(model)
            } catch {
                guard let self, !self.retired, self.syntaxGeneration == generation, !token.isCancelled, !Task.isCancelled else { return }
                model.syntaxWorking = false; model.syntaxError = error.localizedDescription
            }
        }
    }
    private func synchronize(fromSource: Bool) {
        guard !retired, !synchronizing else { return }; synchronizing = true
        let origin = (fromSource ? sourceScroll : scroll).contentView.bounds.origin
        let target = fromSource ? scroll : sourceScroll
        var next = target.contentView.bounds.origin; next.y = origin.y
        target.contentView.scroll(to: target.contentView.constrainBoundsRect(NSRect(origin:next,size:target.contentView.bounds.size)).origin)
        target.reflectScrolledClipView(target.contentView); locator.refreshViewport()
        layoutAnnotationHeading()
        synchronizing = false
    }
    private func layoutAnnotationHeading() {
        var x = -scroll.contentView.bounds.minX + 2
        for label in annotationHeading.subviews { label.frame.origin = NSPoint(x:x,y:0); x += label.frame.width }
    }
    override func layout() {
        super.layout()
        locator.frame = NSRect(x: 0, y: 0, width: 10, height: bounds.height)
        let gutter = min(gutterWidth, max(150, bounds.width * 0.55)), height = max(0,bounds.height - 22)
        annotationHeading.frame = NSRect(x:10,y:height,width:gutter,height:22)
        sourceHeading.frame = NSRect(x:16 + gutter,y:height,width:max(0,bounds.width - gutter - 16),height:22)
        scroll.frame = NSRect(x:10,y:0,width:gutter,height:height)
        sourceScroll.frame = NSRect(x:10 + gutter,y:0,width:max(0,bounds.width - gutter - 10),height:height)
        scroll.tile(); sourceScroll.tile()
        let extra = max(0,scroll.contentSize.height - sourceScroll.contentSize.height)
        if extra > 0 { scroll.frame.origin.y += extra; scroll.frame.size.height -= extra; scroll.tile() }
        reflowSource()
        pendingReflowAnchor=nil
        editor.refreshRevisionTooltips()
        synchronize(fromSource:true)
        locator.refreshViewport()
    }
}

/// CTheme::GetThemeColor preserves hue/saturation and inverts HSL luminance,
/// clamped to 5...90% in ordinary dark mode.
private func blameSyntaxColor(_ rgb: [UInt8], dark: Bool) -> NSColor? {
    guard rgb.count == 3 else { return nil }
    var r = CGFloat(rgb[0])/255, g = CGFloat(rgb[1])/255, b = CGFloat(rgb[2])/255
    if dark {
        let minimum = min(r,g,b), maximum = max(r,g,b), delta = maximum - minimum
        let light = (minimum + maximum)/2
        let saturation = delta == 0 ? 0 : delta/(1 - abs(2*light - 1))
        var hue:CGFloat = 0
        if delta > 0 {
            if maximum == r { hue = (g-b)/delta + (g < b ? 6 : 0) }
            else if maximum == g { hue = (b-r)/delta + 2 }
            else { hue = (r-g)/delta + 4 }
        }
        let l = min(0.9,max(0.05,1-light)), c = (1-abs(2*l-1))*saturation
        let x = c*(1-abs(hue.truncatingRemainder(dividingBy:2)-1)), m = l-c/2
        switch Int(hue) {
        case 0: (r,g,b) = (c,x,0)
        case 1: (r,g,b) = (x,c,0)
        case 2: (r,g,b) = (0,c,x)
        case 3: (r,g,b) = (0,x,c)
        case 4: (r,g,b) = (x,0,c)
        default: (r,g,b) = (c,0,x)
        }
        r += m; g += m; b += m
    }
    return NSColor(srgbRed:r,green:g,blue:b,alpha:1)
}

@MainActor protocol BlameSourceTooltipProviding {
    func revisionTooltip(at point:NSPoint)->String?
}
private final class BlameSourceTextView: NSTextView, BlameSourceTooltipProviding, NSViewToolTipOwner {
    var retired = false
    var copyAvailable:()->Bool={false}
    var publishCopy:(String)->Void={_ in}
    var tooltipForRow: (Int)->String? = { _ in nil }
    func revisionTooltip(at point:NSPoint)->String? {
        guard !retired,bounds.contains(point),let row=sourceRow(atY:point.y),rowRectangles.indices.contains(row),
              point.y>=rowRectangles[row].minY,point.y<rowRectangles[row].maxY else {return nil}
        return tooltipForRow(row)
    }
    func refreshRevisionTooltips() {
        removeAllToolTips()
        if !retired,!rowRectangles.isEmpty {addToolTip(bounds,owner:self,userData:nil)}
    }
    @objc func view(_ view:NSView,stringForToolTip tag:NSView.ToolTipTag,point:NSPoint,userData:UnsafeMutableRawPointer?)->String {
        revisionTooltip(at:point) ?? ""
    }
    var lineHeight: CGFloat = 22
    var rowColors: [NSColor] = []
    var rowRectangles: [NSRect] = []
    func sourceRow(atY y:CGFloat) -> Int? {
        guard !rowRectangles.isEmpty else { return nil }
        var low=0,high=rowRectangles.count
        while low < high { let middle=(low+high)/2; if rowRectangles[middle].minY <= y { low=middle+1 } else { high=middle } }
        return max(0,low-1)
    }
    var onContextMenu: (Int,NSEvent) -> Void = { _,_ in }
    var contextMenuAvailable:()->Bool = {true}
    var keyboardContextRow:(()->Int?)?
    @discardableResult private func showKeyboardContext()->Bool {
        guard !retired,window?.isVisible==true,contextMenuAvailable(),let row=keyboardContextRow?(),let event=blameKeyboardContextEvent(self) else {return false}
        onContextMenu(row,event);return true
    }
    override func accessibilityPerformShowMenu()->Bool {showKeyboardContext()}
    var onOpen:()->Void={}
    var onFind: () -> Void = {}
    var onFindNext: (Bool) -> Void = { _ in }
    var onGoTo: () -> Void = {}
    private var focusObservers: [NSObjectProtocol] = []
    func updateSelectionColor() {
        var attributes = selectedTextAttributes
        attributes[.foregroundColor] = window?.isKeyWindow == true && window?.firstResponder === self ? NSColor.selectedTextColor : NSColor.unemphasizedSelectedTextColor
        selectedTextAttributes = attributes
    }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        focusObservers.forEach { NotificationCenter.default.removeObserver($0) }; focusObservers = []
        if let window {
            for name in [NSWindow.didBecomeKeyNotification,NSWindow.didResignKeyNotification] {
                focusObservers.append(NotificationCenter.default.addObserver(forName:name,object:window,queue:.main) { [weak self] _ in self?.updateSelectionColor() })
            }
        }
        updateSelectionColor()
    }
    override func becomeFirstResponder() -> Bool { let accepted = super.becomeFirstResponder(); updateSelectionColor(); return accepted }
    override func resignFirstResponder() -> Bool {
        let accepted = super.resignFirstResponder()
        var attributes = selectedTextAttributes; attributes[.foregroundColor] = NSColor.unemphasizedSelectedTextColor; selectedTextAttributes = attributes
        return accepted
    }
    deinit { focusObservers.forEach { NotificationCenter.default.removeObserver($0) } }
    override func copy(_ sender: Any?) {
        guard !retired,isSelectable,copyAvailable(),window?.firstResponder === self,let contents=selectedCopyText else{return}
        publishCopy(contents)
    }
    private var selectedCopyText:String?{
        let text=string as NSString
        let ranges=selectedRanges.map{$0.rangeValue}.filter{$0.location != NSNotFound && $0.length>0 && NSMaxRange($0)<=text.length}
        return ranges.isEmpty ? nil:ranges.map{text.substring(with:$0)}.joined(separator:"\n")
    }
    override func validateMenuItem(_ item:NSMenuItem)->Bool{
        if item.action == #selector(copy(_:)){return !retired && isSelectable && copyAvailable() && window?.firstResponder === self && selectedCopyText != nil}
        return super.validateMenuItem(item)
    }
    override func selectAll(_ sender: Any?) { guard !retired else { return }; super.selectAll(sender) }
    override func writeSelection(to pboard: NSPasteboard, types: [NSPasteboard.PasteboardType]) -> Bool {
        guard !retired, isSelectable else { return false }
        guard let contents=selectedCopyText else{return false}
        var written = false
        for type in types where type == .string || type.rawValue == "NSStringPboardType" { written = pboard.setString(contents,forType:type) || written }
        return written
    }
    override func writeSelection(to pboard: NSPasteboard, type: NSPasteboard.PasteboardType) -> Bool {
        writeSelection(to:pboard,types:[type])
    }
    override func keyDown(with event: NSEvent) {
        guard !retired else { return }
        if BlameWindowController.routeCommandKey(event,from:window) {return}
        let flags = event.modifierFlags.intersection([.command,.control,.option,.shift])
        if event.keyCode==109,flags == .shift,showKeyboardContext() {return}
        if flags.contains(.command), !flags.contains(.control), !flags.contains(.option) {
            switch event.charactersIgnoringModifiers?.lowercased() {
            case "o":onOpen();return
            case "f": onFind(); return
            case "g": onFindNext(flags.contains(.shift)); return
            case "l": onGoTo(); return
            default: break
            }
        }
        super.keyDown(with:event)
    }
    override func drawBackground(in rect: NSRect) {
        super.drawBackground(in:rect)
        guard !rowColors.isEmpty, let first=sourceRow(atY:rect.minY), let end=sourceRow(atY:rect.maxY) else { return }
        for row in first...min(end,rowColors.count-1) where rowRectangles.indices.contains(row) {
            rowColors[row].setFill()
            var background=rowRectangles[row];background.size.width=bounds.width;background.intersection(rect).fill()
        }
        guard let manager=layoutManager,let container=textContainer,let storage=textStorage else { return }
        let origin=textContainerOrigin
        // A dirty rectangle in the empty tail contains no glyphs. Expand it
        // horizontally to discover its line fragment before clipping the fill.
        let visible=NSRect(x:0,y:rect.minY-origin.y,width:bounds.width,height:rect.height)
        let glyphs=manager.glyphRange(forBoundingRect:visible,in:container)
        manager.enumerateLineFragments(forGlyphRange:glyphs) { fragment,used,_,range,_ in
            let characters=manager.characterRange(forGlyphRange:range,actualGlyphRange:nil)
            guard characters.length>0,NSMaxRange(characters)<=storage.length,
                  let color=storage.attribute(NSAttributedString.Key("TurtleGitBlameEOLFill"),at:NSMaxRange(characters)-1,effectiveRange:nil) as? NSColor else { return }
            let start=used.maxX+origin.x
            let tail=NSRect(x:start,y:fragment.minY+origin.y,width:max(0,self.bounds.width-start),height:fragment.height).intersection(rect)
            color.setFill();tail.fill()
        }
    }
    override func rightMouseDown(with event: NSEvent) {
        guard !retired else { return }
        let point = convert(event.locationInWindow,from:nil)
        if let row=sourceRow(atY:point.y) { onContextMenu(row,event) }
    }
    override func mouseDown(with event: NSEvent) {
        guard !retired else { return }
        if event.modifierFlags.contains(.control) { rightMouseDown(with:event); return }
        super.mouseDown(with:event)
    }
}

@MainActor private func blameSourceBackground(_ model: BlameWindowModel, line: GitBlameLine, dark: Bool, highlightKind: Int? = nil) -> NSColor {
    let value = model.presentation.ageColor(rank:model.ranks[line.hash],historyCount:model.historyCount,dark:dark,enabled:model.colorAge)
    let color = NSColor(srgbRed:CGFloat((value >> 16) & 255) / 255,green:CGFloat((value >> 8) & 255) / 255,blue:CGFloat(value & 255) / 255,alpha:1)
    let kind = highlightKind ?? model.highlightKind(line)
    switch kind {
    case 1: return dark ? NSColor(srgbRed:0,green:30.0/255,blue:80.0/255,alpha:1) : .selectedContentBackgroundColor
    case 2:
        let selected = dark ? NSColor(srgbRed:0,green:30.0/255,blue:80.0/255,alpha:1) : .selectedContentBackgroundColor
        return selected.blended(withFraction:dark ? 0.15 : 0.35,of:dark ? NSColor(srgbRed:240.0/255,green:240.0/255,blue:240.0/255,alpha:1) : .white) ?? selected
    case 3,4:
        let percentage = kind == 3 ? 20 : 10
        let level = ((dark ? 240 : 0) * percentage + (dark ? 32 : 255) * (100 - percentage)) / 100
        return NSColor(srgbRed:CGFloat(level)/255,green:CGFloat(level)/255,blue:CGFloat(level)/255,alpha:1)
    default: return model.colorAge && model.ranks[line.hash] != nil ? color : dark ? NSColor(srgbRed:32.0/255,green:32.0/255,blue:32.0/255,alpha:1) : .white
    }
}

private final class BlameLocatorView: NSView {
    weak var table: NSTableView?
    weak var scroll: NSScrollView?
    var presentation = GitBlamePresentation() { didSet { if presentation != oldValue { needsDisplay=true } } }
    var ranks: [Int?] = [] { didSet { needsDisplay=true } }
    var historyCount = 0 { didSet { if historyCount != oldValue { needsDisplay=true } } }
    var colorAge = true { didSet { if colorAge != oldValue { needsDisplay=true } } }
    private var visibleRows: NSRange?
    private(set) var drawingCount = 0
    func refreshViewport() {
        let next = table.map { $0.rows(in:visibleBlameSourceRect($0)) }
        if next != visibleRows { visibleRows=next; needsDisplay=true }
    }
    override var isFlipped: Bool { true }
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setAccessibilityElement(true); setAccessibilityRole(.image)
        setAccessibilityLabel("Blame source locator")
        toolTip = "Age overview of the whole source file; darkened section shows visible lines."
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); needsDisplay = true }
    override func draw(_ dirtyRect: NSRect) {
        drawingCount += 1
        let dark = effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        let background = dark ? NSColor(srgbRed: 32.0 / 255, green: 32.0 / 255, blue: 32.0 / 255, alpha: 1) : .white
        background.setFill(); bounds.fill()
        guard !ranks.isEmpty, let table, scroll != nil else {
            setAccessibilityValue("No source lines"); return
        }
        // AppKit can keep table rows behind the floating header in visibleRect.
        // Convert the header into source coordinates before finding visible rows.
        let rows = table.rows(in: visibleBlameSourceRect(table))
        guard rows.location != NSNotFound, rows.length > 0 else {
            setAccessibilityValue("No visible source lines"); return
        }
        let first = min(ranks.count, rows.location)
        let end = min(ranks.count, NSMaxRange(rows))
        let height = Int(bounds.height)
        for line in ranks.indices {
            let value = presentation.locatorColor(rank: ranks[line], historyCount: historyCount, dark: dark, enabled: colorAge, visible: line >= first && line < end)
            NSColor(srgbRed: CGFloat((value >> 16) & 255) / 255, green: CGFloat((value >> 8) & 255) / 255, blue: CGFloat(value & 255) / 255, alpha: 1).setFill()
            let top = line * height / ranks.count, bottom = (line + 1) * height / ranks.count
            NSRect(x: 0, y: CGFloat(top), width: bounds.width, height: CGFloat(bottom - top)).fill()
        }
        let text: NSColor = dark ? NSColor(srgbRed: 240.0 / 255, green: 240.0 / 255, blue: 240.0 / 255, alpha: 1) : .black
        text.setFill()
        for boundary in [first, end] {
            NSRect(x: 0, y: CGFloat(boundary * height / ranks.count), width: bounds.width, height: 1).fill()
        }
        setAccessibilityValue("Visible lines \(min(ranks.count, first + 1)) through \(end) of \(ranks.count)")
    }
}

private final class BlameRowView: NSTableRowView {
    var ageColor: NSColor = .textBackgroundColor
    var revisionHighlighted = false
    override func drawBackground(in dirtyRect: NSRect) {
        ageColor.setFill(); dirtyRect.fill()
    }
    override func drawSelection(in dirtyRect: NSRect) {
        if revisionHighlighted { ageColor.setFill(); dirtyRect.fill() }
        else { super.drawSelection(in: dirtyRect) }
    }
}

// MainFrm.cpp enables all four dock edges and floating/auto-hide for Output and Properties.
enum BlamePane:String,CaseIterable,Identifiable,Codable {
    case log,properties
    var id:String { rawValue }
    var title:String { self == .log ? "Log" : "Properties" }
    var caption:String { self == .log ? "Git Revision List" : "Commit Info" }
    var icon:MenuIcon { self == .log ? .log : .imageInfo }
    static let dragType="org.turtlegit.blame.pane"
}
enum BlamePanePlacement:String,CaseIterable,Codable,Identifiable {
    case left,right,top,bottom,floating
    var id:String { rawValue }
    var title:String { self == .floating ? "Float" : "Dock "+rawValue.capitalized }
    static func edge(at point:CGPoint,size:CGSize)->Self {
        let width=max(1,size.width),height=max(1,size.height)
        return [(Self.left,point.x/width),(.right,1-point.x/width),(.top,point.y/height),(.bottom,1-point.y/height)].min{$0.1<$1.1}!.0
    }
}
struct BlamePaneLayout:Codable,Equatable {
    var log:BlamePanePlacement = .bottom,properties:BlamePanePlacement = .right
    var logLastDock:BlamePanePlacement = .bottom,propertiesLastDock:BlamePanePlacement = .right
    var logAutoHide=false,propertiesAutoHide=false
    // Optional additions preserve decoding of profiles saved before pane tabs.
    var tabbed:Bool?=nil,activeTab:BlamePane?=nil
    static func load(_ preferences:UserDefaults)->Self {
        guard let data=preferences.data(forKey:"Blame.PaneLayout"),var value=try? JSONDecoder().decode(Self.self,from:data) else { return Self() }
        if value.logLastDock == .floating { value.logLastDock = .bottom }
        if value.propertiesLastDock == .floating { value.propertiesLastDock = .right }
        return value
    }
    func placement(_ pane:BlamePane)->BlamePanePlacement { pane == .log ? log : properties }
    func lastDock(_ pane:BlamePane)->BlamePanePlacement { pane == .log ? logLastDock : propertiesLastDock }
    func autoHidden(_ pane:BlamePane)->Bool { pane == .log ? logAutoHide : propertiesAutoHide }
    mutating func setAutoHidden(_ pane:BlamePane,_ value:Bool) { if pane == .log { logAutoHide=value } else { propertiesAutoHide=value } }
    mutating func place(_ pane:BlamePane,_ value:BlamePanePlacement) {
        if pane == .log { log=value;if value != .floating { logLastDock=value } }
        else { properties=value;if value != .floating { propertiesLastDock=value } }
        if value == .floating { setAutoHidden(pane,false) }
        if log != properties || value == .floating { tabbed=false;activeTab=nil }
    }
}
struct BlamePaneLayoutMenu:View {
    @ObservedObject var model:BlameWindowModel
    var body:some View {
        ForEach(BlamePane.allCases) { pane in
            Menu(pane.title+" Pane") { BlamePaneChoices(model:model,pane:pane) }
        }
        Button("Restore Default Pane Layout") { model.restorePaneLayout() }.disabled(!model.canFind)
    }
}
private struct BlamePaneChoices:View {
    @ObservedObject var model:BlameWindowModel
    let pane:BlamePane
    var body:some View {
        ForEach(BlamePanePlacement.allCases) { placement in
            Toggle(placement.title,isOn:Binding(get:{model.paneLayout.placement(pane)==placement},set:{_ in model.setPanePlacement(pane,placement)}))
        }
        Divider()
        Toggle("Tab with "+(pane == .log ? "Properties" : "Log"),isOn:Binding(get:{model.panesAreTabbed},set:{model.tabPane(pane,joined:$0)}))
        Toggle("Auto Hide",isOn:Binding(get:{model.paneAutoHidden(pane)},set:{model.setPaneAutoHidden(pane,$0)})).disabled(model.paneLayout.placement(pane) == .floating)
    }
}
private struct BlamePaneHeader:View {
    @ObservedObject var model:BlameWindowModel
    let pane:BlamePane
    var body:some View {
        HStack(spacing:6) {
            BlamePaneCaption(model:model,pane:pane).frame(height:18)
                .help("Drag to an edge to dock, or outside the workspace to float; double-click to float or dock.")
            Spacer(minLength:2)
            Menu { BlamePaneChoices(model:model,pane:pane) } label: { Image(systemName:"chevron.down") }.menuStyle(.borderlessButton).fixedSize().accessibilityLabel(pane.title+" pane placement")
            Button { model.setPaneVisible(pane,false) } label: { Image(systemName:"xmark") }.buttonStyle(.plain).accessibilityLabel("Hide "+pane.title)
        }.padding(5).background(Color(nsColor:.controlBackgroundColor)).disabled(!model.canFind)
    }
}
private struct BlamePaneCaption:NSViewRepresentable {
    @ObservedObject var model:BlameWindowModel
    let pane:BlamePane
    var compact=false
    func makeNSView(context:Context)->BlamePaneCaptionButton {
        let button=BlamePaneCaptionButton();button.isBordered=false;button.alignment = .left
        button.font = .boldSystemFont(ofSize:11);button.setAccessibilityLabel("Drag "+pane.caption)
        return button
    }
    func updateNSView(_ button:BlamePaneCaptionButton,context:Context) {
        button.model=model;button.pane=pane;button.title=compact ? "" : pane.caption
        button.image=pane.icon.contextImage();button.imagePosition=compact ? .imageOnly : .imageLeft
        button.isEnabled=model.canFind && context.environment.isEnabled
    }
    static func dismantleNSView(_ button:BlamePaneCaptionButton,coordinator:()) { button.retire() }
}
/// Owns the native drag session so unsuccessful outside drops can float a pane.
/// Escape is observed only inside this process and always cancels that transition.
@MainActor final class BlamePaneCaptionButton:NSButton,NSDraggingSource {
    weak var model:BlameWindowModel?
    var pane:BlamePane = .log
    private var initialEvent:NSEvent?
    private var data:Data?
    private var workspaceFrame=NSRect.zero
    private var escapePressed=false
    private var escapeMonitor:Any?
    override func acceptsFirstMouse(for event:NSEvent?)->Bool { true }
    override func accessibilityPerformPress()->Bool {
        guard isEnabled,let model,model.canFind else { return false };model.togglePaneFloating(pane);return true
    }
    override func mouseDown(with event:NSEvent) {
        guard isEnabled,model?.canFind==true else { return }
        if event.clickCount==2 { model?.togglePaneFloating(pane);initialEvent=nil }
        else { initialEvent=event }
    }
    override func mouseUp(with event:NSEvent) { initialEvent=nil }
    override func mouseDragged(with event:NSEvent) {
        guard isEnabled,data==nil,let initialEvent,let model,model.canFind,model.paneVisible(pane),let window,
              hypot(event.locationInWindow.x-initialEvent.locationInWindow.x,event.locationInWindow.y-initialEvent.locationInWindow.y)>3 else { return }
        self.initialEvent=nil;escapePressed=false
        data=model.paneDragData(pane)
        var ancestor: NSView?=self
        while let view=ancestor,!(view is BlameDockRootSplit) { ancestor=view.superview }
        if let ancestor { workspaceFrame=window.convertToScreen(ancestor.convert(ancestor.bounds,to:nil)) }
        else { let owner=window.parent ?? window;workspaceFrame=owner.contentView.map{owner.convertToScreen($0.convert($0.bounds,to:nil))} ?? owner.frame }
        let item=NSPasteboardItem();item.setData(data!,forType:NSPasteboard.PasteboardType(BlamePane.dragType))
        let dragging=NSDraggingItem(pasteboardWriter:item)
        let snapshot=bitmapImageRepForCachingDisplay(in:bounds)
        if let snapshot { cacheDisplay(in:bounds,to:snapshot) }
        let image=NSImage(size:bounds.size);if let snapshot { image.addRepresentation(snapshot) }
        dragging.setDraggingFrame(bounds,contents:image)
        escapeMonitor=NSEvent.addLocalMonitorForEvents(matching:.keyDown) { [weak self] event in if event.keyCode==53 { self?.escapePressed=true };return event }
        let session=beginDraggingSession(with:[dragging],event:event,source:self)
        session.animatesToStartingPositionsOnCancelOrFail=false
    }
    func draggingSession(_ session:NSDraggingSession,sourceOperationMaskFor context:NSDraggingContext)->NSDragOperation { context == .withinApplication ? .move : [] }
    func ignoreModifierKeys(for session:NSDraggingSession)->Bool { true }
    func draggingSession(_ session:NSDraggingSession,endedAt screenPoint:NSPoint,operation:NSDragOperation) {
        let payload=data,cancelled=escapePressed;clearSession()
        guard let payload else { return }
        _=model?.finishPaneDrag(payload,at:screenPoint,outsideWorkspace:!workspaceFrame.insetBy(dx:-8,dy:-8).contains(screenPoint),cancelled:cancelled,operation:operation)
    }
    private func clearSession() {
        if let escapeMonitor { NSEvent.removeMonitor(escapeMonitor) };escapeMonitor=nil;data=nil;initialEvent=nil
    }
    func retire() { clearSession();model=nil }
    deinit { if let escapeMonitor { NSEvent.removeMonitor(escapeMonitor) } }
}
private struct BlameAuthorImage: NSViewRepresentable {
    @ObservedObject var loader: LogGravatar
    func makeNSView(context: Context) -> NSImageView {
        let view=NSImageView();view.imageScaling = .scaleProportionallyUpOrDown;view.imageFrameStyle = .none
        view.setAccessibilityLabel("Commit author Gravatar");return view
    }
    func updateNSView(_ view:NSImageView,context:Context) { view.image=loader.image }
    func sizeThatFits(_ proposal:ProposedViewSize,nsView:NSImageView,context:Context)->CGSize? {CGSize(width:80,height:80)}
}
private struct BlamePaneContent:View {
    @ObservedObject var model:BlameWindowModel
    let pane:BlamePane
    var body:some View {
        if pane == .log { HStack(alignment:.top,spacing:0) { BlameHistoryTable(model:model);if model.showGravatar { BlameAuthorImage(loader:model.gravatar).frame(width:80,height:80).overlay(Rectangle().stroke(Color.secondary,lineWidth:1)) } } }
        else { BlamePropertiesPane(model:model) }
    }
}
private struct BlameAutoHideTab:NSViewRepresentable {
    let pane:BlamePane,enabled:Bool
    let action:()->Void
    func makeCoordinator()->Coordinator { Coordinator(action) }
    func makeNSView(context:Context)->NSButton {
        let button=PaneTabButton(title:pane.title,target:context.coordinator,action:#selector(Coordinator.pressed(_:)))
        button.bezelStyle = .rounded;button.controlSize = .small;button.font = .systemFont(ofSize:11)
        button.image=pane.icon.contextImage();button.imagePosition = .imageLeft
        button.toolTip="Show "+pane.title;button.setAccessibilityLabel("Show auto-hidden "+pane.title)
        return button
    }
    func updateNSView(_ button:NSButton,context:Context) {
        context.coordinator.action=action;button.isEnabled=enabled && context.environment.isEnabled
    }
    static func dismantleNSView(_ button:NSButton,coordinator:Coordinator) { button.target=nil;button.action=nil;coordinator.action={} }
    private final class PaneTabButton:NSButton {
        override func accessibilityPerformPress()->Bool {
            guard isEnabled,let action,let target else { return false }
            return sendAction(action,to:target)
        }
    }
    final class Coordinator:NSObject {
        var action:()->Void
        init(_ action:@escaping ()->Void) { self.action=action }
        @objc func pressed(_ sender:NSButton) { action() }
    }
}
private struct BlameDockedPane:View {
    @ObservedObject var model:BlameWindowModel
    let pane:BlamePane
    @State private var showing=false
    var body:some View {
        if model.paneAutoHidden(pane) {
            BlameAutoHideTab(pane:pane,enabled:model.canFind,action:{showing.toggle()})
                .frame(width:pane == .log ? 90 : 115,height:28)
                .popover(isPresented:$showing) {
                    VStack(spacing:0) { BlamePaneHeader(model:model,pane:pane);BlamePaneContent(model:model,pane:pane) }
                        .frame(width:pane == .log ? 680 : 320,height:360)
                }.onDisappear { showing=false }
        } else {
            VStack(spacing:0) { BlamePaneHeader(model:model,pane:pane);BlamePaneContent(model:model,pane:pane) }
        }
    }
}
private struct BlamePaneWorkspace:View {
    @ObservedObject var model:BlameWindowModel
    var body:some View {
        GeometryReader { geometry in
            BlameNativeDockWorkspace(model:model)
            .onDrop(of:[BlamePane.dragType],delegate:BlamePaneDockDrop(model:model,size:geometry.size))
            .overlay(alignment:.topLeading) {
                if let edge=model.paneDropPreview {
                    let rect=dropRect(edge,size:geometry.size)
                    Text(edge.title).frame(width:rect.width,height:rect.height)
                        .background(Color.accentColor.opacity(0.2)).border(Color.accentColor)
                        .offset(x:rect.minX,y:rect.minY).allowsHitTesting(false).accessibilityHidden(true)
                }
            }
        }
    }
    private func dropRect(_ edge:BlamePanePlacement,size:CGSize)->CGRect {
        switch edge {
        case .left:return CGRect(x:0,y:0,width:min(150,size.width/3),height:size.height)
        case .right:let width=min(150,size.width/3);return CGRect(x:size.width-width,y:0,width:width,height:size.height)
        case .top:return CGRect(x:0,y:0,width:size.width,height:min(100,size.height/3))
        default:let height=min(100,size.height/3);return CGRect(x:0,y:size.height-height,width:size.width,height:height)
        }
    }
}
@MainActor private struct BlamePaneDockDrop:DropDelegate {
    let model:BlameWindowModel,size:CGSize
    func validateDrop(info:DropInfo)->Bool { model.canFind && info.hasItemsConforming(to:[BlamePane.dragType]) }
    func dropUpdated(info:DropInfo)->DropProposal? {
        guard validateDrop(info:info) else { return DropProposal(operation:.cancel) }
        model.paneDropPreview=BlamePanePlacement.edge(at:info.location,size:size)
        return DropProposal(operation:.move)
    }
    func dropExited(info:DropInfo) { model.paneDropPreview=nil }
    func performDrop(info:DropInfo)->Bool {
        model.paneDropPreview=nil
        return model.receivePaneDrop(info.itemProviders(for:[BlamePane.dragType]),placement:BlamePanePlacement.edge(at:info.location,size:size))
    }
}
@MainActor private final class BlameFloatingPaneController:NSWindowController,NSWindowDelegate {
    private weak var blameOwner:BlameWindowController?
    private let pane:BlamePane,preferences:UserDefaults
    private var retiring=false
    private var frameKey:String { "Blame.Pane."+pane.rawValue+".FloatingFrame" }
    init(owner:BlameWindowController,pane:BlamePane,preferences:UserDefaults) {
        self.blameOwner=owner;self.pane=pane;self.preferences=preferences
        let panel=BlameCommandPanel(contentRect:NSRect(x:0,y:0,width:pane == .log ? 700 : 330,height:350),styleMask:[.titled,.closable,.resizable,.utilityWindow],backing:.buffered,defer:false)
        panel.title=pane.caption;panel.isReleasedWhenClosed=false;panel.hidesOnDeactivate=true;panel.minSize=NSSize(width:260,height:160)
        panel.contentViewController=NSHostingController(rootView:BlamePaneContent(model:owner.model,pane:pane))
        super.init(window:panel)
        let accessory=NSTitlebarAccessoryViewController()
        accessory.view=NSHostingView(rootView:HStack(spacing:2) {
            BlamePaneCaption(model:owner.model,pane:pane,compact:true).frame(width:24,height:20).help("Drag to dock this pane")
            Menu { BlamePaneChoices(model:owner.model,pane:pane) } label: { Image(systemName:"rectangle.split.2x1") }.menuStyle(.borderlessButton).accessibilityLabel(pane.title+" pane placement")
        }.frame(width:56,height:22))
        accessory.layoutAttribute = .right;panel.addTitlebarAccessoryViewController(accessory)
        var frame=preferences.string(forKey:frameKey).map(NSRectFromString) ?? panel.frame
        if ![frame.minX,frame.minY,frame.width,frame.height].allSatisfy({$0.isFinite}) || frame.width<260 || frame.height<160 { frame=panel.frame }
        let screen=owner.window?.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? NSRect(x:0,y:0,width:1200,height:800)
        frame.size.width=min(frame.width,screen.width);frame.size.height=min(frame.height,screen.height)
        if preferences.string(forKey:frameKey)==nil { frame.origin=NSPoint(x:(owner.window?.frame.midX ?? screen.midX)-frame.width/2,y:(owner.window?.frame.midY ?? screen.midY)-frame.height/2) }
        frame.origin.x=min(max(frame.minX,screen.minX),screen.maxX-frame.width)
        frame.origin.y=min(max(frame.minY,screen.minY),screen.maxY-frame.height)
        panel.setFrame(frame,display:false);panel.delegate=self
        owner.window?.addChildWindow(panel,ordered:.above)
    }
    required init?(coder:NSCoder) { fatalError("init(coder:) is not supported") }
    func position(at point:CGPoint) {
        guard let window else { return }
        let screen=NSScreen.screens.first{NSMouseInRect(point,$0.visibleFrame,false)}?.visibleFrame ?? blameOwner?.window?.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? window.frame
        var frame=window.frame
        frame.size.width=min(frame.width,screen.width);frame.size.height=min(frame.height,screen.height)
        frame.origin.x=min(max(point.x-30,screen.minX),screen.maxX-frame.width)
        frame.origin.y=min(max(point.y-frame.height+15,screen.minY),screen.maxY-frame.height)
        window.setFrame(frame,display:true);saveFrame()
    }
    private func saveFrame() { if let window { preferences.set(NSStringFromRect(window.frame),forKey:frameKey) } }
    func windowDidMove(_ notification:Notification) { saveFrame() }
    func windowDidResize(_ notification:Notification) { saveFrame() }
    func windowWillClose(_ notification:Notification) {
        saveFrame();if let window { window.parent?.removeChildWindow(window) }
        if !retiring { blameOwner?.floatingPaneClosed(pane) }
    }
    func retire() { guard !retiring else { return };retiring=true;window?.close() }
}

/// Native split frames avoid intrinsic-content compression from nested hosting
/// views. Keep the source host stable while moving the two existing pane hosts.
private struct BlameNativeDockWorkspace:NSViewControllerRepresentable {
    @ObservedObject var model:BlameWindowModel
    func makeNSViewController(context:Context)->BlameDockWorkspaceController { BlameDockWorkspaceController(model:model) }
    func updateNSViewController(_ controller:BlameDockWorkspaceController,context:Context) { controller.update(model) }
}
@MainActor private final class BlameDockRootSplit:NSSplitView {
    var afterLayout:()->Void={}
    override func layout() { super.layout();afterLayout() }
}
/// Explicit native tab selector avoids AppKit's theme-transition label collapse
/// when a reusable NSTabView is detached and reattached to dock groups.
@MainActor private final class BlamePaneTabGroup:NSView {
    let tabs=NSTabView(),selector=NSSegmentedControl()
    let minimumWidth:CGFloat=250
    override init(frame:NSRect) {
        super.init(frame:frame)
        tabs.tabViewType = .noTabsNoBorder;tabs.autoresizingMask=[.width,.height]
        selector.segmentCount=2;selector.trackingMode = .selectOne;selector.segmentStyle = .rounded
        selector.controlSize = .small;selector.font = .systemFont(ofSize:11)
        for (index,pane) in BlamePane.allCases.enumerated() { selector.setLabel(pane.caption,forSegment:index);selector.setWidth(index==0 ? 135 : 90,forSegment:index) }
        selector.setAccessibilityLabel("Blame pane tabs")
        addSubview(tabs);addSubview(selector)
    }
    required init?(coder:NSCoder) { fatalError("init(coder:) is not supported") }
    override func layout() {
        super.layout()
        tabs.frame=NSRect(x:0,y:0,width:bounds.width,height:max(0,bounds.height-26))
        selector.frame=NSRect(x:max(0,(bounds.width-230)/2),y:max(0,bounds.height-24),width:230,height:22)
    }
}
@MainActor private final class BlameDockWorkspaceController:NSViewController,NSSplitViewDelegate,NSTabViewDelegate {
    private var model:BlameWindowModel
    private let root=BlameDockRootSplit(),center=NSSplitView(),tabGroup=BlamePaneTabGroup(frame:.zero)
    private var tabs:NSTabView { tabGroup.tabs }
    private var groups:[BlamePanePlacement:NSSplitView]=[:]
    private let source:NSHostingView<BlameTable>
    private var hosts:[BlamePane:NSHostingView<BlameDockedPane>]=[:]
    private var edgePanes:[BlamePanePlacement:[BlamePane]]=[:]
    private var previousLayout:BlamePaneLayout?,previousLog:Bool?,previousProperties:Bool?,previousRevision = -1
    private var applying=false,pending=true
    init(model:BlameWindowModel) {
        self.model=model;source=NSHostingView(rootView:BlameTable(model:model))
        super.init(nibName:nil,bundle:nil)
        source.sizingOptions=[];source.autoresizingMask=[.width,.height]
        for pane in BlamePane.allCases {
            let host=NSHostingView(rootView:BlameDockedPane(model:model,pane:pane));host.sizingOptions=[];host.autoresizingMask=[.width,.height];hosts[pane]=host
        }
        for edge in BlamePanePlacement.allCases where edge != .floating { groups[edge]=NSSplitView() }
    }
    required init?(coder:NSCoder) { fatalError("init(coder:) is not supported") }
    override func loadView() {
        root.isVertical=false;center.isVertical=true
        tabs.delegate=self;tabGroup.selector.target=self;tabGroup.selector.action=#selector(selectPaneTab(_:))
        for (edge,split) in groups { split.isVertical=[.top,.bottom].contains(edge) }
        for split in [root,center]+Array(groups.values) { split.dividerStyle = .thin;split.delegate=self;split.autoresizingMask=[.width,.height] }
        root.afterLayout={ [weak self] in self?.applyPendingFrames() };view=root
        rebuild()
    }
    func update(_ model:BlameWindowModel) {
        if self.model !== model {
            self.model=model;source.rootView=BlameTable(model:model)
            for pane in BlamePane.allCases { hosts[pane]?.rootView=BlameDockedPane(model:model,pane:pane) }
            previousLayout=nil
        }
        guard isViewLoaded else { return }
        tabGroup.selector.isEnabled=model.canFind
        tabGroup.selector.selectedSegment=(model.paneLayout.activeTab ?? .log) == .log ? 0 : 1
        if var previousLayout,previousLog==model.showLog,previousProperties==model.showProperties,previousRevision==model.paneLayoutRevision {
            previousLayout.activeTab=model.paneLayout.activeTab
            if previousLayout==model.paneLayout {
                if model.panesAreTabbed,tabs.numberOfTabViewItems>0 {
                    applying=true;tabs.selectTabViewItem(withIdentifier:(model.paneLayout.activeTab ?? .log).rawValue);applying=false
                }
                self.previousLayout=model.paneLayout;return
            }
        }
        if previousLayout != model.paneLayout || previousLog != model.showLog || previousProperties != model.showProperties || previousRevision != model.paneLayoutRevision { rebuild() }
    }
    private func rebuild() {
        applying=true;defer { applying=false }
        previousLayout=model.paneLayout;previousLog=model.showLog;previousProperties=model.showProperties;previousRevision=model.paneLayoutRevision
        for item in tabs.tabViewItems { tabs.removeTabViewItem(item) }
        for split in [root,center]+Array(groups.values) { for child in split.arrangedSubviews { child.removeFromSuperview() } }
        for edge in BlamePanePlacement.allCases where edge != .floating {
            let panes=BlamePane.allCases.filter{model.paneVisible($0) && model.paneLayout.placement($0)==edge};edgePanes[edge]=panes
            if model.panesAreTabbed,panes.count==2,!panes.contains(where:{model.paneAutoHidden($0)}) {
                tabGroup.frame=NSRect(x:0,y:0,width:max(280,groups[edge]!.bounds.width),height:max(100,groups[edge]!.bounds.height))
                for pane in panes {
                    let item=NSTabViewItem(identifier:pane.rawValue);item.label=pane.caption;item.view=hosts[pane];tabs.addTabViewItem(item)
                }
                tabs.selectTabViewItem(withIdentifier:(model.paneLayout.activeTab ?? .log).rawValue)
                tabGroup.selector.selectedSegment=(model.paneLayout.activeTab ?? .log) == .log ? 0 : 1
                groups[edge]?.addArrangedSubview(tabGroup)
            } else { for pane in panes { if let host=hosts[pane] { groups[edge]?.addArrangedSubview(host) } } }
        }
        if has(.top) { root.addArrangedSubview(groups[.top]!) }
        root.addArrangedSubview(center)
        if has(.bottom) { root.addArrangedSubview(groups[.bottom]!) }
        if has(.left) { center.addArrangedSubview(groups[.left]!) }
        center.addArrangedSubview(source)
        if has(.right) { center.addArrangedSubview(groups[.right]!) }
        pending=true;root.needsLayout=true
    }
    @objc private func selectPaneTab(_ sender:NSSegmentedControl) {
        guard model.canFind,BlamePane.allCases.indices.contains(sender.selectedSegment) else { return }
        model.selectPaneTab(BlamePane.allCases[sender.selectedSegment])
    }
    func tabView(_ tabView:NSTabView,shouldSelect tabViewItem:NSTabViewItem?)->Bool { applying || model.canFind }
    func tabView(_ tabView:NSTabView,didSelect tabViewItem:NSTabViewItem?) {
        guard !applying,let id=tabViewItem?.identifier as? String,let pane=BlamePane(rawValue:id) else { return }
        model.selectPaneTab(pane)
    }
    private func has(_ edge:BlamePanePlacement)->Bool { !(edgePanes[edge] ?? []).isEmpty }
    private func collapsed(_ edge:BlamePanePlacement)->Bool { (edgePanes[edge] ?? []).allSatisfy{model.paneAutoHidden($0)} }
    private func extentKey(_ edge:BlamePanePlacement)->String { "Blame.Pane.Dock."+edge.rawValue+".Extent" }
    private func extent(_ edge:BlamePanePlacement,available:CGFloat)->CGFloat {
        let horizontal=[BlamePanePlacement.top,.bottom].contains(edge)
        if collapsed(edge) { return horizontal ? 34 : 115 }
        let saved=model.labelDefaults.double(forKey:extentKey(edge)),fallback:CGFloat=horizontal ? 170 : 280
        return min(max(saved.isFinite && saved>0 ? CGFloat(saved) : fallback,horizontal ? 80 : 160),available*0.4)
    }
    private func applyPendingFrames() {
        guard pending,!applying,root.bounds.width>0,root.bounds.height>0 else { return }
        applying=true;defer { applying=false };pending=false
        root.adjustSubviews()
        if has(.top) { root.setPosition(extent(.top,available:root.bounds.height),ofDividerAt:0) }
        if has(.bottom) { root.setPosition(root.bounds.height-extent(.bottom,available:root.bounds.height)-root.dividerThickness,ofDividerAt:root.arrangedSubviews.count-2) }
        center.adjustSubviews()
        if has(.left) { center.setPosition(extent(.left,available:center.bounds.width),ofDividerAt:0) }
        if has(.right) { center.setPosition(center.bounds.width-extent(.right,available:center.bounds.width)-center.dividerThickness,ofDividerAt:center.arrangedSubviews.count-2) }
        for split in groups.values where !split.arrangedSubviews.isEmpty {
            split.adjustSubviews()
            if split.arrangedSubviews.count>1 { split.setPosition((split.isVertical ? split.bounds.width : split.bounds.height)/2,ofDividerAt:0) }
        }
    }
    func splitView(_ splitView:NSSplitView,shouldAdjustSizeOfSubview view:NSView)->Bool {
        if splitView === root { return view === center }
        if splitView === center { return view === source }
        return true
    }
    private func minimum(_ child:NSView,in split:NSSplitView)->CGFloat {
        if child === source { return 450 }
        if child === center { return 90 }
        if let edge=groups.first(where:{$0.value === child})?.key {
            if collapsed(edge) { return [.top,.bottom].contains(edge) ? 34 : 115 }
            return split.isVertical ? (model.panesAreTabbed ? tabGroup.minimumWidth : 160) : 80
        }
        return split.isVertical ? 120 : 60
    }
    func splitView(_ splitView:NSSplitView,constrainSplitPosition proposedPosition:CGFloat,ofSubviewAt dividerIndex:Int)->CGFloat {
        let children=splitView.arrangedSubviews
        guard children.indices.contains(dividerIndex),dividerIndex+1<children.count else { return proposedPosition }
        let lower=children[...dividerIndex].reduce(CGFloat(0)){$0+minimum($1,in:splitView)}+CGFloat(dividerIndex)*splitView.dividerThickness
        let upper=(splitView.isVertical ? splitView.bounds.width : splitView.bounds.height)-children[(dividerIndex+1)...].reduce(CGFloat(0)){$0+minimum($1,in:splitView)}-CGFloat(children.count-dividerIndex-2)*splitView.dividerThickness
        return min(max(proposedPosition,lower),max(lower,upper))
    }
    func splitViewDidResizeSubviews(_ notification:Notification) {
        guard !applying,!pending,let split=notification.object as? NSSplitView,split === root || split === center else { return }
        for (edge,group) in groups where has(edge) && !collapsed(edge) && group.superview === split {
            let value=split.isVertical ? group.frame.width : group.frame.height
            if value.isFinite,value>0 { model.labelDefaults.set(Double(value),forKey:extentKey(edge)) }
        }
    }
}

/// Native root and floating panes share the active Blame document's accelerators.
@MainActor private final class BlameCommandWindow: NSWindow {
    override func performKeyEquivalent(with event:NSEvent)->Bool {
        BlameWindowController.routeCommandKey(event,from:self) || super.performKeyEquivalent(with:event)
    }
    override func keyDown(with event:NSEvent) {
        if !BlameWindowController.routeCommandKey(event,from:self) {super.keyDown(with:event)}
    }
}
@MainActor private final class BlameCommandPanel: NSPanel {
    override func performKeyEquivalent(with event:NSEvent)->Bool {
        BlameWindowController.routeCommandKey(event,from:self) || super.performKeyEquivalent(with:event)
    }
    override func keyDown(with event:NSEvent) {
        if !BlameWindowController.routeCommandKey(event,from:self) {super.keyDown(with:event)}
    }
}

extension BlameWindowController {
    var commandsAvailable:Bool {
        model.canFind && !hasBlockingHistoryChild && window?.attachedSheet == nil && goToWindow == nil
    }
    private func showGoToLine() {
        guard commandsAvailable,let window else {return}
        let original = model,controller = BlameGoToLineWindowController()
        goToWindow = controller;model.navigationSheetPresented = true;controller.window?.appearance = window.appearance
        guard let panel = controller.window else {goToWindow = nil;model.navigationSheetPresented = false;return}
        window.beginSheet(panel) { [weak self,weak controller,weak original] response in
            guard let self,let controller,self.goToWindow === controller else {return}
            self.goToWindow = nil;original?.navigationSheetPresented = false
            let requested = controller.requested
            controller.retire()
            guard response == .OK,let original,self.model === original,self.commandsAvailable,let requested else {return}
            original.goToLine(requested);self.focusSource()
        }
        panel.makeFirstResponder(controller.line)
    }
    private func cancelGoToLine() {
        let controller = goToWindow;goToWindow = nil;model.navigationSheetPresented = false;controller?.retire()
    }
    private static func commandViews(_ root:NSView?)->[NSView] {
        guard let root else {return []};return [root]+root.subviews.flatMap {commandViews($0)}
    }
    func focusSource() {
        focusGeneration += 1
        guard commandsAvailable,let window,
              let source = Self.commandViews(window.contentView).first(where:{$0 is BlameSourceContainer}) as? BlameSourceContainer else {return}
        window.makeKeyAndOrderFront(nil);window.makeFirstResponder(source.editor)
    }
    /// F6 cycles the interactive source and revision Log, including a floating Log.
    /// Hidden/auto-hidden Log panes remain hidden; tabbed Log is selected on entry.
    func focusNextPane(previous:Bool) {
        guard commandsAvailable,let window else {return}
        let key = commandKeyWindow(),responding = key?.firstResponder
        let onLog = responding is BlameHistoryNativeTable
        let onSource = (responding as? NSView).map {view in Self.commandViews(window.contentView).contains{$0 is BlameSourceContainer && view.isDescendant(of:$0)}} ?? false
        guard model.showLog,!model.paneAutoHidden(.log),!onLog,(onSource || previous) else {focusSource();return}
        if model.panesAreTabbed {model.selectPaneTab(.log)}
        focusGeneration += 1
        let identity = focusGeneration,original = model
        func focusLog() -> Bool {
            guard focusGeneration == identity,model === original,Self.focusedOwner(commandKeyWindow()) === self,commandsAvailable,model.showLog,!model.paneAutoHidden(.log) else {return true}
            let host = floatingPaneWindow(.log) ?? window
            host.contentView?.layoutSubtreeIfNeeded()
            guard let table = Self.commandViews(host.contentView).first(where:{$0 is BlameHistoryNativeTable}) else {return false}
            host.makeKeyAndOrderFront(nil);return host.makeFirstResponder(table)
        }
        if !focusLog() {
            Task { @MainActor [weak self] in
                await Task.yield()
                guard let self,self.focusGeneration == identity,self.model === original else {return}
                _ = focusLog()
            }
        }
    }
    @discardableResult static func routeCommandKey(_ event:NSEvent,from source:NSWindow?)->Bool {
        guard let source,let owner = focusedOwner(source),!owner.model.retired,
              owner.commandKeyWindow() === source,
              source === owner.window || owner.floatingPanes.values.contains(where:{$0.window === source}),
              event.windowNumber == source.windowNumber else {return false}
        if BlameZoomKeyRouting.route(event,owner:owner) {return true}
        let flags = event.modifierFlags.intersection([.command,.control,.option,.shift])
        enum Action {case find,next,previous,goTo,open,nextPane,previousPane,close}
        let action:Action
        if event.keyCode == 99,flags == [] || flags == .shift {action = flags == .shift ? .previous:.next}
        else if event.keyCode == 97,flags == [] || flags == .shift {action = flags == .shift ? .previousPane:.nextPane}
        else if event.keyCode == 53,flags.isEmpty {
            guard (source.firstResponder as? NSTextView)?.isFieldEditor != true else {return false}
            action = .close
        } else if flags == .control || flags == .command || flags == [.command,.shift] {
            switch (event.charactersIgnoringModifiers ?? "").lowercased() {
            case "f" where flags == .control || flags == .command:action = .find
            case "g" where flags == .control:action = .goTo
            case "g" where flags == .command:action = .next
            case "g" where flags == [.command,.shift]:action = .previous
            case "l" where flags == .command:action = .goTo
            case "o" where flags == .control || flags == .command:action = .open
            case "q" where flags == .control:action = .close
            default:return false
            }
        } else {return false}
        // Recognized commands stay consumed when disabled; they cannot fall
        // through into field editing, a second document, or another menu target.
        guard owner.commandsAvailable else {return true}
        switch action {
        case .find:owner.model.onFind?()
        case .next:owner.model.findLine(previous:false)
        case .previous:owner.model.findLine(previous:true)
        case .goTo:owner.model.onGoTo?()
        case .open:owner.openDocument()
        case .nextPane:owner.focusNextPane(previous:false)
        case .previousPane:owner.focusNextPane(previous:true)
        case .close:source.performClose(nil)
        }
        return true
    }
}
