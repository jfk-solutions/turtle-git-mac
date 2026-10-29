import AppKit
import Combine
import SwiftUI
import TurtleGitCore
import UniformTypeIdentifiers

@MainActor private final class PatchNSWindow: NSWindow {
    weak var patchText: NSTextView?
    weak var documentSession: PatchDocumentSession?
    private var livePatchText:PatchTextView.PatchText? {
        guard let text=patchText as? PatchTextView.PatchText,text.window === self else{return nil};return text
    }
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection([.command, .shift, .control, .option])
        if modifiers == .command, event.charactersIgnoringModifiers?.lowercased() == "o", documentSession?.enabled == true { documentSession?.openDocument(); return true }
        if modifiers == .command, event.charactersIgnoringModifiers?.lowercased() == "s", documentSession?.enabled == true { documentSession?.saveDocument(); return true }
        if event.keyCode == 99, modifiers.isEmpty || modifiers == .shift { find(modifiers == .shift ? .previousMatch : .nextMatch); return true }
        if modifiers == [.command, .shift], event.charactersIgnoringModifiers?.lowercased() == "s" {
            livePatchText?.savePatch(nil); return true
        }
        if modifiers == .command, event.charactersIgnoringModifiers?.lowercased() == "p" {
            livePatchText?.printPatch(nil); return true
        }
        if modifiers == .command, event.charactersIgnoringModifiers == "f" {
            find(.showFindInterface); return true
        }
        if modifiers == .command || modifiers == [.command, .shift], event.charactersIgnoringModifiers?.lowercased() == "g" {
            find(modifiers.contains(.shift) ? .previousMatch : .nextMatch); return true
        }
        return super.performKeyEquivalent(with: event)
    }
    func find(_ action: NSTextFinder.Action) {
        livePatchText?.find(action)
    }
    override func cancelOperation(_ sender: Any?) {
        if let text = livePatchText, text.coordinator?.model.findVisible == true {
            text.coordinator?.model.hideFind()
        } else if livePatchText?.enclosingScrollView?.isFindBarVisible == true {
            find(.hideFindInterface); makeFirstResponder(patchText)
        } else { performClose(sender) }
    }
}

@MainActor final class PatchWindowController: NSWindowController, NSWindowDelegate {
    let model: PatchWindowModel
    private(set) var documentSession: PatchDocumentSession!
    var startupInput: UnifiedDiffInputSession?
    private var standaloneCompletion:UnifiedDiffToolCompletion?
    private var standaloneCloseTask:Task<Void,Never>?
    private var standaloneCompletionRequested=false
    private var closed=false
    var startupInputReporter:((UnifiedDiffStartupInputOutcome)->Void)? {
        guard let receipt=standaloneCompletion else{return nil}
        return {receipt.finish($0)}
    }
    func configureStandaloneInputCompletion(_ completion:@escaping(Int32)->Void){
        guard standaloneCompletion==nil,!closed else{return}
        standaloneCompletion=UnifiedDiffToolCompletion(completion)
    }
    /// Called only after the application grants its ordinary dirty-document
    /// termination and drains accepted input. It does not close another owner.
    func completeStandaloneInputForTermination(){completeStandaloneAfterOwnedDrain()}
    private func completeStandaloneAfterOwnedDrain(){
        guard let receipt=standaloneCompletion,!standaloneCompletionRequested else{return}
        standaloneCompletionRequested=true
        let session=documentSession!,input=startupInput
        session.retire()
        standaloneCloseTask=Task{[weak self,receipt,session,input] in
            await input?.cancelAndWait()
            await session.waitForRetirement()
            receipt.ownerClosed()
            self?.standaloneCloseTask=nil
        }
    }

    var onClosed: () -> Void = {}
    var onMoved: () -> Void = {}
    private let preferences: UserDefaults
    private var flashGeneration = 0
    func windowDidMove(_ notification: Notification) { onMoved() }
    convenience init(documentDirectory: URL, preferences: UserDefaults = .standard) {
        self.init(repository: nil, access: nil, preferences: preferences, documentDirectory: documentDirectory)
    }
    init(repository: GitRepository?, access: RepositoryAccessLease?, preferences: UserDefaults = .standard, documentDirectory: URL? = nil) {
        self.preferences = preferences
        model = PatchWindowModel(repository: repository, access: access, appearancePreferences: preferences, documentDirectory: documentDirectory)
        model.usesSourceFindBar = true
        model.darkMode = NSApp.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        let savedWidth = preferences.double(forKey: "PartialPatchWindowWidth")
        let width = savedWidth >= 460 && savedWidth <= 4000 ? savedWidth : 600
        let window = PatchNSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: 760),
                              styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.minSize = NSSize(width: 460, height: 500); window.isReleasedWhenClosed = false
        // Follow the application's live appearance until this document receives
        // an explicit File > Dark Mode choice. Embedded views inherit their host.
        window.appearance = nil
        let host = NSHostingController(rootView: PatchDialog(model: model))
        // Patch content scrolls; its intrinsic size must not replace window limits.
        host.sizingOptions = []
        window.contentViewController = host
        super.init(window: window); window.delegate = self; TurtleGitHelp.attach(window, topic: .unifiedDiff)
        documentSession = PatchDocumentSession(owner: self); window.documentSession = documentSession
        window.setContentSize(NSSize(width: width, height: 760))
        model.saveDocument = { [weak self] in self?.documentSession.saveDocument() }
        model.openDocument = { [weak self] in self?.documentSession.openDocument() }
        model.saveAs = { [weak window] in (window?.patchText as? PatchTextView.PatchText)?.savePatch(nil) }
        model.printDiff = { [weak window] in (window?.patchText as? PatchTextView.PatchText)?.printPatch(nil) }

        model.onFindBoundary = { [weak self, weak window] in
            guard let self, !self.model.retired, let view = window?.contentView else { return }
            self.flashGeneration += 1; let identity = self.flashGeneration
            view.wantsLayer = true
            for step in 0..<6 {
                DispatchQueue.main.asyncAfter(deadline: .now() + Double(step) * 0.1) { [weak self, weak view] in
                    guard let self, self.flashGeneration == identity, !self.model.retired, let view else { return }
                    view.layer?.borderWidth = step % 2 == 0 ? 2 : 0
                    view.layer?.borderColor = NSColor.controlAccentColor.cgColor
                }
            }
        }
        DialogGeometry.attach(window, identifier: "PatchWindowController")
    }
    func presentDocument(_ bytes: Data, title: String, comparison: String, information: String, paths: [String] = [], file: URL? = nil, fileAccess: RepositoryAccessLease? = nil, refreshAvailable: Bool = false, refresh: (() -> Void)? = nil) {
        model.allowsDocumentEditing = true
        // The model's readOnly bit fences staging; standalone document editing
        // has its separate gate. Publish every comparison field as one request.
        model.readOnly = true
        documentSession.present(bytes, file: file, access: fileAccess) { [weak self] in
            guard let self else { return }
            self.model.comparisonTitle = comparison; self.model.readOnlyInformation = information
            self.model.paths = paths; self.model.refreshAvailable = refreshAvailable; self.model.customRefresh = refresh
            self.window?.title = title
        }
    }
    func acceptDocumentSave(_ source:UnifiedDiffDocument) {
        model.markDocumentSaved(source)
        (window as? PatchNSWindow)?.patchText?.breakUndoCoalescing()
    }
    func setDarkMode(_ dark: Bool) {
        guard let window, window.delegate === self, !model.retired, !model.busy,
              !model.confirmingQuit, model.error == nil, window.attachedSheet == nil,
              NSApp.modalWindow == nil else { return }
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        model.darkMode = dark
    }
    func windowWillClose(_ notification: Notification) {
        guard let closing=notification.object as? NSWindow,closing === window,!closed else{return}
        closed=true
        startupInput?.cancel()
        flashGeneration += 1; window?.contentView?.layer?.borderWidth = 0
        documentSession.retire(); model.retire()
        if let window { preferences.set(window.frame.width, forKey: "PartialPatchWindowWidth") }
        onClosed()
        completeStandaloneAfterOwnedDrain()
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if startupInput?.requestClose() == true || documentSession.requestStartupInputClose() { return false }
        guard !model.busy, !model.confirmingQuit, sender.attachedSheet == nil else { return false }
        if documentSession.dirty { documentSession.requestClose(); return false }
        return true
    }
    static func focusedOwner(_ initial: NSWindow?) -> PatchWindowController? {
        var candidate = initial, seen = Set<ObjectIdentifier>()
        while let window = candidate, seen.insert(ObjectIdentifier(window)).inserted {
            if let owner = window.delegate as? PatchWindowController { return owner }
            candidate = window.sheetParent ?? window.parent
        }
        return nil
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
}

