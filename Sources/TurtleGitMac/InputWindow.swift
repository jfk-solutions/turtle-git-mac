// SPDX-License-Identifier: GPL-2.0-or-later
import AppKit
import TurtleGitCore

// Shared CInputDlg adaptation for branch descriptions and notes. See NOTICE.
final class InputMessageTextView: ProjectMessageTextView {
    var accept: () -> Void = {}
    override func keyDown(with event: NSEvent) {
        if !event.modifierFlags.intersection([.control, .command]).isEmpty, event.keyCode == 36 || event.keyCode == 76 { accept(); return }
        super.keyDown(with: event)
    }
}
@MainActor class InputWindowController: NSWindowController, NSWindowDelegate, NSTextViewDelegate {
    static private(set) var activeSaves = 0
    let editor: NSTextView
    let checkbox = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    private var minimumLength: Int
    private var readyForInput = true
    let ok = NSButton(title: "OK", target: nil, action: nil)
    let cancelButton = NSButton(title: "Cancel", target: nil, action: nil)
    let errorLabel = NSTextField(wrappingLabelWithString: "")
    private(set) var busy = false
    private(set) var saved = false
    private var closed = false
    private var pendingSave=false
    private(set) var cancelling=false
    var allowsSaveCancellation=false
    var closesAfterSavedNoteFailure=false
    var pendingOwnedWork:()->Bool={false}
    var retireOwnedChildren:()->Void={}
    var retryPreparation:(()->Void)? {didSet{updateAcceptance()}}

