import AppKit
import SwiftUI
import TurtleGitCore

private struct BlameParentMenuTarget {
    let choice: GitBlameParentComparison
    let originalLine: Int
    let options: GitBlameOptions
    let target:BlameWindowModel.HistoryTarget?
}

@MainActor final class BlameWindowController: NSWindowController, NSWindowDelegate {
    private(set) var model: BlameWindowModel
    var onClosed: () -> Void = {}
    private(set) var findWindow: BlameFindWindowController?
    private(set) var findAlert:NSAlert?
    private var feedbackGeneration=0
    private var columnAlert:NSAlert?
    private(set) var historyUnifiedWindows:[UUID:PatchWindowController]=[:]
    private(set) var containingReferences:[UUID:CommitContainingReferencesWindowController]=[:]
    var configureContainingReferences:(CommitContainingReferencesWindowController)->Void = { _ in }
    private let preferences:UserDefaults
    let recentDocuments:BlameRecentDocuments?
    private let documentOpener:BlameDocumentOpener
    private(set) var openPanel:NSOpenPanel?
    private var openingGeneration=0
    private var recentID:UUID?
    var onDocumentChanged:()->Void={}
    var chooseFile:(NSOpenPanel,NSWindow,@escaping (URL?)->Void)->Void = { panel,owner,reply in panel.beginSheetModal(for:owner) { reply($0 == .OK ? panel.url : nil) } }
    var chooseScope:(NSOpenPanel,NSWindow,@escaping (URL?)->Void)->Void = { panel,owner,reply in panel.beginSheetModal(for:owner) { reply($0 == .OK ? panel.url : nil) } }

    init(repository: GitRepository, access: RepositoryAccessLease?, path: String, revision: String, options: GitBlameOptions = GitBlamePreferences.load(), preferences: UserDefaults = .standard, recentDocuments:BlameRecentDocuments? = nil, requireScope:Bool = GitRuntime.isAppStoreBuild, provider:any RepositoryBookmarkProvider = SystemRepositoryBookmarkProvider()) {
        self.preferences=preferences;self.recentDocuments=recentDocuments
        documentOpener=BlameDocumentOpener(requireScope:requireScope,provider:provider,factory:{ GitRepository(root:$0,executable:repository.executable) });self.requireScope=requireScope;self.scopeProvider=provider
        model = BlameWindowModel(repository: repository, access: access, path: path, revision: revision, options: options, labelDefaults: preferences)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1120, height: 700), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "\(path) at \(revision.prefix(7)) – Blame – TurtleGit"
        window.minSize = NSSize(width: 820, height: 400); window.isReleasedWhenClosed = false
        window.acceptsMouseMovedEvents = true
        window.contentViewController = NSHostingController(rootView: BlameDialog(model: model))
        super.init(window: window); window.delegate = self; window.setContentSize(NSSize(width: 1120, height: 700)); window.center(); model.onFind = { [weak self] in self?.showFind() }; model.onFindFeedback = { [weak self] in self?.feedback($0) };model.onOpenDocument={ [weak self] in self?.openDocument() };model.onCancelDocumentOpen={ [weak self] in self?.cancelOpenDocument() };model.onOpenRecent={ [weak self] in self?.openRecent($0) };model.recentDocuments=recentDocuments;model.onLoaded={ [weak self] in
            guard let self,revision=="HEAD",let recentDocuments=self.recentDocuments else { return }
            let lease=self.model.repositoryAccess ?? RepositoryAccessLease(url:self.model.repository.root,provider:self.scopeProvider)
            do { try recentDocuments.remember(root:self.model.repository.root,path:self.model.path,lease:lease) } catch { self.model.error=error.localizedDescription }
        };model.reload()

