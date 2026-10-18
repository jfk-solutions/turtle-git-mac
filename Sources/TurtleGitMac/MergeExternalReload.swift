// SPDX-License-Identifier: GPL-2.0-or-later
import AppKit
import TurtleGitCore

/// Per-document equivalent of TortoiseMerge's delayed activation reload check.
/// The observation receipt is independent of the editor's guarded save baseline.
@MainActor final class MergeExternalReloadCoordinator {
    private final class Request {
        let epoch: UUID
        let owner: NSWindow
        let sources: [MergeExternalSource]
        let permissions: [RepositoryAccessLease]
        let cancellation = OperationCancellation()
        var question: NSAlert?
        var questioning = false, answered = false, finished = false
        var answer = NSApplication.ModalResponse.cancel
        var result: MergeExternalSourceProbe?
        var observer: NSObjectProtocol?
        init(epoch: UUID, owner: NSWindow, sources: [MergeExternalSource], permissions: [RepositoryAccessLease]) {
            self.epoch = epoch; self.owner = owner; self.sources = sources; self.permissions = permissions
        }
    }
    private weak var window: NSWindow?
    private let sources: () -> [MergeExternalSource]
    private let permissions: () -> [RepositoryAccessLease]
    private let ready: () -> Bool
    private let dirty: () -> Bool
    private let reload: () -> Void
    private let keep: (Set<String>) -> Void
    private let failed: (Error) -> Void
    private var epoch = UUID(), retired = false, requested = false
    private var delayed: Task<Void, Never>?
    private var request: Request?
    private var observations: [String: MergeExternalSourceObservation] = [:]
    private var observedSources: [String: MergeExternalSource] = [:]
    private var activationObservers: [NSObjectProtocol] = []
    private(set) static var activeRequests = 0
    var hasPendingWork: Bool { delayed != nil || request != nil }
    var blocksCommands: Bool { request?.questioning == true }
    var stateChanged: () -> Void = {}
    var isActive: (NSWindow) -> Bool = { NSApp.isActive && $0.isKeyWindow && !$0.isMiniaturized }
    var delayNanoseconds: UInt64 = 300_000_000
    var presentQuestion: (NSAlert, NSWindow, @escaping (NSApplication.ModalResponse) -> Void) -> Void = {
        $0.beginSheetModal(for: $1, completionHandler: $2)
    }
    var probe: ([MergeExternalSource], [String: MergeExternalSourceObservation], OperationCancellation) async throws -> MergeExternalSourceProbe = { sources, previous, cancellation in
        try await Task.detached { try MergeExternalSources.probe(sources, previous: previous, cancellation: cancellation) }.value
    }
    init(window: NSWindow, sources: @escaping () -> [MergeExternalSource], permissions: @escaping () -> [RepositoryAccessLease],
         ready: @escaping () -> Bool, dirty: @escaping () -> Bool, reload: @escaping () -> Void,
         keep: @escaping (Set<String>) -> Void, failed: @escaping (Error) -> Void) {
        self.window = window; self.sources = sources; self.permissions = permissions; self.ready = ready
        self.dirty = dirty; self.reload = reload; self.keep = keep; self.failed = failed
        installObservers()
    }
    private func installObservers() {
        guard let window else { return }
        for (name, owner) in [(NSApplication.didBecomeActiveNotification, nil as AnyObject?), (NSWindow.didDeminiaturizeNotification, window as AnyObject?)] {
            activationObservers.append(NotificationCenter.default.addObserver(forName: name, object: owner, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { guard let self, let window = self.window, self.isActive(window) else { return }; self.activate() }
            })
        }
        activationObservers.append(NotificationCenter.default.addObserver(forName: NSWindow.didEndSheetNotification, object: window, queue: .main) { [weak self] _ in
            DispatchQueue.main.async { [weak self] in self?.resume() }
        })
    }
    deinit { for observer in activationObservers { NotificationCenter.default.removeObserver(observer) } }
    /// File/Open adopts an existing native frame rather than the prepared one.
    /// Retain any old operation through drain, but bind future activation/sheets
    /// to the actual adopted owner before its first accepted load.
    func rebind(to window: NSWindow) {
        guard !retired else { return }
        for observer in activationObservers { NotificationCenter.default.removeObserver(observer) }; activationObservers = []
        self.window = window; installObservers(); reset()
    }
    private func changedState() {
        DispatchQueue.main.async { [weak self] in guard let self, !self.retired else { return }; self.stateChanged() }
    }
    func activate() {
        guard !retired else { return }
        requested = true
        guard request == nil else { return }
        delayed?.cancel()
        let captured = epoch, delay = delayNanoseconds
        delayed = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: delay) } catch { return }
            guard let self, !self.retired, self.epoch == captured, !Task.isCancelled else { return }
            self.delayed = nil; self.resume()
        }
    }
    /// A busy load/save/chooser can defer an activation without polling the disk.
    /// The owning model calls this when its existing operation settles.
    func resume() {
        guard !retired, requested, delayed == nil, request == nil, let window,
              isActive(window), ready(), window.attachedSheet == nil, NSApp.modalWindow == nil else { return }
        let inputs = sources()
        guard !inputs.isEmpty else { requested = false; return }
        requested = false
        let operation = Request(epoch: epoch, owner: window, sources: inputs, permissions: permissions())
        request = operation; Self.activeRequests += 1; changedState()
        let probe = probe, previous = observations
        Task { [self, operation] in
            do {
                let result = try await probe(operation.sources, previous, operation.cancellation)
                guard accepts(operation) else { finish(operation); return }
                guard ready(), operation.owner.attachedSheet == nil, NSApp.modalWindow == nil, isActive(operation.owner) else {
                    requested = true; finish(operation); return
                }
                guard !result.changed.isEmpty else {
                    acknowledge(result, sources: operation.sources); finish(operation); return
                }
                operation.result = result; ask(operation)
            } catch {
                let publish = accepts(operation) && !operation.cancellation.isCancelled && ready()
                finish(operation)
                if publish { failed(error) }
            }
        }
    }
    /// Successful explicit Reload/Save/Save As changes the displayed receipt.
    /// Cancel old work, but keep actual worker/sheet accounting through its drain.
    func reset(preservingUnchangedSources: Bool = false, invalidatingSources: Set<String> = []) {
        guard !retired else { return }
        epoch = UUID()
        if preservingUnchangedSources {
            let current = sources()
            let retained = Set(current.filter { source in
                !invalidatingSources.contains(source.id) && observedSources[source.id].map { sameSources([source], [$0]) } == true
            }.map { $0.id })
            observations = observations.filter { retained.contains($0.key) }
            observedSources = observedSources.filter { retained.contains($0.key) }
        } else { observations = [:]; observedSources = [:] }
        delayed?.cancel(); delayed = nil
        if let operation = request {
            operation.cancellation.cancel()
            if operation.questioning { endQuestion(operation) }
        }
        if let window, isActive(window) { requested = true }
        if request == nil { activateIfRequested() }
    }
    private func activateIfRequested() { if requested { activate() } }
    func retire() {
        guard !retired else { return }
        retired = true; epoch = UUID(); requested = false
        for observer in activationObservers { NotificationCenter.default.removeObserver(observer) }; activationObservers = []
        delayed?.cancel(); delayed = nil; observations = [:]; observedSources = [:]
        guard let operation = request else { return }
        operation.cancellation.cancel()
        if operation.questioning { endQuestion(operation) }
    }
    private func sameSources(_ a: [MergeExternalSource], _ b: [MergeExternalSource]) -> Bool {
        guard a.count == b.count else { return false }
        return zip(a, b).allSatisfy { pair in
            let (left, right) = pair
            return left.id == right.id && GitReferenceName.equal(left.url.path, right.url.path) &&
                left.expectedBytes == right.expectedBytes && left.expectedMissing == right.expectedMissing &&
                left.expectedPermissions == right.expectedPermissions
        }
    }
    private func accepts(_ operation: Request) -> Bool {
        !retired && !operation.finished && request === operation && operation.epoch == epoch &&
            !operation.cancellation.isCancelled && window === operation.owner && sameSources(operation.sources, sources())
    }
    private func ask(_ operation: Request) {
        guard accepts(operation), let result = operation.result else { finish(operation); return }
        operation.questioning = true
        let alert = NSAlert(); alert.alertStyle = .warning
        alert.messageText = String(localized: "Do you want to load the changed files?")
        let explanation = dirty()
            ? String(localized: "Some files have changed outside TurtleGitMerge. Loading them will replace your unsaved changes.")
            : String(localized: "Some files have changed outside TurtleGitMerge. The views can be updated with the new content.")
        let paths = operation.sources.filter { result.changed.contains($0.id) }.map { $0.url.path }
        alert.informativeText = explanation + "\n\n" + paths.joined(separator: "\n")
        alert.addButton(withTitle: String(localized: "Load changes")); alert.addButton(withTitle: String(localized: "Ignore changes")); alert.addButton(withTitle: String(localized: "Cancel"))
        alert.buttons[0].keyEquivalent = "\r"; alert.buttons[2].keyEquivalent = "\u{1b}"
        alert.window.appearance = operation.owner.effectiveAppearance
        operation.question = alert
        operation.observer = NotificationCenter.default.addObserver(forName: NSWindow.didEndSheetNotification, object: operation.owner, queue: .main) { [self, operation] _ in
            DispatchQueue.main.async { [self, operation] in
                guard operation.answered else { return }; drainQuestion(operation)
            }
        }
        changedState()
        presentQuestion(alert, operation.owner) { [weak self, weak operation] answer in
            guard let self, let operation, !operation.answered, !operation.finished else { return }
            operation.answered = true; operation.answer = answer; self.endQuestion(operation)
        }
    }
    private func endQuestion(_ operation: Request) {
        operation.answered = true
        if let alert = operation.question {
            alert.window.sheetParent?.endSheet(alert.window, returnCode: operation.answer)
            alert.window.orderOut(nil)
        }
        // A captured request owns the window, lease and continuation until AppKit
        // really releases the sheet, including forced document retirement.
        DispatchQueue.main.async { [self, operation] in drainQuestion(operation) }
    }
    private func drainQuestion(_ operation: Request) {
        guard !operation.finished, operation.answered else { return }
        if let sheet = operation.question?.window,
           sheet.sheetParent != nil || operation.owner.attachedSheet === sheet { return }
        let current = accepts(operation)
        let accepted = current && ready() && operation.owner.attachedSheet == nil && NSApp.modalWindow == nil
        if current && !accepted { requested = true }
        let result = operation.result, answer = operation.answer
        if accepted, let result { acknowledge(result, sources: operation.sources) }
        finish(operation)
        guard accepted, let result else { return }
        if answer == .alertFirstButtonReturn { reload() }
        else { keep(result.changed) } // Source Cancel and Ignore share this branch.
    }
    private func acknowledge(_ result: MergeExternalSourceProbe, sources: [MergeExternalSource]) {
        observations = result.observations
        observedSources = Dictionary(sources.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    }
    private func finish(_ operation: Request) {
        guard !operation.finished else { return }
        operation.finished = true
        if let observer = operation.observer { NotificationCenter.default.removeObserver(observer); operation.observer = nil }
        operation.question = nil
        Self.activeRequests -= 1
        if request === operation { request = nil }
        withExtendedLifetime(operation.permissions) {}
        changedState()
        if !retired, requested { DispatchQueue.main.async { [weak self] in self?.resume() } }
    }
}