@MainActor final class PatchWindowModel: ObservableObject {
    let repository: GitRepository?
    let documentDirectory: URL
    private let access: RepositoryAccessLease?
    let appearancePreferences: UserDefaults
    @Published var darkMode = false
    @Published private(set) var appearanceRevision = 0
    private var appearanceSettings:UnifiedDiffAppearance
    private var appearanceChanges:[AnyCancellable]=[]
    @Published var document = GitPatch(text: "") { didSet { originalDiff = nil; findRevision=UUID() } }
    private var originalDiff: UnifiedDiffDocument?
    var usesSourceFindBar = false
    @Published var allowsDocumentEditing = false
    @Published private(set) var documentDirty = false
    @Published private(set) var documentResetRevision = 0
    private var savedDocument: UnifiedDiffDocument?
    private var editBuffer:UnifiedDiffEditBuffer?
    private var approvedReplacementText: String?
    private var savedText = ""
    var savedDocumentBytes: Data { savedDocument?.bytes ?? Data() }
    var refreshReplacementApproved: Bool { approvedReplacementText.map {GitReferenceName.equal($0,document.text)} == true }
    var repositoryAccess: RepositoryAccessLease? { access }
    var requestReplacement: ((Data,ComparisonTextEncoding) -> Void)?
    var requestReload: (([String], Bool,ComparisonTextEncoding) -> Void)?
    var documentChanged: () -> Void = {}
    var canEditText: Bool { allowsDocumentEditing && readOnly && canFind && error == nil }
    func editDocument(_ text: String) {
        guard canEditText else { return }
        approvedReplacementText = nil
        if editBuffer==nil,let savedDocument {editBuffer=UnifiedDiffEditBuffer(document:savedDocument)}
        editBuffer?.replaceText(text)
        document = GitPatch(text:text,displayLegacyEncoding:document.displayLegacyEncoding)
        refreshDocumentDirtyState()
        documentChanged()
    }
    private func refreshDocumentDirtyState() {
        do {
            if !GitReferenceName.equal(document.text, savedText) { documentDirty = true }
            else if let editBuffer, let savedDocument { documentDirty = try editBuffer.snapshot().bytes != savedDocument.bytes }
            else { documentDirty = false }
            if !documentDirty { originalDiff = savedDocument }
        } catch { documentDirty = true } // An unencodable draft stays editable; Save reports the codec error.
    }
    func lineEditingBufferSnapshot() throws -> UnifiedDiffEditBuffer {
        if let editBuffer { return editBuffer }
        return UnifiedDiffEditBuffer(document: try documentSnapshot())
    }
    /// The native editor installs provenance before publishing its didChangeText
    /// notification. A byte-only permutation is still a dirty document edit.
    func installLineEditingBuffer(_ buffer: UnifiedDiffEditBuffer) { editBuffer = buffer }
    func markDocumentSaved(_ source:UnifiedDiffDocument) {
        savedText=source.displayText;savedDocument=source
        if editBuffer==nil {editBuffer=UnifiedDiffEditBuffer(document:source)} else {editBuffer?.markSaved(source)}
        originalDiff=source;documentDirty=false;documentChanged()
    }
    @Published var selectedLines = Set<Int>()
    @Published var staged = false
    @Published var readOnly = false { didSet { if !readOnly { originalDiff = nil;editBuffer=nil } } }
    @Published var refreshAvailable = true
    var saveDocument: () -> Void = {}
    var openDocument: () -> Void = {}
    var saveAs: () -> Void = {}
    var printDiff: () -> Void = {}
    @Published var showPageSetup = false
    func pageSetup() {
        guard !retired, !busy, !confirmingQuit, !showPageSetup else { return }
        busy = true; showPageSetup = true
    }
    @Published var comparisonTitle = "HEAD → Working tree"
    var customRefresh: (() -> Void)?
    var readOnlyInformation: String?
    var base: String?
    @Published var busy = false {didSet {if oldValue != busy {findRevision=UUID()}}}
    @Published var confirmingQuit = false {didSet {if oldValue != confirmingQuit {findRevision=UUID()}}}
    @Published var error: String? { didSet { if error != nil { approvedReplacementText = nil } } }
    @Published var paths: [String] = []
    private var generation = 0
    private var readTask: Task<Void, Never>?
    private var readCancellation: OperationCancellation?
    private var ownedReads = 0
    private var applying = false
    var applyingChanges: Bool { applying }
    var externalAvailability: () -> Bool = { true }
    private(set) var retired = false
    static private(set) var activeOperations = 0
    @Published private(set) var loading = false
    @Published private(set) var cancelling = false
    @Published private(set) var findVisible = false {didSet {if oldValue != findVisible {findRevision=UUID()}}}
    @Published private(set) var findFocusRequest = 0
    @Published private(set) var findBoundaryCount = 0
    @Published var findText = ""
    @Published var findMatchCase = false
    private var findRevision=UUID()
    struct FindContext:Equatable {let owner:ObjectIdentifier;let revision:UUID;let source:UUID?}
    var findContext:FindContext {.init(owner:ObjectIdentifier(self),revision:findRevision,source:sourceOwnerID)}
    func canUseFind(_ context:FindContext)->Bool {canFind && findVisible && context.source != nil && context==findContext && sourceAttached()}
    func findField(context:FindContext)->Binding<String> {
        Binding(get:{self.findText},set:{if self.canUseFind(context) {self.changeFindText($0)}})
    }
    func findCase(context:FindContext)->Binding<Bool> {
        Binding(get:{self.findMatchCase},set:{if self.canUseFind(context) {self.findMatchCase=$0}})
    }
    func search(previous:Bool,context:FindContext) {guard canUseFind(context) else{return};search(previous:previous)}
    func hideFind(context:FindContext) {guard canUseFind(context) else{return};hideFind()}
    private(set) var sourceCallbackRevision=UUID()
    func sourceCallbacksCurrent(_ identity:UUID,revision:UUID)->Bool {!retired && sourceOwnerID==identity && sourceCallbackRevision==revision}
    var sourceOwnerID: UUID? {didSet {
        guard oldValue != sourceOwnerID else{return};sourceMoved(sourceOwnerID)
    }}
    func sourceMoved(_ identity:UUID?) {
        guard sourceOwnerID==identity else{return};findRevision=UUID();sourceCallbackRevision=UUID()
        // Registration/attachment may occur during a SwiftUI update. Refresh
        // the bar on the next turn, only while this registration still owns it.
        let owner=sourceOwnerID
        Task {@MainActor [weak self] in
            await Task.yield()
            guard let self,!self.retired,self.sourceOwnerID==owner else{return}
            self.objectWillChange.send()
        }
    }
    var sourceAttached:()->Bool = {false}
    var sourceSelection: () -> NSRange = { NSRange(location: 0, length: 0) }
    var selectSource: (NSRange) -> Void = { _ in }
    var focusSource: () -> Void = {}
    var onFindBoundary: () -> Void = {}
    var canFind: Bool { !retired && !busy && !confirmingQuit }
    func showFind() {
        guard canFind else { return }
        let selected = sourceSelection(), text = document.text as NSString
        if selected.length > 0, selected.location <= text.length, NSMaxRange(selected) <= text.length {
            changeFindText(text.substring(with: selected))
        }
        findRevision=UUID();findVisible = true; findFocusRequest += 1
    }
    func hideFind() {
        guard canFind else { return }; findVisible = false; focusSource()
    }
    func changeFindText(_ text: String) {
        guard canFind else { return }; findText = text
        selectSource(NSRange(location: 0, length: 0))
        if !text.isEmpty { search(previous: false) }
    }
    func search(previous: Bool) {
        guard canFind else { return }
        guard !findText.isEmpty else { showFind(); return }
        let text = document.text as NSString, selection = sourceSelection()
        let cursor = min(text.length, previous ? selection.location : NSMaxRange(selection))
        if let found=UnifiedDiffSearch.find(findText,in:document.text,from:cursor,backwards:previous,matchCase:findMatchCase) {
            selectSource(found)
        } else {
            selectSource(NSRange(location:cursor,length:0));findBoundaryCount += 1;onFindBoundary()
        }
    }

