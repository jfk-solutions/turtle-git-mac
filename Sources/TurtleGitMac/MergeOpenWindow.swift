import AppKit
import TurtleGitCore

/// Native IDD_OPENDLG: preserves both groups while radio controls their gates.
@MainActor final class MergeOpenWindowController: NSWindowController, NSWindowDelegate {
    enum Slot: Int, CaseIterable { case base, theirs, mine, diff, directory }
    let base = NSTextField(), theirs = NSTextField(), mine = NSTextField(), diff = NSTextField(), directory = NSTextField()
    let merging = NSButton(radioButtonWithTitle: "Merging", target: nil, action: nil)
    let apply = NSButton(radioButtonWithTitle: "Apply unified diff", target: nil, action: nil)
    let clipboard = NSButton(checkboxWithTitle: "Use Unified Diff from clipboard", target: nil, action: nil)
    let status = NSTextField(labelWithString: "")
    let ok = NSButton(title: "OK", target: nil, action: nil)
    private var browseButtons: [Slot: NSButton] = [:]
    private var grants: [RepositoryAccessLease]
    private let preferences: UserDefaults
    private let pasteboard: NSPasteboard
    private var picker: NSOpenPanel?
    private var retired = false
    private(set) var busy = false
    var requiresScopes = GitRuntime.isAppStoreBuild
    var choosePath: ((Slot, URL?) async -> URL?)?
    var onAccepted: (MergeOpenRequest, [RepositoryAccessLease]) throws -> Void = { _, _ in }
    var onClosed: () -> Void = {}
    var mode: MergeOpenMode { apply.state == .on ? .applyUnifiedDiff : .merging }
    init(preferences: UserDefaults = .standard, pasteboard: NSPasteboard = .general, permissions: [RepositoryAccessLease] = []) {
        self.preferences = preferences; self.pasteboard = pasteboard; grants = permissions
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 660, height: 520), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "TurtleGitMerge"; window.isReleasedWhenClosed = false
        super.init(window: window); window.delegate = self; window.center()
        merging.target = self; merging.action = #selector(selectMerging); apply.target = self; apply.action = #selector(selectApply)
        clipboard.target = self; clipboard.action = #selector(clipboardChanged)
        let radios = NSStackView(views: [merging, apply]); radios.spacing = 24
        func group(_ title: String, entries: [(Slot, String, NSTextField)]) -> NSBox {
            let box = NSBox(); box.title = title
            var rows: [[NSView]] = []
            for (slot, label, field) in entries {
                field.setAccessibilityLabel(label); field.maximumNumberOfLines = 1
                (field.cell as? NSTextFieldCell)?.usesSingleLineMode = true; (field.cell as? NSTextFieldCell)?.isScrollable = true
                field.widthAnchor.constraint(equalToConstant: 370).isActive = true
                let browse = NSButton(title: "Browse…", target: self, action: #selector(browseClicked)); browse.tag = slot.rawValue
                browse.setAccessibilityLabel("Browse " + label); browseButtons[slot] = browse
                rows.append([NSTextField(labelWithString: label + ":"), field, browse])
            }
            let grid = NSGridView(views: rows); grid.rowSpacing = 10; grid.columnSpacing = 12
            let content = NSStackView(views: title == "Apply unified diff" ? [clipboard, grid] : [grid])
            content.orientation = .vertical; content.alignment = .leading; content.spacing = 10
            box.contentView = content; box.heightAnchor.constraint(equalToConstant: 126).isActive = true; return box
        }
        let mergeGroup = group("Merging", entries: [(.base, "Base file", base), (.theirs, "Their file", theirs), (.mine, "My file", mine)])
        let patchGroup = group("Apply unified diff", entries: [(.diff, "Diff file", diff), (.directory, "Directory", directory)])
        ok.target = self; ok.action = #selector(accept); ok.keyEquivalent = "\r"
        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancelClicked)); cancel.keyEquivalent = "\u{1b}"
        let help = NSButton(title: "Help", target: self, action: #selector(helpClicked))
        let buttons = NSStackView(views: [ok, NSView(), cancel, NSView(), help]); buttons.distribution = .fill; buttons.spacing = 16
        status.textColor = .systemRed; status.isSelectable = true; status.maximumNumberOfLines = 2
        let version = NSTextField(labelWithString: "TurtleGitMerge " + (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "Development"))
        version.textColor = .secondaryLabelColor
        let stack = NSStackView(views: [version, radios, mergeGroup, patchGroup, status, buttons])
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 12
        let host = NSView(); host.addSubview(stack); stack.translatesAutoresizingMaskIntoConstraints = false; window.contentView = host
        NSLayoutConstraint.activate([stack.leadingAnchor.constraint(equalTo: host.leadingAnchor, constant: 16), stack.trailingAnchor.constraint(equalTo: host.trailingAnchor, constant: -16), stack.topAnchor.constraint(equalTo: host.topAnchor, constant: 14), mergeGroup.widthAnchor.constraint(equalTo: stack.widthAnchor), patchGroup.widthAnchor.constraint(equalTo: stack.widthAnchor), buttons.widthAnchor.constraint(equalTo: stack.widthAnchor), status.widthAnchor.constraint(equalTo: stack.widthAnchor)])
        setMode(MergeOpenMode(rawValue: preferences.integer(forKey: "TurtleGitMerge.OpenRadio")) ?? .merging)
        DialogGeometry.attach(window, identifier: "TurtleGitMerge.Open", legacyName: "OpenDlg")
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    func setMode(_ mode: MergeOpenMode) {
        guard !retired, !busy else { return }
        merging.state = mode == .merging ? .on : .off; apply.state = mode == .applyUnifiedDiff ? .on : .off
        updateGates()
    }
    func updateGates() {
        let enabled = !retired && !busy, mergingMode = mode == .merging
        merging.isEnabled = enabled; apply.isEnabled = enabled
        for (slot, field) in [(.base, base), (.theirs, theirs), (.mine, mine), (.diff, diff), (.directory, directory)] as [(Slot, NSTextField)] {
            let active = enabled && (slot.rawValue < 3 ? mergingMode : !mergingMode) && (slot != .diff || clipboard.state != .on)
            field.isEnabled = active; browseButtons[slot]?.isEnabled = active
        }
        // Do not read clipboard contents while polling native controls.
        clipboard.isEnabled = enabled && !mergingMode && pasteboard.availableType(from: [PatchClipboard.unifiedDiff, PatchClipboard.legacyUnifiedDiff, .string]) != nil
        ok.isEnabled = enabled
    }
    private func field(_ slot: Slot) -> NSTextField { [base, theirs, mine, diff, directory][slot.rawValue] }
    func browse(_ slot: Slot, authorize: URL? = nil) {
        guard !retired, !busy, let window else { return }
        busy = true; updateGates()
        Task {
            let existing = authorize ?? (field(slot).stringValue.isEmpty ? nil : URL(fileURLWithPath: (field(slot).stringValue as NSString).expandingTildeInPath))
            let chosen: URL?
            if let choosePath { chosen = await choosePath(slot, existing) }
            else {
                let panel = NSOpenPanel(); panel.canChooseDirectories = slot == .directory; panel.canChooseFiles = slot != .directory
                panel.allowsMultipleSelection = false; panel.title = slot == .directory ? "Choose patch target directory" : "Select file"
                panel.directoryURL = existing.map { slot == .directory ? $0 : $0.deletingLastPathComponent() }
                if let authorize { panel.message = "Select “\(authorize.lastPathComponent)” to grant access." }
                picker = panel
                let response = await withCheckedContinuation { continuation in panel.beginSheetModal(for: window) { continuation.resume(returning: $0) } }
                chosen = response == .OK ? panel.url : nil
            }
            guard !retired else { return }; picker = nil; busy = false
            defer { updateGates() }
            guard let chosen else { return }
            let lease = RepositoryAccessLease(url: chosen)
            guard !requiresScopes || lease.hasSecurityScope else { status.stringValue = "File permission is required. Select this path with Browse."; return }
            guard authorize == nil || lease.contains(authorize!) else { status.stringValue = "Select the requested file or folder."; return }
            grants.append(lease); field(slot).stringValue = chosen.path; status.stringValue = ""
        }
    }
    @objc func accept() {
        guard !retired, !busy else { return }
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
            try onAccepted(request, grants)
            preferences.set(mode.rawValue, forKey: "TurtleGitMerge.OpenRadio")
            close()
        } catch { status.stringValue = error.localizedDescription }
    }
    func present(parent: NSWindow?) { if let parent, let window { parent.beginSheet(window) } else { showWindow(nil) }; window?.makeFirstResponder(mode == .merging ? base : diff) }
    func windowWillClose(_ notification: Notification) {
        guard !retired else { return }; retired = true
        picker?.cancel(nil); picker = nil
        if let window, let parent = window.sheetParent { parent.endSheet(window) }
        onClosed()
    }
    @objc private func selectMerging() { setMode(.merging) }
    @objc private func selectApply() { setMode(.applyUnifiedDiff) }
    @objc private func clipboardChanged() { updateGates() }
    @objc private func browseClicked(_ sender: NSButton) { if let slot = Slot(rawValue: sender.tag) { browse(slot) } }
    @objc private func cancelClicked() { close() }
    @objc private func helpClicked() { NSWorkspace.shared.open(URL(string: "https://tortoisegit.org/docs/tortoisegitmerge/tmerge-dug-open.html")!) }
}
