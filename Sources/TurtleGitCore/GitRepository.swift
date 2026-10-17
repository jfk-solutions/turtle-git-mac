import Foundation

/// Serializes repository operations off the main actor. Arguments never pass through a shell.
public actor GitRepository {
    public nonisolated let root: URL
    public nonisolated let executable: URL
    public nonisolated let askpass: URL?
    // Synchronous actor-isolated replay scopes cannot interleave repository work.
    // Nested helpers inherit the owned token; explicit caller tokens still win.
    var replayCancellation: OperationCancellation?
    var replayOutput: (@Sendable (GitOutputChunk) -> Void)?
    public nonisolated let diffDetection: GitDiffDetection
    public init(root: URL, executable: URL = URL(fileURLWithPath: "/usr/bin/git"), askpass: URL? = GitAskpassRuntime.bundled(), diffDetection: GitDiffDetection = .load()) {
        self.root = root.standardizedFileURL; self.executable = executable; self.askpass = askpass; self.diffDetection = diffDetection
    }
    /// With retainStandardOutput false, stdout is delivered only through onOutput;
    /// stderr and exit/cancellation diagnostics remain in the returned result.
    public func run(_ arguments: [String], environmentOverrides: [String: String] = [:], literalPathspecs: Bool = true, successfulExitCodes: ClosedRange<Int32> = 0...0, cancellation: OperationCancellation? = nil, input: Data? = nil, retainStandardOutput: Bool = true, consumeOutput: ((GitOutputChunk) throws -> Void)? = nil, onOutput: (@Sendable (GitOutputChunk) -> Void)? = nil) throws -> GitResult {
        let cancellation = cancellation ?? replayCancellation
        let onOutput = onOutput ?? replayCommandOutput(arguments)
        try cancellation?.check()
        let temporary = try TurtleGitTemporaryStorage.root.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let out = temporary.appendingPathComponent("stdout"), err = temporary.appendingPathComponent("stderr")
        FileManager.default.createFile(atPath: out.path, contents: nil)
        FileManager.default.createFile(atPath: err.path, contents: nil)
        let output = try FileHandle(forWritingTo: out), error = try FileHandle(forWritingTo: err)
        defer { try? output.close(); try? error.close() }
        let commandArguments = (literalPathspecs ? ["--literal-pathspecs"] : ["--no-literal-pathspecs"]) + ["-C", root.path] + arguments
        var inputReader:FileHandle?
        if let input {
            let file=temporary.appendingPathComponent("stdin")
            guard FileManager.default.createFile(atPath:file.path,contents:input,attributes:[.posixPermissions:0o600]) else { throw NSError(domain:NSPOSIXErrorDomain,code:Int(EIO)) }
            inputReader=try FileHandle(forReadingFrom:file)
        }
        defer { try? inputReader?.close() }
        var environment = ProcessInfo.processInfo.environment
        environment["GIT_TERMINAL_PROMPT"] = "0"
        environment["GIT_PAGER"] = "cat"
        environment["LC_ALL"] = "C"
        environment.merge(GitRuntime.environment(executable: executable)) { _, runtime in runtime }
        environment.merge(SSHClientPreferences.load().environment(existing: environment)) { _, selected in selected }
        environment.merge(environmentOverrides) { _, override in override }
        let sshPrompt = GitAskpassRuntime.sshEnvironment(arguments: arguments, environment: environment, helper: askpass)
        environment.merge(sshPrompt) { _, selected in selected }
        if !sshPrompt.isEmpty { environment["TURTLEGIT_ASKPASS_APPEARANCE"] = UserDefaults.standard.string(forKey: "appearance") ?? "system" }
        if GitAskpassRuntime.shouldInstall(arguments: arguments, environment: environment, helper: askpass), let askpass {
            // Preserve explicit core.askPass, including an explicitly empty value.
            let configured = try run(["config", "--get", "core.askPass"], environmentOverrides: environmentOverrides, successfulExitCodes: 0...1, cancellation: cancellation)
            if configured.exitCode == 1 {
                environment["GIT_ASKPASS"] = GitAskpassRuntime.command(askpass)
                environment["TURTLEGIT_ASKPASS_APPEARANCE"] = UserDefaults.standard.string(forKey: "appearance") ?? "system"
            }
        }
        if arguments.prefix(while: { $0 != "--" }).contains("svn"), let askpass,
           environment["GIT_ASKPASS"] == GitAskpassRuntime.command(askpass), environment["TURTLEGIT_DISABLE_ASKPASS"] != "1" {
            let certificates = temporary.appendingPathComponent("svn-certificates", isDirectory: true)
            try FileManager.default.createDirectory(at: certificates, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            environment["TURTLEGIT_SVN_NATIVE_PROMPTS"] = "1"
            environment["TURTLEGIT_SVN_CERT_DIRECTORY"] = certificates.path
        } else {
            environment.removeValue(forKey: "TURTLEGIT_SVN_NATIVE_PROMPTS"); environment.removeValue(forKey: "TURTLEGIT_SVN_CERT_DIRECTORY")
        }
        // Disk-backed streams avoid pipe deadlock with large diffs and command output.
        let status: Int32
        if cancellation != nil || onOutput != nil || consumeOutput != nil {
            let outputReader = try FileHandle(forReadingFrom: out), errorReader = try FileHandle(forReadingFrom: err)
            defer { try? outputReader.close(); try? errorReader.close() }
            // Synchronous consumers run on this repository actor, so bounded
            // history metadata reads cannot interleave unrelated mutations.
            var consumerError:Error?
            let processCancellation = consumeOutput == nil ? (cancellation ?? OperationCancellation()) : OperationCancellation()
            func read(_ reader: FileHandle, stream: GitOutputChunk.Stream, drain: Bool = false) {
                guard consumerError==nil,onOutput != nil || consumeOutput != nil else { return }
                repeat {
                    let bytes = (try? reader.read(upToCount:64 * 1024)) ?? Data()
                    if bytes.isEmpty {
                        // A walk may remain live after producing a short prefix.
                        // Let the synchronous consumer flush it during idle polls.
                        if !drain,case .stdout=stream {
                            do { try consumeOutput?(GitOutputChunk(stream:stream,data:Data())) }
                            catch { consumerError=error;processCancellation.cancel() }
                        }
                        return
                    }
                    let chunk=GitOutputChunk(stream:stream,data:bytes)
                    do { try consumeOutput?(chunk) }
                    catch { consumerError=error;processCancellation.cancel();return }
                    onOutput?(chunk)
                    if !drain { return }
                } while true
            }
            status = try CancellableGitProcess.run(executable: executable, arguments: commandArguments, environment: environment, output: output.fileDescriptor, error: error.fileDescriptor, input:inputReader?.fileDescriptor, cancellation: processCancellation, pollOutput: {
                if cancellation?.isCancelled==true { processCancellation.cancel() }
                read(outputReader, stream:.stdout);read(errorReader, stream:.stderr)
            })
            read(outputReader, stream: .stdout, drain: true); read(errorReader, stream: .stderr, drain: true)
            if let consumerError { throw consumerError }
        } else {
            status = try CancellableGitProcess.run(executable: executable, arguments: commandArguments, environment: environment, output: output.fileDescriptor, error: error.fileDescriptor,input:inputReader?.fileDescriptor)
        }
        let result = GitResult(exitCode: status, stdout: retainStandardOutput ? try Data(contentsOf: out) : Data(), stderr: try Data(contentsOf: err))
        if cancellation?.isCancelled == true { throw GitCommandCancellationFailure(result: result) }
        guard successfulExitCodes.contains(status) else {
            throw GitFailure(arguments: arguments, code: status, message: result.text)
        }
        return result
    }
    public func discoverRoot(cancellation:OperationCancellation? = nil) throws -> URL {
        let result: GitResult
        do { result = try run(["rev-parse", "--show-toplevel"],cancellation:cancellation) }
        catch let original as GitFailure {
            try cancellation?.check()
            guard (try? isBare(cancellation:cancellation)) == true else { try cancellation?.check();throw original }
            result = try run(["rev-parse", "--absolute-git-dir"],cancellation:cancellation)
        }
        // Only remove Git's final LF: spaces and embedded newlines can be part of a path.
        var bytes = result.stdout
        if bytes.last == 10 { bytes.removeLast() }
        // FinderRequest and GitRepository normalize file URLs. Git can report
        // /private/tmp while Foundation spells that same root /tmp on macOS.
        return URL(fileURLWithPath: String(decoding: bytes, as: UTF8.self), isDirectory: true).standardizedFileURL
    }
    public func isBare(cancellation: OperationCancellation? = nil) throws -> Bool { try run(["rev-parse", "--is-bare-repository"], cancellation: cancellation).text.trimmingCharacters(in: .newlines) == "true" }
    public func status(refreshIndex: Bool = true, cancellation: OperationCancellation? = nil) throws -> [StatusEntry] { StatusEntry.parse(try run(["status", "--porcelain=v1", "-z", "--untracked-files=all", "--ignored", diffDetection.statusArgument], environmentOverrides: refreshIndex ? [:] : ["GIT_OPTIONAL_LOCKS": "0"], cancellation: cancellation).stdout) }
    public func trackedPaths(cancellation:OperationCancellation? = nil) throws -> [String] {
        try run(["ls-files", "-z"],cancellation:cancellation).stdout.split(separator: 0).map { String(decoding: $0, as: UTF8.self) }
    }
    public func branch(cancellation: OperationCancellation? = nil) throws -> String { try run(["branch", "--show-current"], cancellation: cancellation).text.trimmingCharacters(in: .newlines) }
    public func log() throws -> [LogEntry] {
        try history()
    }

    public func diff(path: String? = nil, staged: Bool = false) throws -> String {
        try diff(paths: path.map { [$0] } ?? [], staged: staged)
    }
    public func diff(paths: [String], staged: Bool = false) throws -> String {
        var args = ["-c","core.precomposeunicode=false","diff", "--no-ext-diff", "--no-color"]
        if staged { args.append("--cached") }
        args.append("--")
        args += paths
        return try run(args).text
    }
    public func stage(_ paths: [String], cancellation: OperationCancellation? = nil) throws {
        try cancellation?.check(); guard !paths.isEmpty else { return }
        _ = try run(["add","--pathspec-from-file=-","--pathspec-file-nul"],cancellation:cancellation,input:literalPathPacket(paths))
    }
    func literalPathPacket(_ paths:[String]) throws -> Data {
        guard paths.allSatisfy({ !$0.isEmpty && !$0.utf8.contains(0) }) else { throw RevisionComparisonFailure.selection }
        return Data(paths.flatMap { Array($0.utf8) + [0] })
    }
    public func unstage(_ paths: [String], cancellation: OperationCancellation? = nil) throws {
        try cancellation?.check()
        guard !paths.isEmpty else { return }
        let head = try run(["rev-parse", "--verify", "HEAD"], successfulExitCodes: 0...128, cancellation: cancellation)
        try cancellation?.check()
        if head.exitCode == 0 {
            _ = try run(["restore","--staged","--pathspec-from-file=-","--pathspec-file-nul"],cancellation:cancellation,input:literalPathPacket(paths))
        } else { _ = try run(["rm","-f","--cached","--pathspec-from-file=-","--pathspec-file-nul"],cancellation:cancellation,input:literalPathPacket(paths)) }
    }
    public func commit(message: String) throws -> String {
        guard !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw GitFailure(arguments: ["commit"], code: 1, message: "Enter a commit message.")
        }
        let messageFile = try makeCommitMessageFile(message); defer { messageFile.remove() }
        return try run(["commit", "-F", messageFile.url.path]).text
    }
}