    private var startupCancel: (() -> Void)?
    @discardableResult func beginStartupInput(cancel: @escaping () -> Void) -> Bool {
        guard !retired, !busy, !confirmingQuit, startupCancel == nil else { return false }
        startupCancel = cancel; busy = true; loading = true; cancelling = false; error = nil
        return true
    }
    func markStartupInputCancelling() {
        guard startupCancel != nil else { return }; cancelling = true
    }
    func finishStartupInput() {
        guard startupCancel != nil else { return }
        startupCancel = nil; loading = false; cancelling = false; busy = applying || ownedReads != 0
    }
    func cancelRead() {
        guard !retired, loading, !cancelling else { return }
        cancelling = true
        if let startupCancel { startupCancel(); return }
        readCancellation?.cancel(); readTask?.cancel()
    }
    func retire() {
        guard !retired else { return }; retired = true; generation += 1
        appearanceChanges.removeAll()
        startupCancel?(); readCancellation?.cancel(); readTask?.cancel()
        sourceAttached={false};sourceSelection = { NSRange(location: 0, length: 0) }; selectSource = { _ in }; focusSource = {}; onFindBoundary = {}
        requestReplacement = nil; requestReload = nil; documentChanged = {};editBuffer=nil
        saveDocument = {}; openDocument = {}; saveAs = {}; printDiff = {}; customRefresh = nil; onApplied = {}; onApplying = { _ in }; onSettled = { _ in }
        findVisible = false; externalAvailability = { false }
    }
    var onApplying: (Bool) -> Void = { _ in }
    var onApplied: () -> Void = {}
    var onSettled: (Bool) -> Void = { _ in }
    init(repository: GitRepository?, access: RepositoryAccessLease?, appearancePreferences: UserDefaults = .standard, documentDirectory: URL? = nil) {
        self.repository = repository; self.access = access; self.appearancePreferences = appearancePreferences
        appearanceSettings = .load(from:appearancePreferences)
        self.documentDirectory = documentDirectory ?? repository?.root ?? URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
        for name in [UserDefaults.didChangeNotification,.unifiedDiffAppearanceChanged] {
            appearanceChanges.append(NotificationCenter.default.publisher(for:name).sink { [weak self] _ in
                Task { @MainActor [weak self] in
                    guard let self,!self.retired else{return}
                    // Equivalent suite instances need not share object identity.
                    // Always read this owner's store; decoded equality prevents
                    // unrelated domains from publishing an appearance change.
                    self.reloadAppearancePreferences()
                }
            })
        }
    }
    private func reloadAppearancePreferences() {
        guard !retired else{return}
        let value=UnifiedDiffAppearance.load(from:appearancePreferences)
        guard value != appearanceSettings else{return}
        appearanceSettings=value;appearanceRevision += 1
    }
    func observedAppearance(dark:Bool) {
        guard !retired,darkMode != dark else{return};darkMode=dark
    }
    var exportDocument: UnifiedDiffDocument { readOnly ? originalDiff ?? UnifiedDiffDocument(bytes: document.bytes,displayLegacyEncoding:document.displayLegacyEncoding) : UnifiedDiffDocument(bytes: document.bytes,displayLegacyEncoding:document.displayLegacyEncoding) }
    func copyPatch(to pasteboard: NSPasteboard = .general) {
        guard !retired, !busy, !confirmingQuit else { return }
        do {
            let source=try documentSnapshot()
            if !PatchClipboard.write(source,to:pasteboard) {error="The patch could not be copied to the clipboard."}
        } catch {self.error=error.localizedDescription}
    }
    func documentSnapshot() throws ->UnifiedDiffDocument {
        if readOnly,documentDirty,let editBuffer {return try editBuffer.snapshot()}
        return exportDocument
    }
    func encodedDocumentBytes() throws ->Data {try documentSnapshot().bytes}
    func setReadOnlyDiff(_ bytes: Data, discardingEdits: Bool = false,displayLegacyEncoding:ComparisonTextEncoding? = nil,sourceEncoding:ComparisonTextEncoding? = nil) {
        guard !retired else { return }
        let legacy=displayLegacyEncoding ?? .legacyEncoding(from:appearancePreferences)
        if allowsDocumentEditing && documentDirty && !discardingEdits && !refreshReplacementApproved {requestReplacement?(bytes,legacy);return}
        approvedReplacementText = nil
        let source = UnifiedDiffDocument(bytes:bytes,displayLegacyEncoding:legacy,sourceEncoding:sourceEncoding)
        readOnly = true; document = GitPatch(text:source.displayText,displayLegacyEncoding:legacy); originalDiff = source
        savedText = document.text; savedDocument = source; editBuffer=allowsDocumentEditing ? UnifiedDiffEditBuffer(document:source):nil; documentDirty = false; documentResetRevision += 1; documentChanged()
    }
    var canApplyLines: Bool { !retired && !readOnly && !busy && !confirmingQuit && externalAvailability() && selectedLines.contains(where: { document.changedLine($0) }) }
    var canApplyHunks: Bool { !retired && !readOnly && !busy && !confirmingQuit && externalAvailability() && document.files.flatMap(\.hunks).contains { hunk in selectedLines.contains(hunk.header) || hunk.range.contains(where: { selectedLines.contains($0) }) } }
    var information: String {
        if readOnly, let readOnlyInformation { return readOnlyInformation }
        if paths.isEmpty { return "Select files in the Commit window to see their patch." }
        if readOnly { return document.text.isEmpty ? "No patch for the selected files." : "Select files in the Commit window to compare their contents." }
        if document.text.isEmpty { return "No selectable text changes in this view." }
        if document.files.contains(where: { !$0.supportsPartialChanges }) { return "Binary, symlink, copied files and metadata-only changes require whole-file staging." }
        if document.files.contains(where: { $0.hasSelectedTextMetadata }) { return "Rename and file mode changes are applied with the selected text. Right-click for staging actions." }
        return "Select changed lines, or place the caret in a hunk. Right-click for staging actions."
    }
    func reload(paths: [String], staged: Bool, discardingEdits: Bool = false,displayLegacyEncoding:ComparisonTextEncoding? = nil) {
        guard !retired, !applying, !confirmingQuit, !showPageSetup, startupCancel == nil else { return }
        let legacy=displayLegacyEncoding ?? .legacyEncoding(from:appearancePreferences)
        if documentDirty && !discardingEdits {requestReload?(paths,staged,legacy);return}
        if let customRefresh { if discardingEdits { approvedReplacementText = document.text }; customRefresh(); return }
        guard let repository = self.repository?.capturingDiffBackend(preferences: appearancePreferences) else { return }
        readCancellation?.cancel(); readTask?.cancel()
        generation += 1; let request = generation, cancellation = OperationCancellation()
        readCancellation = cancellation
        let base = self.base, readOnly = self.readOnly
        self.paths = paths; self.staged = staged; selectedLines = []; document = GitPatch(text: "")
        busy = true; loading = true; cancelling = false; error = nil
        ownedReads += 1; Self.activeOperations += 1
        readTask = Task {
            defer {
                ownedReads -= 1; Self.activeOperations -= 1
                if request == generation {
                    readTask = nil; readCancellation = nil; loading = false; cancelling = false; busy = false
                } else if retired && ownedReads == 0 && !applying { loading = false; cancelling = false; busy = false }
            }
            do {
                let bytes: Data
                if paths.isEmpty { bytes = Data() }
                else if readOnly { bytes = try await repository.workingTreePatchData(paths: paths, base: base, cancellation: cancellation) }
                else { bytes = try await repository.patchData(paths:paths,staged:staged,base:base,cancellation:cancellation,includeUntracked:!staged) }
                guard !retired, request == generation, !cancellation.isCancelled, !Task.isCancelled else { return }
                if readOnly { setReadOnlyDiff(bytes,displayLegacyEncoding:legacy) } else { document = GitPatch(bytes:bytes,includesUntracked:!staged,displayLegacyEncoding:legacy) }
            } catch {
                if !retired && request == generation && !cancellation.isCancelled && !Task.isCancelled { self.error = error.localizedDescription }
            }
        }
    }
    func apply(entireHunks: Bool) {
        guard let repository, !retired, !readOnly, entireHunks ? canApplyHunks : canApplyLines else { return }
        let document = self.document, paths = self.paths, staged = self.staged, lines = selectedLines, base = self.base
        let releaseParent = onApplying, settleParent = onSettled
        busy = true; applying = true; Self.activeOperations += 1; releaseParent(true)
        Task {
            var succeeded = false
            do {
                try await repository.applyPatchSelection(document, paths: paths, staged: staged, lines: lines, entireHunks: entireHunks, base: base)
                succeeded = true
            } catch { if !retired { self.error = error.localizedDescription } }
            applying = false; busy = ownedReads != 0; Self.activeOperations -= 1
            // Balance the original parent gate even after a forced child close.
            releaseParent(false); settleParent(succeeded)
            guard !retired else { return }
            if succeeded { onApplied(); reload(paths: paths, staged: staged) }
        }
    }
}