        configureHistoryActions()
        applyWindowAppearance()
        DialogGeometry.attach(window, identifier: "BlameWindowController")
    }
    private let requireScope:Bool
    private let scopeProvider:any RepositoryBookmarkProvider
    func openDocument() {
        guard model.canFind,!model.openingDocument,!hasBlockingHistoryChild,let window,window.attachedSheet==nil else { return }
        let panel=NSOpenPanel();panel.canChooseFiles=true;panel.canChooseDirectories=false;panel.allowsMultipleSelection=false;panel.prompt="Blame File"
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
        if let access=model.repositoryAccess,access.contains(file),(!requireScope || access.hasSecurityScope) { prepare(file,scope:access);return }
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
                let document=try await documentOpener.prepare(file:file,scope:scope,options:options)
                guard openingGeneration==identity,!old.retired else { return }
                old.retireSourceView?();old.onFind=nil;old.onFindFeedback=nil;old.retire()
                let replacement=BlameWindowModel(repository:document.repository,access:document.access,path:document.snapshot.path,revision:"HEAD",options:document.options,labelDefaults:preferences)
                replacement.install(document.snapshot,history:document.history,options:document.options);replacement.recentHistoryError=old.recentHistoryError
                model=replacement;replacement.onFind={ [weak self] in self?.showFind() };replacement.onFindFeedback={ [weak self] in self?.feedback($0) };replacement.onOpenDocument={ [weak self] in self?.openDocument() };replacement.onCancelDocumentOpen={ [weak self] in self?.cancelOpenDocument() };replacement.onOpenRecent={ [weak self] in self?.openRecent($0) };replacement.recentDocuments=recentDocuments
                window?.contentViewController=NSHostingController(rootView:BlameDialog(model:replacement))
                Array(containingReferences.values).forEach { $0.close() };containingReferences=[:]
                Array(historyUnifiedWindows.values).forEach { $0.close() };historyUnifiedWindows=[:]
                configureHistoryActions();findWindow?.rebind(replacement);applyWindowAppearance()
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
    private var hasBlockingHistoryChild:Bool { containingReferences.values.contains { $0.hasBlockingChild } || historyUnifiedWindows.values.contains { $0.model.busy || $0.window?.attachedSheet != nil } }
    private func configureHistoryActions() {
        model.onHistoryUnified={ [weak self] bytes,title,alternate in
            guard let self,!self.model.retired else { return };let original=self.model
            if try await !UnifiedDiffApplication.openExternal(bytes,alternate:alternate,preferences:self.preferences) {
                guard self.model===original,!original.retired else { return };let id=UUID()
                let child=UnifiedDiffApplication.presentBuiltin(bytes,repository:original.repository,access:original.repositoryAccess,existing:nil,title:title,onClosed:{ [weak self] in self?.historyUnifiedWindows.removeValue(forKey:id) })
                child.window?.appearance=self.window?.appearance;self.historyUnifiedWindows[id]=child
            }
        }

        model.confirmHistoryReset={ [weak self] in
            guard let self,let window=self.window,window.attachedSheet==nil,!self.model.retired else { return false }
            let alert=NSAlert();alert.messageText="Reset Blame Log columns?";alert.informativeText="Restore the default columns, order and widths?";alert.addButton(withTitle:"No");alert.addButton(withTitle:"Yes");self.columnAlert=alert
            return await withCheckedContinuation { continuation in
                alert.beginSheetModal(for:window) { [weak self] response in
                    if self?.columnAlert === alert { self?.columnAlert=nil }
                    continuation.resume(returning:self?.model.retired==false && response == .alertSecondButtonReturn)
                }
            }
        }
        model.onContainingReferences={ [weak self] hash in
            guard let self,self.model.canFind,let parent=self.window,parent.attachedSheet==nil else { return }
            let id=UUID(),child=CommitContainingReferencesWindowController(repository:self.model.repository,access:self.model.repositoryAccess,revision:hash,preferences:self.preferences)
            self.configureContainingReferences(child)
            child.onClosed={ [weak self,weak child,weak parent] in if let window=child?.window { parent?.removeChildWindow(window) };self?.containingReferences.removeValue(forKey:id) }
            self.containingReferences[id]=child
            if let window=child.window { window.appearance=parent.appearance;parent.addChildWindow(window,ordered:.above);window.center();window.orderFront(nil) };child.refresh()
        }
    }
    private func applyWindowAppearance() {
        window?.appearance=model.darkOverride.map { NSAppearance(named:$0 ? .darkAqua : .aqua)! }
        findWindow?.window?.appearance=window?.appearance
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
        guard model.canFind else { return }
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
        feedbackGeneration += 1;openingGeneration += 1;documentOpener.cancel()
        if let alert=columnAlert { alert.window.sheetParent?.endSheet(alert.window,returnCode:.cancel);alert.window.close();columnAlert=nil }
        Array(historyUnifiedWindows.values).forEach { $0.close() };historyUnifiedWindows=[:]
        Array(containingReferences.values).forEach { $0.close() };containingReferences=[:]
        if let panel=openPanel { panel.sheetParent?.endSheet(panel,returnCode:.cancel);panel.close();openPanel=nil };model.openingDocument=false
        if let alert=findAlert {
            alert.window.sheetParent?.endSheet(alert.window,returnCode:.cancel);alert.window.close();findAlert=nil
        }
        model.searchFeedbackBusy=false
        findWindow?.close();findWindow=nil
        model.retireSourceView?();model.retireSourceView=nil;model.onFind=nil;model.onFindFeedback=nil;model.retire();onClosed()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
}

enum BlameFindFeedback { case wrapped(line:Int),notFound(text:String) }

@MainActor final class BlameWindowModel: ObservableObject {
    private(set) static var activeSyntaxRequests = 0
    let repository: GitRepository, path: String
    let fullCommitMessageOnLogLine: Bool
    private let access: RepositoryAccessLease?
    var repositoryAccess:RepositoryAccessLease? { access }
    let labelDefaults: UserDefaults
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
        case "date": return repeated ? "" : DateFormatter.localizedString(from:line.date,dateStyle:.short,timeStyle:.short)
        case "filename": return repeated && lines[row - 1].filename == line.filename ? "" : line.filename
        case "original": return String(line.originalLine)
        default: return String(line.number)
        }
    }
    private var revision: String
    private var generation = 0
    private var pendingLine: Int?
    private var clipboardGeneration = 0
    private var historyClipboardCancellation:OperationCancellation?
    private(set) static var activeHistoryOperations=0
    @Published private(set) var historyColumns:BlameHistoryColumns
    @Published private(set) var resettingHistoryColumns=false
    var confirmHistoryReset:() async -> Bool = { false }
    var onHistoryExport:((String)->Void)?
    var onHistoryReference:((Bool,String)->Void)?
    var onHistorySwitch:((String)->Void)?
    var onHistoryBrowse:((String)->Void)?
    var onContainingReferences:((String)->Void)?
    var onHistoryUnified:((Data,String,Bool) async throws -> Void)?
    private var historyParentCache:[String:[GitBlameParentComparison]]=[:]
    private var historyParentToken:OperationCancellation?
    private var sourceParentToken:OperationCancellation?
    @Published private(set) var readingHistoryParents=false
    func cachedHistoryParents(_ target:HistoryTarget)->[GitBlameParentComparison] {
        guard acceptsHistory(target),target.entries.count==1 else { return [] };return historyParentCache[target.entries[0].hash] ?? []
    }
    private var unifiedReadTokens:[UUID:OperationCancellation]=[:]
    func prepareHistoryParents(_ target:HistoryTarget,completion:@escaping ([GitBlameParentComparison])->Void) {
        guard acceptsHistory(target),target.entries.count==1,let snapshot else { completion([]);return }
        let hash=target.entries[0].hash
        if let choices=historyParentCache[hash] { completion(choices);return }
        historyParentToken?.cancel();let token=OperationCancellation();historyParentToken=token;readingHistoryParents=true;Self.activeHistoryOperations += 1
        Task { [self,access] in
            defer { Self.activeHistoryOperations -= 1;withExtendedLifetime(access) {};if historyParentToken===token { historyParentToken=nil;readingHistoryParents=false } }
            do {
                if GitRuntime.isAppStoreBuild && (access?.hasSecurityScope != true || access?.contains(repository.root) != true) { throw RepositoryAccessFailure.securityScopeUnavailable }
                let choices=try await repository.blameHistoryParentComparisons(snapshot,revision:hash,cancellation:token)
                guard acceptsHistory(target),!token.isCancelled else { return };historyParentCache[hash]=choices;completion(choices)
            } catch { if acceptsHistory(target),!token.isCancelled { self.error=error.localizedDescription;completion([]) } }
        }
    }
    enum ParentAction { case previous,compare,unified }
    func performHistoryParent(_ target:HistoryTarget,choices:[GitBlameParentComparison],action:ParentAction,alternate:Bool = false,originalLine:Int = 1) {
        guard acceptsHistory(target),!choices.isEmpty else { return }
        if action == .previous { for choice in choices { onPrevious?(choice.path,choice.revision,originalLine,appliedOptions) };return }
        if action == .compare { for choice in choices { onChanges?(choice.comparison) };return }
        let id=UUID(),token=OperationCancellation();unifiedReadTokens[id]=token;Self.activeHistoryOperations += 1
        Task { [self,access] in
            defer { unifiedReadTokens.removeValue(forKey:id);Self.activeHistoryOperations -= 1;withExtendedLifetime(access) {} }
            do {
                if GitRuntime.isAppStoreBuild && (access?.hasSecurityScope != true || access?.contains(repository.root) != true) { throw RepositoryAccessFailure.securityScopeUnavailable }
                for choice in choices {
                    let bytes=try await repository.revisionComparisonPatchData(choice.comparison,paths:choice.comparison.files.map(\.path),cancellation:token)
                    guard acceptsHistory(target),!token.isCancelled else { return }
                    try await onHistoryUnified?(bytes,"Parent \(choice.parentNumber) → \(target.entries[0].hash.prefix(8)) — \(choice.path)",alternate)
                }
            } catch { if acceptsHistory(target),!token.isCancelled { self.error=error.localizedDescription } }
        }
    }
    private func cancelHistoryParentReads() {
        sourceParentToken?.cancel();sourceParentToken=nil;readingHistoryParents=false
        historyParentToken?.cancel();historyParentToken=nil;unifiedReadTokens.values.forEach { $0.cancel() };historyParentCache=[:]
    }

    func saveHistoryColumns(_ value:BlameHistoryColumns) { guard canFind else { return };historyColumns=value;value.save(labelDefaults) }
    func resetHistoryColumns() {
        guard canFind else { return };let request=generation;resettingHistoryColumns=true;Self.activeHistoryOperations += 1
        Task { [self] in
            defer { resettingHistoryColumns=false;Self.activeHistoryOperations -= 1 }
            let accepted=await confirmHistoryReset()
            guard !retired,request==generation,accepted else { return };historyColumns=BlameHistoryColumns();historyColumns.save(labelDefaults)
        }
    }
    struct HistoryTarget { let owner:ObjectIdentifier,generation:Int;let entries:[LogEntry];var sourceOrigin=false }
    func sourceParentTarget(_ hash:String)->HistoryTarget? {
        guard canFind,let line=lines.first(where:{ $0.hash==hash }) else { return nil }
        let entry=historyEntries.first { $0.hash==hash } ?? LogEntry(hash:hash,author:line.author,date:ISO8601DateFormatter().string(from:line.date),subject:line.summary)
        return HistoryTarget(owner:ObjectIdentifier(self),generation:generation,entries:[entry],sourceOrigin:true)
    }
    func historyTarget(_ entries:[LogEntry])->HistoryTarget? {
        guard canFind,!entries.isEmpty,entries.allSatisfy({ item in historyEntries.contains { $0.hash==item.hash } }) else { return nil }
        return HistoryTarget(owner:ObjectIdentifier(self),generation:generation,entries:entries)
    }
    func acceptsHistory(_ target:HistoryTarget)->Bool { canFind && target.owner==ObjectIdentifier(self) && target.generation==generation && target.entries.allSatisfy { item in target.sourceOrigin ? lines.contains { $0.hash==item.hash } : historyEntries.contains { $0.hash==item.hash } } }

    @Published var copyingLog = false
    @Published var snapshot: GitBlameSnapshot?
    @Published var busy = false
    @Published var error: String?
    @Published var ignoreWhitespace = false
    @Published var onlyFirstParent = false
    @Published var showCompleteLog = true
    @Published var followRenames = false
    @Published var historyEntries: [LogEntry] = [] { didSet { historyVersion += 1 } }
    private(set) var historyVersion=0
    @Published var selectedLogHashes: Set<String> = []
    @Published var showProperties=true { didSet { labelDefaults.set(showProperties,forKey:"Blame.ShowProperties") } }
    @Published var showToolbar=true { didSet { labelDefaults.set(showToolbar,forKey:"Blame.ShowToolbar") } }
    @Published var showLog=true { didSet { labelDefaults.set(showLog,forKey:"Blame.ShowLog") } }
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
    private var cachedSourceFont: (String, Int, NSFont)?
    var sourceFont: NSFont {
        if let cachedSourceFont, cachedSourceFont.0 == presentation.fontName, cachedSourceFont.1 == presentation.fontSize { return cachedSourceFont.2 }
        let font = NSFontManager.shared.font(withFamily: presentation.fontName, traits: [], weight: 5, size: CGFloat(presentation.fontSize)) ?? .monospacedSystemFont(ofSize: CGFloat(presentation.fontSize), weight: .regular)
        cachedSourceFont = (presentation.fontName, presentation.fontSize, font)
        return font
    }
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
    private var parentCache: [String: [GitBlameParentComparison]] = [:]
    @Published var highlightedHash: String?
    @Published var hoveredLine: Int?
    @Published var find = ""
    @Published var matchCase = false
    @Published var navigationMessage = ""
    @Published var recentHistoryError:String?
    @Published var openingDocument=false
    @Published var cancellingDocument=false
    var onCancelDocumentOpen:(()->Void)?
    var onLoaded:(()->Void)?
    var onOpenDocument:(()->Void)?
    var onOpenRecent:((BlameRecentDocument)->Void)?
    var recentDocuments:BlameRecentDocuments?
    @Published var searchFeedbackBusy=false
    private(set) var retired=false
    var canFind:Bool { !retired && !busy && !searchFeedbackBusy && !openingDocument && !resettingHistoryColumns }
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
        if let focus, !old.contains(focus), let line = lines.first(where: { $0.hash == focus }) { selection = line.number }
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
    init(repository: GitRepository, access: RepositoryAccessLease?, path: String, revision: String, options: GitBlameOptions = GitBlameOptions(), labelDefaults: UserDefaults = .standard) {
        self.repository = repository; self.access = access; self.path = path; self.revision = revision; self.labelDefaults = labelDefaults;self.historyColumns = .load(labelDefaults)
        showProperties=labelDefaults.object(forKey:"Blame.ShowProperties") as? Bool ?? true
        showToolbar=labelDefaults.object(forKey:"Blame.ShowToolbar") as? Bool ?? true
        showLog=labelDefaults.object(forKey:"Blame.ShowLog") as? Bool ?? true
        showStatusBar=labelDefaults.object(forKey:"Blame.ShowStatusBar") as? Bool ?? true
        colorAge=labelDefaults.object(forKey:"Blame.ColorAge") as? Bool ?? true
        darkOverride=labelDefaults.object(forKey:"Blame.DarkMode") as? Bool
        marginFields = Set(BlameMarginField.allCases.filter { labelDefaults.object(forKey:"Blame." + $0.rawValue) as? Bool ?? ($0 == .author) })
        syntaxEnabled = labelDefaults.object(forKey:"Blame.EnableLexer") as? Bool ?? !NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
        wrapLongLines = labelDefaults.bool(forKey:"Blame.WrapLongLines")
        self.fullCommitMessageOnLogLine = labelDefaults.bool(forKey: "FullCommitMessageOnLogLine")
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
        retired=true;onFind=nil;onFindFeedback=nil;onGoTo=nil;onOpenDocument=nil;onCancelDocumentOpen=nil;onOpenRecent=nil;onLoaded=nil;onLog=nil;onChanges=nil;onPrevious=nil;recentDocuments=nil;invalidate()
    }
    func invalidate() { cancelHistoryParentReads();historyClipboardCancellation?.cancel();historyClipboardCancellation=nil;generation += 1; parentGeneration += 1; clipboardGeneration += 1; copyingLog = false; firstVisibleSourceRow = nil; scrollSourceRowToTop = nil; selectedSourceText = nil; sourceNavigation = nil }
    func prepareParentMenu(number: Int, completion: @escaping () -> Void) {
        selection = number; loadParents(completion: completion)
    }
    private func loadParents(completion: @escaping () -> Void) {
        sourceParentToken?.cancel()
        parentGeneration += 1; let request = parentGeneration
        guard let line = selectedLine else { parentChoices = []; loadingParents = false; return }
        let key = line.hash + "\0" + line.filename
        if let cached = parentCache[key] { parentChoices = cached; loadingParents = false; completion(); return }
        sourceParentToken?.cancel();let token=OperationCancellation();sourceParentToken=token
        parentChoices = []; loadingParents = true;Self.activeHistoryOperations += 1
        Task { [self,access] in
            defer { Self.activeHistoryOperations -= 1;withExtendedLifetime(access) {};if sourceParentToken===token { sourceParentToken=nil } }
            do {
                if GitRuntime.isAppStoreBuild && (access?.hasSecurityScope != true || access?.contains(repository.root) != true) { throw RepositoryAccessFailure.securityScopeUnavailable }
                let choices = try await repository.blameParentComparisons(revision:line.hash,path:line.filename,cancellation:token)
                guard request == parentGeneration else { return }
                parentCache[key] = choices; parentChoices = choices; loadingParents = false
                if selectedLine?.number == line.number, selectedLine?.hash == line.hash, selectedLine?.filename == line.filename { completion() }
            } catch { if request == parentGeneration { if !token.isCancelled { self.error = error.localizedDescription }; loadingParents = false } }
        }
    }
    func reload(saveThresholds: Bool = false) {
        guard !retired,!busy,!openingDocument,!searchFeedbackBusy else { return }
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
        busy = true; error = nil
        Task {
            do {
                if GitRuntime.isAppStoreBuild && (access?.hasSecurityScope != true || access?.contains(repository.root) != true) { throw RepositoryAccessFailure.securityScopeUnavailable }
                let result = try await repository.blame(path: path, revision: revision, options: options)
                let entries = try await repository.blameHistory(result, options: options)
                guard request == generation else { return }
                install(result.applyingDisplayIdentities(entries),history:entries,options:options)
                busy = false; applyPendingLine();onLoaded?()
            } catch {
                if request == generation {
                    snapshot = nil; selection = nil; highlightedHash = nil; hoveredLine = nil; origins = [:]; ranks = [:]
                    historyCount = 0; navigationMessage = ""
                    historyEntries = []; selectedLogHashes = []
                    self.error = error.localizedDescription; busy = false
                }
            }
        }
    }
    func install(_ result:GitBlameSnapshot,history entries:[LogEntry],options:GitBlameOptions) {
        let hashes=entries.map(\.hash)
        ranks=Dictionary(hashes.enumerated().map { ($0.element,$0.offset) },uniquingKeysWith:min)
        origins=Dictionary(result.lines.map { ($0.hash,$0) },uniquingKeysWith:{ first,_ in first })
        historyCount=hashes.count;appliedOptions=options;snapshot=result;historyEntries=entries
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
        selection = selected; navigationMessage = "Line \(selected)"
    }
    func showLog(_ line: GitBlameLine) { onLog?(line.filename, line.hash) }
    func copyLogMessage(_ hash:String) { copyHistoryDetails([hash],includePaths:true) }
    func copyHistoryDetails(_ hashes:[String],includePaths:Bool) {
        guard canFind,!hashes.isEmpty else { return }
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
                guard request==generation,clipboardRequest==clipboardGeneration,!retired,!token.isCancelled else { return };copy(text)
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
    @State private var showingGoToLine = false
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
                    Button { SettingsPresentationService.shared.show() } label: { CommandLabel(title:"Settings…",icon:.settings) }
                    Button("Close") { NSApp.sendAction(#selector(NSWindow.performClose(_:)),to:nil,from:nil) }.keyboardShortcut("w",modifiers:.command)
                }
                Menu("Edit") {
                    Button { NSApp.sendAction(Selector(("copy:")),to:nil,from:nil) } label: { CommandLabel(title:"Copy",icon:.copy) }
                    Button { model.onFind?() } label: { CommandLabel(title:"Find…",icon:.mergeFind) }
                    Button { model.findLine(previous:false) } label: { CommandLabel(title:"Find Next",icon:.jumpDown) }.keyboardShortcut("g",modifiers:.command)
                    Button { model.findLine(previous:true) } label: { CommandLabel(title:"Find Previous",icon:.jumpUp) }.keyboardShortcut("g",modifiers:[.command,.shift])
                    Button { showingGoToLine=true } label: { CommandLabel(title:"Go To Line…",icon:.log) }.keyboardShortcut("l",modifiers:.command)
                    Divider()
                    BlameEncodingMenu(selection: Binding(get: { model.sourceEncoding }, set: { model.setEncoding($0) }))
                }
                Menu("View") {
                    Button("Next") { model.navigateChange(previous:false) }.disabled(model.selectedLogHashes.isEmpty)
                    Button("Previous") { model.navigateChange(previous:true) }.disabled(model.selectedLogHashes.isEmpty)
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
                    Toggle("Status Bar",isOn:$model.showStatusBar)
                    Toggle("Toolbar",isOn:$model.showToolbar)
                    Divider()
                    Toggle("Wrap long lines",isOn:Binding(get:{model.wrapLongLines},set:{model.setWrapLongLines($0)}))
                }
                Button { SettingsPresentationService.shared.show() } label: { CommandLabel(title:"Settings…",icon:.settings) }
            }.disabled(model.busy || model.openingDocument || model.searchFeedbackBusy) }
            if let error=model.recentHistoryError { Text(error).font(.caption).foregroundStyle(.orange).textSelection(.enabled) }
            if model.openingDocument { HStack { ProgressView(model.cancellingDocument ? "Cancelling…" : "Opening file…").controlSize(.small);Button("Cancel") { model.onCancelDocumentOpen?() }.disabled(model.cancellingDocument) } }
            if model.busy { ProgressView("Reading annotations…").controlSize(.small) }
            if model.syntaxWorking { ProgressView("Coloring source…").controlSize(.small) }
            if let error = model.syntaxError { Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled) }
            if model.loadingParents || model.readingHistoryParents { ProgressView("Reading previous revisions…").controlSize(.small) }
            if model.copyingLog { ProgressView("Reading log message for clipboard…").controlSize(.small) }
            if let error = model.error { Text(error).foregroundStyle(.red).textSelection(.enabled) }
            HSplitView {
                VSplitView {
                    BlameTable(model: model).frame(minHeight: 90, maxHeight: .infinity)
                    if model.showLog { BlameHistoryTable(model:model).frame(minHeight:80,idealHeight:170,maxHeight:320) }
                }.frame(minWidth: 450, maxWidth: .infinity, maxHeight: .infinity)
                if model.showProperties {
                    BlamePropertiesPane(entry: model.selectedHistoryEntry, history: model.historyEntries, copy: model.copy)
                        .frame(minWidth: 230, idealWidth: 300, maxWidth: 350, maxHeight: .infinity)
                }
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
            if model.showStatusBar { if let line = model.selectedLine {
                Text("\(line.hash) • \(line.author) <\(line.email)>").font(.system(size: 11)).textSelection(.enabled)
                Text("\(line.summary)\nOrigin: \(line.filename), line \(line.originalLine)").font(.system(size: 11)).textSelection(.enabled)
            }
            Text("\(model.lines.count) lines • \(model.snapshot?.encoding.rawValue ?? "") • \(model.navigationMessage)").font(.system(size: 11)).foregroundStyle(.secondary) }
        }.padding(12).onAppear { model.onGoTo = { showingGoToLine = true } }
        .onDisappear { model.onGoTo = nil }.sheet(isPresented: $showingGoToLine) {
            BlameGoToLineDialog { requested in model.goToLine(requested) }
        }.onReceive(NotificationCenter.default.publisher(for: .blamePreferencesChanged)) { _ in model.applyPreferences() }
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

