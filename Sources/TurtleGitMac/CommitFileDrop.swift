// SPDX-License-Identifier: GPL-2.0-or-later
import AppKit
import SwiftUI
import UniformTypeIdentifiers
import TurtleGitCore

/// Reads URL bytes rather than a temporary file representation or file promise.
enum CommitFileURLReader {
    static func read(_ provider: NSItemProvider) async throws -> URL {
        let request = Request()
        return try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { continuation in
                request.begin(continuation)
                let progress = provider.loadDataRepresentation(forTypeIdentifier: UTType.fileURL.identifier) { item, error in
                    if let error { request.finish(.failure(error)); return }
                    let url = item.flatMap { URL(dataRepresentation: $0, relativeTo: nil) }
                    guard let url, url.isFileURL else { request.finish(.failure(Failure.invalid)); return }
                    request.finish(.success(url))
                }
                request.install(progress)
                request.installTimeout(Task {
                    do { try await Task.sleep(nanoseconds: 10_000_000_000); request.stop(Failure.timeout) }
                    catch { /* Completed or canceled request. */ }
                })
            }
        }, onCancel: { request.stop(CancellationError()) })
    }
    enum Failure: LocalizedError {
        case invalid, timeout
        var errorDescription: String? { self == .invalid ? "The drop does not contain a local file URL." : "Reading the dropped file URL timed out." }
    }
    private final class Request: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<URL, Error>?
        private var progress: Progress?
        private var result: Result<URL, Error>?
        private var timeout: Task<Void, Never>?
        func begin(_ continuation: CheckedContinuation<URL, Error>) {
            lock.lock()
            if let result { lock.unlock(); continuation.resume(with: result) }
            else { self.continuation = continuation; lock.unlock() }
        }
        func install(_ progress: Progress) {
            lock.lock(); self.progress = progress; let done = result != nil; lock.unlock()
            if done { progress.cancel() }
        }
        func installTimeout(_ timeout: Task<Void, Never>) {
            lock.lock(); self.timeout = timeout; let done = result != nil; lock.unlock()
            if done { timeout.cancel() }
        }
        func finish(_ result: Result<URL, Error>) {
            lock.lock(); guard self.result == nil else { lock.unlock(); return }
            self.result = result; let reply = continuation, timeout = timeout; continuation = nil; self.timeout = nil; lock.unlock()
            timeout?.cancel(); reply?.resume(with: result)
        }
        func stop(_ error: Error) {
            finish(.failure(error)); lock.lock(); let progress = progress; lock.unlock(); progress?.cancel()
        }
    }
}

@MainActor final class CommitFileDropTargets: ObservableObject {
    private final class WeakProbe { weak var value: CommitFileInteraction.Probe?; init(_ value: CommitFileInteraction.Probe) { self.value = value } }
    private var probes: [String: WeakProbe] = [:]
    func set(_ probe: CommitFileInteraction.Probe, for key: String) { probes[key] = WeakProbe(probe) }
    func accepts(_ location: CGPoint, key: String) -> Bool { probes[key]?.value?.acceptsFileDrop(at: location) == true }
}

@MainActor struct CommitFileDropDelegate: DropDelegate {
    let model: CommitWindowModel
    let targets: CommitFileDropTargets
    let key: String
    func validateDrop(info: DropInfo) -> Bool {
        model.canReceiveFileDrop && info.hasItemsConforming(to: [UTType.fileURL]) && targets.accepts(info.location, key: key)
    }
    func dropUpdated(info: DropInfo) -> DropProposal? { DropProposal(operation: validateDrop(info: info) ? .copy : .cancel) }
    func performDrop(info: DropInfo) -> Bool {
        guard validateDrop(info: info) else { return false }
        return model.receiveFileDrop(info.itemProviders(for: [UTType.fileURL]))
    }
}
