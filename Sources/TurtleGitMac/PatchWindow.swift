import AppKit
import SwiftUI
import TurtleGitCore
import UniformTypeIdentifiers

@MainActor private final class PatchNSWindow: NSWindow {
    weak var patchText: NSTextView?
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection([.command, .shift, .control, .option])
        if modifiers == [.command, .shift], event.charactersIgnoringModifiers?.lowercased() == "s" {
            (patchText as? PatchTextView.PatchText)?.savePatch(nil); return true
        }
        if modifiers == .command, event.charactersIgnoringModifiers?.lowercased() == "p" {
            (patchText as? PatchTextView.PatchText)?.printPatch(nil); return true
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
        guard let patchText else { return }
        if action == .showFindInterface, patchText.selectedRange().length > 0 {
            let selection = NSMenuItem(); selection.tag = NSTextFinder.Action.setSearchString.rawValue
            patchText.performTextFinderAction(selection)
        }
        let sender = NSMenuItem(); sender.tag = action.rawValue
        patchText.performTextFinderAction(sender)
    }
    override func cancelOperation(_ sender: Any?) {
        if patchText?.enclosingScrollView?.isFindBarVisible == true {
            find(.hideFindInterface); makeFirstResponder(patchText)
        } else { performClose(sender) }
    }
}

@MainActor final class PatchWindowController: NSWindowController, NSWindowDelegate {
    let model: PatchWindowModel
    var onClosed: () -> Void = {}
    var onMoved: () -> Void = {}
    func windowDidMove(_ notification: Notification) { onMoved() }
    init(repository: GitRepository, access: RepositoryAccessLease?) {
        model = PatchWindowModel(repository: repository, access: access)
        let savedWidth = UserDefaults.standard.double(forKey: "PartialPatchWindowWidth")
        let width = savedWidth >= 460 && savedWidth <= 4000 ? savedWidth : 600
        let window = PatchNSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: 760),
                              styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.minSize = NSSize(width: 460, height: 500); window.isReleasedWhenClosed = false
        let host = NSHostingController(rootView: PatchDialog(model: model))
        // Patch content scrolls; its intrinsic size must not replace window limits.
        host.sizingOptions = []
        window.contentViewController = host
        super.init(window: window); window.delegate = self
        window.setContentSize(NSSize(width: width, height: 760))
        model.saveAs = { [weak window] in (window?.patchText as? PatchTextView.PatchText)?.savePatch(nil) }
        model.printDiff = { [weak window] in (window?.patchText as? PatchTextView.PatchText)?.printPatch(nil) }
    }
    func windowWillClose(_ notification: Notification) {
        if let window { UserDefaults.standard.set(window.frame.width, forKey: "PartialPatchWindowWidth") }
        onClosed()
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool { !model.busy && !model.confirmingQuit && sender.attachedSheet == nil }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
}

