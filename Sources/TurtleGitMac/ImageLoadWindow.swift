import AppKit
import TurtleGitCore
import UniformTypeIdentifiers

@MainActor final class ImageLoadWindowController: NSWindowController, NSWindowDelegate {
    let left = NSTextField(), right = NSTextField()
    private let status = NSTextField(wrappingLabelWithString: "")
    private let ok = NSButton(title: "OK", target: nil, action: nil)
    private var permissions: [RepositoryAccessLease]
    private(set) var retired = false
    private var panel: NSOpenPanel?
    private weak var parent: NSWindow?
    var requiresScopes = GitRuntime.isAppStoreBuild
    var makeOpenPanel: () -> NSOpenPanel = { NSOpenPanel() }
    var onAccepted: (ImageFileComparison, [RepositoryAccessLease]) throws -> Void = { _, _ in }
    var onClosed: () -> Void = {}
    init(leftPath: String, permissions: [RepositoryAccessLease]) {
        self.permissions = permissions
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 620, height: 180), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Load Images"; window.isReleasedWhenClosed = false
        super.init(window: window); window.delegate = self
        window.contentView = ImageLoadBackgroundView(frame: NSRect(x: 0, y: 0, width: 620, height: 180))
        for field in [left, right] {
            field.maximumNumberOfLines = 1; field.lineBreakMode = .byClipping
            (field.cell as? NSTextFieldCell)?.usesSingleLineMode = true
            (field.cell as? NSTextFieldCell)?.isScrollable = true
        }
        left.stringValue = leftPath
        left.setAccessibilityLabel("Left image"); right.setAccessibilityLabel("Right image")
        let leftBrowse = NSButton(title: "…", target: self, action: #selector(browseLeft))
        let rightBrowse = NSButton(title: "…", target: self, action: #selector(browseRight))
        leftBrowse.setAccessibilityLabel("Browse left image"); rightBrowse.setAccessibilityLabel("Browse right image")
        leftBrowse.bezelStyle = .rounded; rightBrowse.bezelStyle = .rounded
        let grid = NSGridView(views: [[NSTextField(labelWithString: "Left image"), left, leftBrowse], [NSTextField(labelWithString: "Right image"), right, rightBrowse]])
        grid.rowSpacing = 12; grid.columnSpacing = 10; grid.column(at: 0).width = 85; grid.column(at: 2).width = 32
        left.widthAnchor.constraint(greaterThanOrEqualToConstant: 400).isActive = true
        let cancelButton = NSButton(title: "Cancel", target: self, action: #selector(cancel))
        cancelButton.bezelStyle = .rounded; ok.bezelStyle = .rounded
        cancelButton.keyEquivalent = "\u{1b}"; ok.target = self; ok.action = #selector(accept); ok.keyEquivalent = "\r"
        let buttons = NSStackView(views: [NSView(), ok, cancelButton]); buttons.orientation = .horizontal; buttons.spacing = 8
        status.maximumNumberOfLines = 2; status.textColor = .systemRed; status.setAccessibilityLabel("Load images error")
        let stack = NSStackView(views: [grid, status, buttons]); stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 12
        let content = window.contentView!; content.addSubview(stack); stack.translatesAutoresizingMaskIntoConstraints = false
        window.center()
        NSLayoutConstraint.activate([stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20), stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20), stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 18), buttons.widthAnchor.constraint(equalTo: stack.widthAnchor), status.widthAnchor.constraint(equalTo: stack.widthAnchor)])
    }
    func present(parent: NSWindow?) {
        self.parent = parent
        if let parent { parent.beginSheet(window!) } else { showWindow(nil) }
        window?.makeFirstResponder(left)
    }
    @objc private func browseLeft() { browse(left) }
    @objc private func browseRight() { browse(right) }
    private func browse(_ field: NSTextField, authorize: URL? = nil) {
        guard !retired, panel == nil, let window else { return }
        let picker = makeOpenPanel(); picker.canChooseFiles = true; picker.canChooseDirectories = false; picker.allowsMultipleSelection = false
        picker.allowedContentTypes = [.image]; picker.allowsOtherFileTypes = true
        picker.title = "Open image file…"
        if let authorize { picker.directoryURL = authorize.deletingLastPathComponent(); picker.message = "Select “" + authorize.lastPathComponent + "” to allow this image to be read." }
        else if !field.stringValue.isEmpty { picker.directoryURL = URL(fileURLWithPath: field.stringValue).deletingLastPathComponent() }
        panel = picker; ok.isEnabled = false
        picker.beginSheetModal(for: window) { [weak self, weak field] response in
            guard let self, !self.retired else { return }
            self.panel = nil; self.ok.isEnabled = true
            guard response == .OK, let url = picker.url, let field else { return }
            let lease = RepositoryAccessLease(url: url)
            guard !self.requiresScopes || lease.hasSecurityScope else { self.status.stringValue = ImageFileComparisonFailure.filePermissionRequired.localizedDescription; return }
            if let authorize, !lease.contains(authorize) { self.status.stringValue = "Select the requested image file."; return }
            self.permissions.append(lease); field.stringValue = url.path; self.status.stringValue = ""
        }
    }
    @objc func accept() {
        guard !retired, panel == nil else { return }
        do {
            func url(_ field: NSTextField) -> URL? { field.stringValue.isEmpty ? nil : URL(fileURLWithPath: (field.stringValue as NSString).expandingTildeInPath) }
            let comparison = try ImageFileComparison(base: url(left), destination: url(right))
            for (field, file) in [(left, comparison.base), (right, comparison.destination)] {
                if let file, requiresScopes, !permissions.contains(where: { $0.hasSecurityScope && $0.contains(file) }) { browse(field, authorize: file); return }
            }
            // Authorize before reading; reject unreadable files without replacing the viewer.
            _ = try comparison.read()
            try onAccepted(comparison, permissions); finish()
        } catch { status.stringValue = error.localizedDescription }
    }
    @objc func cancel() { guard panel == nil else { return }; finish() }
    func retire() { finish() }
    private func finish(closeWindow: Bool = true) {
        guard !retired else { return }; retired = true
        if let panel, let window { window.endSheet(panel, returnCode: .cancel); panel.orderOut(nil) }; panel = nil
        if let parent, parent.attachedSheet === window { parent.endSheet(window!) }
        window?.orderOut(nil); if closeWindow { window?.close() }; onClosed()
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool { if panel != nil { return false }; cancel(); return false }
    func windowWillClose(_ notification: Notification) { if !retired { finish(closeWindow: false) } }
    required init?(coder: NSCoder) { fatalError() }
}

private final class ImageLoadBackgroundView: NSView {
    override var isOpaque: Bool { true }
    override func draw(_ dirtyRect: NSRect) { NSColor.windowBackgroundColor.setFill(); dirtyRect.fill() }
}
