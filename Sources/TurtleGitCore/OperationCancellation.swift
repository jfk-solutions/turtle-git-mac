import Foundation

public enum OperationCancellationFailure: LocalizedError {
    case cancelled
    public var errorDescription: String? { "Operation cancelled." }
}

/// Cooperative cancellation shared by a native window and the repository actor.
/// Operations check boundaries; GitRepository.run can also opt into terminating
/// its owned child process group when this token is cancelled.
public final class OperationCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    // Immutable parent ownership makes propagation directional: retiring an
    // optional child never cancels the enclosing command or its siblings.
    private let parent: OperationCancellation?
    public init(parent: OperationCancellation? = nil) { self.parent = parent }
    public func cancel() { lock.lock(); cancelled = true; lock.unlock() }
    public var isCancelled: Bool {
        lock.lock(); let local = cancelled; lock.unlock()
        return local || parent?.isCancelled == true
    }
    public func check() throws { if isCancelled { throw OperationCancellationFailure.cancelled } }
}

public struct WorkingFileRevertProgress: Sendable {
    public enum Step: String, Sendable {
        case unstage = "Unstage addition", recycle = "Move to Trash", move = "Restore old name", restore = "Revert"
    }
    public let step: Step
    public let path: String
    public let finished: Bool
    public let completed: Int
    public let total: Int
}
