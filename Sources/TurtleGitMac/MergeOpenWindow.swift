// SPDX-License-Identifier: GPL-2.0-or-later
// Adapts OpenDlg; Copyright (C) 2012, 2019-2020, 2023 TortoiseGit; 2006-2010, 2012-2013 TortoiseSVN.
import AppKit
import UniformTypeIdentifiers
import TurtleGitCore

@MainActor final class MergeOpenPathField: NSTextField {
    var acceptURL: (URL) -> Bool = { _ in false }
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        isEnabled && sender.draggingPasteboard.canReadObject(forClasses:[NSURL.self], options:[.urlReadingFileURLsOnly:true]) ? .copy : []
    }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        acceptDrop(from:sender.draggingPasteboard)
    }
    func acceptDrop(from pasteboard: NSPasteboard) -> Bool {
        guard isEnabled, let urls = pasteboard.readObjects(forClasses:[NSURL.self], options:[.urlReadingFileURLsOnly:true]) as? [URL], urls.count == 1 else { return false }
        return acceptURL(urls[0])
    }
}

/// Native IDD_OPENDLG: preserves both groups while radio controls their gates.
@MainActor final class MergeOpenWindowController: NSWindowController, NSWindowDelegate, NSTextFieldDelegate {
    static private(set) var activeChoices = 0
    private(set) var pendingChoices = 0
    enum Slot: Int, CaseIterable { case base, theirs, mine, diff, directory }
    let base = MergeOpenPathField(), theirs = MergeOpenPathField(), mine = MergeOpenPathField(), diff = MergeOpenPathField(), directory = MergeOpenPathField()
    let merging = NSButton(radioButtonWithTitle: "Merging", target: nil, action: nil)
    let apply = NSButton(radioButtonWithTitle: "Apply unified diff", target: nil, action: nil)
    let clipboard = NSButton(checkboxWithTitle: "Use Unified Diff from clipboard", target: nil, action: nil)
    let status = NSTextField(labelWithString: "")
    let ok = NSButton(title: "OK", target: nil, action: nil)
    private var browseButtons: [Slot: NSButton] = [:]
    private var grants: [RepositoryAccessLease]
    private let wordCommands=GitInputWordCommands()
    private let preferences: UserDefaults
    private let pasteboard: NSPasteboard
    private var picker: NSOpenPanel?
    private var clipboardMonitor: Timer?
    private var ownerObserver: NSObjectProtocol?
    private var clipboardChangeCount = -1
    private var clipboardFormatAvailable = false
    var monitoringClipboard: Bool { clipboardMonitor != nil }
    private var completionPrefixes: [ObjectIdentifier:String] = [:]
    private var retired = false
    private var accepting = false
    private var choiceID: UUID?
    private struct Form: Equatable {
        let mode: MergeOpenMode
        let clipboard: Int
        let paths: [Data]
    }
    private var form: Form { Form(mode: mode, clipboard: clipboard.state.rawValue, paths: Slot.allCases.map { Data(field($0).stringValue.utf8) }) }
    private(set) var busy = false
    var requiresScopes = GitRuntime.isAppStoreBuild
    var choosePath: ((Slot, URL?) async -> URL?)?
    // Native panel seams preserve production panel configuration and one-response ownership.
    var presentPicker: ((NSOpenPanel, NSWindow, @escaping (NSApplication.ModalResponse) -> Void) -> Void)?
    var selectedPath: (NSOpenPanel) -> URL? = { $0.url }
    var makeLease: (URL) -> RepositoryAccessLease = { RepositoryAccessLease(url: $0) }
    var onAccepted: (MergeOpenRequest, [RepositoryAccessLease]) throws -> Void = { _, _ in }
    var onClosed: () -> Void = {}
    var mode: MergeOpenMode { apply.state == .on ? .applyUnifiedDiff : .merging }
    init(preferences: UserDefaults = .standard, pasteboard: NSPasteboard = .general, permissions: [RepositoryAccessLease] = []) {
        self.preferences = preferences; self.pasteboard = pasteboard; grants = permissions
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 470), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "TurtleGitMerge"; window.isReleasedWhenClosed = false
        super.init(window: window); TurtleGitHelp.attach(window, topic: .compare); window.delegate = self; window.center()
        merging.target = self; merging.action = #selector(selectMerging); apply.target = self; apply.action = #selector(selectApply)
        clipboard.target = self; clipboard.action = #selector(clipboardChanged)
        let radios = NSStackView(views: [merging, apply]); radios.spacing = 24
        func group(_ title: String, entries: [(Slot, String, NSTextField)]) -> NSBox {
            let box = NSBox(); box.title = title
            var rows: [[NSView]] = []
            for (slot, label, field) in entries {
                if let pathField = field as? MergeOpenPathField {
                    pathField.registerForDraggedTypes([.fileURL]); pathField.acceptURL = { [weak self] in self?.acceptPath($0, slot:slot) == true }
                }
                field.delegate = self
                field.setAccessibilityLabel(label); field.maximumNumberOfLines = 1
                (field.cell as? NSTextFieldCell)?.usesSingleLineMode = true; (field.cell as? NSTextFieldCell)?.isScrollable = true
                field.widthAnchor.constraint(equalToConstant: 400).isActive = true
                let browse = NSButton(title: "Browse…", target: self, action: #selector(browseClicked)); browse.tag = slot.rawValue
                browse.setAccessibilityLabel("Browse " + label); browseButtons[slot] = browse
                let caption = NSTextField(labelWithString: label + ":")
                caption.widthAnchor.constraint(equalToConstant: 86).isActive = true
                browse.widthAnchor.constraint(equalToConstant: 86).isActive = true
                rows.append([caption, field, browse])
            }
            let grid = NSGridView(views: rows); grid.rowSpacing = 10; grid.columnSpacing = 12
            let content = NSStackView(views: title == "Apply unified diff" ? [clipboard, grid] : [grid])
            content.orientation = .vertical; content.alignment = .leading; content.spacing = 10
            box.contentViewMargins = NSSize(width: 12, height: 10)
            box.contentView = content; box.heightAnchor.constraint(equalToConstant: title == "Merging" ? 132 : 120).isActive = true; return box
        }
        let mergeGroup = group("Merging", entries: [(.base, "Base file", base), (.theirs, "Their file", theirs), (.mine, "My file", mine)])
        let patchGroup = group("Apply unified diff", entries: [(.diff, "Diff file", diff), (.directory, "Directory", directory)])
        ok.target = self; ok.action = #selector(accept); ok.keyEquivalent = "\r"
        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancelClicked)); cancel.keyEquivalent = "\u{1b}"
        let help = NSButton(title: "Help", target: self, action: #selector(helpClicked))
        let buttons = NSStackView(views: [ok, cancel, help]); buttons.distribution = .equalSpacing; buttons.spacing = 16
        status.textColor = .systemRed; status.isSelectable = true; status.maximumNumberOfLines = 2
        status.setAccessibilityLabel("Open status"); status.heightAnchor.constraint(equalToConstant: 34).isActive = true
        let version = NSTextField(labelWithString: "TurtleGitMerge " + (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "Development"))
        version.textColor = .secondaryLabelColor
        let stack = NSStackView(views: [version, radios, mergeGroup, patchGroup, status, buttons])
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 12
        let host = NSView(); host.addSubview(stack); stack.translatesAutoresizingMaskIntoConstraints = false; window.contentView = host
        NSLayoutConstraint.activate([stack.leadingAnchor.constraint(equalTo: host.leadingAnchor, constant: 16), stack.trailingAnchor.constraint(equalTo: host.trailingAnchor, constant: -16), stack.topAnchor.constraint(equalTo: host.topAnchor, constant: 14), mergeGroup.widthAnchor.constraint(equalTo: stack.widthAnchor), patchGroup.widthAnchor.constraint(equalTo: stack.widthAnchor), buttons.widthAnchor.constraint(equalTo: stack.widthAnchor), status.widthAnchor.constraint(equalTo: stack.widthAnchor)])
        window.minSize = window.frame.size
        setMode(MergeOpenMode(rawValue: preferences.integer(forKey: "TurtleGitMerge.OpenRadio")) ?? .merging)
        DialogGeometry.attach(window, identifier: "TurtleGitMerge.Open", legacyName: "OpenDlg")
    }
    deinit {
        clipboardMonitor?.invalidate()
        if let ownerObserver { NotificationCenter.default.removeObserver(ownerObserver) }
    }
    func acceptPath(_ url: URL, slot: Slot) -> Bool {
        guard !retired, !busy, !accepting, field(slot).isEnabled, validPath(url, slot: slot) else { return false }
        let lease = makeLease(url)
        if requiresScopes && !lease.hasSecurityScope {
            field(slot).stringValue = url.path; browse(slot,authorize:url); return true
        }
        retainGrant(lease); field(slot).stringValue = url.path; status.stringValue = ""; return true
    }
    func completionCandidates(for text: String, directoryOnly: Bool = false) -> [String] {
        guard !retired, !busy, !accepting, !text.isEmpty, !text.contains("\0") else { return [] }
        let expanded = (text as NSString).expandingTildeInPath
        let folder = expanded.hasSuffix("/") ? URL(fileURLWithPath:expanded) : URL(fileURLWithPath:expanded).deletingLastPathComponent()
        guard !requiresScopes || grants.contains(where:{ $0.hasSecurityScope && $0.contains(folder) }) else { return [] }
        let prefix = expanded.hasSuffix("/") ? "" : (expanded as NSString).lastPathComponent
        guard let names = try? FileManager.default.contentsOfDirectory(atPath:folder.path) else { return [] }
        return names.filter { $0.hasPrefix(prefix) }.sorted { $0.localizedStandardCompare($1) == .orderedAscending }.prefix(100).compactMap { name in
            let url = folder.appendingPathComponent(name); var directory: ObjCBool = false
            guard FileManager.default.fileExists(atPath:url.path,isDirectory:&directory), !directoryOnly || directory.boolValue else { return nil }
            let full = url.path + (directory.boolValue ? "/" : "")
            if text.hasPrefix("~"), full.hasPrefix(NSHomeDirectory()+"/") { return "~" + full.dropFirst(NSHomeDirectory().count) }
            return full
        }
    }
    func control(_ control:NSControl,textView:NSTextView,doCommandBy selector:Selector)->Bool {
        guard !retired,!busy,!accepting,Slot.allCases.contains(where:{field($0) === control}) else{return false}
        wordCommands.policy=GitInputWordBreak(defaults:preferences)
        return wordCommands.handle(control,text:textView,selector:selector,combo:false,owner:self)
    }
    func control(_ control: NSControl, textView: NSTextView, completions words: [String], forPartialWordRange range: NSRange, indexOfSelectedItem index: UnsafeMutablePointer<Int>) -> [String] {
        guard !retired, !busy, !accepting, let slot = Slot.allCases.first(where:{ field($0) === control }), field(slot).isEnabled, range.location != NSNotFound, NSMaxRange(range) <= (textView.string as NSString).length else { return [] }
        let prefix = (textView.string as NSString).substring(to:NSMaxRange(range))
        index.pointee = -1
        return completionCandidates(for:prefix,directoryOnly:slot == .directory).compactMap {
            let value = $0 as NSString; return range.location <= value.length ? value.substring(from:range.location) : nil
        }
    }
    func controlTextDidChange(_ notification: Notification) {
        guard !retired, !busy, !accepting, let field = notification.object as? NSTextField, Slot.allCases.contains(where: { self.field($0) === field }), field.isEnabled else { return }
        let id = ObjectIdentifier(field), value = field.stringValue
        guard completionPrefixes[id] != value else { return }; completionPrefixes[id] = value
        DispatchQueue.main.async { [weak self, weak field] in
            guard let self, !self.retired, !self.busy, !self.accepting, let field, field.isEnabled, field.stringValue.utf8.elementsEqual(value.utf8), let editor = field.currentEditor() as? NSTextView else { return }
            editor.complete(nil)
        }
    }
    func pollClipboard() {
        guard !retired else { return }
        let count = pasteboard.changeCount
        let available = pasteboard.availableType(from:[PatchClipboard.unifiedDiff,PatchClipboard.legacyUnifiedDiff,.string]) != nil
        guard count != clipboardChangeCount || available != clipboardFormatAvailable else { return }
        clipboardChangeCount = count; clipboardFormatAvailable = available; updateGates()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    func setMode(_ mode: MergeOpenMode) {
        guard !retired, !busy, !accepting else { return }
        merging.state = mode == .merging ? .on : .off; apply.state = mode == .applyUnifiedDiff ? .on : .off
        updateGates()
    }
    func updateGates() {
        let enabled = !retired && !busy && !accepting, mergingMode = mode == .merging
        merging.isEnabled = enabled; apply.isEnabled = enabled
        for (slot, field) in [(.base, base), (.theirs, theirs), (.mine, mine), (.diff, diff), (.directory, directory)] as [(Slot, NSTextField)] {
            let active = enabled && (slot.rawValue < 3 ? mergingMode : !mergingMode) && (slot != .diff || clipboard.state != .on)
            field.isEnabled = active; browseButtons[slot]?.isEnabled = active
        }
        // Do not read clipboard contents while polling native controls.
        clipboard.isEnabled = enabled && !mergingMode && (clipboard.state == .on || pasteboard.availableType(from: [PatchClipboard.unifiedDiff, PatchClipboard.legacyUnifiedDiff, .string]) != nil)
        ok.isEnabled = enabled
    }
    private func field(_ slot: Slot) -> NSTextField { [base, theirs, mine, diff, directory][slot.rawValue] }
    private func validPath(_ url: URL, slot: Slot) -> Bool {
        guard url.isFileURL, !url.path.contains("\0"),
              let properties = try? url.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey]) else { return false }
        return slot == .directory ? properties.isDirectory == true : properties.isRegularFile == true
    }
    private func retainGrant(_ lease: RepositoryAccessLease) {
        grants.removeAll { $0.url.standardizedFileURL.path == lease.url.standardizedFileURL.path }
        grants.append(lease)
    }
    func browse(_ slot: Slot, authorize: URL? = nil) {
        guard !retired, !busy, !accepting, choiceID == nil, field(slot).isEnabled,
              let window, window.attachedSheet == nil else { return }
        let captured = form, identity = UUID()
        let existing = authorize ?? (field(slot).stringValue.isEmpty ? nil : URL(fileURLWithPath: (field(slot).stringValue as NSString).expandingTildeInPath))
        choiceID = identity; busy = true; Self.activeChoices += 1; pendingChoices += 1; updateGates()
        Task { [self] in
            defer {
                Self.activeChoices -= 1; pendingChoices -= 1
                if choiceID == identity { choiceID = nil; picker = nil; busy = false; updateGates() }
            }
            guard !retired, form == captured, self.window === window else { return }
            let chosen: URL?
            if let choosePath { chosen = await choosePath(slot, existing) }
            else {
                let panel = NSOpenPanel(); panel.canChooseDirectories = slot == .directory; panel.canChooseFiles = slot != .directory
                panel.allowsMultipleSelection = false; panel.treatsFilePackagesAsDirectories = false
                panel.title = slot == .directory ? "Choose patch target directory" : "Select file"
                panel.directoryURL = existing.map { slot == .directory ? $0 : $0.deletingLastPathComponent() }
                if slot == .diff {
                    panel.allowedContentTypes = [UTType(filenameExtension: "patch"), UTType(filenameExtension: "diff")].compactMap { $0 }
                    panel.allowsOtherFileTypes = true
                }
                if let authorize { panel.message = "Select “\(authorize.lastPathComponent)” to grant access." }
                picker = panel
                let response: NSApplication.ModalResponse = await withCheckedContinuation { continuation in
                    var answered = false
                    let reply: (NSApplication.ModalResponse) -> Void = { response in
                        guard !answered else { return }; answered = true; continuation.resume(returning: response)
                    }
                    if let presentPicker { presentPicker(panel, window, reply) }
                    else { panel.beginSheetModal(for: window, completionHandler: reply) }
                }
                chosen = response == .OK ? selectedPath(panel) : nil
            }
            guard !retired, choiceID == identity, form == captured, self.window === window else { return }
            guard let chosen else { window.makeFirstResponder(field(slot)); return }
            guard validPath(chosen, slot: slot) else {
                status.stringValue = slot == .directory ? "Select an existing directory." : "Select an existing regular file."
                return
            }
            let lease = makeLease(chosen)
            guard !requiresScopes || lease.hasSecurityScope else { status.stringValue = "File permission is required. Select this path with Browse."; return }
            guard authorize == nil || lease.contains(authorize!) else { status.stringValue = "Select the requested file or folder."; return }
            retainGrant(lease); field(slot).stringValue = chosen.path; status.stringValue = ""
            window.makeFirstResponder(field(slot))
        }
    }
    @objc func accept() {
        guard !retired, !busy, !accepting, window?.attachedSheet == nil else { return }
        let acceptedMode = mode
        do {
            let bytes = mode == .applyUnifiedDiff && clipboard.state == .on ? PatchClipboard.snapshot(from: pasteboard) : nil
            if mode == .applyUnifiedDiff && clipboard.state == .on && bytes == nil { status.stringValue = "The clipboard no longer contains a unified diff."; return }
            let request = try MergeOpenRequest.selection(mode: mode, base: base.stringValue, theirs: theirs.stringValue, mine: mine.stringValue, diff: diff.stringValue, directory: directory.stringValue, clipboard: bytes)
            let paths: [(Slot, URL)]
            switch request {
            case .compare(let baseURL, let mineURL, _):
                paths = Slot.allCases.prefix(3).compactMap { slot in
                    let value = field(slot).stringValue; guard !value.isEmpty else { return nil }
                    let url = URL(fileURLWithPath: (value as NSString).expandingTildeInPath).standardizedFileURL
                    return url == baseURL || url == mineURL ? (slot, url) : nil
                }
            case .merge(let baseURL, let theirsURL, let mineURL): paths = [(.base, baseURL), (.theirs, theirsURL), (.mine, mineURL)]
            case .patch(let file, let directory, _): paths = [file.map { (.diff, $0) }, directory.map { (.directory, $0) }].compactMap { $0 }
            }
            if requiresScopes, let missing = paths.first(where: { item in !grants.contains { $0.hasSecurityScope && $0.contains(item.1) } }) { browse(missing.0, authorize: missing.1); return }
            accepting = true; updateGates()
            defer { accepting = false; updateGates() }
            try onAccepted(request, grants)
            preferences.set(acceptedMode.rawValue, forKey: "TurtleGitMerge.OpenRadio")
            close()
        } catch { if !retired { status.stringValue = error.localizedDescription } }
    }
    func present(parent: NSWindow?) {
        guard !retired, window?.isVisible != true, window?.sheetParent == nil, parent?.attachedSheet == nil else { return }
        if let parent, let window {
            if let ownerObserver { NotificationCenter.default.removeObserver(ownerObserver) }
            ownerObserver = NotificationCenter.default.addObserver(forName:NSWindow.willCloseNotification,object:parent,queue:.main) { [weak self] _ in MainActor.assumeIsolated { self?.close() } }
            parent.beginSheet(window)
        } else { showWindow(nil) }
        if clipboardMonitor == nil {
            clipboardMonitor = Timer.scheduledTimer(withTimeInterval:0.5,repeats:true) { [weak self] _ in MainActor.assumeIsolated { self?.pollClipboard() } }
        }
        pollClipboard(); window?.makeFirstResponder(mode == .merging ? base : diff)
    }
    func windowWillClose(_ notification: Notification) {
        guard !retired else { return }; retired = true
        clipboardMonitor?.invalidate(); clipboardMonitor = nil
        if let ownerObserver { NotificationCenter.default.removeObserver(ownerObserver); self.ownerObserver = nil }
        choiceID = nil; busy = false; updateGates()
        if let picker { (picker.sheetParent ?? window)?.endSheet(picker, returnCode: .cancel); picker.orderOut(nil) }
        picker = nil
        if let window, let parent = window.sheetParent { parent.endSheet(window) }
        let finished = onClosed; onClosed = {}; onAccepted = { _, _ in }; finished()
    }
    @objc private func selectMerging() { setMode(.merging) }
    @objc private func selectApply() { setMode(.applyUnifiedDiff) }
    @objc private func clipboardChanged() { guard !retired, !busy, !accepting else { return }; updateGates() }
    @objc private func browseClicked(_ sender: NSButton) { if let slot = Slot(rawValue: sender.tag) { browse(slot) } }
    @objc private func cancelClicked() { close() }
    @objc private func helpClicked() { TurtleGitHelp.show(.compare) }
}
