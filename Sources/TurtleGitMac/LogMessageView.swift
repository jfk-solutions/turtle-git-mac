// SPDX-License-Identifier: GPL-2.0-or-later
import AppKit
import SwiftUI
import TurtleGitCore

struct LogMessageView: NSViewRepresentable {
    @ObservedObject var model: LogWindowModel
    func makeCoordinator() -> Coordinator { Coordinator(model: model) }
    func makeNSView(context: Context) -> NSScrollView {
        let editor = LogMessageTextView()
        editor.isEditable = false; editor.isSelectable = true; editor.isRichText = false
        editor.isAutomaticLinkDetectionEnabled = false
        editor.linkTextAttributes = [.foregroundColor:NSColor.linkColor,.cursor:NSCursor.pointingHand]
        editor.textContainerInset = NSSize(width:12,height:12); editor.autoresizingMask = [.width]
        editor.isVerticallyResizable = true; editor.textContainer?.widthTracksTextView = true
        editor.setAccessibilityLabel("Log message")
        let scroll = NSScrollView(); scroll.hasVerticalScroller = true; scroll.documentView = editor
        context.coordinator.attach(editor); return scroll
    }
    func updateNSView(_ view: NSScrollView, context: Context) { context.coordinator.refresh() }
    static func dismantleNSView(_ view: NSScrollView, coordinator: Coordinator) { coordinator.retire() }
    @MainActor final class Coordinator: NSObject, NSTextViewDelegate {
        static private(set) var activeOperations = 0
        typealias Query = @Sendable (HistoryMessageDocument, IssueTrackerProperties, HistoryMessageOptions, OperationCancellation) async throws -> HistoryMessageStyles
        private weak var editor: LogMessageTextView?
        private weak var model: LogWindowModel?
        private let query: Query
        private var document = HistoryMessageDocument(plain: "")
        private var properties = IssueTrackerProperties()
        private var options = HistoryMessageOptions()
        private var sourceGeneration = UUID(), request = UUID()
        private var styles = HistoryMessageStyles()
        private var task: Task<Void,Never>?, token: OperationCancellation?
        private var preferencesObserver: NSObjectProtocol?, closeObserver: NSObjectProtocol?
        private var retired = false, configured = false
        private var menuGeneration = UUID()
        var openURL: (URL) -> Void = { NSWorkspace.shared.open($0) }
        init(model: LogWindowModel, query: Query? = nil) {
            self.model = model; let worker = HistoryMessageStyler()
            self.query = query ?? { try await worker.prepare($0,properties:$1,options:$2,cancellation:$3) }
        }
        func attach(_ editor: LogMessageTextView) {
            self.editor = editor; editor.delegate = self; editor.coordinator = self
            preferencesObserver = NotificationCenter.default.addObserver(forName:UserDefaults.didChangeNotification,object:model?.colorPreferences,queue:.main) { [weak self] _ in Task { @MainActor [weak self] in self?.refresh() } }
            editor.onWindowChanged = { [weak self] in self?.observeOwner() }; observeOwner(); refresh()
        }
        private func observeOwner() {
            if let closeObserver { NotificationCenter.default.removeObserver(closeObserver) }; closeObserver = nil
            guard let window = editor?.window else { return }
            closeObserver = NotificationCenter.default.addObserver(forName:NSWindow.willCloseNotification,object:window,queue:nil) { [weak self] _ in MainActor.assumeIsolated { self?.retire() } }
        }
        func refresh() {
            guard !retired, let model, !model.isInvalidated, let editor else { return }
            let next = model.messageDocument, prefs = model.colorPreferences
            var options = HistoryMessageOptions(defaults:prefs)
            options.query = model.appliedMessageSearch.query; options.fields = model.appliedMessageSearch.fields; options.regex = model.appliedMessageSearch.regex; options.caseSensitive = model.appliedMessageSearch.caseSensitive
            let changed = !configured || next != document || properties != model.issueProperties || self.options != options || sourceGeneration != model.messageLinkGeneration
            if changed {
                configured = true; self.options = options; document = next; properties = model.issueProperties; sourceGeneration = model.messageLinkGeneration
                token?.cancel(); task?.cancel(); request = UUID(); let request = request
                styles = HistoryMessageStyles(); styles.bold = document.bold
                if editor.string != next.text { editor.string = next.text; editor.setSelectedRange(NSRange(location:0,length:0)); editor.scrollToBeginningOfDocument(nil) }
                let document = document, properties = properties, query = query, token = OperationCancellation(); self.token = token
                Self.activeOperations += 1
                task = Task { [weak self] in
                    defer { Self.activeOperations -= 1 }
                    do {
                        try await Task.sleep(nanoseconds:100_000_000)
                        let result = try await query(document,properties,options,token)
                        guard let self, !self.retired, self.request == request, !token.isCancelled, !Task.isCancelled,
                              self.model?.messageLinkGeneration == self.sourceGeneration, self.model?.isInvalidated == false else { return }
                        self.styles = result; self.apply(); self.token = nil; self.task = nil
                    } catch { /* A stale/invalid helper result never changes message text or navigation. */ }
                }
            }
            apply()
        }
        private func apply() {
            guard !retired, let editor, let storage = editor.textStorage, let model, editor.string == document.text else { return }
            let prefs = model.colorPreferences
            let font = MessageEditorFont.resolve(name:prefs.string(forKey:"LogFontName") ?? MessageEditorFont.defaultName,size:prefs.object(forKey:"LogFontSize") as? Int ?? MessageEditorFont.defaultSize)
            let selection = editor.selectedRanges, origin = editor.enclosingScrollView?.contentView.bounds.origin
            storage.beginEditing(); storage.setAttributes([.font:font,.foregroundColor:NSColor.textColor],range:NSRange(location:0,length:storage.length))
            func valid(_ range: NSRange) -> Bool { range.location >= 0 && range.location <= storage.length && range.length <= storage.length - range.location }
            func trait(_ ranges: [NSRange], _ trait: NSFontTraitMask) {
                for range in ranges where valid(range) {
                    var fonts: [(NSRange,NSFont)] = []
                    storage.enumerateAttribute(.font,in:range) { value, run, _ in fonts.append((run,NSFontManager.shared.convert(value as? NSFont ?? font,toHaveTrait:trait))) }
                    for (run,font) in fonts { storage.addAttribute(.font,value:font,range:run) }
                }
            }
            trait(styles.bold,.boldFontMask); trait(styles.italic,.italicFontMask)
            for range in styles.underlined where valid(range) { storage.addAttribute(.underlineStyle,value:NSUnderlineStyle.single.rawValue,range:range) }
            for range in styles.highlights where valid(range) { storage.addAttribute(.foregroundColor,value:LogPalette.native(.filterMatch,preferences:prefs),range:range) }
            for (index,link) in styles.links.enumerated() where valid(link.range) {
                storage.addAttributes([.link:"turtlegit-message-link:" + request.uuidString + ":" + String(index),.foregroundColor:NSColor.linkColor,.toolTip:link.target],range:link.range)
            }
            storage.endEditing(); editor.selectedRanges = selection
            if let origin { editor.enclosingScrollView?.contentView.scroll(to:origin) }
        }
        func retire() {
            guard !retired else { return }; retired = true; menuGeneration = UUID(); request = UUID(); token?.cancel(); task?.cancel(); token = nil; task = nil
            for observer in [preferencesObserver,closeObserver].compactMap({$0}) { NotificationCenter.default.removeObserver(observer) }
            preferencesObserver = nil; closeObserver = nil; editor?.delegate = nil; editor?.coordinator = nil; editor?.onWindowChanged = {}; editor = nil
        }
        private var current: Bool {
            guard !retired, let editor, let model, !model.isInvalidated else { return false }
            return sourceGeneration == model.messageLinkGeneration && document == model.messageDocument && editor.string == document.text
        }
        private var interactive: Bool { current && model?.canFollowMessageLink == true && editor?.window?.attachedSheet == nil && NSApp.modalWindow == nil }
        func link(at index: Int) -> HistoryMessageLink? { styles.links.first { NSLocationInRange(index,$0.range) } }
        func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
            guard charIndex >= 0, charIndex < (textView.string as NSString).length,
                  let value = link as? String, value == textView.textStorage?.attribute(.link,at:charIndex,effectiveRange:nil) as? String,
                  textView.selectedRange().length == 0, let target = self.link(at:charIndex) else { return true }
            activate(target); return true
        }
        func activate(_ link: HistoryMessageLink, expected: UUID? = nil) {
            guard expected == nil || expected == request else { return }
            guard interactive, styles.links.contains(link) else { return }
            if link.kind == .hash { model?.followMessageHash(link.target) }
            else if let url = SourceMessageLinkURL.url(link.target) { openURL(url) }
        }
        func copySelection() {
            guard interactive, let model, let editor else { return }
            let range = editor.selectedRange(), text = editor.string as NSString
            guard range.location >= 0, range.length > 0, range.location <= text.length, range.length <= text.length-range.location else { return }
            model.copy(text.substring(with: range))
        }
        func menu(at index: Int) -> NSMenu {
            menuGeneration = UUID()
            let epoch = menuGeneration, expected = request, selection = model?.selected, generation = model?.messageLoadGeneration, controls = model?.logControlsEpoch
            let fullText = document.text, range = editor?.selectedRange() ?? NSRange(location:0,length:0)
            let text = fullText as NSString
            let selectionText = range.location >= 0 && range.location <= text.length && range.length <= text.length-range.location ? text.substring(with:range) : ""
            var used = false
            let menu = NSMenu(); menu.autoenablesItems = false
            let available: () -> Bool = { [weak self] in
                guard let self else { return false }
                return !used && self.menuGeneration == epoch && self.request == expected && self.interactive &&
                    self.model?.selected == selection && self.model?.messageLoadGeneration == generation && self.model?.logControlsEpoch == controls
            }
            func add(_ title: String, icon: MenuIcon, enabled: Bool = true, _ action: @escaping () -> Void) {
                let item = MessageLinkMenuItem(title:title, icon:icon, defaults:model?.colorPreferences ?? .standard, available: { available() && enabled }) {
                    guard available(), enabled else { return }; used = true; action()
                }
                menu.addItem(item)
            }
            if let link = link(at:index) {
                add(link.kind == .hash ? "Jump to commit" : "Open link", icon:link.kind == .hash ? .log:.open) { [weak self] in self?.activate(link, expected:expected) }
                add(link.kind == .hash ? "Copy hash" : "Copy link address", icon:.copy) { [weak self] in self?.copyLink(link, expected:expected) }
                menu.addItem(.separator())
            }
            add("Copy", icon:.copy, enabled:!selectionText.isEmpty) { [weak model = self.model] in model?.copy(selectionText) }
            menu.addItem(.separator())
            // Copy the document directly: selection and viewport never need to
            // be changed/restored, matching the source Copy-all end state.
            add("Copy all", icon:.copy, enabled:!fullText.isEmpty) { [weak model = self.model] in model?.copy(fullText) }
            if let model, model.revision != nil {
                menu.addItem(.separator())
                add("Edit Notes", icon:.rebaseEdit, enabled:model.canEditNotes) { [weak model] in model?.editNotes() }
            }
            menu.addItem(.separator())
            add("Select All", icon:.copy, enabled:!fullText.isEmpty) { [weak editor = self.editor] in editor?.selectAll(nil) }
            return menu
        }
        func copyLink(_ link: HistoryMessageLink, expected: UUID? = nil) {
            guard expected == nil || expected == request else { return }
            guard interactive, styles.links.contains(link) else { return }; model?.copy(link.target)
        }
    }
}
final class LogMessageTextView: NSTextView {
    weak var coordinator: LogMessageView.Coordinator?
    var onWindowChanged: () -> Void = {}
    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); onWindowChanged() }
    override func menu(for event: NSEvent) -> NSMenu? {
        let point = convert(event.locationInWindow,from:nil)
        return coordinator?.menu(at:characterIndexForInsertion(at:point))
    }
    override func copy(_ sender: Any?) {
        coordinator?.copySelection()
    }
}
