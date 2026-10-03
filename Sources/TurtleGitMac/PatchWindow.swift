import AppKit
import SwiftUI
import TurtleGitCore
import UniformTypeIdentifiers

@MainActor private final class PatchNSWindow: NSWindow {
    weak var patchText: NSTextView?
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection([.command, .shift, .control, .option])
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
        } else { close() }
    }
}

@MainActor final class PatchWindowController: NSWindowController, NSWindowDelegate {
    let model: PatchWindowModel
    var onClosed: () -> Void = {}
    init(repository: GitRepository, access: RepositoryAccessLease?) {
        model = PatchWindowModel(repository: repository, access: access)
        let savedWidth = UserDefaults.standard.double(forKey: "PartialPatchWindowWidth")
        let width = savedWidth >= 460 && savedWidth <= 4000 ? savedWidth : 600
        let window = PatchNSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: 760),
                              styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.minSize = NSSize(width: 460, height: 500); window.isReleasedWhenClosed = false
        window.contentViewController = NSHostingController(rootView: PatchDialog(model: model))
        super.init(window: window); window.delegate = self
        window.setContentSize(NSSize(width: width, height: 760))
    }
    func windowWillClose(_ notification: Notification) {
        if let window { UserDefaults.standard.set(window.frame.width, forKey: "PartialPatchWindowWidth") }
        onClosed()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
}

@MainActor final class PatchWindowModel: ObservableObject {
    let repository: GitRepository
    private let access: RepositoryAccessLease?
    @Published var document = GitPatch(text: "")
    @Published var selectedLines = Set<Int>()
    @Published var staged = false
    var base: String?
    @Published var busy = false
    @Published var error: String?
    @Published var paths: [String] = []
    private var generation = 0
    var onApplying: (Bool) -> Void = { _ in }
    var onApplied: () -> Void = {}
    init(repository: GitRepository, access: RepositoryAccessLease?) { self.repository = repository; self.access = access }
    var canApplyLines: Bool { !busy && selectedLines.contains(where: { document.changedLine($0) }) }
    var canApplyHunks: Bool { !busy && document.files.flatMap(\.hunks).contains { hunk in selectedLines.contains(hunk.header) || hunk.range.contains(where: { selectedLines.contains($0) }) } }
    var information: String {
        if paths.isEmpty { return "Select files in the Commit window to see their patch." }
        if document.text.isEmpty { return "No changes in this view. New files must be staged as a whole file first." }
        if document.files.contains(where: { !$0.supportsPartialChanges }) { return "Some files require whole-file staging: new/deleted, renamed, binary or mode changes." }
        return "Select changed lines, or place the caret in a hunk. Right-click for staging actions."
    }
    func reload(paths: [String], staged: Bool) {
        generation += 1; let request = generation
        let base = self.base
        self.paths = paths; self.staged = staged; selectedLines = []; document = GitPatch(text: ""); busy = true
        Task {
            do {
                let result = paths.isEmpty ? GitPatch(text: "") : try await repository.patch(paths: paths, staged: staged, base: base)
                guard request == generation else { return }
                document = result; busy = false
            } catch { if request == generation { self.error = error.localizedDescription; busy = false } }
        }
    }
    func apply(entireHunks: Bool) {
        guard entireHunks ? canApplyHunks : canApplyLines else { return }
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
                Text(model.staged ? (model.base == nil ? "HEAD → Index" : "Parent → Index") : "Index → Working tree").font(.headline)
                Spacer(); if model.busy { ProgressView().controlSize(.small) }
                Button("Refresh") { model.reload(paths: model.paths, staged: model.staged) }.disabled(model.busy)
            }
            PatchTextView(model: model).frame(minWidth: 430, minHeight: 360)
            Text(model.information).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                Button(model.staged ? "Unstage selected hunks" : "Stage selected hunks") { model.apply(entireHunks: true) }.disabled(!model.canApplyHunks)
                Button(model.staged ? "Unstage selected lines" : "Stage selected lines") { model.apply(entireHunks: false) }.disabled(!model.canApplyLines)
            }
        }.padding(12)
        .alert("Patch could not be applied", isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) {
            Button("OK") { model.error = nil }
        } message: { Text(model.error ?? "") }
    }
}

struct PatchTextView: NSViewRepresentable {
    @ObservedObject var model: PatchWindowModel
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
        guard let text = scroll.documentView as? NSTextView, text.string != model.document.text else { return }
        let value = NSMutableAttributedString(string: "")
        for (index, line) in model.document.lines.enumerated() {
            let color: NSColor
            if model.document.changedLine(index) { color = line.hasPrefix("+") ? .systemGreen : .systemRed }
            else if line.hasPrefix("@@") { color = .systemBlue }
            else { color = line.hasPrefix(" ") ? .labelColor : .secondaryLabelColor }
            value.append(NSAttributedString(string: line + "\n", attributes: [.font: NSFont.monospacedSystemFont(ofSize: 12, weight: .regular), .foregroundColor: color]))
        }
        text.textStorage?.setAttributedString(value)
        text.setSelectedRange(NSRange(location: 0, length: 0))
    }
    @MainActor final class Coordinator: NSObject, NSTextViewDelegate {
        var model: PatchWindowModel
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
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow(); (window as? PatchNSWindow)?.patchText = self
        }
        override func cancelOperation(_ sender: Any?) { window?.cancelOperation(sender) }
        @objc func savePatch(_ sender: Any?) {
            guard let window, let model = coordinator?.model else { return }
            let snapshot = model.document.text
            let panel = NSSavePanel(); panel.nameFieldStringValue = "changes.patch"
            panel.allowedContentTypes = [UTType(filenameExtension: "patch") ?? .plainText]
            panel.beginSheetModal(for: window) { response in
                guard response == .OK, let url = panel.url else { return }
                do { try Data(snapshot.utf8).write(to: url, options: .atomic) }
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
            save.target = self; save.image = MenuIcon.unifiedDiff.image(); menu.addItem(save)
            menu.addItem(.separator())
            for (title, selector, enabled) in [("selected hunks", #selector(Coordinator.hunks(_:)), coordinator.model.canApplyHunks), ("selected lines", #selector(Coordinator.lines(_:)), coordinator.model.canApplyLines)] {
                let item = NSMenuItem(title: (coordinator.model.staged ? "Unstage " : "Stage ") + title, action: selector, keyEquivalent: "")
                item.target = coordinator; item.image = (coordinator.model.staged ? MenuIcon.revert : .add).image(); item.isEnabled = enabled; menu.addItem(item)
            }
            menu.addItem(.separator())
            let copy = NSMenuItem(title: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "")
            copy.target = self; copy.image = MenuIcon.copy.image(); menu.addItem(copy)
            menu.addItem(NSMenuItem(title: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: ""))
            let find = NSMenuItem(title: "Find…", action: #selector(showFind(_:)), keyEquivalent: "")
            find.target = self; menu.addItem(find)
            return menu
        }
    }
}
