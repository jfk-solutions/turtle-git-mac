// SPDX-License-Identifier: GPL-2.0-or-later
// Native shell ApplyPatch/TortoiseGitMerge /diff and /patchpath handoff.
import AppKit
import SwiftUI
import TurtleGitCore

@MainActor final class ReviewPatchWorkflow: NSWindowController, NSWindowDelegate, ObservableObject {
    static private(set) var activeLoads = 0
    @Published private(set) var loading = false
    @Published private(set) var status = "Choose a patch and a target folder to review its changes."
    @Published private(set) var error: String?
    enum TargetChoice { case suggested, original, cancel }
    private var clipboardBytes: Data?
    private var clipboardLoader: ((OperationCancellation) async throws -> Data)?
    private let clipboardTitle: String
    private var sourceTitle: String
    private let token = OperationCancellation()
    var chooseBetterTarget: ((URL, URL) async -> TargetChoice)?
    private var file: URL?
    private var target: URL?
    private let preferred: URL?
    private var grants: [RepositoryAccessLease]
    private let executable: URL
    private let preferences: UserDefaults
    @MainActor private final class Choice: NSObject {
        let panel: NSOpenPanel
        let continuation: CheckedContinuation<URL?, Never>
        let generation: Int
        var responded = false
        var releasing = false
        var result: URL?
        var bytes: Data?
        var observer: NSObjectProtocol?
        var button: NSButton?
        var action: (() -> Void)?
        init(_ panel: NSOpenPanel, _ continuation: CheckedContinuation<URL?, Never>, generation: Int) { self.panel = panel; self.continuation = continuation; self.generation = generation }
        @objc func clipboard() { action?() }
    }
    private var choice: Choice?
    private var picker: NSOpenPanel? { choice?.panel }
    var presentPicker: ((NSOpenPanel, NSWindow, @escaping (NSApplication.ModalResponse) -> Void) -> Void)?
    var selectedPickerURL: (NSOpenPanel) -> URL? = { $0.url }
    private let pasteboard: NSPasteboard
    private var generation = 0, retired = false, started = false
    var chooseFile: (() async -> URL?)?
    var chooseTarget: (() async -> URL?)?
    var presentation: ((WorkingTreePatchWindowController) -> Void)?
    var preparedPresentation: ((WorkingTreePatchWindowController) throws -> Void)?
    private var pendingReview: WorkingTreePatchWindowController?
    var onFinished: () -> Void = {}
    init(file: URL?, target: URL?, preferred: URL? = nil, grants: [RepositoryAccessLease] = [], executable: URL, preferences: UserDefaults = .standard, clipboardBytes: Data? = nil, title: String = "Clipboard patch", clipboardLoader: ((OperationCancellation) async throws -> Data)? = nil, pasteboard: NSPasteboard = .general) {
        self.clipboardBytes = clipboardBytes; self.clipboardTitle = title; self.sourceTitle = file?.lastPathComponent ?? title
        self.clipboardLoader = clipboardLoader; self.pasteboard = pasteboard
        self.file = file; self.target = target; self.preferred = preferred; self.grants = grants; self.executable = executable; self.preferences = preferences
        let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 560, height: 190), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Review/apply single patch – TurtleGitMerge"; window.isReleasedWhenClosed = false
        super.init(window: window); window.delegate = self; window.center()
        window.contentViewController = NSHostingController(rootView: ReviewPatchPreparation(workflow: self))
    }
    func start() {
        guard !started, !retired else { return }; started = true
        Task { await prepare() }
    }
    private func covered(_ url: URL) -> Bool { !GitRuntime.isAppStoreBuild || grants.contains { $0.hasSecurityScope && $0.contains(url) } }
    private func pick(file: Bool) async -> URL? {
        if file, let chooseFile { return await chooseFile() }
        if !file, let chooseTarget { return await chooseTarget() }
        guard !retired, let window, window.attachedSheet == nil else { return nil }
        let panel = NSOpenPanel(); panel.canChooseFiles = file; panel.canChooseDirectories = !file
        panel.title = file ? "Open patch file" : "Choose patch target folder"
        panel.prompt = file ? "Review Patch" : "Choose Folder"
        panel.directoryURL = target ?? self.file?.deletingLastPathComponent() ?? preferred
        panel.message = file ? "Choose the single patch to review." : "Choose the folder whose files this patch changes. A Git repository is optional."
        if file { panel.nameFieldStringValue = self.file?.lastPathComponent ?? "" }
        return await withCheckedContinuation { continuation in
            let pending = Choice(panel, continuation, generation: generation); choice = pending
            if file {
                let button = NSButton(title: "Use Clipboard Patch", target: pending, action: #selector(Choice.clipboard))
                button.bezelStyle = .rounded; button.image = MenuIcon.patch.image(); button.imagePosition = .imageLeading
                button.setAccessibilityIdentifier("PatchReview.UseClipboard"); pending.button = button
                pending.action = { [weak self, weak pending] in
                    guard let self, let pending, self.choice === pending, !pending.responded, !self.retired, pending.generation == self.generation else { return }
                    guard let bytes = PatchClipboard.snapshot(from: self.pasteboard) else { panel.message = "The clipboard does not contain a unified patch. Choose a file or copy a patch and try again."; return }
                    pending.bytes = bytes; self.respond(pending, response: .abort)
                }
                panel.accessoryView = NSStackView(views: [button]); panel.isAccessoryViewDisclosed = true
            }
            pending.observer = NotificationCenter.default.addObserver(forName: NSWindow.didEndSheetNotification, object: window, queue: .main) { [weak self, weak pending] _ in
                DispatchQueue.main.async { if let pending { self?.drain(pending) } }
            }
            let reply: (NSApplication.ModalResponse) -> Void = { [weak self] response in self?.respond(pending, response: response) }
            if let presentPicker { presentPicker(panel, window, reply) } else { panel.beginSheetModal(for: window, completionHandler: reply) }
        }
    }
    private func respond(_ pending: Choice, response: NSApplication.ModalResponse) {
        guard choice === pending, !pending.responded else { return }
        pending.responded = true; pending.result = !retired && response == .OK ? selectedPickerURL(pending.panel) : nil
        release(pending, response: response)
    }
    private func release(_ pending: Choice, response: NSApplication.ModalResponse) {
        if !pending.releasing {
            pending.releasing = true
            if let parent = pending.panel.sheetParent { parent.endSheet(pending.panel, returnCode: response) }; pending.panel.orderOut(nil)
        }
        DispatchQueue.main.async { [self] in drain(pending) }
    }
    private func drain(_ pending: Choice) {
        guard choice === pending, pending.responded, pending.panel.sheetParent == nil, window?.attachedSheet !== pending.panel else { return }
        choice = nil; pending.button?.target = nil; pending.button?.action = nil; pending.action = nil
        if let observer = pending.observer { NotificationCenter.default.removeObserver(observer) }
        let valid = !retired && generation == pending.generation
        if valid, let bytes = pending.bytes { clipboardBytes = bytes; file = nil; sourceTitle = clipboardTitle }
        pending.continuation.resume(returning: valid ? pending.result : nil)
    }
    private func cancelPicker() {
        if let choice { choice.responded = true; choice.result = nil; choice.bytes = nil; release(choice, response: .cancel) }
    }
    private func prepare() async {
        let current = generation
        guard !retired else { return }
        if let loader = clipboardLoader {
            clipboardLoader = nil; loading = true; status = "Opening clipboard patch…"; Self.activeLoads += 1
            do { clipboardBytes = try await loader(token) }
            catch { Self.activeLoads -= 1; loading = false; if !retired { fail(error) }; return }
            Self.activeLoads -= 1; loading = false
            guard !retired, generation == current else { return }
        }
        if clipboardBytes == nil && (file == nil || !covered(file!)) {
            let selected = await pick(file: true)
            guard !retired, generation == current else { return }
            if clipboardBytes == nil {
                guard let selected else { cancel(); return }
                if let original = file, original != selected { target = nil }
                file = selected; grants.append(RepositoryAccessLease(url: selected))
            }
        }
        if clipboardBytes == nil && (file == nil || !covered(file!)) { fail(RepositoryAccessFailure.securityScopeUnavailable); return }
        if target == nil || !covered(target!) {
            guard let choice = await pick(file: false), !retired, generation == current else { cancel(); return }
            target = choice; grants.append(RepositoryAccessLease(url: choice))
        }
        guard let target, covered(target), !retired else { fail(RepositoryAccessFailure.securityScopeUnavailable); return }
        loading = true; status = "Opening patch review…"; Self.activeLoads += 1
        let grants = grants, file = file, clipboardBytes = clipboardBytes, token = token
        defer { Self.activeLoads -= 1; loading = false }
        do {
            let bytes = try await Task.detached {
                try withExtendedLifetime(grants) {
                    guard !token.isCancelled else { throw OperationCancellationFailure.cancelled }
                    guard try target.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true else { throw FinderCommandFailure.selection }
                    if let clipboardBytes { return clipboardBytes }
                    guard let file, try file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else { throw FinderCommandFailure.selection }
                    return try Data(contentsOf: file, options: .mappedIfSafe)
                }
            }.value
            var selectedTarget = target
            let strip = PatchTargetMatching.initialStripCount(bytes)
            let candidate = GitRepository(root: target, executable: executable)
            let paths = try await candidate.patchTargetPaths(bytes, stripCount: strip, cancellation: token)
            let boundary = GitRuntime.isAppStoreBuild ? grants.filter { $0.hasSecurityScope && $0.contains(target) }.map(\.url).min { $0.path.count < $1.path.count } : nil
            let suggestion = await Task.detached { PatchTargetMatching.suggestion(start: target, paths: paths, boundary: boundary, cancellation: token) }.value
            guard !retired, generation == current else { return }
            if let suggestion {
                let choice = await betterTarget(original: target, suggested: suggestion)
                guard !retired, generation == current else { return }
                switch choice {
                case .suggested: selectedTarget = suggestion
                case .original: break
                case .cancel: cancel(); return
                }
            }
            guard covered(selectedTarget) else { throw RepositoryAccessFailure.securityScopeUnavailable }
            let repository = GitRepository(root: selectedTarget, executable: executable)
            // In a sandbox, discovery is fenced at the largest real folder grant;
            // a nested-folder-only grant must never probe unauthorized ancestors.
            let anchor = grants.filter { $0.contains(selectedTarget) && (!GitRuntime.isAppStoreBuild || $0.hasSecurityScope) }.map(\.url).min { $0.path.count < $1.path.count } ?? selectedTarget
            let environment = GitRuntime.isAppStoreBuild ? ["GIT_CEILING_DIRECTORIES": anchor.deletingLastPathComponent().path] : [:]
            let fact = try await repository.run(["rev-parse", "--is-inside-work-tree"], environmentOverrides: environment, successfulExitCodes: 0...128, cancellation: token)
            let isGit = fact.exitCode == 0 && fact.text.trimmingCharacters(in: .whitespacesAndNewlines) == "true"
            guard !retired, generation == current else { return }
            let access = grants.first { $0.contains(selectedTarget) && (!GitRuntime.isAppStoreBuild || $0.hasSecurityScope) }
            let fileAccess = file.flatMap { file in grants.first { $0.contains(file) && (!GitRuntime.isAppStoreBuild || $0.hasSecurityScope) } }
            let controller = WorkingTreePatchWindowController(repository: repository, access: access, fileAccess: fileAccess,
                bytes: bytes, title: clipboardBytes == nil ? (file?.lastPathComponent ?? sourceTitle) : sourceTitle, preferences: preferences, directoryMode: true, isGitWorkingTree: isGit, initialStripCount: strip, automaticallyRefresh: preparedPresentation == nil)
            if let preparedPresentation {
                pendingReview = controller
                await withCheckedContinuation { continuation in controller.model.refresh { continuation.resume() } }
                guard !retired, generation == current, !token.isCancelled else { controller.close(); pendingReview = nil; return }
                guard controller.model.review != nil else {
                    let message = controller.model.notice
                    controller.close(); pendingReview = nil
                    throw PreparedReviewFailure(message: message)
                }
                do { try preparedPresentation(controller); pendingReview = nil }
                catch { controller.close(); pendingReview = nil; throw error }
            } else {
                ReviewPatchWindows.retain(controller, grants: grants)
                if let presentation { presentation(controller) } else { controller.showWindow(nil); controller.window?.makeKeyAndOrderFront(nil) }
            }
            window?.close()
        } catch { if !retired, generation == current { fail(error) } }
    }
    private func betterTarget(original: URL, suggested: URL) async -> TargetChoice {
        if let chooseBetterTarget { return await chooseBetterTarget(original, suggested) }
        guard !retired, let window, window.attachedSheet == nil else { return .cancel }
        let alert = NSAlert(); alert.messageText = "A better patch target folder was found."
        alert.informativeText = "Suggested: " + suggested.path + "\n\nSelected: " + original.path
        alert.addButton(withTitle: "Use Suggested Folder"); alert.addButton(withTitle: "Keep Selected Folder"); alert.addButton(withTitle: "Cancel")
        let response = await withCheckedContinuation { continuation in alert.beginSheetModal(for: window) { continuation.resume(returning: $0) } }
        return response == .alertFirstButtonReturn ? .suggested : response == .alertSecondButtonReturn ? .original : .cancel
    }
    private struct PreparedReviewFailure: LocalizedError { let message: String; var errorDescription: String? { message.isEmpty ? "Could not prepare the patch review." : message } }
    private func fail(_ failure: Error) { error = failure.localizedDescription; status = "Could not open this patch." }
    func cancel() {
        guard !retired else { return }
        generation += 1; token.cancel()
        cancelPicker()
        window?.close()
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool { if picker != nil { cancel(); return false }; return true }
    func windowWillClose(_ notification: Notification) {
        guard !retired else { return }; retired = true; generation += 1; token.cancel(); pendingReview?.close(); pendingReview = nil
        cancelPicker()
        if let sheet = window?.attachedSheet, sheet !== picker { window?.endSheet(sheet, returnCode: .abort); sheet.close() }
        if let window, let parent = window.sheetParent { parent.endSheet(window) }
        onFinished()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
}

@MainActor private enum ReviewPatchWindows {
    private static var windows: [UUID: (WorkingTreePatchWindowController, [RepositoryAccessLease])] = [:]
    static func retain(_ controller: WorkingTreePatchWindowController, grants: [RepositoryAccessLease]) {
        let id = UUID(); windows[id] = (controller, grants); controller.onClosed = { windows.removeValue(forKey: id) }
    }
}

private struct ReviewPatchPreparation: View {
    @ObservedObject var workflow: ReviewPatchWorkflow
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Review/apply single patch").font(.headline)
            Text(workflow.error ?? workflow.status).textSelection(.enabled).foregroundStyle(workflow.error == nil ? Color.primary : Color.red)
            Spacer()
            HStack { if workflow.loading { ProgressView().controlSize(.small) }; Spacer(); Button(workflow.error == nil ? "Cancel" : "Close") { workflow.cancel() }.keyboardShortcut(.cancelAction) }
        }.padding(16)
    }
}