@MainActor final class PatchWindowModel: ObservableObject {
    let repository: GitRepository
    private let access: RepositoryAccessLease?
    @Published var document = GitPatch(text: "") { didSet { originalDiff = nil } }
    private var originalDiff: UnifiedDiffDocument?
    @Published var selectedLines = Set<Int>()
    @Published var staged = false
    @Published var readOnly = false { didSet { if !readOnly { originalDiff = nil } } }
    @Published var refreshAvailable = true
    var saveAs: () -> Void = {}
    var printDiff: () -> Void = {}
    @Published var showPageSetup = false
    func pageSetup() {
        guard !busy, !confirmingQuit, !showPageSetup else { return }
        busy = true; showPageSetup = true
    }
    @Published var comparisonTitle = "HEAD → Working tree"
    var customRefresh: (() -> Void)?
    var readOnlyInformation: String?
    var base: String?
    @Published var busy = false
    @Published var confirmingQuit = false
    @Published var error: String?
    @Published var paths: [String] = []
    private var generation = 0
    var onApplying: (Bool) -> Void = { _ in }
    var onApplied: () -> Void = {}
    init(repository: GitRepository, access: RepositoryAccessLease?) { self.repository = repository; self.access = access }
    var exportDocument: UnifiedDiffDocument { readOnly ? originalDiff ?? UnifiedDiffDocument(bytes: Data(document.text.utf8)) : UnifiedDiffDocument(bytes: Data(document.text.utf8)) }
    func setReadOnlyDiff(_ bytes: Data) {
        let source = UnifiedDiffDocument(bytes: bytes)
        readOnly = true; document = GitPatch(text: source.displayText); originalDiff = source
    }
    var canApplyLines: Bool { !readOnly && !busy && !confirmingQuit && selectedLines.contains(where: { document.changedLine($0) }) }
    var canApplyHunks: Bool { !readOnly && !busy && !confirmingQuit && document.files.flatMap(\.hunks).contains { hunk in selectedLines.contains(hunk.header) || hunk.range.contains(where: { selectedLines.contains($0) }) } }
    var information: String {
        if readOnly, let readOnlyInformation { return readOnlyInformation }
        if paths.isEmpty { return "Select files in the Commit window to see their patch." }
        if readOnly { return document.text.isEmpty ? "No patch for the selected files." : "Select files in the Commit window to compare their contents." }
        if document.text.isEmpty { return "No changes in this view. New files must be staged as a whole file first." }
        if document.files.contains(where: { !$0.supportsPartialChanges }) { return "Some files require whole-file staging: new/deleted, renamed, binary or mode changes." }
        return "Select changed lines, or place the caret in a hunk. Right-click for staging actions."
    }
    func reload(paths: [String], staged: Bool) {
        if let customRefresh { customRefresh(); return }
        generation += 1; let request = generation
        let base = self.base, readOnly = self.readOnly
        self.paths = paths; self.staged = staged; selectedLines = []; document = GitPatch(text: ""); busy = true
        Task {
            do {
                let bytes: Data
                if paths.isEmpty { bytes = Data() }
                else if readOnly { bytes = try await repository.workingTreePatchData(paths: paths, base: base) }
                else { bytes = Data(try await repository.patch(paths: paths, staged: staged, base: base).text.utf8) }
                guard request == generation else { return }
                if readOnly { setReadOnlyDiff(bytes) } else { document = GitPatch(text: String(decoding: bytes, as: UTF8.self)) }
                busy = false
            } catch { if request == generation { self.error = error.localizedDescription; busy = false } }
        }
    }
    func apply(entireHunks: Bool) {
        guard !readOnly, entireHunks ? canApplyHunks : canApplyLines else { return }
        let document = self.document, paths = self.paths, staged = self.staged, lines = selectedLines, base = self.base
        busy = true; onApplying(true)
        Task {
            do {
                try await repository.applyPatchSelection(document, paths: paths, staged: staged, lines: lines, entireHunks: entireHunks, base: base)
                busy = false; onApplying(false); onApplied(); reload(paths: paths, staged: staged)
            } catch { self.error = error.localizedDescription; busy = false; onApplying(false) }
        }
    }
}

struct PatchDialog: View {
    @ObservedObject var model: PatchWindowModel
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(model.readOnly ? model.comparisonTitle : model.staged ? (model.base == nil ? "HEAD → Index" : "Parent → Index") : "Index → Working tree").font(.headline)
                Spacer(); if model.busy { ProgressView().controlSize(.small) }
                Button { model.saveAs() } label: { CommandLabel(title: "Save As…", icon: .saveAs) }.disabled(model.busy)
                Button { model.printDiff() } label: { Label("Print…", systemImage: "printer") }.disabled(model.busy)
                if model.refreshAvailable { Button("Refresh") { model.reload(paths: model.paths, staged: model.staged) }.disabled(model.busy) }
            }
            PatchTextView(model: model).frame(minWidth: 430, minHeight: 360)
            Text(model.information).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if !model.readOnly {
                HStack {
                    Button(model.staged ? "Unstage selected hunks" : "Stage selected hunks") { model.apply(entireHunks: true) }.disabled(!model.canApplyHunks)
                    Button(model.staged ? "Unstage selected lines" : "Stage selected lines") { model.apply(entireHunks: false) }.disabled(!model.canApplyLines)
                }
            }
        }.padding(12).disabled(model.confirmingQuit)
        .sheet(isPresented: $model.showPageSetup, onDismiss: { model.busy = false }) { PatchPageSetup(model: model) }
        .onReceive(NotificationCenter.default.publisher(for: .unifiedDiffAppearanceChanged)) { _ in model.objectWillChange.send() }
        .alert(model.readOnly ? "Patch could not be loaded" : "Patch could not be applied", isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) {
            Button("OK") { model.error = nil }
        } message: { Text(model.error ?? "") }
    }
}