struct PatchDialog: View {
    @ObservedObject var model: PatchWindowModel
    var reservesLoadingStatus = false
    var minimumTextHeight:CGFloat = 360
    @Environment(\.colorScheme) private var colorScheme
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if model.readOnly { HStack {
                Text(model.readOnly ? model.comparisonTitle : model.staged ? (model.base == nil ? "HEAD → Index" : "Parent → Index") : "Index → Working tree").font(.headline)
                Spacer(); if model.busy { ProgressView().controlSize(.small) }
                Button { model.copyPatch() } label: { CommandLabel(title: "Copy Patch", icon: .copy) }.disabled(model.busy || model.exportDocument.bytes.isEmpty)
                Button { model.saveAs() } label: { CommandLabel(title: "Save As…", icon: .saveAs) }.disabled(model.busy)
                Button { model.printDiff() } label: { Label("Print…", systemImage: "printer") }.disabled(model.busy)
                if model.refreshAvailable { Button("Refresh") { model.reload(paths: model.paths, staged: model.staged) }.disabled(model.busy) }
            } }
            PatchTextView(model: model).frame(minWidth: 430, minHeight: minimumTextHeight)
            if model.findVisible { PartialPatchFindBar(model: model) }
            if reservesLoadingStatus {
                loadingStatus.frame(height: 24).opacity(model.loading ? 1 : 0)
                    .allowsHitTesting(model.loading).accessibilityHidden(!model.loading)
            } else if model.loading { loadingStatus }
            if model.readOnly { Text(model.documentDirty ? "Modified patch document" : model.information).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
        }.padding(model.readOnly ? 12 : 0).disabled(model.confirmingQuit)
        .background(Color(nsColor:.windowBackgroundColor))
        .onAppear {model.observedAppearance(dark:colorScheme == .dark)}
        .onChange(of:colorScheme) {model.observedAppearance(dark:$0 == .dark)}
        .sheet(isPresented: $model.showPageSetup, onDismiss: { model.busy = false }) { PatchPageSetup(model: model) }
        .alert(model.readOnly ? "Patch could not be loaded" : "Patch could not be applied", isPresented: Binding(get: { !model.retired && model.error != nil }, set: { if !$0 && !model.retired { model.error = nil } })) {
            Button("OK") { model.error = nil }
        } message: { Text(model.error ?? "") }
    }
    private var loadingStatus: some View {
        HStack {
            ProgressView(model.cancelling ? "Cancelling…" : "Loading patch…").controlSize(.small)
            Button("Cancel") { model.cancelRead() }.disabled(model.cancelling)
        }
    }
}

private struct PartialPatchFindBar: View {
    @ObservedObject var model: PatchWindowModel
    @FocusState private var focused: Bool
    var body: some View {
        let context=model.findContext
        HStack(spacing: 6) {
            Button { model.hideFind(context:context) } label: { Image(nsImage: MenuIcon.originalImage(resource: "cancel-normal", size: 16) ?? NSImage(systemSymbolName: "xmark", accessibilityDescription: "Close Find")!) }.buttonStyle(.plain).help("Close Find")
            Text("Find:").fixedSize()
            TextField("Find", text:model.findField(context:context))
                .textFieldStyle(.roundedBorder).focused($focused).frame(minWidth:64).onSubmit { model.search(previous: false,context:context) }
                .onExitCommand { model.hideFind(context:context) }
                .accessibilityIdentifier(model.readOnly ? "UnifiedDiff.FindText" : "PartialPatch.FindText")
            Button("‹ Previous") { model.search(previous: true,context:context) }.fixedSize()
            Button("Next ›") { model.search(previous: false,context:context) }.fixedSize()
            Toggle("Match case", isOn:model.findCase(context:context)).toggleStyle(.checkbox).fixedSize()
        }.controlSize(.small).frame(height:24).padding(6).disabled(!model.canFind)
        .onAppear { requestFocus() }
        .onChange(of: model.findFocusRequest) { _ in requestFocus() }
    }
    private func requestFocus() {
        focused = false
        let context=model.findContext,request=model.findFocusRequest
        DispatchQueue.main.async { if model.canUseFind(context),model.findFocusRequest==request { focused = true } }
    }
}

/// Match the actual text extent after layout, including late viewport sizing.
/// PatchView's unwrapped lines must scroll horizontally rather than clip.
@MainActor final class PatchScrollView: NSScrollView {
    private var measuring = false
    weak var lineNumberGutter: PatchLineNumberGutter?
    var resetToStart = false
    override func layout() { super.layout(); updateDocumentExtent() }
    func updateDocumentExtent() {
        guard !measuring, let text = documentView as? NSTextView,
              let layout = text.layoutManager, let container = text.textContainer,
              contentView.bounds.width > 0, contentView.bounds.height > 0 else { return }
        measuring = true; defer { measuring = false }
        layout.ensureLayout(for: container)
        let used = layout.usedRect(for: container), inset = text.textContainerInset
        // The actual clip viewport is authoritative, including native borders,
        // scrollers and a visible find bar.
        let viewport = contentView.bounds.size
        // NSTextView may perform another native sizeToFit after this layout.
        // Keep that resize from shrinking underneath the actual viewport.
        if text.minSize != viewport { text.minSize = viewport }
        let size = NSSize(width: max(viewport.width, ceil(used.maxX + inset.width * 2)), height: max(viewport.height, ceil(used.maxY + inset.height * 2)))
        if text.frame.size != size { text.setFrameSize(size) }
        restoreDocumentOrigin(contentView.bounds.origin)
        if resetToStart {
            resetToStart = false; text.setSelectedRange(NSRange(location: 0, length: 0))
            contentView.scroll(to: .zero); reflectScrolledClipView(contentView)
        }
    }
    func restoreDocumentOrigin(_ origin: NSPoint) {
        guard let text = documentView else { return }
        let viewport = contentView.bounds.size
        let point = NSPoint(x: min(max(0, origin.x), max(0, text.frame.width - viewport.width)),
                            y: min(max(0, origin.y), max(0, text.frame.height - viewport.height)))
        if contentView.bounds.origin != point { contentView.scroll(to: point); reflectScrolledClipView(contentView) }
    }
}

