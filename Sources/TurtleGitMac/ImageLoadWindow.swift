import AppKit
import Darwin
import TurtleGitCore
import UniformTypeIdentifiers

/// App-owned immutable copy of an already accepted repository object. It never
/// resolves a relative historical path against the current working directory.
final class ImageLoadSeed: @unchecked Sendable {
    let url:URL
    let original:ComparisonFileContent
    private let directory:URL,identity:stat
    private init(url:URL,directory:URL,original:ComparisonFileContent,identity:stat) {self.url=url;self.directory=directory;self.original=original;self.identity=identity}
    static func capture(_ content:ComparisonFileContent,cancellation:OperationCancellation)throws->ImageLoadSeed {
        try cancellation.check()
        let directory=FileManager.default.temporaryDirectory.resolvingSymlinksInPath().standardizedFileURL.appendingPathComponent("TurtleGitImageSeed-"+UUID().uuidString,isDirectory:true)
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:false,attributes:[.posixPermissions:0o700])
        do {
            let suffix=(content.path as NSString).pathExtension
            let safeSuffix = !suffix.isEmpty && suffix.utf8.count<=16 && suffix.utf8.allSatisfy{(48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0)}
            let name="image-"+UUID().uuidString+(safeSuffix ? "."+suffix:"")
            let url=directory.appendingPathComponent(name)
            try content.bytes.write(to:url,options:.atomic)
            try FileManager.default.setAttributes([.posixPermissions:0o400],ofItemAtPath:url.path)
            var identity=stat();guard lstat(url.path,&identity)==0 else {throw CocoaError(.fileReadUnknown)}
            try cancellation.check();return ImageLoadSeed(url:url,directory:directory,original:content,identity:identity)
        } catch {try? FileManager.default.removeItem(at:directory);throw error}
    }
    func contains(_ candidate:URL)->Bool {candidate.isFileURL && candidate.standardizedFileURL.path==url.path}
    /// Output admission also blocks existing hard-link, case and symlink aliases.
    /// Input authority remains the exact private URL, not these wider aliases.
    func protects(_ candidate:URL)->Bool {
        if contains(candidate) {return true}
        guard candidate.isFileURL else{return false};var value=stat()
        return stat(candidate.path,&value)==0 && value.st_dev==identity.st_dev && value.st_ino==identity.st_ino
    }
    func validate(_ document:FileComparisonDocument)throws {
        for content in [document.base,document.destination] where content.path==url.path {
            var current=stat()
            guard lstat(url.path,&current)==0,current.st_mode & S_IFMT == S_IFREG,
                  current.st_dev==identity.st_dev,current.st_ino==identity.st_ino,
                  url.resolvingSymlinksInPath().path==url.path,content.bytes==original.bytes else {throw FileComparisonEditFailure.changed}
        }
    }
    deinit {try? FileManager.default.removeItem(at:directory)}
}
struct ImageLoadReceipt:Sendable {
    let comparison:ImageFileComparison,document:FileComparisonDocument,seeds:[ImageLoadSeed]
}

