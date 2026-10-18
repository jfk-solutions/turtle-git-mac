import Foundation
import Darwin

public struct SubmoduleUpdateOptions: Codable, Sendable {
    public var initialize = true
    public var recursive = false
    public var force = false
    public var noFetch = false
    public var merge = false
    public var rebase = false
    public var remote = false
    public init() {}
    public func arguments(paths: [String]) -> [String] {
        var args = ["submodule", "update", "--progress"]
        if initialize { args.append("--init") }
        if recursive { args.append("--recursive") }
        if force { args.append("--force") }
        if noFetch { args.append("--no-fetch") }
        if merge { args.append("--merge") }
        if rebase { args.append("--rebase") }
        if remote { args.append("--remote") }
        return args + ["--"] + paths
    }
}

/// One command may update only part of its selected paths before failing. Only
/// zero-status batches belong to successfulPaths; attemptedPaths is deliberately
/// broader and is the authoritative refresh boundary for native consumers.
public struct SubmoduleUpdateResult: Sendable {
    public struct Entry: Sendable {
        public let paths: [String]
        public let exitCode: Int32
        public let output: String
    }
    public let entries: [Entry]
    public let cancelled: Bool
    public var attemptedPaths: [String] { entries.flatMap(\.paths) }
    public var successfulPaths: [String] { entries.filter { $0.exitCode == 0 }.flatMap(\.paths) }
    public var exitCode: Int32 { cancelled ? 130 : entries.isEmpty ? -1 : entries.reduce(0) { $0 | $1.exitCode } }
    public var success: Bool { !cancelled && exitCode == 0 }
    public var output: String { entries.map(\.output).joined(separator: "\n") }
}
public struct SubmoduleUpdateExecutionFailure: LocalizedError {
    public let result: SubmoduleUpdateResult
    public let underlying: Error
    public var errorDescription: String? { underlying.localizedDescription }
}
public enum SubmoduleUpdateBatchPlan {
    /// argv is passed directly to exec, so count UTF-8 bytes, NUL terminators
    /// and pointer slots rather than shell quotes or Windows UTF-16 lengths.
    public static func paths(_ paths: [String], fixedArguments: [String], byteLimit: Int) throws -> [[String]] {
        let pointer = MemoryLayout<UnsafeRawPointer?>.size
        let fixed = fixedArguments.reduce(pointer) { $0 + $1.utf8.count + 1 + pointer }
        guard byteLimit > fixed else { throw SubmoduleUpdateFailure.commandSize }
        var batches: [[String]] = [], current: [String] = [], size = fixed
        for path in paths {
            let cost = path.utf8.count + 1 + pointer
            guard fixed + cost <= byteLimit else { throw SubmoduleUpdateFailure.commandSize }
            if size + cost > byteLimit { batches.append(current); current=[];size=fixed }
            current.append(path);size += cost
        }
        if !current.isEmpty { batches.append(current) }
        return batches
    }
    static var platformByteLimit: Int {
        let maximum = Int(sysconf(_SC_ARG_MAX))
        let environment = ProcessInfo.processInfo.environment.reduce(0) { $0 + $1.key.utf8.count + $1.value.utf8.count + 2 + MemoryLayout<UnsafeRawPointer?>.size }
        // Reserve runtime-added Git/SSH/askpass environment, exec bookkeeping
        // and the submodule shell helper's own argument expansion.
        return max(1024, min(128 * 1024, (maximum > 0 ? maximum : 256 * 1024) - environment - 32 * 1024))
    }
}

public enum SubmoduleUpdateFailure: LocalizedError {
    case selection, commandSize
    public var errorDescription: String? {
        switch self {
        case .selection: return "Select existing submodules to update. Refresh if their paths changed."
        case .commandSize: return "A selected submodule path exceeds the available Git command argument size."
        }
    }
}

extension GitRepository {
    public func submoduleUpdatePaths(scope: [String] = [], cancellation: OperationCancellation? = nil) throws -> [String] {
        try cancellation?.check()
        var paths = try submodulePathNames(cancellation: cancellation)
        let modules = root.appendingPathComponent(".gitmodules")
        if FileManager.default.fileExists(atPath: modules.path) {
            let type = try FileManager.default.attributesOfItem(atPath: modules.path)[.type] as? FileAttributeType
            guard type == .typeRegular else { throw SubmoduleComparisonFailure.unsafeCheckout }
            // Query names separately: values and subsection names may contain LF.
            let names = try run(["config", "--no-includes", "--null", "--file", modules.path, "--name-only", "--get-regexp", "^submodule\\..*\\.path$"], successfulExitCodes: 0...1, cancellation: cancellation).stdout.split(separator: 0)
            for name in names {
                let values = try run(["config", "--no-includes", "--null", "--file", modules.path, "--get-all", String(decoding: name, as: UTF8.self)], successfulExitCodes: 0...1, cancellation: cancellation).stdout.split(separator: 0)
                if let last = values.last { paths.insert(GitReferenceName(String(decoding: last, as: UTF8.self))) }
            }
        }
        for path in paths { try cancellation?.check(); _ = try restoreLocation(path.rawValue) }
        let prefixes = scope.filter { !$0.isEmpty && $0 != "." }
        return paths.map(\.rawValue).filter { path in
            prefixes.isEmpty || prefixes.contains { GitReferenceName.equal(path, $0) || GitReferenceName.removingPrefix($0 + "/", from: path) != nil }
        }.sorted {
            let order = $0.localizedStandardCompare($1)
            return order == .orderedSame ? $0.utf8.lexicographicallyPrecedes($1.utf8) : order == .orderedAscending
        }
    }