struct PatchTextView: NSViewRepresentable {
    @ObservedObject var model: PatchWindowModel
    @Environment(\.colorScheme) private var scheme
    @Environment(\.colorSchemeContrast) private var contrast
    func makeCoordinator() -> Coordinator { Coordinator(model: model) }
    func makeNSView(context: Context) -> NSScrollView {
        let text = PatchText()
        text.isEditable = false; text.isSelectable = true; text.delegate = context.coordinator
        text.coordinator = context.coordinator
        text.isRichText = false; text.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        text.usesFindBar = true; text.isIncrementalSearchingEnabled = true
        text.isHorizontallyResizable = true; text.isVerticallyResizable = true
        text.autoresizingMask = [.width]
        text.textContainer?.widthTracksTextView = false
        text.textContainer?.containerSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        let scroll = NSScrollView(); scroll.hasVerticalScroller = true; scroll.hasHorizontalScroller = true
        scroll.findBarPosition = .belowContent
        scroll.autohidesScrollers = true; scroll.borderType = .bezelBorder; scroll.documentView = text
        return scroll
    }
    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.model = model
        guard let text = scroll.documentView as? NSTextView else { return }
        let settings = UnifiedDiffAppearance.load(), dark = scheme == .dark, highContrast = contrast == .increased
        let cache = context.coordinator
        guard cache.lastText != model.document.text || cache.lastAppearance != settings || cache.dark != dark || cache.highContrast != highContrast else { return }
        let contentChanged = cache.lastText != model.document.text, selection = text.selectedRange()
        cache.lastText = model.document.text; cache.lastAppearance = settings; cache.dark = dark; cache.highContrast = highContrast
        let font = NSFont(name: settings.fontName, size: CGFloat(settings.fontSize)) ?? NSFontManager.shared.font(withFamily: settings.fontName, traits: [], weight: 5, size: CGFloat(settings.fontSize)) ?? NSFont.monospacedSystemFont(ofSize: CGFloat(settings.fontSize), weight: .regular)
        let paragraph = NSMutableParagraphStyle(); paragraph.tabStops = []
        paragraph.defaultTabInterval = max(1, (" " as NSString).size(withAttributes: [.font: font]).width * CGFloat(settings.tabSize))
        func color(_ rgb: UInt32) -> NSColor { NSColor(srgbRed: CGFloat((rgb >> 16) & 255) / 255, green: CGFloat((rgb >> 8) & 255) / 255, blue: CGFloat(rgb & 255) / 255, alpha: 1) }
        text.backgroundColor = highContrast ? .textBackgroundColor : color(settings.colors(.context, dark: dark).background)
        text.insertionPointColor = highContrast ? .labelColor : color(settings.colors(.context, dark: dark).foreground)
        let value = NSMutableAttributedString(string: "")
        for (index, line) in model.document.lines.enumerated() {
            let terminated = index < model.document.lines.count - 1 || model.document.text.hasSuffix("\n")
            let style = UnifiedDiffLineStyle.classify(line + (terminated ? "\n" : "")), palette = settings.colors(style, dark: dark)
            let face = !highContrast && style == .comment ? NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask) : font
            value.append(NSAttributedString(string: line + "\n", attributes: [.font: face, .paragraphStyle: paragraph,
                .foregroundColor: highContrast ? NSColor.labelColor : color(palette.foreground),
                .backgroundColor: highContrast ? NSColor.textBackgroundColor : color(palette.background)]))
        }
        text.textStorage?.setAttributedString(value)
        if contentChanged { text.setSelectedRange(NSRange(location: 0, length: 0)) }
        else {
            let location = min(selection.location, value.length)
            text.setSelectedRange(NSRange(location: location, length: min(selection.length, value.length - location)))
        }
    }
    @MainActor final class Coordinator: NSObject, NSTextViewDelegate {
        var model: PatchWindowModel
        var lastText: String?
        var lastAppearance: UnifiedDiffAppearance?
        var dark = false, highContrast = false
        init(model: PatchWindowModel) { self.model = model }
        func textViewDidChangeSelection(_ notification: Notification) {
            guard let view = notification.object as? NSTextView else { return }
            let selected = view.selectedRange(); var offset = 0, lines = Set<Int>()
            for (index, line) in model.document.lines.enumerated() {
                let range = NSRange(location: offset, length: (line as NSString).length + 1)
                if selected.length == 0 ? NSLocationInRange(selected.location, range) : NSIntersectionRange(selected, range).length > 0 { lines.insert(index) }
                offset += range.length
            }
            model.selectedLines = lines
        }
        @objc func hunks(_ sender: NSMenuItem) { model.apply(entireHunks: true) }
        @objc func lines(_ sender: NSMenuItem) { model.apply(entireHunks: false) }
    }
    final class PatchText: NSTextView {
        weak var coordinator: Coordinator?
        private var printSession: PatchPrintSession?
        @objc func printPatch(_ sender: Any?) {
            guard let window, window.attachedSheet == nil, let model = coordinator?.model,
                  !model.busy, !model.confirmingQuit, printSession == nil else { return }
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
        }
        override func cancelOperation(_ sender: Any?) { window?.cancelOperation(sender) }
        @objc func savePatch(_ sender: Any?) {
            guard let window, window.attachedSheet == nil, let model = coordinator?.model, !model.busy, !model.confirmingQuit else { return }
            let snapshot = model.exportDocument
            let panel = NSSavePanel(); panel.nameFieldStringValue = "changes.patch"
            panel.allowedContentTypes = [UTType(filenameExtension: "patch") ?? .plainText]
            panel.beginSheetModal(for: window) { response in
                guard response == .OK, let url = panel.url else { return }
                do { try snapshot.write(to: url) }
                catch { model.error = error.localizedDescription }
            }
        }
        @objc func showFind(_ sender: Any?) { (window as? PatchNSWindow)?.find(.showFindInterface) }
        override func menu(for event: NSEvent) -> NSMenu? {
            guard let coordinator else { return super.menu(for: event) }
            if selectedRange().length == 0 {
                let location = characterIndexForInsertion(at: convert(event.locationInWindow, from: nil))
                setSelectedRange(NSRange(location: location, length: 0))
            }
            let menu = NSMenu()
            let save = NSMenuItem(title: "Save As…", action: #selector(savePatch(_:)), keyEquivalent: "")
            save.target = self; save.image = MenuIcon.unifiedDiff.contextImage(); menu.addItem(save)
            let print = NSMenuItem(title: "Print…", action: #selector(printPatch(_:)), keyEquivalent: "")
            print.target = self; print.image = MenuPresentationSettings.applicationContextIcons() ? NSImage(systemSymbolName: "printer", accessibilityDescription: "Print") : nil
            menu.addItem(print)
            menu.addItem(.separator())
            if !coordinator.model.readOnly {
                for (title, selector, enabled) in [("selected hunks", #selector(Coordinator.hunks(_:)), coordinator.model.canApplyHunks), ("selected lines", #selector(Coordinator.lines(_:)), coordinator.model.canApplyLines)] {
                    let item = NSMenuItem(title: (coordinator.model.staged ? "Unstage " : "Stage ") + title, action: selector, keyEquivalent: "")
                    item.target = coordinator; item.image = (coordinator.model.staged ? MenuIcon.revert : .add).contextImage(); item.isEnabled = enabled; menu.addItem(item)
                }
                menu.addItem(.separator())
            }
            let copy = NSMenuItem(title: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "")
            copy.target = self; copy.image = MenuIcon.copy.contextImage(); menu.addItem(copy)
            menu.addItem(NSMenuItem(title: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: ""))
            let find = NSMenuItem(title: "Find…", action: #selector(showFind(_:)), keyEquivalent: "")
            find.target = self; menu.addItem(find)
            return menu
        }
    }
}
