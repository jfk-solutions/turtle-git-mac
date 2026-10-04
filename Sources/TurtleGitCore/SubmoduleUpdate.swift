import Foundation

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

public enum SubmoduleUpdateFailure: LocalizedError {
    case selection
    public var errorDescription: String? { "Select existing submodules to update. Refresh if their paths changed." }
}

extension GitRepository {
    public func submoduleUpdatePaths(scope: [String] = []) throws -> [String] {
        var paths = try submodulePaths()
        let modules = root.appendingPathComponent(".gitmodules")
        if FileManager.default.fileExists(atPath: modules.path) {
            let type = try FileManager.default.attributesOfItem(atPath: modules.path)[.type] as? FileAttributeType
            guard type == .typeRegular else { throw SubmoduleComparisonFailure.unsafeCheckout }
            // Query names separately: values and subsection names may contain LF.
            let names = try run(["config", "--no-includes", "--null", "--file", modules.path, "--name-only", "--get-regexp", "^submodule\\..*\\.path$"], successfulExitCodes: 0...1).stdout.split(separator: 0)
            for name in names {
                let values = try run(["config", "--no-includes", "--null", "--file", modules.path, "--get-all", String(decoding: name, as: UTF8.self)], successfulExitCodes: 0...1).stdout.split(separator: 0)
                if let last = values.last { paths.insert(String(decoding: last, as: UTF8.self)) }
            }
        }
        for path in paths { _ = try restoreLocation(path) }
        let prefixes = scope.filter { !$0.isEmpty && $0 != "." }
        return paths.filter { path in prefixes.isEmpty || prefixes.contains { path == $0 || path.hasPrefix($0 + "/") } }.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    public func updateSubmodules(paths: [String], options: SubmoduleUpdateOptions) throws -> String {
        let available = Set(try submoduleUpdatePaths())
        guard !paths.isEmpty, Set(paths).count == paths.count, paths.allSatisfy({ available.contains($0) }) else { throw SubmoduleUpdateFailure.selection }
        for path in paths {
            let location = try restoreLocation(path)
            if let type = try? FileManager.default.attributesOfItem(atPath: location.path)[.type] as? FileAttributeType,
               type != .typeDirectory { throw SubmoduleComparisonFailure.unsafeCheckout }
        }
        // Always carry the reviewed selection explicitly. Selecting all within a
        // folder must not update unreviewed submodules elsewhere in the project.
        return try run(options.arguments(paths: paths)).text
    }
}
