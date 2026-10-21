// Native replacement of IDD_REVGRAPHFILTER / CRevGraphFilterDlg.
// SPDX-License-Identifier: GPL-2.0-or-later
import AppKit
import TurtleGitCore

@MainActor final class RevisionGraphCompletionEditor: NSTextView {
    override var rangeForUserCompletion: NSRange {
        let text=string as NSString, selection=selectedRange()
        guard selection.location != NSNotFound, NSMaxRange(selection) <= text.length else { return NSRange(location:NSNotFound,length:0) }
        var start=selection.location
        while start > 0, !(UnicodeScalar(text.character(at:start-1)).map { CharacterSet.whitespacesAndNewlines.contains($0) } ?? false) { start -= 1 }
        return NSRange(location:start,length:NSMaxRange(selection)-start)
    }
}

@MainActor final class RevisionGraphFilterController: NSWindowController, NSWindowDelegate, NSTextFieldDelegate {
    static var activeOperations = 0
    private(set) var pendingOperations=0
    private var releasing=false
    private var delivery:(()->Void)?
    var hasPendingWork:Bool {releasing || pendingOperations>0 || picker?.hasPendingWork == true || window?.attachedSheet != nil || window?.sheetParent != nil}

    private(set) var completionNames: [String] = ["HEAD"]
    private(set) var completionError: String?
    private let completionEditor = RevisionGraphCompletionEditor()
    private let referenceReader: ((OperationCancellation) async throws -> [String])?
    private var completing = false
    private var completionAlert: NSAlert?
    private var pendingCompletionFailure = false
    private var completionCancellation: OperationCancellation?
    private var completionWorker: Task<Void, Never>?
    let model: RevisionGraphWindowModel
    let fromField = NSTextField(string: ""), toField = NSTextField(string: "")
    let current = NSButton(checkboxWithTitle: "Only Current Branch", target: nil, action: nil)
    let local = NSButton(checkboxWithTitle: "Only Local Branches", target: nil, action: nil)
    let fromBrowse = NSButton(title: "RefBrowser", target: nil, action: nil)
    let toBrowse = NSButton(title: "RefBrowser", target: nil, action: nil)
    let ok = NSButton(title: "OK", target: nil, action: nil)
    let cancel = NSButton(title: "Cancel", target: nil, action: nil)
    let reset = NSButton(title: "Reset filter", target: nil, action: nil)
    private var completion: ((RevisionGraphOptions?) -> Void)?
    private(set) var picker: ReferenceBrowserWindowController?
    private var finished = false
    private var pickerRequest: UUID?
    private weak var pendingFocus: NSTextField?
    init(model: RevisionGraphWindowModel, referenceReader: ((OperationCancellation) async throws -> [String])? = nil, completion: @escaping (RevisionGraphOptions?) -> Void) {
        self.model = model; self.referenceReader=referenceReader; self.completion = completion
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 510, height: 190), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Revision Graph Filter"; window.isReleasedWhenClosed = false
        super.init(window: window); window.delegate = self
        fromField.stringValue = model.options.from; toField.stringValue = model.options.to
        current.state = model.options.onlyCurrentBranch ? .on : .off; local.state = model.options.onlyLocalBranches ? .on : .off
        completionEditor.isFieldEditor=true; completionEditor.isAutomaticTextCompletionEnabled=false
        completionEditor.isAutomaticSpellingCorrectionEnabled=false; completionEditor.isContinuousSpellCheckingEnabled=false
        fromField.delegate=self; toField.delegate=self
        window.initialFirstResponder=fromField
        fromField.setAccessibilityLabel("From revision"); toField.setAccessibilityLabel("To revision")
        let grid = NSGridView(views: [[NSTextField(labelWithString: "From:"), fromField, fromBrowse], [NSTextField(labelWithString: "To:"), toField, toBrowse]])
        grid.rowSpacing = 10; grid.columnSpacing = 10; grid.column(at: 1).width = 295
        let scopes = NSStackView(views: [current, local]); scopes.orientation = .horizontal; scopes.spacing = 24
        let buttons = NSStackView(views: [ok, cancel, reset]); buttons.orientation = .horizontal; buttons.spacing = 8
        let stack = NSStackView(views: [NSTextField(labelWithString: "Include only the following revision range:"), grid, scopes, buttons]); stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 14
        stack.edgeInsets = NSEdgeInsets(top: 12, left: 12, bottom: 12, right: 12); stack.translatesAutoresizingMaskIntoConstraints = false
        let content = RevisionGraphSurface(); content.addSubview(stack); window.contentView = content
        NSLayoutConstraint.activate([stack.leadingAnchor.constraint(equalTo: content.leadingAnchor), stack.trailingAnchor.constraint(equalTo: content.trailingAnchor), stack.topAnchor.constraint(equalTo: content.topAnchor), stack.bottomAnchor.constraint(equalTo: content.bottomAnchor)])
        for button in [current, local] { button.target = self; button.action = #selector(scopeChanged(_:)) }
        fromBrowse.target = self; fromBrowse.action = #selector(browseFrom); toBrowse.target = self; toBrowse.action = #selector(browseTo)
        ok.target = self; ok.action = #selector(accept); ok.keyEquivalent = "\r"; window.defaultButtonCell = ok.cell as? NSButtonCell
        cancel.target = self; cancel.action = #selector(abort); cancel.keyEquivalent = "\u{1b}"
        reset.target = self; reset.action = #selector(resetFilter)
        NotificationCenter.default.addObserver(self, selector: #selector(sheetEnded), name: NSWindow.didEndSheetNotification, object: window)
        scopeChanged(nil)
        loadCompletions()
    }
    deinit { completionCancellation?.cancel(); completionWorker?.cancel() }
    private func loadCompletions() {
        let token=OperationCancellation(); completionCancellation=token
        Self.activeOperations += 1;pendingOperations += 1
        completionWorker=Task { [self] in
            defer { Self.activeOperations -= 1;pendingOperations -= 1; completionWorker=nil; completionCancellation=nil; withExtendedLifetime(model.access) {} }
            do {
                if GitRuntime.isAppStoreBuild && (model.access?.hasSecurityScope != true || model.access?.contains(model.repository.root) != true) { throw RepositoryAccessFailure.securityScopeUnavailable }
                let references:[String]
                if let referenceReader { references=try await referenceReader(token) }
                else {
                    let output=try await model.repository.run(["for-each-ref","--format=%(refname)"],environmentOverrides:["GIT_OPTIONAL_LOCKS":"0"],cancellation:token)
                    references=String(decoding:output.stdout,as:UTF8.self).split(separator:"\n").map(String.init)
                }
                guard !finished, !model.closed, !token.isCancelled else { return }
                var names=["HEAD"], seen:Set<GitReferenceName>=["HEAD"]
                for reference in references.sorted(by:{ $0.localizedStandardCompare($1) == .orderedAscending }) {
                    var variants=[reference]
                    if reference.hasPrefix("refs/") { variants.append(String(reference.dropFirst(5))) }
                    for prefix in ["refs/heads/","refs/remotes/","refs/tags/"] where reference.hasPrefix(prefix) { variants.append(String(reference.dropFirst(prefix.count))) }
                    for value in variants where seen.insert(GitReferenceName(value)).inserted { names.append(value) }
                }
                completionNames=names
            } catch {
                guard !finished, !model.closed, !token.isCancelled else { return }
                completionError=error.localizedDescription
                // Completion is advisory: arbitrary revision expressions remain editable.
                fromField.toolTip=completionError; toField.toolTip=completionError
                pendingCompletionFailure=true; showCompletionFailure()
            }
        }
    }
    private func showCompletionFailure() {
        guard !finished, !model.closed, pendingCompletionFailure, picker == nil,
              let window, window.attachedSheet == nil else { return }
        pendingCompletionFailure=false
        let alert=NSAlert(); alert.messageText="Could not get all refs."; alert.informativeText=completionError ?? ""
        alert.alertStyle = .critical; alert.addButton(withTitle:"OK"); completionAlert=alert
        alert.beginSheetModal(for:window) { [weak self] _ in
            guard let self else { return }; self.completionAlert=nil
            if !self.finished, !self.model.closed { self.window?.makeFirstResponder(self.fromField) }
        }
    }
    func windowWillReturnFieldEditor(_ sender:NSWindow,to client:Any?) -> Any? {
        guard let field=client as? NSTextField, field === fromField || field === toField else { return nil }
        return completionEditor
    }
    func controlTextDidChange(_ notification:Notification) {
        guard !completing, !finished, !model.closed, picker == nil, window?.attachedSheet == nil,
              let field=notification.object as? NSTextField, field === fromField || field === toField,
              let editor=field.currentEditor() as? NSTextView, !editor.hasMarkedText(),
              let event=NSApp.currentEvent, event.type == .keyDown, ![51,117,53].contains(event.keyCode) else { return }
        completing=true; defer { completing=false }; editor.complete(nil)
    }
    func completions(for prefix:String) -> [String] {
        guard !finished, !model.closed, picker == nil, window?.attachedSheet == nil, !prefix.isEmpty else { return [] }
        return completionNames.filter { $0.range(of:prefix,options:[.anchored,.caseInsensitive,.literal]) != nil }
    }
    func control(_ control:NSControl,textView:NSTextView,completions words:[String],forPartialWordRange charRange:NSRange,indexOfSelectedItem index:UnsafeMutablePointer<Int>) -> [String] {
        guard control === fromField || control === toField, control.isEnabled,
              charRange.location <= (textView.string as NSString).length,
              charRange.length <= (textView.string as NSString).length-charRange.location else { return [] }
        index.pointee = -1
        return completions(for:(textView.string as NSString).substring(with:charRange))
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    @objc func scopeChanged(_ sender: NSButton?) {
        guard !finished, !model.closed, picker == nil, window?.attachedSheet == nil else { return }
        if current.state == .on { local.state = .off }
        else if local.state == .on { current.state = .off }
        current.isEnabled = local.state == .off; local.isEnabled = current.state == .off
        toField.isEnabled = current.state == .off && local.state == .off; toBrowse.isEnabled = toField.isEnabled
        if !toField.isEnabled { toField.stringValue = "" }
    }
    @objc func accept() {
        guard !finished, !model.closed, picker == nil, window?.attachedSheet == nil else { return }
        window?.makeFirstResponder(nil)
        var options = model.options; options.from = fromField.stringValue; options.to = toField.stringValue
        options.onlyCurrentBranch = current.state == .on; options.onlyLocalBranches = local.state == .on
        finish(options)
    }
    @objc func abort() { guard !finished, !model.closed, picker == nil, window?.attachedSheet == nil else { return }; finish(nil) }
    @objc func resetFilter() {
        guard !finished, !model.closed, picker == nil, window?.attachedSheet == nil else { return }
        fromField.stringValue = ""; toField.stringValue = ""; current.state = .off; local.state = .off; accept()
    }
    private func finish(_ result: RevisionGraphOptions?) {
        guard !finished else { return }; finished = true
        completionCancellation?.cancel(); completionWorker?.cancel()
        let callback=completion;completion=nil;delivery={callback?(result)}
        if let window {window.sheetParent?.endSheet(window);window.close()}
    }
    @objc private func browseFrom() { browse(fromField) }
    @objc private func browseTo() { guard toField.isEnabled else { return }; browse(toField) }
    private func browse(_ field: NSTextField) {
        guard !finished, !model.closed, picker == nil, let window, window.attachedSheet == nil else { return }
        window.makeFirstResponder(nil)
        let request = UUID(); pickerRequest = request
        let picker = ReferenceBrowserWindowController(repository: model.repository, access: model.access, initial: "HEAD", preferences: model.preferences, pickMultiple: true) { [weak self, weak field] value in
            guard let self, !self.finished, !self.model.closed, self.pickerRequest == request else { return }
            self.pickerRequest = nil; self.picker = nil
            if let value, !value.isEmpty { field?.stringValue = value }
            self.pendingFocus = field; self.restoreInputFocus()
        }
        self.picker = picker; if let child = picker.window { child.alphaValue = window.alphaValue; window.beginSheet(child) }
        picker.model.load()
    }
    @objc private func sheetEnded() { restoreInputFocus(); showCompletionFailure() }
    private func restoreInputFocus() {
        guard !finished, !model.closed, picker == nil, let window, window.attachedSheet == nil, let field = pendingFocus else { return }
        pendingFocus = nil; window.makeFirstResponder(field)
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool { guard picker == nil, sender.attachedSheet == nil else { return false }; finish(nil); return false }
    func windowWillClose(_ notification:Notification) {
        guard !releasing else{return};releasing=true
        if let window {window.sheetParent?.endSheet(window,returnCode:.abort)}
        NotificationCenter.default.removeObserver(self)
        completionCancellation?.cancel();completionWorker?.cancel()
        let sheet=completionAlert?.window ?? window?.attachedSheet,child=picker
        if let sheet {sheet.sheetParent?.endSheet(sheet,returnCode:.abort);sheet.orderOut(nil)}
        completionAlert=nil;pickerRequest=nil;pendingFocus=nil;child?.abandonPresentation();picker=nil
        if !finished {finished=true;let callback=completion;completion=nil;delivery={callback?(nil)}}
        let release=FinderFilesystemWorkflowRelease(ready:{ [self,child,sheet] in pendingOperations==0 && window?.sheetParent==nil && child?.hasPendingWork != true && child?.window?.sheetParent==nil && sheet?.sheetParent==nil },completion:{ [self,child] in releasing=false;let done=delivery;delivery=nil;done?();withExtendedLifetime(child){} });release.start()
    }
}