struct PatchTextView: NSViewRepresentable {
    @ObservedObject var model: PatchWindowModel
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.colorScheme) private var colorScheme
    func makeCoordinator() -> Coordinator { Coordinator(model: model) }
    func makeNSView(context: Context) -> PatchTextHost {
        let text = PatchText()
        text.isEditable = model.canEditText; text.allowsUndo = true; text.isSelectable = true; text.delegate = context.coordinator
        text.isAutomaticQuoteSubstitutionEnabled = false; text.isAutomaticDashSubstitutionEnabled = false; text.isAutomaticTextReplacementEnabled = false; text.isAutomaticSpellingCorrectionEnabled = false
        text.coordinator = context.coordinator
        text.columnSelection = PatchColumnSelectionController(text: text)
        text.isRichText = false; text.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        text.usesFindBar = !model.usesSourceFindBar; text.isIncrementalSearchingEnabled = !model.usesSourceFindBar
        text.isHorizontallyResizable = true; text.isVerticallyResizable = true
        text.autoresizingMask = []
        text.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        text.textContainer?.widthTracksTextView = false
        text.textContainer?.containerSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        let scroll = PatchScrollView(); scroll.hasVerticalScroller = true; scroll.hasHorizontalScroller = true
        scroll.findBarPosition = .belowContent
        scroll.autohidesScrollers = true; scroll.borderType = .bezelBorder; scroll.documentView = text
        let gutter = PatchLineNumberGutter(scroll: scroll, text: text)
        return PatchTextHost(scroll: scroll, gutter: gutter)
    }
    func updateNSView(_ host: PatchTextHost, context: Context) {
        let scroll = host.scroll
        guard !model.retired, let text = scroll.documentView as? PatchText else { return }
        if context.coordinator.model !== model {
            let previous=context.coordinator.model
            if previous.sourceOwnerID==context.coordinator.identity {
                previous.sourceOwnerID=nil;previous.sourceAttached={false};previous.sourceSelection={NSRange(location:0,length:0)};previous.selectSource={_ in};previous.focusSource={}
            }
        }
        context.coordinator.model = model
        text.isEditable = model.canEditText
        text.usesFindBar = !model.usesSourceFindBar; text.isIncrementalSearchingEnabled = !model.usesSourceFindBar
        let identity=context.coordinator.identity
        model.sourceOwnerID = identity
        let callbackRevision=model.sourceCallbackRevision
        scroll.lineNumberGutter?.bind(identity: identity, revision: callbackRevision) { [weak text, weak model] in
            guard let text, let model else { return false }
            return model.canFind && model.sourceCallbacksCurrent(identity, revision: callbackRevision) && text.coordinator?.model === model
        }
        model.sourceAttached={ [weak text,weak model] in
            guard let text,let model else{return false};return model.sourceCallbacksCurrent(identity,revision:callbackRevision) && text.coordinator?.model === model && text.window != nil
        }
        model.sourceSelection = { [weak text,weak model] in
            guard let text,let model,model.sourceCallbacksCurrent(identity,revision:callbackRevision),text.coordinator?.model === model,text.window != nil else{return NSRange(location:0,length:0)}
            return text.selectedRange()
        }
        model.selectSource = { [weak text,weak model] range in
            guard let text,let model,model.sourceCallbacksCurrent(identity,revision:callbackRevision),text.coordinator?.model === model,text.window != nil else { return }; let count = (text.string as NSString).length
            let selected = NSRange(location: min(range.location, count), length: min(range.length, max(0, count - range.location)))
            text.setSelectedRange(selected); text.scrollRangeToVisible(selected)
        }
        model.focusSource = { [weak text,weak model] in
            guard let text,let model,model.sourceCallbacksCurrent(identity,revision:callbackRevision),text.coordinator?.model === model else{return};text.window?.makeFirstResponder(text)
        }
        let settings = UnifiedDiffAppearance.load(from: model.appearancePreferences), dark = colorScheme == .dark, highContrast = contrast == .increased
        let cache = context.coordinator
        guard !text.hasMarkedText() else { return }
        guard cache.needsStyling || cache.resetRevision != model.documentResetRevision || (cache.lastText.map {GitReferenceName.equal($0,model.document.text)} != true) || cache.lastAppearance != settings || cache.dark != dark || cache.highContrast != highContrast else { return }
        let contentChanged = cache.resetRevision != model.documentResetRevision || (cache.lastText.map {GitReferenceName.equal($0,model.document.text)} != true), selection = text.selectedRange(), selectionAffinity = text.selectionAffinity, selectionSnapshot = text.columnSelection?.snapshot(), scrollOrigin = scroll.contentView.bounds.origin
        cache.resetRevision = model.documentResetRevision; cache.needsStyling = false
        cache.lastText = model.document.text; cache.lastAppearance = settings; cache.dark = dark; cache.highContrast = highContrast
        let font = NSFont(name: settings.fontName, size: CGFloat(settings.fontSize)) ?? NSFontManager.shared.font(withFamily: settings.fontName, traits: [], weight: 5, size: CGFloat(settings.fontSize)) ?? NSFont.monospacedSystemFont(ofSize: CGFloat(settings.fontSize), weight: .regular)
        let paragraph = NSMutableParagraphStyle(); paragraph.tabStops = []
        paragraph.defaultTabInterval = max(1, (" " as NSString).size(withAttributes: [.font: font]).width * CGFloat(settings.tabSize))
        func color(_ rgb: UInt32) -> NSColor { NSColor(srgbRed: CGFloat((rgb >> 16) & 255) / 255, green: CGFloat((rgb >> 8) & 255) / 255, blue: CGFloat(rgb & 255) / 255, alpha: 1) }
        text.backgroundColor = highContrast ? .textBackgroundColor : color(settings.colors(.context, dark: dark).background)
        text.drawsBackground = true
        scroll.drawsBackground = true;scroll.backgroundColor = text.backgroundColor
        scroll.contentView.drawsBackground = true;scroll.contentView.backgroundColor = text.backgroundColor
        if text.string.isEmpty {text.font = font}
        text.textColor = highContrast ? .labelColor : color(settings.colors(.context,dark:dark).foreground)
        text.typingAttributes = [.font:font,.paragraphStyle:paragraph,.foregroundColor:text.textColor ?? NSColor.labelColor,.backgroundColor:text.backgroundColor]
        text.selectedTextAttributes = [.backgroundColor:NSColor.selectedTextBackgroundColor,.foregroundColor:NSColor.selectedTextColor]
        text.insertionPointColor = highContrast ? .labelColor : color(settings.colors(.context, dark: dark).foreground)
        text.whitespaceColor = highContrast ? .labelColor : dark ? NSColor(srgbRed: 180.0/255, green: 180.0/255, blue: 180.0/255, alpha: 1) : .secondaryLabelColor
        let value = NSMutableAttributedString(string: "")
        for (index, line) in model.document.lines.enumerated() {
            let terminated = index < model.document.lines.count - 1 || model.document.text.utf8.last == 10
            let style = UnifiedDiffLineStyle.classify(line + (terminated ? "\n" : "")), palette = settings.colors(style, dark: dark)
            let face = !highContrast && style == .comment ? NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask) : font
            value.append(NSAttributedString(string: line + (terminated ? "\n" : ""), attributes: [.font: face, .paragraphStyle: paragraph,
                .foregroundColor: highContrast ? NSColor.labelColor : color(palette.foreground),
                .backgroundColor: highContrast ? NSColor.textBackgroundColor : color(palette.background)]))
        }
        if GitReferenceName.equal(text.string,value.string) {
            text.textStorage?.beginEditing()
            value.enumerateAttributes(in: NSRange(location: 0, length: value.length)) { attributes, range, _ in text.textStorage?.setAttributes(attributes, range: range) }
            text.textStorage?.endEditing()
        } else { text.textStorage?.setAttributedString(value) }
        text.needsDisplay = true
        scroll.lineNumberGutter?.refresh(font: font, dark: dark, highContrast: highContrast)
        if contentChanged { text.undoManager?.removeAllActions(); scroll.resetToStart = true; text.setSelectedRange(NSRange(location: 0, length: 0)) }
        else {
            let location = min(selection.location, value.length)
            if let selectionSnapshot { _ = text.columnSelection?.applySnapshot(selectionSnapshot) }
            else { text.setSelectedRange(NSRange(location: location, length: min(selection.length, value.length - location)), affinity: selectionAffinity, stillSelecting: false) }
        }
        host.layoutSubtreeIfNeeded()
        scroll.updateDocumentExtent()
        if !contentChanged {scroll.restoreDocumentOrigin(scrollOrigin)}
    }
    static func dismantleNSView(_ host: PatchTextHost, coordinator: Coordinator) {
        let scroll = host.scroll
        host.gutter.retire(); scroll.lineNumberGutter = nil
        if let text = scroll.documentView as? PatchText { text.columnSelection?.retire(); text.columnSelection = nil; text.delegate = nil; text.coordinator = nil }
        if coordinator.model.sourceOwnerID == coordinator.identity {
            coordinator.model.sourceOwnerID = nil;coordinator.model.sourceAttached={false}
            coordinator.model.sourceSelection = { NSRange(location: 0, length: 0) }
            coordinator.model.selectSource = { _ in }; coordinator.model.focusSource = {}
        }
    }
    @MainActor final class Coordinator: NSObject, NSTextViewDelegate {
        let identity = UUID()
        var model: PatchWindowModel
        var lastText: String?
        var resetRevision = -1, needsStyling = true
        var lastAppearance: UnifiedDiffAppearance?
        var dark = false, highContrast = false
        init(model: PatchWindowModel) { self.model = model }
        func textDidChange(_ notification: Notification) {
            guard let text = notification.object as? NSTextView, !text.hasMarkedText(), model.canEditText else { return }
            (text as? PatchText)?.resetViewportNavigation()
            (text.enclosingScrollView as? PatchScrollView)?.lineNumberGutter?.documentChanged()
            lastText = text.string; needsStyling = true; model.editDocument(text.string)
        }
        func textView(_ textView: NSTextView, shouldChangeTextIn affectedCharRange: NSRange, replacementString: String?) -> Bool { model.canEditText }
        func textViewDidChangeSelection(_ notification: Notification) {
            guard !model.retired, let view = notification.object as? NSTextView else { return }
            let selections = (view as? PatchText)?.columnSelection?.snapshot().ranges ?? view.selectedRanges.map(\.rangeValue)
            let index = (view.enclosingScrollView as? PatchScrollView)?.lineNumberGutter?.lineIndex ?? PatchLineIndex(text: view.string)
            var spans: [ClosedRange<Int>] = []
            for selected in selections {
                guard selected.location <= index.utf16Length, selected.length <= index.utf16Length - selected.location,
                      let first = index.lineIndex(atUTF16Offset: selected.location),
                      let last = index.lineIndex(atUTF16Offset: selected.length > 0 ? NSMaxRange(selected) - 1 : selected.location) else { continue }
                spans.append(first...last)
            }
            var lines = Set<Int>(), end = -1
            for span in spans.sorted(by: { $0.lowerBound < $1.lowerBound }) {
                let start = max(span.lowerBound, end + 1)
                if start <= span.upperBound { for line in start...span.upperBound { lines.insert(line) } }
                end = max(end, span.upperBound)
            }
            model.selectedLines = lines
        }
        @objc func hunks(_ sender: NSMenuItem) { model.apply(entireHunks: true) }
        @objc func lines(_ sender: NSMenuItem) { model.apply(entireHunks: false) }
    }
    final class PatchText: NSTextView {
        weak var coordinator: Coordinator?
        var columnSelection: PatchColumnSelectionController?
        var overtypeRevision:Int?
        var overtypeEnabled=false
        var suppressOvertype=false
        var viewportDesiredX:CGFloat?
        var viewportLayoutSize:NSSize?
        var viewportFont:NSFont?
        var viewportRevision:UUID?
        var viewportDocumentRevision:Int?
        var applyingViewportSelection=false
        func resetViewportNavigation() {if !applyingViewportSelection {viewportDesiredX=nil}}
        override func setSelectedRange(_ range: NSRange) { resetViewportNavigation(); columnSelection?.externalSelectionChanged(); super.setSelectedRange(range) }
        override func setSelectedRange(_ range: NSRange, affinity: NSSelectionAffinity, stillSelecting: Bool) {
            resetViewportNavigation(); columnSelection?.externalSelectionChanged(); super.setSelectedRange(range, affinity: affinity, stillSelecting: stillSelecting)
        }
        override func setSelectedRanges(_ ranges: [NSValue], affinity: NSSelectionAffinity, stillSelecting: Bool) {
            resetViewportNavigation(); columnSelection?.externalSelectionChanged(); super.setSelectedRanges(ranges, affinity: affinity, stillSelecting: stillSelecting)
        }
        override func mouseDown(with event: NSEvent) {
            if columnSelection?.mouseDown(with: event) == true { return }
            columnSelection?.externalSelectionChanged(); super.mouseDown(with: event)
        }
        override func keyDown(with event: NSEvent) {
            if let command=PatchNavigationCommand.command(for:event) {_ = performNavigationCommand(command);return}
            if let command=PatchSelectionCommand.command(for:event) {_ = performSelectionCommand(command);return}
            if let command=PatchCaretCommand.command(for:event) {_ = performCaretCommand(command);return}
            if let direction = PatchColumnDirection.direction(for: event), columnSelection?.available == true {
                _ = columnSelection?.extendRectangle(direction: direction); return
            }
            super.keyDown(with: event)
        }
        override func drawInsertionPoint(in rect:NSRect,color:NSColor,turnedOn flag:Bool) {
            guard caretOvertype,isEditable,!hasMarkedText() else {super.drawInsertionPoint(in:rect,color:color,turnedOn:flag);return}
            var block=rect
            let at=selectedRange().location,shown=string as NSString
            var width=(" " as NSString).size(withAttributes:typingAttributes).width
            if at<shown.length,shown.character(at:at) != 10,shown.character(at:at) != 13 {
                width=shown.substring(with:shown.rangeOfComposedCharacterSequence(at:at)).size(withAttributes:typingAttributes).width
            }
            block.size.width=max(rect.width,max(2,width))
            // A translucent overlay keeps the source glyph readable. Redraw
            // its backing glyph on blink-off instead of erasing it with a
            // wide background-colored insertion point.
            if flag {
                NSGraphicsContext.saveGraphicsState();color.withAlphaComponent(0.35).setFill()
                block.fill(using:.sourceOver);NSGraphicsContext.restoreGraphicsState()
            } else {setNeedsDisplay(block)}
        }
        override func copy(_ sender: Any?) { if !handleColumnCopy(cutting: false) { super.copy(sender) } }
        override func cut(_ sender: Any?) { if !handleColumnCopy(cutting: true) { super.cut(sender) } }
        override func paste(_ sender: Any?) {
            suppressOvertype=true;defer{suppressOvertype=false}
            if !handleColumnPaste() {
                let board=linePasteboard()
                if board.name == NSPasteboard.Name.general {super.paste(sender)}
                else {
                    // Honor the same explicit board as column Paste without
                    // consulting the user's clipboard. AppKit still owns the
                    // plain-text insertion, selection and native Undo path.
                    _ = readSelection(from:board,type:.string)
                }
            }
        }
        override func insertText(_ value: Any, replacementRange: NSRange) {
            let plain = (value as? NSAttributedString)?.string ?? (value as? String)
            if replacementRange.location==NSNotFound,!hasMarkedText(),let plain,handleCaretTyping(plain) {return}
            if !hasMarkedText(), let plain, handleColumnTyping(plain) { return }
            super.insertText(value, replacementRange: replacementRange)
        }
        override func insertNewline(_ sender: Any?) {
            if !hasMarkedText(), handleColumnTyping("\n") { return }
            super.insertNewline(sender)
        }
        override func setMarkedText(_ value: Any, selectedRange: NSRange, replacementRange: NSRange) {
            if !hasMarkedText(), hasColumnSelection, columnSelection?.available == true { columnSelection?.collapseToPrimary() }
            super.setMarkedText(value, selectedRange: selectedRange, replacementRange: replacementRange)
        }
        override func deleteBackward(_ sender: Any?) { if hasMarkedText() || !handleColumnDelete(backwards: true) { super.deleteBackward(sender) } }
        override func deleteForward(_ sender: Any?) { if hasMarkedText() || !handleColumnDelete(backwards: false) { super.deleteForward(sender) } }
        override func moveWordLeft(_ sender:Any?) {_ = performNavigationCommand(.previousWord)}
        override func moveWordRight(_ sender:Any?) {_ = performNavigationCommand(.nextWord)}
        override func moveWordBackward(_ sender:Any?) {_ = performNavigationCommand(.previousWord)}
        override func moveWordForward(_ sender:Any?) {_ = performNavigationCommand(.nextWord)}
        override func moveWordLeftAndModifySelection(_ sender:Any?) {_ = performNavigationCommand(.selectPreviousWord)}
        override func moveWordRightAndModifySelection(_ sender:Any?) {_ = performNavigationCommand(.selectNextWord)}
        override func moveWordBackwardAndModifySelection(_ sender:Any?) {_ = performNavigationCommand(.selectPreviousWord)}
        override func moveWordForwardAndModifySelection(_ sender:Any?) {_ = performNavigationCommand(.selectNextWord)}
        override func moveToBeginningOfLine(_ sender:Any?) {_ = performNavigationCommand(.smartLineStart)}
        override func moveToEndOfLine(_ sender:Any?) {_ = performNavigationCommand(.lineEnd)}
        override func moveToBeginningOfLineAndModifySelection(_ sender:Any?) {_ = performNavigationCommand(.selectSmartLineStart)}
        override func moveToEndOfLineAndModifySelection(_ sender:Any?) {_ = performNavigationCommand(.selectLineEnd)}
        override func moveToBeginningOfDocument(_ sender:Any?) {_ = performNavigationCommand(.documentStart)}
        override func moveToEndOfDocument(_ sender:Any?) {_ = performNavigationCommand(.documentEnd)}
        override func moveToBeginningOfDocumentAndModifySelection(_ sender:Any?) {_ = performNavigationCommand(.selectDocumentStart)}
        override func moveToEndOfDocumentAndModifySelection(_ sender:Any?) {_ = performNavigationCommand(.selectDocumentEnd)}
        override func pageUp(_ sender:Any?) {_ = performNavigationCommand(.pageUp)}
        override func pageDown(_ sender:Any?) {_ = performNavigationCommand(.pageDown)}
        override func pageUpAndModifySelection(_ sender:Any?) {_ = performNavigationCommand(.selectPageUp)}
        override func pageDownAndModifySelection(_ sender:Any?) {_ = performNavigationCommand(.selectPageDown)}
        override func lowercaseWord(_ sender:Any?) {_ = performSelectionCommand(.lowerCase)}
        override func uppercaseWord(_ sender:Any?) {_ = performSelectionCommand(.upperCase)}
        override func deleteWordBackward(_ sender:Any?) {_ = performSelectionCommand(.deleteWordLeft)}
        override func deleteWordForward(_ sender:Any?) {_ = performSelectionCommand(.deleteWordRight)}
        override func deleteToBeginningOfLine(_ sender:Any?) {_ = performSelectionCommand(.deleteLineLeft)}
        override func deleteToEndOfLine(_ sender:Any?) {_ = performSelectionCommand(.deleteLineRight)}
        override func validateUserInterfaceItem(_ item: NSValidatedUserInterfaceItem) -> Bool {
            let selectionActions:[Selector:PatchSelectionCommand]=[#selector(lowercaseWord(_:)):.lowerCase,#selector(uppercaseWord(_:)):.upperCase,#selector(deleteWordBackward(_:)):.deleteWordLeft,#selector(deleteWordForward(_:)):.deleteWordRight,#selector(deleteToBeginningOfLine(_:)):.deleteLineLeft,#selector(deleteToEndOfLine(_:)):.deleteLineRight]
            if let action=item.action,let command=selectionActions[action] {return canPerformSelectionCommand(command)}
            if hasColumnSelection {
                if item.action == #selector(copy(_:)) { return canCopyColumnSelection(cutting: false) }
                if item.action == #selector(cut(_:)) { return canCopyColumnSelection(cutting: true) }
                if item.action == #selector(paste(_:)) { return columnSelection?.available == true && coordinator?.model.canEditText == true }
            }
            return super.validateUserInterfaceItem(item)
        }
        var linePasteboard: () -> NSPasteboard = { .general }
        struct WhitespaceMark {
            enum Kind { case space, tab }
            let kind: Kind
            let rect: NSRect
        }
        var whitespaceColor: NSColor = .secondaryLabelColor
        /// Draw only visible spaces/tabs. The backing text, selection offsets,
        /// accessibility text and exported patch bytes are never rewritten.
        func whitespaceMarks(in rect: NSRect) -> [WhitespaceMark] {
            guard let manager = layoutManager, let container = textContainer else { return [] }
            let origin = textContainerOrigin
            let glyphs = manager.glyphRange(forBoundingRect: rect.offsetBy(dx: -origin.x, dy: -origin.y), in: container)
            let characters = manager.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
            let contents = string as NSString
            guard characters.location != NSNotFound, NSMaxRange(characters) <= contents.length else { return [] }
            return (characters.location..<NSMaxRange(characters)).compactMap { index in
                let character = contents.character(at: index)
                guard character == 32 || character == 9 else { return nil }
                let glyph = manager.glyphRange(forCharacterRange: NSRange(location: index, length: 1), actualCharacterRange: nil)
                let bounds = manager.boundingRect(forGlyphRange: glyph, in: container).offsetBy(dx: origin.x, dy: origin.y)
                guard bounds.width > 0, bounds.height > 0, bounds.intersects(rect) else { return nil }
                return WhitespaceMark(kind: character == 32 ? .space : .tab, rect: bounds)
            }
        }
        override func draw(_ dirtyRect: NSRect) {
            super.draw(dirtyRect)
            whitespaceColor.set()
            for mark in whitespaceMarks(in: dirtyRect) {
                let rect = mark.rect
                switch mark.kind {
                case .space:
                    NSBezierPath(ovalIn: NSRect(x: rect.midX - 1, y: rect.midY - 1, width: 2, height: 2)).fill()
                case .tab:
                    let start = rect.minX + min(2, rect.width / 4), end = rect.maxX - min(2, rect.width / 4)
                    let tip = min(3, (end - start) / 2)
                    let path = NSBezierPath(); path.lineWidth = 1
                    path.move(to: NSPoint(x: start, y: rect.midY)); path.line(to: NSPoint(x: end, y: rect.midY))
                    path.move(to: NSPoint(x: end - tip, y: rect.midY - tip)); path.line(to: NSPoint(x: end, y: rect.midY)); path.line(to: NSPoint(x: end - tip, y: rect.midY + tip)); path.stroke()
                }
            }
        }
        private var printSession: PatchPrintSession?
        @objc func printPatch(_ sender: Any?) {
            guard let window, window.attachedSheet == nil, let model = coordinator?.model,
                  !model.retired, !model.busy, !model.confirmingQuit, printSession == nil else { return }
            let snapshot = NSAttributedString(attributedString: attributedString())
            model.busy = true
            do {
                printSession = try PatchPrintSession(snapshot: snapshot, selection: selectedRange(), title: window.title) { [weak self, weak model] in
                    model?.busy = false; self?.printSession = nil
                }
                printSession?.run(for: window)
            } catch { model.busy = false; model.error = error.localizedDescription }
        }
        override func printView(_ sender: Any?) { printPatch(sender) }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow(); (window as? PatchNSWindow)?.patchText = self
            if let coordinator {coordinator.model.sourceMoved(coordinator.identity)}
        }
        func find(_ action: NSTextFinder.Action) {
            guard let coordinator,let window else{return}
            let model=coordinator.model
            guard model.sourceOwnerID==coordinator.identity,model.canFind else{return}
            guard (window as? PatchNSWindow)?.patchText === self || !(window is PatchNSWindow) else{return}
            if !model.usesSourceFindBar {
                if action == .showFindInterface, selectedRange().length > 0 {
                    let selected = NSMenuItem(); selected.tag = NSTextFinder.Action.setSearchString.rawValue; super.performTextFinderAction(selected)
                }
                let item = NSMenuItem(); item.tag = action.rawValue; super.performTextFinderAction(item); return
            }
            switch action {
            case .showFindInterface: model.showFind()
            case .hideFindInterface: model.hideFind()
            case .nextMatch: model.search(previous: false)
            case .previousMatch: model.search(previous: true)
            default: break
            }
        }
        override func unmarkText() {
            super.unmarkText()
            if let coordinator, coordinator.model.canEditText { coordinator.lastText = string; coordinator.needsStyling = true; coordinator.model.editDocument(string) }
        }
        override func performKeyEquivalent(with event: NSEvent) -> Bool {
            if window?.firstResponder === self,let command=PatchNavigationCommand.command(for:event) {_ = performNavigationCommand(command);return true}
            if window?.firstResponder === self,let command=PatchSelectionCommand.command(for:event) {_ = performSelectionCommand(command);return true}
            if window?.firstResponder === self,let command=PatchCaretCommand.command(for:event) {
                _ = performCaretCommand(command);return true
            }
            if let direction = PatchColumnDirection.direction(for: event), columnSelection?.available == true {
                _ = columnSelection?.extendRectangle(direction: direction); return true
            }
            if window?.firstResponder === self, let command = PatchLineCommand.command(for: event) {
                _ = performLineCommand(command); return true
            }
            let modifiers = event.modifierFlags.intersection([.command, .shift, .control, .option])
            guard window?.firstResponder === self || enclosingScrollView?.isFindBarVisible == true || coordinator?.model.findVisible == true else { return super.performKeyEquivalent(with: event) }
            if modifiers == .command, event.charactersIgnoringModifiers?.lowercased() == "f" {
                find(.showFindInterface); return true
            }
            if modifiers == .command || modifiers == [.command, .shift], event.charactersIgnoringModifiers?.lowercased() == "g" {
                find(modifiers.contains(.shift) ? .previousMatch : .nextMatch); return true
            }
            return super.performKeyEquivalent(with: event)
        }
        override func insertTab(_ sender: Any?) {
            if hasMarkedText() { super.insertTab(sender); return }
            _ = performLineTab(backwards: false)
        }
        override func insertBacktab(_ sender: Any?) {
            if hasMarkedText() { super.insertBacktab(sender); return }
            _ = performLineTab(backwards: true)
        }
        override func cancelOperation(_ sender: Any?) {
            if coordinator?.model.findVisible == true { coordinator?.model.hideFind() }
            else if enclosingScrollView?.isFindBarVisible == true {
                find(.hideFindInterface); window?.makeFirstResponder(self)
            } else { window?.performClose(sender) }
        }
        @objc func savePatch(_ sender: Any?) {
            guard let window, window.attachedSheet == nil, let model = coordinator?.model, !model.retired, !model.busy, !model.confirmingQuit else { return }
            if model.allowsDocumentEditing, let session = (window.delegate as? PatchWindowController)?.documentSession { session.saveDocument(as: true); return }
            let snapshot = model.exportDocument
            let panel = NSSavePanel(); panel.nameFieldStringValue = "changes.patch"
            panel.allowedContentTypes = [UTType(filenameExtension: "patch") ?? .plainText]
            panel.beginSheetModal(for: window) { response in
                guard !model.retired, response == .OK, let url = panel.url else { return }
                do { try snapshot.write(to: url) }
                catch { model.error = error.localizedDescription }
            }
        }
        @objc func undoPatch(_ sender: Any?) { guard coordinator?.model.canEditText == true else { return }; undoManager?.undo() }
        @objc func redoPatch(_ sender: Any?) { guard coordinator?.model.canEditText == true else { return }; undoManager?.redo() }
        override func performTextFinderAction(_ sender: Any?) {
            if coordinator?.model.usesSourceFindBar != true { super.performTextFinderAction(sender); return }
            guard let tag = (sender as? NSMenuItem)?.tag, let action = NSTextFinder.Action(rawValue: tag) else { return }
            find(action)
        }
        @objc func applyPatchFile(_ sender: NSMenuItem) {
            guard let owner = window?.delegate as? PatchWindowController, sender.representedObject as? String == owner.documentSession.documentIdentity.uuidString else { return }
            owner.documentSession.applyPatch()
        }
        @objc func unifiedSettings(_ sender: NSMenuItem) {
            guard let owner = window?.delegate as? PatchWindowController, sender.representedObject as? String == owner.documentSession.documentIdentity.uuidString else { return }
            owner.documentSession.showSettings()
        }
        @objc func showFind(_ sender: Any?) { find(.showFindInterface) }
        override func menu(for event: NSEvent) -> NSMenu? {
            guard let coordinator else { return super.menu(for: event) }
            if selectedRanges.count == 1, columnSelection?.snapshot().rectangular != true, selectedRange().length == 0 {
                let location = characterIndexForInsertion(at: convert(event.locationInWindow, from: nil))
                setSelectedRange(NSRange(location: location, length: 0))
            }
            let menu = NSMenu(),defaults=coordinator.model.appearancePreferences
            let save = NSMenuItem(title: "Save As…", action: #selector(savePatch(_:)), keyEquivalent: "")
            save.target = self; save.image = MenuIcon.unifiedDiff.contextImage(defaults:defaults); menu.addItem(save)
            let print = NSMenuItem(title: "Print…", action: #selector(printPatch(_:)), keyEquivalent: "")
            print.target = self; print.image = MenuPresentationSettings.applicationContextIcons(defaults:defaults) ? NSImage(systemSymbolName: "printer", accessibilityDescription: "Print") : nil
            menu.addItem(print)
            if coordinator.model.allowsDocumentEditing, let owner = window?.delegate as? PatchWindowController {
                for (title, selector, icon) in [("Apply Patch…", #selector(applyPatchFile(_:)), MenuIcon.patch), ("Unified Diff Settings…", #selector(unifiedSettings(_:)), .settingsUnifiedDiff)] {
                    let item = NSMenuItem(title: title, action: selector, keyEquivalent: ""); item.target = self; item.image = icon.contextImage(defaults:defaults)
                    item.representedObject = owner.documentSession.documentIdentity.uuidString; item.isEnabled = coordinator.model.canFind; menu.addItem(item)
                }
            }
            menu.addItem(.separator())
            if !coordinator.model.readOnly {
                for (title, selector, enabled) in [("selected hunks", #selector(Coordinator.hunks(_:)), coordinator.model.canApplyHunks), ("selected lines", #selector(Coordinator.lines(_:)), coordinator.model.canApplyLines)] {
                    let item = NSMenuItem(title: (coordinator.model.staged ? "Unstage " : "Stage ") + title, action: selector, keyEquivalent: "")
                    item.target = coordinator; item.image = (coordinator.model.staged ? MenuIcon.revert : .add).contextImage(defaults:defaults); item.isEnabled = enabled; menu.addItem(item)
                }
                menu.addItem(.separator())
            }
            if coordinator.model.canEditText {
                for (title, selector, icon) in [("Undo", #selector(undoPatch(_:)), MenuIcon.mergeUndo), ("Redo", #selector(redoPatch(_:)), .mergeRedo), ("Paste", #selector(NSText.paste(_:)), .mergePaste)] {
                    let item = NSMenuItem(title: title, action: selector, keyEquivalent: ""); item.target = self; item.image = icon.contextImage(defaults:defaults); menu.addItem(item)
                }
            }
            if coordinator.model.canEditText {
                let cut = NSMenuItem(title: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: ""); cut.target = self
                cut.image = MenuPresentationSettings.applicationContextIcons(defaults:defaults) ? NSImage(systemSymbolName: "scissors", accessibilityDescription: "Cut") : nil; menu.addItem(cut)
            }
            let copy = NSMenuItem(title: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "")
            copy.target = self; copy.image = MenuIcon.copy.contextImage(defaults:defaults); menu.addItem(copy)
            let navigationMenu=NSMenuItem(title:NSLocalizedString("Navigation",comment:"Unified Diff navigation menu"),action:nil,keyEquivalent:"")
            navigationMenu.image=MenuIcon.mergeNextInline.contextImage(defaults:defaults);navigationMenu.submenu=makeNavigationCommandMenu();menu.addItem(navigationMenu)
            let selectionMenu=NSMenuItem(title:NSLocalizedString("Selection Editing",comment:"Unified Diff selection editing menu"),action:nil,keyEquivalent:"")
            selectionMenu.image=MenuIcon.mergeLineEdited.contextImage(defaults:defaults);selectionMenu.submenu=makeSelectionCommandMenu();menu.addItem(selectionMenu)
            let caretMenu=NSMenuItem(title:NSLocalizedString("Caret",comment:"Unified Diff caret menu"),action:nil,keyEquivalent:"")
            caretMenu.image=MenuIcon.mergeLineEdited.contextImage(defaults:defaults);caretMenu.submenu=makeCaretCommandMenu();menu.addItem(caretMenu)
            let lineMenu = NSMenuItem(title: NSLocalizedString("Lines", comment: "Unified Diff editing menu"), action: nil, keyEquivalent: "")
            lineMenu.image = MenuIcon.mergeLineEdited.contextImage(defaults: defaults)
            lineMenu.submenu = makeLineCommandMenu(); menu.addItem(lineMenu)
            let selectAll=NSMenuItem(title:"Select All",action:#selector(NSText.selectAll(_:)),keyEquivalent:"");selectAll.image=MenuIcon.mergeMarked.contextImage(defaults:defaults);menu.addItem(selectAll)
            let find = NSMenuItem(title: "Find…", action: #selector(showFind(_:)), keyEquivalent: "")
            find.target = self; find.image=MenuIcon.mergeFind.contextImage(defaults:defaults); menu.addItem(find)
            return menu
        }
    }
}
