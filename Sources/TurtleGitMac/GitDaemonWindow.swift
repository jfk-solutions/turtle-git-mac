// SPDX-License-Identifier: GPL-2.0-or-later
// Native counterpart of Commands/DaemonCommand.cpp and its ProgressDlg.
import AppKit
import SwiftUI
import TurtleGitCore

/// Producers cannot queue unlimited UI tasks while the window is busy.
private final class DaemonOutputMailbox: @unchecked Sendable {
    private let lock = NSLock()
    private var pending = Data(), readinessTail = Data(), ready = false, dropped = false
    func append(_ chunk: GitOutputChunk) {
        lock.lock(); defer { lock.unlock() }
        readinessTail.append(chunk.data)
        if readinessTail.range(of: Data("Ready to rumble".utf8)) != nil { ready = true }
        readinessTail = Data(readinessTail.suffix(32))
        let available = max(0, 64 * 1024 - pending.count)
        pending.append(chunk.data.prefix(available)); dropped = dropped || chunk.data.count > available
    }
    func take() -> (Data, Bool) {
        lock.lock(); defer { lock.unlock() }
        var bytes = pending; pending.removeAll(keepingCapacity: true)
        if dropped { bytes.append(Data("\n[Daemon output queue truncated]\n".utf8)); dropped = false }
        return (bytes, ready)
    }
}

@MainActor final class GitDaemonWindowModel: ObservableObject {
    enum Phase { case warning, running, stopping, finished }
    static private(set) var activeOperations = 0
    let repository: GitRepository
    let access: RepositoryAccessLease?
    let configuration: GitDaemonConfiguration
    let preferences: UserDefaults
    @Published private(set) var phase = Phase.warning
    @Published var rememberWarning = false
    @Published private(set) var output = ""
    @Published private(set) var status = ""
    @Published private(set) var urls: [String] = []
    @Published private(set) var error: String?
    var close: () -> Void = {}
    var run: @Sendable (GitRepository, GitDaemonConfiguration, OperationCancellation, @escaping @Sendable (GitOutputChunk) -> Void) throws -> Int32 = {
        try GitDaemon.run(repository: $0, configuration: $1, cancellation: $2, onOutput: $3)
    }
    private let token = OperationCancellation()
    private let mailbox = DaemonOutputMailbox()
    private let parser: GitCliOutputParser
    private var outputState: GitProgressOutputState
    private var started = false, retired = false, closeAfterStop = false
    private var pump: Task<Void, Never>?
    var busy: Bool { phase == .running || phase == .stopping }
    var command: String { (try? configuration.arguments(root: repository.root))?.map { $0.contains(" ") ? "\"" + $0 + "\"" : $0 }.joined(separator: " ") ?? "git daemon" }
    init(repository: GitRepository, access: RepositoryAccessLease?, configuration: GitDaemonConfiguration = .init(), preferences: UserDefaults = .standard) {
        self.repository = repository; self.access = access; self.configuration = configuration; self.preferences = preferences
        outputState = GitProgressOutputState(preferences: preferences)
        parser = GitCliOutputParser(limit: outputState.limit)
    }
    func begin() {
        guard !started, !retired, phase == .warning else { return }
        if preferences.bool(forKey: "DaemonNoSecurityWarning") { proceed() }
    }
    func proceed() {
        guard !started, !retired, phase == .warning else { return }
        guard !GitRuntime.isAppStoreBuild || (access?.hasSecurityScope == true && access?.contains(repository.root) == true) else {
            error = RepositoryAccessFailure.securityScopeUnavailable.localizedDescription; phase = .finished; return
        }
        do { _ = try configuration.arguments(root: repository.root) }
        catch { self.error = error.localizedDescription; phase = .finished; return }
        preferences.set(rememberWarning || preferences.bool(forKey: "DaemonNoSecurityWarning"), forKey: "DaemonNoSecurityWarning")
        started = true; phase = .running; status = "Starting Git daemon…"; urls = configuration.urls()
        Self.activeOperations += 1
        let repository = repository, configuration = configuration, token = token, mailbox = mailbox, runner = run
        // Keep the real security scope alive until the daemon and its workers stop.
        let access = access
        pump = Task { [weak self] in
            while !Task.isCancelled {
                self?.drain()
                do { try await Task.sleep(nanoseconds: 100_000_000) } catch { return }
            }
        }
        Task {
            let result = await Task.detached {
                withExtendedLifetime(access) { Result { try runner(repository, configuration, token, { mailbox.append($0) }) } }
            }.value
            Self.activeOperations -= 1
            pump?.cancel(); pump = nil; drain()
            outputState.consume(parser.finish(), parser: parser); output = outputState.output
            phase = .finished
            if token.isCancelled { status = "Git daemon stopped." }
            else {
                switch result {
                case .success: status = "Git daemon exited."
                case .failure(let failure): error = failure.localizedDescription; status = "Git daemon failed."
                }
            }
            if closeAfterStop && !retired { close() }
        }
    }
    private func drain() {
        let (bytes, ready) = mailbox.take()
        parser.appendChunk(bytes); outputState.consume(parser.processPending(), parser: parser); output = outputState.output
        if ready && phase == .running { status = "Git daemon is running." }
    }
    func cancel(closeWhenStopped: Bool = false) {
        guard !retired else { return }
        if phase == .warning { preferences.removeObject(forKey: "DaemonNoSecurityWarning"); close(); return }
        if busy { closeAfterStop = closeAfterStop || closeWhenStopped; phase = .stopping; status = "Stopping Git daemon…"; token.cancel() }
        else { close() }
    }
    func retire() { retired = true; token.cancel(); pump?.cancel(); pump = nil }
}