private struct BlameGoToLineDialog: View {
    let apply: (Int) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var line = "0"
    @State private var error: String?
    @FocusState private var focused: Bool
    private func accept() {
        guard let requested = GitBlameNavigation.requestedLine(line) else {
            error = "Enter a whole number from 0 to \(GitBlameNavigation.maximumGoToLine)."
            focused = true; return
        }
        apply(requested); dismiss()
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Go to line").font(.headline)
            HStack {
                Text("Line:")
                TextField("Line number", text: $line).focused($focused).onSubmit { accept() }
            }
            if let error { Text(error).foregroundStyle(.red).font(.callout).fixedSize(horizontal: false, vertical: true) }
            HStack {
                Button("OK") { accept() }.keyboardShortcut(.defaultAction)
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
            }
        }.padding(20).frame(width: 300).onAppear { focused = true }
    }
}

private struct BlamePropertiesPane: View {
    let entry: LogEntry?
    let history: [LogEntry]
    let copy: (String) -> Void
    private func property(_ name: String, _ value: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(name).foregroundStyle(.secondary).frame(width: 88, alignment: .leading)
            Text(value.isEmpty ? " " : value).frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
        }.accessibilityElement(children: .combine)
    }
    private var properties: GitBlameRevisionProperties? { entry.map { GitBlameRevisionProperties(entry: $0) } }
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Properties").font(.headline).padding(8)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Basic information").font(.headline)
                    property("SHA-1", entry?.hash ?? "")
                    property("Author", entry?.author ?? "")
                    property("Author date", properties?.authorDate ?? "")
                    property("Author email", entry?.email ?? "")
                    property("Committer", entry?.committer ?? "")
                    property("Committer email", entry?.committerEmail ?? "")
                    property("Committer date", properties?.committerDate ?? "")
                    property("Subject", properties?.subject ?? "")
                    property("Body", properties?.body ?? "")
                    Divider()
                    Text("Parents").font(.headline)
                    ForEach(entry?.parents ?? [], id: \.self) { hash in
                        let subject = history.first(where: { $0.hash == hash }).map { GitBlameRevisionProperties(entry: $0).subject } ?? ""
                        property(String(hash.prefix(7)), subject).help("\(hash)\n\(subject)")
                            .contextMenu {
                                TurtleGitContextMenu {
                                    Button { copy(hash) } label: { CommandLabel(title: "Copy SHA-1 to clipboard", icon: .copy) }
                                }
                            }
                    }
                }.font(.system(size: 11)).padding(10).frame(maxWidth: .infinity, alignment: .leading)
            }
        }.background(Color(nsColor: .controlBackgroundColor)).accessibilityLabel("Blame Properties")
    }
}

