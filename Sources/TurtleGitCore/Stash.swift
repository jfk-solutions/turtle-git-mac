import Foundation

public struct StashSaveOptions: Sendable {
    public var message = ""
    public var includeUntracked = false
    public var all = false
    public init() {}
}
public struct StashSaveResult: Sendable {
    public let output: String
    public let previous: String?
    public let current: String?
    public var created: Bool { current != nil && current != previous }
}
public enum StashFailure: LocalizedError {
    case combination, message
    public var errorDescription: String? {
        switch self {
        case .combination: return "Include untracked and --all cannot be combined."
        case .message: return "The stash message cannot contain a NUL character."
        }
    }
}
extension GitRepository {
    public func saveStash(_ options: StashSaveOptions) throws -> StashSaveResult {
        guard !(options.includeUntracked && options.all) else { throw StashFailure.combination }
        guard !options.message.contains("\0") else { throw StashFailure.message }
        let previous = (try? run(["rev-parse", "--verify", "refs/stash"]).text.trimmingCharacters(in: .newlines))
        var args = ["stash", "push"]
        if options.includeUntracked { args.append("--include-untracked") }
        else if options.all { args.append("--all") }
        if !options.message.isEmpty { args += ["-m", options.message] }
        // Stash uses the magic pathspec :/ in its internal clean subprocess.
        // Whole-repository save accepts no user paths, so preserve Git's own
        // pathspec semantics here; literal mode would silently skip cleanup.
        let output = try run(args, literalPathspecs: false).text
        let current = (try? run(["rev-parse", "--verify", "refs/stash"]).text.trimmingCharacters(in: .newlines))
        return StashSaveResult(output: output, previous: previous, current: current)
    }
}