    private var token: OperationCancellation?
    private var fontObserver: NSObjectProtocol?
    private let preferences: UserDefaults
    private var issueProperties: IssueTrackerProperties
    private let write: (String, Bool, OperationCancellation) async throws -> Void
    var onClosed: () -> Void = {}
    var onTextChanged: (String) -> Void = { _ in }
    init(title: String = "Input", hint: String = "Enter log message:", text: String, checkboxTitle: String? = nil, checked: Bool = false, minimumLength: Int = 0, projectSettings: ProjectDialogSettings = ProjectDialogSettings(), issueProperties: IssueTrackerProperties = IssueTrackerProperties(), preferences: UserDefaults, write: @escaping (String, Bool, OperationCancellation) async throws -> Void) {
        self.preferences = preferences; self.issueProperties = issueProperties; self.write = write; self.minimumLength = max(0, minimumLength)
        let input = InputMessageTextView(frame: .zero); editor = input
        let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 510, height: 255), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = title; window.isReleasedWhenClosed = false; window.contentMinSize = .init(width: 360, height: 210)
        super.init(window: window); window.delegate = self
        let content = NSView(); window.contentView = content
        let hint = NSTextField(labelWithString: hint)
        let scroll = NSScrollView(); scroll.hasVerticalScroller = true; scroll.borderType = .bezelBorder; scroll.documentView = input
        input.isRichText = false; input.allowsUndo = true; input.isVerticallyResizable = true; input.isHorizontallyResizable = false
        input.autoresizingMask = [.width]; input.textContainer?.widthTracksTextView = true
        input.textContainer?.containerSize = .init(width: 0, height: CGFloat.greatestFiniteMagnitude)
        input.maxSize = .init(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        input.textContainerInset = .init(width: 5, height: 5); input.string = text
        input.setAccessibilityLabel(title); input.undoManager?.removeAllActions(); input.delegate = self
        input.spellingPreferences = preferences; input.applyProjectSettings(projectSettings)
        checkbox.title = checkboxTitle ?? ""; checkbox.isHidden = checkboxTitle?.isEmpty != false; checkbox.state = checked ? .on : .off
        errorLabel.textColor = .systemRed
        ok.bezelStyle = .rounded; cancelButton.bezelStyle = .rounded
        ok.target = self; ok.action = #selector(save); cancelButton.target = self; cancelButton.action = #selector(cancel)
        cancelButton.keyEquivalent = "\u{1b}"; input.accept = { [weak self] in self?.save() }
        for view in [hint, scroll, errorLabel, checkbox, ok, cancelButton] { view.translatesAutoresizingMaskIntoConstraints = false; content.addSubview(view) }
        NSLayoutConstraint.activate([
            hint.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 12), hint.topAnchor.constraint(equalTo: content.topAnchor, constant: 10),
            scroll.leadingAnchor.constraint(equalTo: hint.leadingAnchor), scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -12), scroll.topAnchor.constraint(equalTo: hint.bottomAnchor, constant: 6),
            scroll.bottomAnchor.constraint(equalTo: errorLabel.topAnchor, constant: -5),
            errorLabel.leadingAnchor.constraint(equalTo: hint.leadingAnchor), errorLabel.trailingAnchor.constraint(equalTo: scroll.trailingAnchor), errorLabel.bottomAnchor.constraint(equalTo: ok.topAnchor, constant: -6),
            cancelButton.trailingAnchor.constraint(equalTo: scroll.trailingAnchor), cancelButton.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -10), cancelButton.widthAnchor.constraint(equalToConstant: 80),
            checkbox.leadingAnchor.constraint(equalTo: hint.leadingAnchor), checkbox.centerYAnchor.constraint(equalTo: ok.centerYAnchor), checkbox.trailingAnchor.constraint(lessThanOrEqualTo: ok.leadingAnchor, constant: -8),
            ok.trailingAnchor.constraint(equalTo: cancelButton.leadingAnchor, constant: -8), ok.bottomAnchor.constraint(equalTo: cancelButton.bottomAnchor), ok.widthAnchor.constraint(equalToConstant: 80)
        ])
        updateFont(); updateAcceptance(); window.center(); DialogGeometry.attach(window, identifier: "InputDlg", legacyName: "InputDlg")
        fontObserver = NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: preferences, queue: .main) { [weak self] _ in Task { @MainActor in self?.updateFont() } }
    }
    private func updateFont() {
        guard !closed else { return }
        let font = MessageEditorFont.resolve(name: preferences.string(forKey: "LogFontName") ?? MessageEditorFont.defaultName, size: preferences.object(forKey: "LogFontSize") as? Int ?? MessageEditorFont.defaultSize)
        (editor as? InputMessageTextView)?.configureSourceStyling(properties: issueProperties, preferences: preferences, font: font)
    }
    func focusEditor() { guard !closed, !busy, let window else { return }; window.makeFirstResponder(editor); editor.setSelectedRange(.init(location: editor.string.utf16.count, length: 0)) }
    var canAccept: Bool { readyForInput && !closed && !busy && editor.string.utf16.count >= minimumLength && !editor.string.contains("\0") }
    func textDidChange(_ notification: Notification) { onTextChanged(editor.string); updateAcceptance() }
    func setInputState(ready: Bool, message: String? = nil) {
        guard !closed else { return }
        readyForInput = ready; editor.isEditable = ready && !busy
        errorLabel.stringValue = message ?? ""; updateAcceptance()
    }
    func configure(text: String, minimumLength: Int, settings: ProjectDialogSettings, issueProperties: IssueTrackerProperties = IssueTrackerProperties()) {
        guard !closed, !busy else { return }
        self.minimumLength = max(0, minimumLength); self.issueProperties = issueProperties; editor.string = text
        editor.undoManager?.removeAllActions()
        (editor as? InputMessageTextView)?.applyProjectSettings(settings)
        updateFont(); setInputState(ready: true); focusEditor()
    }
    private func updateAcceptance() {
        let retry = !readyForInput && retryPreparation != nil && !busy && !closed
        ok.title=retry ? "Retry":"OK";ok.isEnabled=canAccept || retry
    }
    private func dismiss() { if let window { window.sheetParent?.endSheet(window); window.close() } }
    @objc func save() {
        if !readyForInput,!closed,!busy,let retryPreparation{retryPreparation();return}
        guard canAccept else { return }
        busy = true; checkbox.isEnabled = false; editor.isEditable = false; ok.isEnabled = false; cancelButton.isEnabled = allowsSaveCancellation; errorLabel.stringValue = ""
        let request = OperationCancellation(); token = request; let text = editor.string, checked = checkbox.state == .on
        InputWindowController.activeSaves += 1;pendingSave=true
        Task {
            defer { InputWindowController.activeSaves -= 1;pendingSave=false }
            do {
                try await write(text, checked, request)
                guard !closed, token === request else { return }
                saved = true; dismiss()
            } catch {
                guard !closed, token === request else { return }
                if closesAfterSavedNoteFailure,let failure=error as? CommitNoteFailure,case .savedButRefreshFailed = failure {saved=true;dismiss();return}
                token = nil; busy = false;cancelling=false; editor.isEditable = readyForInput; checkbox.isEnabled = true; updateAcceptance(); cancelButton.isEnabled = true
                errorLabel.stringValue = error.localizedDescription; window?.makeFirstResponder(editor)
            }
        }
    }
    @objc func cancel() {
        guard !closed else{return}
        if busy {
            guard allowsSaveCancellation,!cancelling else{return}
            cancelling=true;token?.cancel();cancelButton.isEnabled=false;errorLabel.stringValue="Cancelling…";return
        }
        dismiss()
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool {guard sender.attachedSheet==nil else{return false};if busy {cancel();return false};return true}
    func windowWillClose(_ notification: Notification) {
        guard !closed else { return }; closed = true; token?.cancel(); token = nil;retireOwnedChildren()
        (editor as? InputMessageTextView)?.retireSourceStyling()
        if let fontObserver { NotificationCenter.default.removeObserver(fontObserver) }; fontObserver = nil
        if let window { window.sheetParent?.endSheet(window) }
        if pendingSave || pendingOwnedWork() || window?.sheetParent != nil || window?.attachedSheet != nil {
            Task{@MainActor [self] in
                while pendingSave || pendingOwnedWork() || window?.sheetParent != nil || window?.attachedSheet != nil {try? await Task.sleep(nanoseconds:5_000_000)}
                let done=onClosed;onClosed={};done()
            }
        }else{let done=onClosed;onClosed={};done()}
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
}

@MainActor final class ReferenceDescriptionWindowController: InputWindowController {
    init(text: String, preferences: UserDefaults, write: @escaping (String, OperationCancellation) async throws -> Void) {
        var settings = ProjectDialogSettings(); settings.language = .init(value: "-1", inherit: false)
        super.init(title: "Edit description", hint: "Edit description", text: text, projectSettings: settings, preferences: preferences) { text, _, token in try await write(text, token) }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
}

/// AppUtils::EditNote calls CheckUserData before reading a note. Keep the
/// captured repository and all modal children alive until their real release.
@MainActor final class NoteIdentitySession {
    private final class Question {
        let alert:NSAlert,token:OperationCancellation
        var completion:((Bool)->Void)?,watcher:Task<Void,Never>?
        var settling=false
        init(_ alert:NSAlert,_ token:OperationCancellation,_ completion:@escaping(Bool)->Void){self.alert=alert;self.token=token;self.completion=completion}
    }
    let repository:GitRepository
    private let access:RepositoryAccessLease?
    private let preferences:UserDefaults
    private weak var parent:NSWindow?
    private var pending:Question?
    private var settings:SettingsSheetController?
    private var operations:[UUID:OperationCancellation]=[:]
    private(set) var retired=false
    var available:()->Bool={true}
    var readIdentity:((OperationCancellation)async throws->ReplayUserIdentity)?
    var presentQuestion:(NSWindow,NSAlert,@escaping(NSApplication.ModalResponse)->Void)->Bool={owner,alert,reply in alert.beginSheetModal(for:owner,completionHandler:reply);return true}
    var configureSettings:(SettingsSheetController)->Void={_ in}
    var question:NSAlert? {pending?.alert}
    var settingsWindow:NSWindow? {settings?.window}
    var navigation:SettingsNavigationController? {settings?.navigation}
    var hasPendingWork:Bool {!operations.isEmpty || pending != nil || settings != nil}
    init(repository:GitRepository,access:RepositoryAccessLease?,preferences:UserDefaults,parent:NSWindow){self.repository=repository;self.access=access;self.preferences=preferences;self.parent=parent}
    private func check(_ token:OperationCancellation)throws {
        try token.check()
        guard !retired,available(),!Task.isCancelled else{throw OperationCancellationFailure.cancelled}
        if GitRuntime.isAppStoreBuild && (access?.hasSecurityScope != true || access?.contains(repository.root) != true){throw RepositoryAccessFailure.securityScopeUnavailable}
    }
    func require(_ token:OperationCancellation)async throws->Bool {
        let id=UUID();operations[id]=token;defer{operations.removeValue(forKey:id);withExtendedLifetime(access){}}
        while true {
            try check(token)
            let identity:ReplayUserIdentity
            if let readIdentity {identity=try await readIdentity(token)}else{identity=try await repository.replayUserIdentity(cancellation:token)}
            try check(token)
            if identity.complete{return true}
            guard await ask(token) else{try check(token);return false}
            try check(token)
            guard await showSettings(token) else{try check(token);return false}
            // Both OK and Cancel release Settings, then require all four values
            // again; closing the child does not certify identity.
        }
    }
    private func ask(_ token:OperationCancellation)async->Bool {
        guard !retired,available(),!token.isCancelled,pending==nil,settings==nil,let owner=parent,owner.attachedSheet==nil else{return false}
        let alert=NSAlert();alert.alertStyle = .critical;alert.messageText="User name and email must be set before commit.";alert.informativeText="Do you want to set these now?"
        alert.addButton(withTitle:"Yes");alert.addButton(withTitle:"No").keyEquivalent="\u{1b}"
        alert.window.alphaValue=owner.alphaValue;alert.window.appearance=owner.effectiveAppearance
        return await withCheckedContinuation{reply in
            let request=Question(alert,token){reply.resume(returning:$0)};pending=request
            request.watcher=Task{@MainActor [weak self,weak request] in
                while !Task.isCancelled {
                    guard let self,let request,self.pending === request,!request.settling else{return}
                    if token.isCancelled || self.retired {self.settle(request,accepted:false);return}
                    try? await Task.sleep(nanoseconds:10_000_000)
                }
            }
            if !presentQuestion(owner,alert,{[weak self,weak request] response in
                guard let self,let request else{return};self.settle(request,accepted:response == .alertFirstButtonReturn)
            }){settle(request,accepted:false)}
        }
    }
    private func settle(_ request:Question,accepted:Bool) {
        guard pending === request,!request.settling else{return};request.settling=true;request.watcher?.cancel();request.watcher=nil
        let child=request.alert.window,owner=child.sheetParent ?? parent
        if child.sheetParent != nil || owner?.attachedSheet === child {owner?.endSheet(child,returnCode:.abort)}
        child.orderOut(nil)
        Task{@MainActor [self,request] in
            while child.sheetParent != nil || owner?.attachedSheet === child || child.attachedSheet != nil {try? await Task.sleep(nanoseconds:5_000_000)}
            child.close();if pending === request{pending=nil}
            let reply=request.completion;request.completion=nil;reply?(accepted && !retired && available() && !request.token.isCancelled)
        }
    }
    private func showSettings(_ token:OperationCancellation)async->Bool {
        guard !retired,available(),!token.isCancelled,settings==nil,let owner=parent,owner.attachedSheet==nil else{return false}
        let workspace=RepositoryModel(startMonitoring:false,initializePreferences:false)
        workspace.root=repository.root;workspace.settingsContextOverride=(repository,access,true)
        let child=SettingsSheetController(workspace:workspace,preferences:preferences,initialPage:.git,title:"Settings – TurtleGit for Mac")
        settings=child;child.window?.alphaValue=owner.alphaValue;child.window?.appearance=owner.effectiveAppearance
        return await withCheckedContinuation{reply in
            var settled=false
            let watcher=Task{@MainActor [weak self,weak child] in
                while !Task.isCancelled && !settled {
                    guard let self,let child,self.settings === child else{return}
                    if token.isCancelled || self.retired {child.retire();return}
                    try? await Task.sleep(nanoseconds:10_000_000)
                }
            }
            child.onClosed={ [weak self,weak child] _ in
                guard !settled else{return};settled=true;watcher.cancel()
                if self?.settings === child{self?.settings=nil}
                reply.resume(returning:self?.retired==false && self?.available()==true && !token.isCancelled)
            }
            configureSettings(child)
            guard !settled,!retired,!token.isCancelled else{child.retire();return}
            child.presentSheet(for:owner)
        }
    }
    func cancel(){operations.values.forEach{$0.cancel()};if let pending{settle(pending,accepted:false)};settings?.retire()}
    func retire(){retired=true;cancel()}
}

/// Shared owned Input sheet for Log and Rebase's selected revision menus.
@MainActor final class CommitNotePresenter {
    private(set) static var activeWarnings=0
    private var retired=false,settlingWarning=false
    private(set) var completionWarning:NSAlert?
    private weak var parent: NSWindow?
    private let model: LogWindowModel
    private let preferences: UserDefaults
    let identitySession:NoteIdentitySession
    private(set) var editor: InputWindowController?
    init(parent: NSWindow, model: LogWindowModel, preferences: UserDefaults) {
        self.parent = parent; self.model = model; self.preferences = preferences
        identitySession=NoteIdentitySession(repository:model.repository,access:model.noteAccess,preferences:preferences,parent:parent)
        identitySession.available={ [weak model] in model?.isInvalidated==false && model?.confirmingQuit==false }
        model.noteIdentitySession=identitySession
        model.prepareNoteIdentity={ [weak identitySession = self.identitySession] token in guard let identitySession else{throw OperationCancellationFailure.cancelled};return try await identitySession.require(token) }
        model.onShowNote = { [weak self] note, settings in self?.show(note, settings: settings) }
    }
    private func show(_ note: CommitNoteSnapshot, settings: ProjectDialogSettings) {
        guard editor == nil, !model.isInvalidated, let parent, parent.attachedSheet == nil else { model.cancelNote(); return }
        let child = InputWindowController(title: "Edit Notes", hint: "Edit Notes", text: note.text, minimumLength: note.minimumLength, projectSettings: settings, issueProperties: model.noteIssueProperties, preferences: preferences) { [model] text, _, token in
            if token.isCancelled { throw CancellationError() }
            try await model.saveNoteText(note, text: text,cancellation:token)
        }
        child.allowsSaveCancellation=true;child.closesAfterSavedNoteFailure=true
        child.pendingOwnedWork={ [weak model] in model?.savingNote==true }
        editor = child
        child.onClosed = { [weak self, weak child] in
            guard let self, self.editor === child else { return }
            self.editor = nil;self.model.cancelNote();self.showCompletionWarning()
        }
        guard let sheet = child.window else { editor = nil; model.cancelNote(); return }
        parent.beginSheet(sheet); child.focusEditor()
    }
    private func showCompletionWarning() {
        guard !retired,!model.isInvalidated,editor==nil,completionWarning==nil,let detail=model.noteCompletionWarning,let parent,parent.attachedSheet==nil else{return}
        let alert=NSAlert();alert.alertStyle = .warning;alert.messageText="Edit Notes";alert.informativeText=detail;alert.addButton(withTitle:"OK")
        alert.window.alphaValue=parent.alphaValue;alert.window.appearance=parent.effectiveAppearance
        completionWarning=alert;model.noteWarningPending=true;Self.activeWarnings += 1
        alert.beginSheetModal(for:parent){ [weak self,weak alert] _ in
            guard let self,let alert else{return};self.finishCompletionWarning(alert,detail:detail)
        }
    }
    private func finishCompletionWarning(_ alert:NSAlert,detail:String?) {
        guard completionWarning === alert,!settlingWarning else{return};settlingWarning=true
        let child=alert.window,owner=child.sheetParent ?? parent
        if child.sheetParent != nil || owner?.attachedSheet === child{owner?.endSheet(child,returnCode:.abort)}
        child.orderOut(nil)
        Task{@MainActor [self,alert] in
            while child.sheetParent != nil || owner?.attachedSheet === child || child.attachedSheet != nil{try? await Task.sleep(nanoseconds:5_000_000)}
            child.close()
            if completionWarning === alert{completionWarning=nil}
            settlingWarning=false;model.noteWarningPending=false;Self.activeWarnings -= 1
            if !retired,let detail,model.noteCompletionWarning?.utf8.elementsEqual(detail.utf8)==true{model.noteCompletionWarning=nil}
        }
    }
    func close(){
        retired=true;identitySession.retire();editor?.close();editor=nil
        if let completionWarning{finishCompletionWarning(completionWarning,detail:nil)}
    }
}
