import Foundation

public struct RequestPullOptions: Sendable {
    public var start = ""
    public var repositoryURL = ""
    public var end = "HEAD"
    public init() {}
}
public enum RequestPullFailure: LocalizedError {
    case end, argument
    public var errorDescription: String? {
        switch self {
        case .end: return "Branch/Tag name must not be empty or is invalid."
        case .argument: return "Pull request arguments cannot contain NUL."
        }
    }
}
extension GitRepository {
    public func validateRequestPullEnd(_ end: String) throws {
        // CGit::IsBranchNameValid rejects these Windows characters in addition
        // to libgit2's branch name check. Keep the source dialog's input gate.
        guard !end.isEmpty, !end.hasPrefix("-"), end != "HEAD", !end.contains("\0"), end.rangeOfCharacter(from: CharacterSet(charactersIn: "\"|<>")) == nil,
              (try? run(["check-ref-format", "refs/heads/" + end])) != nil else {
            throw RequestPullFailure.end
        }
    }
    /// Generates request text only. Git checks that the advertised URL publishes
    /// the requested end; no refs, index or working-tree files are changed.
    public func requestPull(_ options: RequestPullOptions, cancellation: OperationCancellation? = nil) throws -> Data {
        try cancellation?.check()
        guard !options.start.contains("\0"), !options.repositoryURL.contains("\0"), !options.end.contains("\0") else { throw RequestPullFailure.argument }
        try validateRequestPullEnd(options.end)
        let start = options.start.hasPrefix("remotes/") ? String(options.start.dropFirst(8)) : options.start
        return try run(["request-pull", "--", start, options.repositoryURL, options.end], cancellation: cancellation).stdout
    }
}
