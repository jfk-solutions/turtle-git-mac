import Foundation

/// Serializes repository operations off the main actor. Arguments never pass through a shell.
public actor GitRepository {
    public nonisolated let root: URL
    public nonisolated let executable: URL
    public init(root: URL, executable: URL = URL(fileURLWithPath: "/usr/bin/git")) {
        self.root = root.standardizedFileURL; self.executable = executable
    }
    public func run(_ arguments: [String]) throws -> GitResult {
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let out = temporary.appendingPathComponent("stdout"), err = temporary.appendingPathComponent("stderr")
        FileManager.default.createFile(atPath: out.path, contents: nil)
        FileManager.default.createFile(atPath: err.path, contents: nil)
        let output = try FileHandle(forWritingTo: out), error = try FileHandle(forWritingTo: err)
        defer { try? output.close(); try? error.close() }
        let process = Process()
        process.executableURL = executable
        process.arguments = ["--literal-pathspecs", "-C", root.path] + arguments
        var environment = ProcessInfo.processInfo.environment
        environment["GIT_TERMINAL_PROMPT"] = "0"
        environment["GIT_PAGER"] = "cat"
        environment["LC_ALL"] = "C"
        environment.merge(GitRuntime.environment(executable: executable)) { _, runtime in runtime }
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = output; process.standardError = error
        // Disk-backed streams avoid pipe deadlock with large diffs and command output.
        try process.run(); process.waitUntilExit()
        let result = GitResult(stdout: try Data(contentsOf: out), stderr: try Data(contentsOf: err))
        guard process.terminationStatus == 0 else {
            throw GitFailure(arguments: arguments, code: process.terminationStatus, message: result.text)
        }
        return result
    }
    public func discoverRoot() throws -> URL {
        let result = try run(["rev-parse", "--show-toplevel"])
        // Only remove Git's final LF: spaces and embedded newlines can be part of a path.
        var bytes = result.stdout
        if bytes.last == 10 { bytes.removeLast() }
        return URL(fileURLWithPath: String(decoding: bytes, as: UTF8.self), isDirectory: true)
    }
    public func status() throws -> [StatusEntry] { StatusEntry.parse(try run(["status", "--porcelain=v1", "-z", "--untracked-files=all", "--ignored"]).stdout) }
    public func trackedPaths() throws -> [String] {
        try run(["ls-files", "-z"]).stdout.split(separator: 0).map { String(decoding: $0, as: UTF8.self) }
    }
    public func branch() throws -> String { try run(["branch", "--show-current"]).text.trimmingCharacters(in: .newlines) }
    public func log() throws -> [LogEntry] {
        try history()
    }

    public func diff(path: String? = nil, staged: Bool = false) throws -> String {
        var args = ["diff", "--no-ext-diff", "--no-color"]
        if staged { args.append("--cached") }
        args.append("--")
        if let path { args.append(path) }
        return try run(args).text
    }
    public func stage(_ paths: [String]) throws { if !paths.isEmpty { _ = try run(["add", "--"] + paths) } }
    public func unstage(_ paths: [String]) throws {
        guard !paths.isEmpty else { return }
        if (try? run(["rev-parse", "--verify", "HEAD"])) != nil {
            _ = try run(["restore", "--staged", "--"] + paths)
        } else { _ = try run(["rm", "--cached", "--"] + paths) }
    }
    public func commit(message: String) throws -> String {
        guard !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw GitFailure(arguments: ["commit"], code: 1, message: "Enter a commit message.")
        }
        return try run(["commit", "-m", message]).text
    }
}