/// CGitBlameLogList uses the shared column manager with ID replacing Actions.
struct BlameHistoryColumns:Equatable {
    static let definitions:[(String,String,Double,Bool)]=[("graph","Graph",65,true),("id","ID",55,true),("hash","SHA-1",92,true),("message","Message",420,true),("author","Author",140,true),("date","Date",170,true),("email","Email",200,false),("committer","Commit Name",140,false),("committerEmail","Commit Email",200,false),("committerDate","Commit Date",170,false)]
    static let names=definitions.map { $0.0 }
    var visible:Set<String>,order:[String],widths:[String:Double]
    init(visible:Set<String> = Set(definitions.filter { $0.3 }.map { $0.0 }),order:[String] = names,widths:[String:Double] = [:]) {
        self.visible=visible.intersection(Self.names).union(["message"])
        var seen=Set<String>();self.order=(order+Self.names).filter { Self.names.contains($0) && seen.insert($0).inserted }
        self.widths=widths.filter { Self.names.contains($0.key) && $0.value.isFinite && $0.value>=24 }.mapValues { min(10000,$0) }
    }
    static func load(_ preferences:UserDefaults)->Self {
        let key="Blame.LogColumns"
        guard preferences.integer(forKey:key+".Version")==6 else { return Self() }
        let widths=(preferences.dictionary(forKey:key+".Widths") ?? [:]).compactMapValues { ($0 as? NSNumber)?.doubleValue }
        return Self(visible:Set(preferences.stringArray(forKey:key) ?? names),order:preferences.stringArray(forKey:key+".Order") ?? names,widths:widths)
    }
    func save(_ preferences:UserDefaults) {
        let key="Blame.LogColumns";preferences.set(6,forKey:key+".Version");preferences.set(Self.names.filter { visible.contains($0) },forKey:key)
        preferences.set(order,forKey:key+".Order");preferences.set(widths,forKey:key+".Widths")
    }
}