    public func updateSubmodules(paths: [String], options: SubmoduleUpdateOptions, cancellation: OperationCancellation? = nil, onOutput: (@Sendable (GitOutputChunk) -> Void)? = nil) throws -> String {
        let result: SubmoduleUpdateResult
        do { result = try updateSubmodulesWorkflow(paths: paths, options: options, cancellation: cancellation, onOutput: onOutput) }
        catch let failure as SubmoduleUpdateExecutionFailure { throw failure.underlying }
        guard result.success else { throw GitFailure(arguments: options.arguments(paths: paths), code: result.exitCode, message: result.output) }
        return result.output
    }
    public func updateSubmodulesWorkflow(paths: [String], options: SubmoduleUpdateOptions, cancellation: OperationCancellation? = nil, argumentByteLimit: Int? = nil, onOutput: (@Sendable (GitOutputChunk) -> Void)? = nil) throws -> SubmoduleUpdateResult {
        let token = cancellation ?? OperationCancellation()
        try token.check()
        let available = Set(try submoduleUpdatePaths(cancellation: cancellation).map { GitReferenceName($0) })
        guard !paths.isEmpty, Set(paths.map { GitReferenceName($0) }).count == paths.count, paths.allSatisfy({ available.contains(GitReferenceName($0)) }) else { throw SubmoduleUpdateFailure.selection }
        for path in paths {
            try cancellation?.check()
            let location = try restoreLocation(path)
            if let type = try? FileManager.default.attributesOfItem(atPath: location.path)[.type] as? FileAttributeType,
               type != .typeDirectory { throw SubmoduleComparisonFailure.unsafeCheckout }
        }
        // Always carry the reviewed selection explicitly, including an all-checked
        // scoped list. Never let batching widen the review to the whole project.
        let fixed = [executable.path, "--literal-pathspecs", "-C", root.path, "-c", "core.precomposeunicode=false"] + options.arguments(paths: [])
        let batches = try SubmoduleUpdateBatchPlan.paths(paths, fixedArguments: fixed, byteLimit: argumentByteLimit ?? SubmoduleUpdateBatchPlan.platformByteLimit)
        var entries: [SubmoduleUpdateResult.Entry] = []
        for batch in batches {
            var submitted = false
            do {
                try token.check()
                // A preceding batch/hook may have changed the remaining paths.
                for path in batch {
                    try token.check();let location=try restoreLocation(path)
                    if let type=try? FileManager.default.attributesOfItem(atPath:location.path)[.type] as? FileAttributeType,type != .typeDirectory {throw SubmoduleComparisonFailure.unsafeCheckout}
                }
                let display=(options.arguments(paths:batch)).map {value in value.contains(where: {$0.isWhitespace || $0 == "'"}) ? "'"+value.replacingOccurrences(of:"'",with:"'\\''")+"'":value}.joined(separator:" ")
                onOutput?(GitOutputChunk(stream:.stdout,data:Data(((entries.isEmpty ? "":"\n")+"git "+display+"\n").utf8)))
                submitted = true
                let result = try run(["-c", "core.precomposeunicode=false"] + options.arguments(paths: batch), successfulExitCodes: 0...255, cancellation: token, onOutput: onOutput)
                entries.append(.init(paths: batch, exitCode: result.exitCode, output: result.text))
            } catch {
                if let interrupted = error as? GitCommandCancellationFailure {
                    entries.append(.init(paths: batch, exitCode: interrupted.result.exitCode, output: interrupted.result.text))
                } else if submitted {
                    // A failed launch cannot promise that no child started; retain
                    // the attempted batch for conservative refresh/recovery.
                    entries.append(.init(paths: batch, exitCode: -1, output: error.localizedDescription))
                }
                throw SubmoduleUpdateExecutionFailure(result: .init(entries: entries, cancelled: token.isCancelled), underlying: error)
            }
        }
        return .init(entries: entries, cancelled: false)
    }
}