@MainActor final class ImageLoadWindowController: NSWindowController, NSWindowDelegate {
    private(set) static var activeReleases=0
    static var imageContentTypes:[UTType] {[.image]+["wmf","emf"].compactMap {UTType(filenameExtension:$0,conformingTo:.data)}}
    private var releaseObserver:NSObjectProtocol?
    private var releaseOwner:NSWindow?
    private var finished=false
    private(set) var reading=false
    private var readCancellation:OperationCancellation?
    private var readTask:Task<Void,Never>?
    private var seeds=[ImageLoadSeed]()
    private var browseButtons=[NSButton]()
    private let spinner=NSProgressIndicator()
    var createSeed:(ComparisonFileContent,OperationCancellation) async throws -> ImageLoadSeed = {content,token in
        try await Task.detached {try ImageLoadSeed.capture(content,cancellation:token)}.value
    }
    var readInputs:(ImageFileComparison,OperationCancellation) async throws -> FileComparisonDocument = {comparison,token in
        try await Task.detached {try token.check();let value=try comparison.read();try token.check();return value}.value
    }
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
    var onAcceptedReceipt:((ImageLoadReceipt,[RepositoryAccessLease])throws->Void)?
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
        browseButtons=[leftBrowse,rightBrowse]
        leftBrowse.bezelStyle = .rounded; rightBrowse.bezelStyle = .rounded
        let grid = NSGridView(views: [[NSTextField(labelWithString: "Left image"), left, leftBrowse], [NSTextField(labelWithString: "Right image"), right, rightBrowse]])
        grid.rowSpacing = 12; grid.columnSpacing = 10; grid.column(at: 0).width = 85; grid.column(at: 2).width = 32
        left.widthAnchor.constraint(greaterThanOrEqualToConstant: 400).isActive = true
        let cancelButton = NSButton(title: "Cancel", target: self, action: #selector(cancel))
        cancelButton.bezelStyle = .rounded; ok.bezelStyle = .rounded
        cancelButton.keyEquivalent = "\u{1b}"; ok.target = self; ok.action = #selector(accept); ok.keyEquivalent = "\r"
        let buttons = NSStackView(views: [NSView(), ok, cancelButton]); buttons.orientation = .horizontal; buttons.spacing = 8
        status.maximumNumberOfLines = 2; status.textColor = .systemRed; status.setAccessibilityLabel("Load images error")
        spinner.style = .spinning;spinner.controlSize = .small;spinner.isDisplayedWhenStopped=false
        let feedback=NSStackView(views:[spinner,status]);feedback.orientation = .horizontal;feedback.spacing=6
        spinner.widthAnchor.constraint(equalToConstant:16).isActive=true
        feedback.heightAnchor.constraint(equalToConstant:32).isActive=true
        let stack = NSStackView(views: [grid, feedback, buttons]); stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 12
        let content = window.contentView!; content.addSubview(stack); stack.translatesAutoresizingMaskIntoConstraints = false
        window.center()
        NSLayoutConstraint.activate([stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20), stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20), stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 18), buttons.widthAnchor.constraint(equalTo: stack.widthAnchor), feedback.widthAnchor.constraint(equalTo: stack.widthAnchor)])
    }
    func present(parent: NSWindow?) {
        self.parent = parent
        if let parent { window?.alphaValue=parent.alphaValue;window?.appearance=parent.appearance;parent.beginSheet(window!) } else { showWindow(nil) }
        window?.makeFirstResponder(left)
    }
    @objc private func browseLeft() { browse(left) }
    @objc private func browseRight() { browse(right) }
    private func browse(_ field: NSTextField, authorize: URL? = nil) {
        guard !retired, !reading, panel == nil, let window else { return }
        let picker = makeOpenPanel(); picker.canChooseFiles = true; picker.canChooseDirectories = false; picker.allowsMultipleSelection = false
        picker.allowedContentTypes = Self.imageContentTypes; picker.allowsOtherFileTypes = true
        picker.alphaValue=window.alphaValue;picker.appearance=window.appearance
        picker.title = "Open image file…"
        if let authorize { picker.directoryURL = authorize.deletingLastPathComponent(); picker.message = "Select “" + authorize.lastPathComponent + "” to allow this image to be read." }
        else if !field.stringValue.isEmpty { picker.directoryURL = URL(fileURLWithPath: UserAccountPaths.expandingTilde(field.stringValue)).deletingLastPathComponent() }
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
    /// Historical prefill is prepared off the UI actor, under the same owned
    /// cancellation/drain boundary as validation. The source identity stays in
    /// the receipt even though the chooser displays a real local filename.
    func retainSeeds(_ values:[ImageLoadSeed]) {guard !retired,!reading else{return};seeds=values}
    func prepareSeed(_ content:ComparisonFileContent) {
        guard !retired,!reading,panel==nil else{return}
        left.stringValue=""
        let token=beginRead(),capture=createSeed
        readTask=Task { [self] in
            defer {endRead(token)}
            do {
                let seed=try await capture(content,token);try token.check()
                guard !retired,readCancellation === token else{return}
                seeds=[seed];left.stringValue=seed.url.path
                left.toolTip=(content.path.contains("\0") ? RepositoryBrowserGitPath.display(key:content.path):content.path)+" — "+content.revision.label
                status.stringValue=""
            } catch {if !retired,!token.isCancelled {showError(error)}}
        }
    }
    private func showError(_ error:Error) {status.stringValue=error.localizedDescription;status.toolTip=error.localizedDescription;status.textColor = .systemRed}
    private func beginRead()->OperationCancellation {
        let token=OperationCancellation();readCancellation=token;reading=true;Self.activeReleases += 1
        left.isEnabled=false;right.isEnabled=false;browseButtons.forEach{$0.isEnabled=false};ok.isEnabled=false
        status.stringValue="Reading images…";status.toolTip=nil;status.textColor = .secondaryLabelColor;spinner.startAnimation(nil);return token
    }
    private func endRead(_ token:OperationCancellation) {
        Self.activeReleases -= 1
        guard readCancellation === token else{return}
        reading=false;readCancellation=nil;readTask=nil
        if !retired {
            left.isEnabled=true;right.isEnabled=true;browseButtons.forEach{$0.isEnabled=true};ok.isEnabled=panel==nil
            spinner.stopAnimation(nil)
        }
        drainRelease()
    }
    @objc func accept() {
        guard !retired,!reading,panel==nil else{return}
        do {
            func url(_ field:NSTextField)->URL? {field.stringValue.isEmpty ? nil:URL(fileURLWithPath:UserAccountPaths.expandingTilde(field.stringValue))}
            let comparison=try ImageFileComparison(base:url(left),destination:url(right))
            for (field,file) in [(left,comparison.base),(right,comparison.destination)] {
                if let file,requiresScopes,!seeds.contains(where:{$0.contains(file)}),!permissions.contains(where:{$0.permits(file)}) {browse(field,authorize:file);return}
            }
            let selected=[comparison.base,comparison.destination].compactMap{$0}
            let retainedSeeds=seeds.filter{seed in selected.contains{seed.contains($0)}}
            let heldPermissions=permissions,read=readInputs,token=beginRead()
            readTask=Task { [self] in
                defer {endRead(token);withExtendedLifetime(heldPermissions) {}}
                do {
                    let document=try await read(comparison,token)
                    guard document.base.path==(comparison.base?.path ?? ""),document.destination.path==(comparison.destination?.path ?? "") else {throw FileComparisonEditFailure.changed}
                    try await Task.detached {try token.check();for seed in retainedSeeds {try seed.validate(document)};try token.check()}.value
                    guard !retired,readCancellation === token,!token.isCancelled else{return}
                    let receipt=ImageLoadReceipt(comparison:comparison,document:document,seeds:retainedSeeds)
                    if let onAcceptedReceipt {try onAcceptedReceipt(receipt,heldPermissions)}
                    else {try onAccepted(comparison,heldPermissions)}
                    status.stringValue="";finish(cancelRead:false)
                } catch {if !retired,!token.isCancelled {showError(error)}}
            }
        } catch {showError(error)}
    }
    @objc func cancel() {guard panel==nil else{return};finish()}
    func retire() {finish()}
    private func finish(closeWindow: Bool = true,cancelRead:Bool=true) {
        guard !retired else { return }; retired = true
        if cancelRead {readCancellation?.cancel();readTask?.cancel()}
        if let panel, let window { window.endSheet(panel, returnCode: .cancel); panel.orderOut(nil) }; panel = nil
        releaseOwner=window?.sheetParent ?? parent
        Self.activeReleases += 1
        releaseObserver=NotificationCenter.default.addObserver(forName:NSWindow.didEndSheetNotification,object:nil,queue:.main) { [self] _ in DispatchQueue.main.async {self.drainRelease()} }
        if let parent=releaseOwner,let window,parent.attachedSheet === window {parent.endSheet(window)}
        window?.orderOut(nil);if closeWindow {window?.close()}
        drainRelease();DispatchQueue.main.async { [self] in drainRelease() }
    }
    private func drainRelease() {
        guard retired,!finished,!reading,window?.attachedSheet == nil,window?.sheetParent == nil,releaseOwner?.attachedSheet !== window else{return}
        finished=true;Self.activeReleases -= 1
        if let releaseObserver {NotificationCenter.default.removeObserver(releaseObserver);self.releaseObserver=nil}
        releaseOwner=nil;seeds=[];permissions=[];let done=onClosed;onClosed={};done()
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool { if panel != nil { return false }; cancel(); return false }
    func windowWillClose(_ notification: Notification) { if !retired { finish(closeWindow: false) } }
    required init?(coder: NSCoder) { fatalError() }
}

private final class ImageLoadBackgroundView: NSView {
    override var isOpaque: Bool { true }
    override func draw(_ dirtyRect: NSRect) { NSColor.windowBackgroundColor.setFill(); dirtyRect.fill() }
}
