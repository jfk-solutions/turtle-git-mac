// SPDX-License-Identifier: GPL-2.0-or-later
import AppKit
import Darwin
import TurtleGitCore

/// One launch-input outcome, separate from later document/Apply diagnostics.
enum UnifiedDiffStartupInputOutcome:Equatable {case success, failure, cancelled}

@MainActor final class UnifiedDiffToolCompletion {
    private var outcome:UnifiedDiffStartupInputOutcome?
    private var closed=false
    private var completion:((Int32)->Void)?
    init(_ completion:@escaping(Int32)->Void){self.completion=completion}
    func finish(_ outcome:UnifiedDiffStartupInputOutcome){guard self.outcome==nil else{return};self.outcome=outcome;deliver()}
    func ownerClosed(){closed=true;deliver()}
    private func deliver(){
        guard closed,let outcome,let completion else{return}
        self.completion=nil;completion(outcome == .success ? 0:1)
    }
}

/// Owns one standalone stdin read. The reader duplicates the descriptor; this
/// session never closes or changes the parent's stdin.
@MainActor final class UnifiedDiffInputSession {
    typealias Reader = @Sendable (Int32, OperationCancellation) throws -> Data
    static private(set) var activeOperations = 0
    private static var active: [ObjectIdentifier: UnifiedDiffInputSession] = [:]
    private(set) var isReading = false
    private(set) var cancelling = false
    private var started = false
    private var generation = UUID()
    private var pendingClose = false
    private weak var controller: PatchWindowController?
    private weak var window: NSWindow?
    private var cancellation: OperationCancellation?
    private var task: Task<Void, Never>?
    private var reportResult:((UnifiedDiffStartupInputOutcome)->Void)?
    private let read: Reader

    init(read: @escaping Reader = { descriptor, cancellation in
        try UnifiedDiffInputReader.read(descriptor: descriptor, cancellation: cancellation)
    }) { self.read = read }

    /// Single use: prepare the empty editable document before waiting for EOF.
    /// The caller owns window presentation, including offscreen verification.
    @discardableResult func start(controller: PatchWindowController,
                                  descriptor: Int32 = STDIN_FILENO,
                                  title: String) -> Bool {
        guard !started, !controller.model.retired, !controller.model.busy,
              !controller.model.confirmingQuit,
              !controller.model.documentDirty, let window = controller.window,
              window.attachedSheet == nil,
              controller.startupInput == nil || controller.startupInput === self else { return false }
        started = true; self.controller = controller; self.window = window
        reportResult=controller.startupInputReporter
        controller.startupInput = self
        controller.presentDocument(Data(), title: title + " – Unified Diff – TurtleGit", comparison: title, information: "")
        // Capture the stream synchronously. Passing only the descriptor number
        // to a deferred worker lets caller close/reuse redirect the read.
        let owned = fcntl(descriptor, F_DUPFD_CLOEXEC, 0)
        guard owned >= 0 else {
            controller.model.error = UnifiedDiffInputFailure.descriptor(errno).localizedDescription
            reportResult?(.failure);reportResult=nil
            return true
        }
        let token = OperationCancellation(), request = generation, read = self.read
        guard controller.model.beginStartupInput(cancel: { [weak self] in self?.cancel() }) else {
            close(owned);reportResult?(.cancelled);reportResult=nil; return false
        }
        cancellation = token; isReading = true; Self.activeOperations += 1
        Self.active[ObjectIdentifier(self)] = self
        task = Task { [self] in
            let result: Result<Data, Error>
            do {
                result = .success(try await Task.detached {
                    defer { close(owned) }
                    return try read(owned, token)
                }.value)
            } catch { result = .failure(error) }
            finish(result, token: token, request: request, title: title)
        }
        return true
    }

    func cancel() {
        guard isReading, !cancelling else { return }
        cancelling = true; cancellation?.cancel()
        if let controller, controller.startupInput === self, !controller.model.retired {
            controller.model.markStartupInputCancelling()
        }
    }

    /// A busy close cancels the reader and returns false from the controller's
    /// close delegate. The same exact window is closed only once the worker exits.
    @discardableResult func requestClose() -> Bool {
        guard isReading else { return false }
        pendingClose = true; cancel(); return true
    }

    func cancelAndWait() async {
        cancel()
        let pending = task
        await pending?.value
    }

    /// Quit drains every accepted stream, including a forcibly closed owner.
    /// Cancel the entire captured group before awaiting any individual worker.
    static func cancelAll(){for session in Array(active.values){session.cancel()}}
    static func cancelAllAndWait() async {
        let sessions = Array(active.values)
        for session in sessions { session.cancel() }
        for session in sessions { await session.cancelAndWait() }
    }

    private func finish(_ result: Result<Data, Error>, token: OperationCancellation,
                        request: UUID, title: String) {
        guard isReading, cancellation === token, generation == request else { return }
        // Account for the real worker before releasing the model or asking its
        // ordinary close delegate to run again.
        isReading = false; cancelling = false; cancellation = nil; task = nil
        Self.activeOperations -= 1
        Self.active.removeValue(forKey: ObjectIdentifier(self))
        let outcome:UnifiedDiffStartupInputOutcome
        if token.isCancelled {outcome = .cancelled}
        else {switch result {case .success:outcome = .success;case .failure:outcome = .failure}}
        reportResult?(outcome);reportResult=nil
        guard let controller, controller.startupInput === self else { return }
        controller.model.finishStartupInput()
        guard !controller.model.retired, let window,
              controller.window === window, window.delegate === controller else { return }
        if pendingClose {
            pendingClose = false
            window.performClose(nil)
            return
        }
        guard !token.isCancelled else { return }
        switch result {
        case .success(let bytes):
            // Empty EOF is a valid empty document. Keep original bytes for
            // encoding/save semantics; the existing document session decodes.
            controller.presentDocument(bytes, title: title + " – Unified Diff – TurtleGit", comparison: title, information: "")
        case .failure(let error): controller.model.error = error.localizedDescription
        }
    }
}
