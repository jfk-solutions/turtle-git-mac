import Foundation

/// Serializes repository operations off the main actor. Arguments never pass through a shell.
public actor GitRepository {
    public nonisolated let root: URL
    public nonisolated let executable: URL
    public init(root: URL, executable: URL = URL(fileURLWithPath: "/usr/bin/git")) {
        self.root = root.standardizedFileURL; self.executable = executable
    }
    public func run(_ arguments: [String], environmentOverrides: [String: String] = [:], literalPathspecs: Bool = true, successfulExitCodes: ClosedRange<Int32> = 0...0, cancellation: OperationCancellation? = nil, onOutput: (@Sendable (GitOutputChunk) -> Void)? = nil) throws -> GitResult {
        try cancellation?.check()
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
        process.arguments = (literalPathspecs ? ["--literal-pathspecs"] : ["--no-literal-pathspecs"]) + ["-C", root.path] + arguments
        var environment = ProcessInfo.processInfo.environment
        environment["GIT_TERMINAL_PROMPT"] = "0"
        environment["GIT_PAGER"] = "cat"
        environment["LC_ALL"] = "C"
        environment.merge(GitRuntime.environment(executable: executable)) { _, runtime in runtime }
        environment.merge(environmentOverrides) { _, override in override }
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = output; process.standardError = error
        // Disk-backed streams avoid pipe deadlock with large diffs and command output.
        let status: Int32
        if cancellation != nil || onOutput != nil {
            let outputReader = try FileHandle(forReadingFrom: out), errorReader = try FileHandle(forReadingFrom: err)
            defer { try? outputReader.close(); try? errorReader.close() }
            func read(_ reader: FileHandle, stream: GitOutputChunk.Stream, drain: Bool = false) {
                guard let onOutput else { return }
                repeat {
                    guard let bytes = try? reader.read(upToCount: 64 * 1024), !bytes.isEmpty else { return }
                    onOutput(GitOutputChunk(stream: stream, data: bytes))
                    if !drain { return }
                } while true
            }
            status = try CancellableGitProcess.run(executable: executable, arguments: process.arguments ?? [], environment: environment, output: output.fileDescriptor, error: error.fileDescriptor, cancellation: cancellation ?? OperationCancellation(), pollOutput: { read(outputReader, stream: .stdout); read(errorReader, stream: .stderr) })
            read(outputReader, stream: .stdout, drain: true); read(errorReader, stream: .stderr, drain: true)
        } else {
            try process.run(); process.waitUntilExit(); status = process.terminationStatus
        }
        let result = GitResult(exitCode: status, stdout: try Data(contentsOf: out), stderr: try Data(contentsOf: err))
        if cancellation?.isCancelled == true { throw GitCommandCancellationFailure(result: result) }
        guard successfulExitCodes.contains(status) else {
            throw GitFailure(arguments: arguments, code: status, message: result.text)
        }
        return result
    }
    public func discoverRoot() throws -> URL {
        let result: GitResult
        do { result = try run(["rev-parse", "--show-toplevel"]) }
        catch let original as GitFailure {
            guard (try? isBare()) == true else { throw original }
            result = try run(["rev-parse", "--absolute-git-dir"])
        }
        // Only remove Git's final LF: spaces and embedded newlines can be part of a path.
        var bytes = result.stdout
        if bytes.last == 10 { bytes.removeLast() }
        // FinderRequest and GitRepository normalize file URLs. Git can report
        // /private/tmp while Foundation spells that same root /tmp on macOS.
        return URL(fileURLWithPath: String(decoding: bytes, as: UTF8.self), isDirectory: true).standardizedFileURL
    }
    public func isBare() throws -> Bool { try run(["rev-parse", "--is-bare-repository"]).text.trimmingCharacters(in: .newlines) == "true" }
    public func status(refreshIndex: Bool = true) throws -> [StatusEntry] { StatusEntry.parse(try run(["status", "--porcelain=v1", "-z", "--untracked-files=all", "--ignored"], environmentOverrides: refreshIndex ? [:] : ["GIT_OPTIONAL_LOCKS": "0"]).stdout) }
    public func trackedPaths() throws -> [String] {
        try run(["ls-files", "-z"]).stdout.split(separator: 0).map { String(decoding: $0, as: UTF8.self) }
    }
    public func branch() throws -> String { try run(["branch", "--show-current"]).text.trimmingCharacters(in: .newlines) }
    public func log() throws -> [LogEntry] {
        try history()
    }

    public func diff(path: String? = nil, staged: Bool = false) throws -> String {
        try diff(paths: path.map { [$0] } ?? [], staged: staged)
    }
    public func diff(paths: [String], staged: Bool = false) throws -> String {
        var args = ["diff", "--no-ext-diff", "--no-color"]
        if staged { args.append("--cached") }
        args.append("--")
        args += paths
        return try run(args).text
    }
    public func stage(_ paths: [String], cancellation: OperationCancellation? = nil) throws { try cancellation?.check(); if !paths.isEmpty { _ = try run(["add", "--"] + paths, cancellation: cancellation) } }
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
        let messageFile = try makeCommitMessageFile(message); defer { messageFile.remove() }
        return try run(["commit", "-F", messageFile.url.path]).text
    }
}