struct BlameHistoryTable:NSViewRepresentable {
    @ObservedObject var model:BlameWindowModel
    func makeCoordinator()->Coordinator { Coordinator(model) }
    func makeNSView(context:Context)->NSScrollView { context.coordinator.makeView() }
    func updateNSView(_ view:NSScrollView,context:Context) { context.coordinator.model=model;context.coordinator.update() }
    static func dismantleNSView(_ view:NSScrollView,coordinator:Coordinator) { coordinator.retired=true }
    @MainActor final class Coordinator:NSObject,NSTableViewDataSource,NSTableViewDelegate,NSMenuDelegate {
        var model:BlameWindowModel
        weak var table:NSTableView?
        var updating=false,retired=false
        private var entries:[LogEntry]=[],graph:[CommitGraphRow]=[]
        private var historyVersion = -1
        private var layout:BlameHistoryColumns?
        private var showGraph=false
        var available:Bool { !retired && model.canFind && table?.window?.attachedSheet==nil }
        init(_ model:BlameWindowModel) { self.model=model }
        func makeView()->NSScrollView {
            let table=BlameHistoryNativeTable();table.style = .plain;table.setAccessibilityLabel("Blame Log")
            table.rowHeight=24;table.intercellSpacing=NSSize(width:4,height:0);table.allowsMultipleSelection=true;table.columnAutoresizingStyle = .noColumnAutoresizing
            for (id,title,width,_) in BlameHistoryColumns.definitions {
                let column=NSTableColumn(identifier:.init(id));column.title=title;column.width=width;column.minWidth=24;column.maxWidth=10000;table.addTableColumn(column)
            }
            table.delegate=self;table.dataSource=self;table.target=self;table.doubleAction=#selector(showLog)
            table.menu=NSMenu();table.menu?.delegate=self
            let header=BlameHistoryColumnHeader(frame:NSRect(x:0,y:0,width:1000,height:24));header.buildMenu={ [weak self] in self?.columnMenu() };table.headerView=header
            table.copySelection={ [weak self] in self?.copyHashes() };table.openSelection={ [weak self] in self?.showLog() };table.showContext={ [weak self] event in self?.showContext(event) }
            self.table=table
            let scroll=NSScrollView();scroll.borderType = .bezelBorder;scroll.hasVerticalScroller=true;scroll.hasHorizontalScroller=true;scroll.documentView=table
            update();return scroll
        }
        func update() {
            guard !retired,let table else { return };updating=true;defer { updating=false }
            if historyVersion != model.historyVersion || showGraph != model.showHistoryGraph {
                historyVersion=model.historyVersion;entries=model.historyEntries;showGraph=model.showHistoryGraph;graph=model.historyGraph;layout=nil;table.reloadData()
            }
            if layout != model.historyColumns || table.tableColumns.first(where:{ $0.identifier.rawValue=="graph" })?.isHidden == showGraph {
                let value=model.historyColumns
                for (index,id) in value.order.enumerated() { if let old=table.tableColumns.firstIndex(where:{ $0.identifier.rawValue==id }),old != index { table.moveColumn(old,toColumn:index) } }
                for column in table.tableColumns {
                    let id=column.identifier.rawValue
                    column.isHidden = !value.visible.contains(id) || id=="graph" && !showGraph
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
        }
        func numberOfRows(in tableView:NSTableView)->Int { entries.count }
        func text(_ id:String,_ row:Int)->String {
            guard entries.indices.contains(row) else { return "" };let entry=entries[row],dates=HistoryDateSettings.load(defaults:model.labelDefaults)
            switch id {
            case "id":return String(entries.count-row)
            case "hash":return String(entry.hash.prefix(10))
            case "author":return entry.author
            case "date":return dates.format(entry.date)
            case "email":return entry.email
            case "committer":return entry.committer
            case "committerEmail":return entry.committerEmail
            case "committerDate":return dates.format(entry.committerDate)
            case "graph":return ""
            default:return entry.logLine(fullMessage:model.fullCommitMessageOnLogLine)
            }
        }
        func tableView(_ tableView:NSTableView,viewFor column:NSTableColumn?,row:Int)->NSView? {
            guard entries.indices.contains(row),let column else { return nil };let entry=entries[row],id=column.identifier.rawValue
            if id=="graph",graph.indices.contains(row) { let cell=GraphCell();cell.graph=graph[row];cell.setAccessibilityLabel("\(entry.parents.count) parents, graph lane \(graph[row].column+1)");return cell }
            let label=NSTextField(labelWithString:text(id,row));label.font=id=="hash" ? .monospacedSystemFont(ofSize:11,weight:.regular) : .systemFont(ofSize:12)
            label.lineBreakMode = .byTruncatingTail;label.maximumNumberOfLines=1;label.toolTip=entry.message+"\n"+entry.hash;if id=="id" { label.alignment = .right }
            let cell=NSTableCellView();cell.textField=label;cell.addSubview(label);label.translatesAutoresizingMaskIntoConstraints=false
            NSLayoutConstraint.activate([label.leadingAnchor.constraint(equalTo:cell.leadingAnchor,constant:3),label.trailingAnchor.constraint(equalTo:cell.trailingAnchor,constant:-3),label.centerYAnchor.constraint(equalTo:cell.centerYAnchor)]);return cell
        }
        func tableViewSelectionDidChange(_ notification:Notification) {
            guard !updating,available,let table else { return }
            let hashes=Set(table.selectedRowIndexes.compactMap { entries.indices.contains($0) ? entries[$0].hash : nil }),row=table.selectedRow
            model.focusHistory(hashes,focus:entries.indices.contains(row) ? entries[row].hash : nil)
        }
        func tableViewColumnDidMove(_ notification:Notification) { saveLayout() }
        func tableViewColumnDidResize(_ notification:Notification) { saveLayout() }
        func saveLayout() {
            guard !updating,available,let table else { return }
            model.saveHistoryColumns(BlameHistoryColumns(visible:model.historyColumns.visible,order:table.tableColumns.map { $0.identifier.rawValue },widths:Dictionary(uniqueKeysWithValues:table.tableColumns.map { ($0.identifier.rawValue,Double($0.width)) })))
        }
        func tableView(_ tableView:NSTableView,sizeToFitWidthOfColumn column:Int)->CGFloat {
            guard tableView.tableColumns.indices.contains(column) else { return 24 };let value=tableView.tableColumns[column],id=value.identifier.rawValue
            let content=entries.indices.map { (text(id,$0) as NSString).size(withAttributes:[.font:NSFont.systemFont(ofSize:12)]).width+14 }.max() ?? 24
            let heading=NSEvent.modifierFlags.contains(.shift) ? (value.title as NSString).size(withAttributes:[.font:NSFont.systemFont(ofSize:12)]).width+20 : 0
            return min(10000,max(24,content,heading))
        }
        func columnMenu()->NSMenu {
            let menu=NSMenu();menu.autoenablesItems=false
            let resetItem=NSMenuItem(title:"Reset columns",action:#selector(reset),keyEquivalent:"");resetItem.target=self;resetItem.isEnabled=available;menu.addItem(resetItem);menu.addItem(.separator())
            for (id,title,_,_) in BlameHistoryColumns.definitions {
                let item=NSMenuItem(title:title,action:#selector(toggle(_:)),keyEquivalent:"");item.target=self;item.representedObject=id;item.state=model.historyColumns.visible.contains(id) ? .on : .off
                item.isEnabled=available && id != "message" && (id != "graph" || model.showHistoryGraph);menu.addItem(item)
            };return menu
        }
        @objc func toggle(_ sender:NSMenuItem) {
            guard available,let id=sender.representedObject as? String,id != "message" else { return };var value=model.historyColumns
            if value.visible.contains(id) { value.visible.remove(id) } else { value.visible.insert(id) };model.saveHistoryColumns(value)
        }
        @objc func reset() { guard available else { return };model.resetHistoryColumns() }
        private var contextTarget:BlameWindowModel.HistoryTarget?
        func showContext(_ event:NSEvent) {
            guard available,let table,let window=table.window else { return }
            let row=event.type == .keyDown ? table.selectedRow : table.row(at:table.convert(event.locationInWindow,from:nil))
            guard row>=0 else { return }
            if !table.selectedRowIndexes.contains(row) { table.selectRowIndexes(IndexSet(integer:row),byExtendingSelection:false) }
            guard let target=model.historyTarget(selected) else { return }
            model.prepareHistoryParents(target) { [weak self,weak table,weak window] _ in
                guard let self,let table,let window,table.window===window,window.isVisible,self.available,self.model.acceptsHistory(target),Set(self.selected.map(\.hash))==Set(target.entries.map(\.hash)),let menu=table.menu else { return }
                self.contextTarget=target;defer { self.contextTarget=nil }
                NSMenu.popUpContextMenu(menu,with:event,for:table)
            }
        }
        private class Invocation:NSObject { let target:BlameWindowModel.HistoryTarget,command:String;init(_ target:BlameWindowModel.HistoryTarget,_ command:String) { self.target=target;self.command=command } }
        private final class ParentInvocation:NSObject {
            let target:BlameWindowModel.HistoryTarget,choices:[GitBlameParentComparison],action:BlameWindowModel.ParentAction
            init(_ target:BlameWindowModel.HistoryTarget,_ choices:[GitBlameParentComparison],_ action:BlameWindowModel.ParentAction) { self.target=target;self.choices=choices;self.action=action }
        }
        @objc func invokeParent(_ sender:NSMenuItem) {
            guard available,let value=sender.representedObject as? ParentInvocation else { return }
            model.performHistoryParent(value.target,choices:value.choices,action:value.action,alternate:NSEvent.modifierFlags.contains(.shift))
        }
        var selected:[LogEntry] { entries.filter { model.selectedLogHashes.contains($0.hash) } }
        func menuNeedsUpdate(_ menu:NSMenu) {
            menu.removeAllItems();menu.autoenablesItems=false
            guard available,let target=contextTarget ?? model.historyTarget(selected),model.acceptsHistory(target) else { return }
            func item(_ title:String,_ command:String,_ icon:MenuIcon,enabled:Bool=true,into parent:NSMenu? = nil) {
                let item=NSMenuItem(title:title,action:#selector(invoke(_:)),keyEquivalent:"");item.target=self;item.image=icon.contextImage(defaults:model.labelDefaults);item.representedObject=Invocation(target,command);item.isEnabled=enabled;(parent ?? menu).addItem(item)
            }
            if target.entries.count==1 {
                let choices=model.cachedHistoryParents(target),parents=Dictionary(grouping:choices,by: \.parentNumber)
                for (title,action,icon,enabled) in [("Blame previous revision",BlameWindowModel.ParentAction.previous,MenuIcon.blame,model.onPrevious != nil),("Compare with previous revision",.compare,.compare,model.onChanges != nil),("Show changes as unified diff",.unified,.unifiedDiff,model.onHistoryUnified != nil)] where !parents.isEmpty {
                    func command(_ number:Int,_ title:String)->NSMenuItem {
                        let result=NSMenuItem(title:title,action:#selector(invokeParent(_:)),keyEquivalent:"");result.target=self;result.image=icon.contextImage(defaults:model.labelDefaults);result.isEnabled=enabled;result.representedObject=ParentInvocation(target,parents[number]!,action);return result
                    }
                    if parents.count==1,let number=parents.keys.first { menu.addItem(command(number,title)) }
                    else {
                        let item=NSMenuItem(title:title,action:nil,keyEquivalent:"");item.image=icon.contextImage(defaults:model.labelDefaults);let sub=NSMenu();sub.autoenablesItems=false
                        for number in parents.keys.sorted() { sub.addItem(command(number,"Parent \(number) (\(parents[number]![0].revision.prefix(8)))")) };item.submenu=sub;menu.addItem(item)
                    }
                }
                if !parents.isEmpty { menu.addItem(.separator()) }
            }
            if target.entries.count==1 {
                item("Show log","log",.log,enabled:model.onLog != nil);menu.addItem(.separator())
                item("Export this version…","export",.export,enabled:model.onHistoryExport != nil)
                item("Create branch at this version…","branch",.branch,enabled:model.onHistoryReference != nil)
                item("Create tag at this version…","tag",.tag,enabled:model.onHistoryReference != nil)
                item("Switch/Checkout to this…","switch",.checkout,enabled:model.onHistorySwitch != nil)
                item("Browse repository","browse",.repositoryBrowser,enabled:model.onHistoryBrowse != nil)
                item("Show branches this commit is on","refs",.showBranches,enabled:model.onContainingReferences != nil);menu.addItem(.separator())
            }
            item("Copy SHA-1 to clipboard","hash",.copy)
            item("Copy log message","details",.copy)
            let parent=NSMenuItem(title:"Copy to clipboard",action:nil,keyEquivalent:"");parent.image=MenuIcon.copy.contextImage(defaults:model.labelDefaults);let sub=NSMenu();sub.autoenablesItems=false;parent.submenu=sub;menu.addItem(parent)
            for (title,command) in [("Full log messages","details"),("Full log messages without changed paths","detailsNoPaths"),("SHA-1","hash"),("Author names and emails","authors"),("Author names","names"),("Author emails","emails"),("Subjects","subjects"),("Messages","messages")] { item(title,command,.copy,into:sub) }
        }
        @objc func invoke(_ sender:NSMenuItem) {
            guard available,let action=sender.representedObject as? Invocation,model.acceptsHistory(action.target) else { return }
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
        @objc func showLog() { guard available,selected.count==1,let entry=selected.first else { return };model.onLog?(model.path,entry.hash) }
        @objc func copyHashes() { guard available,!selected.isEmpty else { return };model.copy(selected.map(\.hash).joined(separator:"\n")) }
    }
}
@MainActor final class BlameHistoryNativeTable:NSTableView {
    var copySelection:()->Void = {},openSelection:()->Void = {}
    var showContext:(NSEvent)->Void = { _ in }
    override func rightMouseDown(with event:NSEvent) { if isEnabled { showContext(event) } }
    override func mouseDown(with event:NSEvent) { if event.modifierFlags.contains(.control) { if isEnabled { showContext(event) };return };super.mouseDown(with:event) }
    override func menu(for event:NSEvent)->NSMenu? {
        guard isEnabled else { return nil };let row=row(at:convert(event.locationInWindow,from:nil));guard row>=0 else { return nil }
        if !selectedRowIndexes.contains(row) { selectRowIndexes(IndexSet(integer:row),byExtendingSelection:false) };menu?.update();return menu
    }
    override func keyDown(with event:NSEvent) { if isEnabled,event.keyCode==109,event.modifierFlags.contains(.shift) { showContext(event);return };if isEnabled,event.keyCode==36 || event.keyCode==76 { openSelection();return };super.keyDown(with:event) }
    override func performKeyEquivalent(with event:NSEvent)->Bool {
        if isEnabled,event.modifierFlags.intersection([.command,.control,.option]) == .command,event.charactersIgnoringModifiers?.lowercased()=="c" { copySelection();return true };return super.performKeyEquivalent(with:event)
    }
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
        table.onContextMenu = { [weak coordinator = context.coordinator] row, event in
            guard let coordinator, coordinator.table != nil, coordinator.model.lines.indices.contains(row), !coordinator.model.busy else { return }
            coordinator.model.prepareParentMenu(number: row + 1) { [weak coordinator] in
                guard let coordinator, let table = coordinator.table, let menu = table.menu, table.window?.isVisible == true else { return }
                NSMenu.popUpContextMenu(menu, with: event, for: table)
            }
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
        table.setAccessibilityLabel("Annotated source")
        let menu = NSMenu(); menu.delegate = context.coordinator; table.menu = menu
        context.coordinator.table = table
        let container = BlameSourceContainer()
        container.editor.delegate = context.coordinator
        container.editor.onContextMenu = { [weak coordinator = context.coordinator] row, event in
            guard let coordinator, let table = coordinator.table, coordinator.model.lines.indices.contains(row), !coordinator.model.busy else { return }
            coordinator.model.prepareParentMenu(number: row + 1) { [weak coordinator] in
                guard let coordinator, let menu = coordinator.table?.menu, let editor = coordinator.container?.editor,
                      editor.window?.isVisible == true else { return }
                NSMenu.popUpContextMenu(menu, with: event, for: editor)
            }
            table.needsDisplay = true
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
        let coordinator = context.coordinator; coordinator.model = model
        guard let table = coordinator.table else { return }
        coordinator.updating = true
        for column in table.tableColumns {
            switch column.identifier.rawValue {
            case "author": column.isHidden = !model.marginFields.contains(.author)
            case "date": column.isHidden = !model.marginFields.contains(.date)
            case "filename": column.isHidden = !model.marginFields.contains(.filename)
            case "original": column.isHidden = !model.marginFields.contains(.original)
            default: break
            }
        }
        if coordinator.revision != model.snapshot?.revision || coordinator.presentation != model.presentation {
            coordinator.revision = model.snapshot?.revision
            coordinator.presentation = model.presentation
            table.rowHeight = max(22, model.sourceFont.ascender - model.sourceFont.descender + model.sourceFont.leading + 6)
        }
        container.installNavigation(model)
        container.updateSource(model)
        let viewportOrigin = container.scroll.contentView.bounds.origin
        table.reloadData()
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
        container.locator.ranks = model.lines.map { model.ranks[$0.hash] }
        container.locator.historyCount = model.historyCount
        container.locator.colorAge = model.colorAge
        container.locator.needsDisplay = true
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
        init(_ model: BlameWindowModel) { self.model = model }
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
            label.toolTip = "\(line.hash)\n\(line.author)\n\(line.summary)\n\(line.filename):\(line.originalLine)"
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
        func menuNeedsUpdate(_ menu: NSMenu) {
            menu.removeAllItems()
            guard let selectedLine = model.selectedLine else { return }
            if model.loadingParents {
                let loading = NSMenuItem(title: "Reading previous revisions…", action: nil, keyEquivalent: ""); loading.isEnabled = false; menu.addItem(loading)
            } else if !model.parentChoices.isEmpty {
                let originalLine = selectedLine.originalLine
                func addCommand(title: String, action: Selector, icon: MenuIcon, enabled: Bool) {
                    func item(_ choice: GitBlameParentComparison, title: String) -> NSMenuItem {
                        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
                        item.target = self; item.image = icon.contextImage()
                        item.representedObject = BlameParentMenuTarget(choice: choice, originalLine: originalLine, options:model.appliedOptions,target:model.sourceParentTarget(selectedLine.hash))
                        item.isEnabled = enabled; return item
                    }
                    if model.parentChoices.count == 1 { menu.addItem(item(model.parentChoices[0], title: title)) }
                    else {
                        let parent = NSMenuItem(title: title, action: nil, keyEquivalent: ""); parent.image = icon.contextImage()
                        let submenu = NSMenu(); submenu.autoenablesItems = false
                        for choice in model.parentChoices { submenu.addItem(item(choice, title: "Parent \(choice.parentNumber) (\(choice.revision.prefix(8)))")) }
                        parent.submenu = submenu; menu.addItem(parent)
                    }
                }
                addCommand(title: "Blame previous revision", action: #selector(blamePrevious(_:)), icon: .blame, enabled: model.onPrevious != nil)
                addCommand(title: "Show changes", action: #selector(showChanges(_:)), icon: .compare, enabled: model.onChanges != nil)
                addCommand(title:"Show changes as unified diff",action:#selector(showUnified(_:)),icon:.unifiedDiff,enabled:model.onHistoryUnified != nil)
            }
            let log = NSMenuItem(title: "Show log", action: #selector(showLog), keyEquivalent: "")
            log.target = self; log.image = MenuIcon.log.contextImage(); log.isEnabled = model.onLog != nil; menu.addItem(log)
            menu.addItem(.separator())
            for (title, action, icon) in [("Copy revision", #selector(copyRevision), MenuIcon.copy), ("Copy log message", #selector(copyLogMessage(_:)), .copy), ("Copy source line", #selector(copySource), .copy)] {
                let item = NSMenuItem(title: title, action: action, keyEquivalent: ""); item.target = self; item.image = icon.contextImage()
                item.representedObject = selectedLine.hash; menu.addItem(item)
            }
            menu.addItem(.separator())
            let copy = NSMenuItem(title: "Copy", action: #selector(copySelectedSource(_:)), keyEquivalent: "")
            copy.target = self; copy.image = MenuIcon.copy.contextImage()
            copy.isEnabled = (container?.editor.selectedRange().length ?? 0) > 0; menu.addItem(copy)
            let all = NSMenuItem(title: "Select All", action: #selector(selectAllSource(_:)), keyEquivalent: "")
            all.target = self; all.isEnabled = !model.lines.isEmpty; menu.addItem(all)
        }
        @objc func showLog() { if let line = model.selectedLine { model.showLog(line) } }
        @objc func showChanges(_ sender: NSMenuItem) {
            if let target=sender.representedObject as? BlameParentMenuTarget,let history=target.target { model.performHistoryParent(history,choices:[target.choice],action:.compare) }
        }
        @objc func showUnified(_ sender:NSMenuItem) {
            if let target=sender.representedObject as? BlameParentMenuTarget,let history=target.target { model.performHistoryParent(history,choices:[target.choice],action:.unified,alternate:NSEvent.modifierFlags.contains(.shift)) }
        }
        @objc func blamePrevious(_ sender: NSMenuItem) {
            if let target=sender.representedObject as? BlameParentMenuTarget,let history=target.target { model.performHistoryParent(history,choices:[target.choice],action:.previous,originalLine:target.originalLine) }
        }
        @objc func copyLogMessage(_ sender: NSMenuItem) {
            if let hash = sender.representedObject as? String { model.copyLogMessage(hash) }
        }
        @objc func copyRevision() { if let line = model.selectedLine { model.copy(line.hash) } }
        @objc func copySource() { if let line = model.selectedLine { model.copy(line.source) } }
        @objc func copySelectedSource(_ sender: Any?) { container?.editor.copy(sender) }
        @objc func selectAllSource(_ sender: Any?) { container?.editor.selectAll(sender) }
    }
}

private final class BlameTableView: NSTableView {
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
    override func reflectScrolledClipView(_ clipView: NSClipView) {
        super.reflectScrolledClipView(clipView); onScroll()
    }
}

private final class BlameSourceContainer: NSView {
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
    private var retired = false
    private var renderedRevision: String?
    private var renderedEncoding: GitBlameEncoding?
    private var renderedPresentation: GitBlamePresentation?
    private var renderedLineCount = -1
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
        locator.scroll = scroll
        scroll.onScroll = { [weak self] in self?.synchronize(fromSource: false) }
        sourceScroll.onScroll = { [weak self] in self?.synchronize(fromSource: true) }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    func retire() {
        retired = true; editor.delegate = nil; editor.onContextMenu = { _,_ in }
        syntaxGeneration += 1; syntaxToken?.cancel(); syntaxTask?.cancel()
        editor.retired = true; editor.isSelectable = false
        editor.onOpen = {};editor.onFind = {}; editor.onFindNext = { _ in }; editor.onGoTo = {}
        scroll.onScroll = {}; sourceScroll.onScroll = {}
    }
    func installNavigation(_ model: BlameWindowModel) {
        guard !retired else { return }
        model.selectedSourceText = { [weak self] in
            guard let self, !self.retired else { return "" }
            let range = self.editor.selectedRange(), text = self.editor.string as NSString
            guard range.location != NSNotFound, NSMaxRange(range) <= text.length else { return "" }
            return text.substring(with: range)
        }
        model.retireSourceView = { [weak self] in self?.retire() }
        editor.onOpen = { [weak model] in model?.onOpenDocument?() }
        editor.onFind = { [weak model] in model?.onFind?() }
        editor.onFindNext = { [weak model] previous in model?.findLine(previous: previous) }
        editor.onGoTo = { [weak model] in model?.onGoTo?() }
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
    func updateSource(_ model: BlameWindowModel) {
        guard !retired else { return }
        if let table = scroll.documentView as? NSTableView {
            gutterWidth = table.tableColumns.filter { !$0.isHidden }.reduce(CGFloat(0)) { $0 + $1.width }
            annotationHeading.subviews.forEach { $0.removeFromSuperview() }
            for column in table.tableColumns where !column.isHidden {
                let label = NSTextField(labelWithString:column.identifier.rawValue == "revision" && model.marginFields.contains(.logID) ? "Log ID" : column.title)
                label.font = .systemFont(ofSize:11); label.maximumNumberOfLines = 1
                label.frame.size = NSSize(width:column.width,height:22); annotationHeading.addSubview(label)
            }
            layoutAnnotationHeading()
            needsLayout = true
        }
        let changed = renderedRevision != model.snapshot?.revision || renderedEncoding != model.snapshot?.encoding ||
            renderedPresentation != model.presentation || renderedLineCount != model.lines.count || wrapped != model.wrapLongLines
        wrapped = model.wrapLongLines
        sourceScroll.hasHorizontalScroller = !wrapped
        editor.isHorizontallyResizable = !wrapped
        editor.textContainer?.widthTracksTextView = wrapped
        let selected = editor.selectedRange()
        if changed {
            renderedRevision = model.snapshot?.revision; renderedEncoding = model.snapshot?.encoding
            renderedPresentation = model.presentation; renderedLineCount = model.lines.count
            editor.lineHeight = max(22, model.sourceFont.ascender - model.sourceFont.descender + model.sourceFont.leading + 6)
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
            desiredSourceWidth = model.lines.reduce(CGFloat(300)) { max($0, model.displayedSource($1).size().width + 24) }
        }
        requestSyntax(model)
        let dark = effectiveAppearance.bestMatch(from:[.aqua,.darkAqua]) == .darkAqua
        editor.rowColors = model.lines.map { line in blameSourceBackground(model, line:line, dark:dark) }
        editor.textStorage?.beginEditing()
        if let storage = editor.textStorage, storage.length > 0 {
            storage.addAttribute(.foregroundColor,value:NSColor.labelColor,range:NSRange(location:0,length:storage.length))
            storage.removeAttribute(.backgroundColor,range:NSRange(location:0,length:storage.length))
            storage.removeAttribute(NSAttributedString.Key("TurtleGitBlameEOLFill"),range:NSRange(location:0,length:storage.length))
            storage.addAttribute(.font,value:model.sourceFont,range:NSRange(location:0,length:storage.length))
            if model.syntaxEnabled, let result = syntaxResult {
                for item in result.ranges where NSMaxRange(item.range) <= storage.length {
                    guard let style = result.styles[String(item.style)] else { continue }
                    if let rgb = style.foreground, let color = blameSyntaxColor(rgb,dark:dark) { storage.addAttribute(.foregroundColor,value:color,range:item.range) }
                    if let rgb = style.background, let color = blameSyntaxColor(rgb,dark:dark) { storage.addAttribute(.backgroundColor,value:color,range:item.range) }
                    var font=model.sourceFont
                    if let family=style.font {
                        font=NSFont(name:family,size:model.sourceFont.pointSize) ?? NSFont(name:"Menlo",size:model.sourceFont.pointSize) ?? .monospacedSystemFont(ofSize:model.sourceFont.pointSize,weight:.regular)
                    }
                    if style.bold == true { font=NSFontManager.shared.convert(font,toHaveTrait:.boldFontMask) }
                    storage.addAttribute(.font,value:font,range:item.range)
                    if style.eolFilled == true,let rgb=style.background,let color=blameSyntaxColor(rgb,dark:dark) {
                        storage.addAttribute(NSAttributedString.Key("TurtleGitBlameEOLFill"),value:color,range:item.range)
                    }
                }
            }
            for (row,line) in model.lines.enumerated() where [1,2].contains(model.highlightKind(line)) && ranges.indices.contains(row) {
                storage.addAttribute(.foregroundColor,value:NSColor.alternateSelectedControlTextColor,range:ranges[row])
                storage.removeAttribute(NSAttributedString.Key("TurtleGitBlameEOLFill"),range:ranges[row])
            }
        }
        editor.textStorage?.endEditing()
        if let storage=editor.textStorage { desiredSourceWidth=max(300,ceil(storage.size().width)+editor.textContainerInset.width*2+24) }
        reflowSource();editor.needsDisplay=true
    }
    private func reflowSource() {
        guard !retired, !reflowing, let manager=editor.layoutManager, let textContainer=editor.textContainer else { return }
        reflowing=true; defer { reflowing=false }
        let origin=sourceScroll.contentView.bounds.origin
        let first=editor.sourceRow(atY:origin.y)
        let within=first.flatMap { editor.rowRectangles.indices.contains($0) ? origin.y-editor.rowRectangles[$0].minY : nil } ?? 0
        let width=wrapped ? max(30,sourceScroll.contentSize.width) : max(desiredSourceWidth,sourceScroll.contentSize.width)
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
            var next=origin;next.y=rectangles[first].minY+min(within,max(0,rectangles[first].height-1))
            if wrapped { next.x=0 }
            sourceScroll.contentView.scroll(to:sourceScroll.contentView.constrainBoundsRect(NSRect(origin:next,size:sourceScroll.contentView.bounds.size)).origin)
        }
        sourceScroll.reflectScrolledClipView(sourceScroll.contentView)
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
                self.syntaxResult = result; model.syntaxWorking = false; self.updateSource(model)
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
        target.reflectScrolledClipView(target.contentView); locator.needsDisplay = true
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
        synchronize(fromSource:true)
        locator.needsDisplay = true
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

private final class BlameSourceTextView: NSTextView {
    var retired = false
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
        guard !retired, selectedRange().length > 0 else { return }
        NSPasteboard.general.clearContents()
        _ = writeSelection(to:NSPasteboard.general,types:[.string])
    }
    override func selectAll(_ sender: Any?) { guard !retired else { return }; super.selectAll(sender) }
    override func writeSelection(to pboard: NSPasteboard, types: [NSPasteboard.PasteboardType]) -> Bool {
        guard !retired, isSelectable else { return false }
        let text = string as NSString
        let ranges = selectedRanges.map { $0.rangeValue }.filter { $0.location != NSNotFound && $0.length > 0 && NSMaxRange($0) <= text.length }
        guard !ranges.isEmpty else { return false }
        let contents = ranges.map { text.substring(with:$0) }.joined(separator:"\n")
        var written = false
        for type in types where type == .string || type.rawValue == "NSStringPboardType" { written = pboard.setString(contents,forType:type) || written }
        return written
    }
    override func writeSelection(to pboard: NSPasteboard, type: NSPasteboard.PasteboardType) -> Bool {
        writeSelection(to:pboard,types:[type])
    }
    override func keyDown(with event: NSEvent) {
        guard !retired else { return }
        let flags = event.modifierFlags.intersection([.command,.control,.option,.shift])
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

@MainActor private func blameSourceBackground(_ model: BlameWindowModel, line: GitBlameLine, dark: Bool) -> NSColor {
    let value = model.presentation.ageColor(rank:model.ranks[line.hash],historyCount:model.historyCount,dark:dark,enabled:model.colorAge)
    let color = NSColor(srgbRed:CGFloat((value >> 16) & 255) / 255,green:CGFloat((value >> 8) & 255) / 255,blue:CGFloat(value & 255) / 255,alpha:1)
    switch model.highlightKind(line) {
    case 1: return dark ? NSColor(srgbRed:0,green:30.0/255,blue:80.0/255,alpha:1) : .selectedContentBackgroundColor
    case 2:
        let selected = dark ? NSColor(srgbRed:0,green:30.0/255,blue:80.0/255,alpha:1) : .selectedContentBackgroundColor
        return selected.blended(withFraction:dark ? 0.15 : 0.35,of:dark ? NSColor(srgbRed:240.0/255,green:240.0/255,blue:240.0/255,alpha:1) : .white) ?? selected
    case 3,4:
        let percentage = model.highlightKind(line) == 3 ? 20 : 10
        let level = ((dark ? 240 : 0) * percentage + (dark ? 32 : 255) * (100 - percentage)) / 100
        return NSColor(srgbRed:CGFloat(level)/255,green:CGFloat(level)/255,blue:CGFloat(level)/255,alpha:1)
    default: return model.colorAge && model.ranks[line.hash] != nil ? color : dark ? NSColor(srgbRed:32.0/255,green:32.0/255,blue:32.0/255,alpha:1) : .white
    }
}

private final class BlameLocatorView: NSView {
    weak var table: NSTableView?
    weak var scroll: NSScrollView?
    var presentation = GitBlamePresentation()
    var ranks: [Int?] = []
    var historyCount = 0
    var colorAge = true
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
