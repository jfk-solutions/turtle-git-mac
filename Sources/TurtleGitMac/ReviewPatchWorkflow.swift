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
    private var file: URL?
    private var target: URL?
    private let preferred: URL?
    private var grants: [RepositoryAccessLease]
    private let executable: URL
    private let preferences: UserDefaults
    private var picker: NSOpenPanel?
    private var generation = 0, retired = false, started = false
    var chooseFile: (() async -> URL?)?
    var chooseTarget: (() async -> URL?)?
    var presentation: ((WorkingTreePatchWindowController) -> Void)?
    var onFinished: () -> Void = {}
    init(file: URL?, target: URL?, preferred: URL? = nil, grants: [RepositoryAccessLease] = [], executable: URL, preferences: UserDefaults = .standard) {
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
        picker = panel
        let response = await withCheckedContinuation { continuation in panel.beginSheetModal(for: window) { continuation.resume(returning: $0) } }
        picker = nil
        guard !retired, response == .OK else { return nil }
        return panel.url
    }
    private func prepare() async {
        let current = generation
        guard !retired else { return }
        if file == nil || !covered(file!) {
            guard let choice = await pick(file: true), !retired, generation == current else { cancel(); return }
            if let original = file, original != choice { target = nil }
            file = choice; grants.append(RepositoryAccessLease(url: choice))
        }
        guard let file, covered(file) else { fail(RepositoryAccessFailure.securityScopeUnavailable); return }
        if target == nil || !covered(target!) {
            guard let choice = await pick(file: false), !retired, generation == current else { cancel(); return }
            target = choice; grants.append(RepositoryAccessLease(url: choice))
        }
        guard let target, covered(target), !retired else { fail(RepositoryAccessFailure.securityScopeUnavailable); return }
        loading = true; status = "Opening patch review…"; Self.activeLoads += 1
        let grants = grants
        defer { Self.activeLoads -= 1; loading = false }
        do {
            let bytes = try await Task.detached {
                try withExtendedLifetime(grants) {
                    guard try file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true,
                          try target.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true else { throw FinderCommandFailure.selection }
                    return try Data(contentsOf: file, options: .mappedIfSafe)
                }
            }.value
            let repository = GitRepository(root: target, executable: executable)
            // In a sandbox, discovery is fenced at the largest real folder grant;
            // a nested-folder-only grant must never probe unauthorized ancestors.
            let anchor = grants.filter { $0.contains(target) && (!GitRuntime.isAppStoreBuild || $0.hasSecurityScope) }.map(\.url).min { $0.path.count < $1.path.count } ?? target
            let environment = GitRuntime.isAppStoreBuild ? ["GIT_CEILING_DIRECTORIES": anchor.deletingLastPathComponent().path] : [:]
            let fact = try await repository.run(["rev-parse", "--is-inside-work-tree"], environmentOverrides: environment, successfulExitCodes: 0...128)
            let isGit = fact.exitCode == 0 && fact.text.trimmingCharacters(in: .whitespacesAndNewlines) == "true"
            guard !retired, generation == current else { return }
            let access = grants.first { $0.contains(target) && (!GitRuntime.isAppStoreBuild || $0.hasSecurityScope) }
            let fileAccess = grants.first { $0.contains(file) && (!GitRuntime.isAppStoreBuild || $0.hasSecurityScope) }
            let controller = WorkingTreePatchWindowController(repository: repository, access: access, fileAccess: fileAccess,
                bytes: bytes, title: file.lastPathComponent, preferences: preferences, directoryMode: true, isGitWorkingTree: isGit)
            ReviewPatchWindows.retain(controller, grants: grants)
            if let presentation { presentation(controller) } else { controller.showWindow(nil); controller.window?.makeKeyAndOrderFront(nil) }
            window?.close()
        } catch { if !retired, generation == current { fail(error) } }
    }
    private func fail(_ failure: Error) { error = failure.localizedDescription; status = "Could not open this patch." }
    func cancel() {
        guard !retired else { return }
        generation += 1
        if let picker { window?.endSheet(picker, returnCode: .cancel); picker.close(); self.picker = nil }
        window?.close()
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool { if picker != nil { cancel(); return false }; return true }
    func windowWillClose(_ notification: Notification) {
        guard !retired else { return }; retired = true; generation += 1
        if let picker { window?.endSheet(picker, returnCode: .cancel); picker.close(); self.picker = nil }
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
