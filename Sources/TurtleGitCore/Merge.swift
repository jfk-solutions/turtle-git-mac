import Foundation

public struct MergeOptions: Sendable {
    public var revision = ""
    public var squash = false
    public var noCommit = false
    public var allowUnrelatedHistories = false
    public var noFastForward = false
    public var fastForwardOnly = false
    public var logCount: Int?
    public var strategy = ""
    public var strategyOption = ""
    public var strategyParameter = ""
    public var message = ""
    public init() {}
    public static let strategies = ["resolve", "recursive", "ours", "subtree"]
    public static let strategyOptions = ["ours", "theirs", "patience", "ignore-space-change", "ignore-all-space", "ignore-space-at-eol", "renormalize", "no-renormalize", "rename-threshold", "subtree"]
}
public enum MergeFailure: LocalizedError {
    case revision, combination, strategy, parameter, logCount
    public var errorDescription: String? {
        switch self {
        case .revision: return "Choose a branch, tag or commit that exists in this repository."
        case .combination: return "No Fast Forward cannot be combined with Fast Forward Only or Squash."
        case .strategy: return "Choose a supported merge strategy and strategy option."
        case .parameter: return "Enter a valid strategy parameter."
        case .logCount: return "Enter a nonnegative number of commit messages."
        }
    }
}
extension GitRepository {
    public func mergeMessageCount() -> Int {
        let value = (try? run(["config", "--get", "merge.log"]).text.trimmingCharacters(in: .newlines)) ?? ""
        return Int(value).flatMap { $0 > 0 ? $0 : nil } ?? 20
    }
    public func merge(_ options: MergeOptions, cancellation: OperationCancellation? = nil, onOutput: (@Sendable (GitOutputChunk) -> Void)? = nil) throws -> String {
        try cancellation?.check()
        guard !(options.noFastForward && (options.fastForwardOnly || options.squash)) else { throw MergeFailure.combination }
        if let count = options.logCount, count < 0 { throw MergeFailure.logCount }
        guard options.strategy.isEmpty || MergeOptions.strategies.contains(options.strategy),
              options.strategyOption.isEmpty || MergeOptions.strategyOptions.contains(options.strategyOption) else { throw MergeFailure.strategy }
        guard !options.revision.isEmpty, !options.revision.contains("\0"),
              (try? run(["rev-parse", "--verify", "--end-of-options", options.revision + "^{commit}"])) != nil else { throw MergeFailure.revision }
        var args = ["merge", "--no-edit"]
        if options.noFastForward { args.append("--no-ff") }
        if options.fastForwardOnly { args.append("--ff-only") }
        if options.squash { args.append("--squash") }
        if options.noCommit { args.append("--no-commit") }
        if options.allowUnrelatedHistories { args.append("--allow-unrelated-histories") }
        if let count = options.logCount { args.append("--log=\(count)") }
        if !options.strategy.isEmpty { args.append("--strategy=" + options.strategy) }
        // Upstream ignores hidden option/parameter values when the strategy changes.
        if options.strategy == "recursive", !options.strategyOption.isEmpty {
            var option = options.strategyOption
            if ["rename-threshold", "subtree"].contains(option), !options.strategyParameter.isEmpty {
                guard !options.strategyParameter.contains("\0") else { throw MergeFailure.parameter }
                if option == "rename-threshold" {
                    let value = options.strategyParameter.hasSuffix("%") ? String(options.strategyParameter.dropLast()) : options.strategyParameter
                    guard let percentage = Int(value), (0...100).contains(percentage) else { throw MergeFailure.parameter }
                }
                option += "=" + options.strategyParameter
            }
            args.append("--strategy-option=" + option)
        }
        if !options.squash, !options.message.isEmpty {
            guard !options.message.contains("\0") else { throw MergeFailure.parameter }
            args += ["-m", options.message]
        }
        // Keep the selected ref name for Git's generated message; -- prevents options.
        args += ["--", options.revision]
        return try run(args, cancellation: cancellation, onOutput: onOutput).text
    }
}