@MainActor final class GitDaemonWindowController: NSWindowController, NSWindowDelegate {
    let model: GitDaemonWindowModel
    var onClosed: () -> Void = {}
    init(repository: GitRepository, access: RepositoryAccessLease?, configuration: GitDaemonConfiguration = .init(), preferences: UserDefaults = .standard) {
        model = GitDaemonWindowModel(repository: repository, access: access, configuration: configuration, preferences: preferences)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 720, height: 480), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = "\(repository.root.lastPathComponent) – Daemon – TurtleGit"
        window.isReleasedWhenClosed = false; window.contentMinSize = NSSize(width: 620, height: 380)
        window.contentViewController = NSHostingController(rootView: GitDaemonDialog(model: model))
        super.init(window: window); window.delegate = self; window.center()
        model.close = { [weak self] in guard let self, !self.model.busy else { return }; self.window?.close() }
        DialogGeometry.attach(window, identifier: "DaemonProgressDialog", legacyName: "DaemonProgressDialog")
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if model.busy { model.cancel(closeWhenStopped: true); return false }
        if model.phase == .warning { model.preferences.removeObject(forKey: "DaemonNoSecurityWarning") }
        return true
    }
    func windowWillClose(_ notification: Notification) { model.retire(); onClosed() }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
}

private struct GitDaemonDialog: View {
    @ObservedObject var model: GitDaemonWindowModel
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Daemon").font(.headline)
            Text(model.repository.root.path).textSelection(.enabled).foregroundStyle(.secondary)
            if model.phase == .warning {
                HStack(alignment: .top) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.yellow).font(.largeTitle)
                    Text("While running daemon, all data of this repository is exposed without authentication and/or encryption.")
                }
                Toggle("Do not show this warning again", isOn: $model.rememberWarning)
                Spacer()
                HStack { Spacer(); Button("Abort") { model.cancel() }.keyboardShortcut(.cancelAction); Button("Proceed") { model.proceed() }.keyboardShortcut(.defaultAction) }
            } else {
                Text(model.urls.joined(separator: "\n")).textSelection(.enabled).foregroundStyle(.blue)
                Text("git " + model.command).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                ScrollView([.horizontal, .vertical]) {
                    Text(model.output).font(.system(.body, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .topLeading)
                }.frame(maxWidth: .infinity, maxHeight: .infinity).padding(8).background(Color(nsColor: .textBackgroundColor)).overlay(Rectangle().stroke(Color(nsColor: .separatorColor)))
                HStack {
                    if model.busy { ProgressView().controlSize(.small) }
                    Text(model.error ?? model.status).foregroundStyle(model.error == nil ? Color.primary : Color.red).textSelection(.enabled)
                    Spacer()
                    Button(model.busy ? "Cancel" : "Close") { model.cancel() }.disabled(model.phase == .stopping).keyboardShortcut(.cancelAction)
                }
            }
        }.padding(16).frame(minWidth: 600, minHeight: 360)
    }
}
