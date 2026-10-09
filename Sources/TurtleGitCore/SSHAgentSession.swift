// SPDX-License-Identifier: GPL-2.0-or-later
import Foundation
import Darwin

public enum SSHAgentFailure: LocalizedError {
    case runtimeMissing, askpassMissing, passphrase, socketPath, startup(String), closed, command(Int32, String), key
    public var errorDescription: String? {
        switch self {
        case .runtimeMissing: return "The App Store build requires bundled OpenSSH agent helpers."
        case .askpassMissing: return "The SSH passphrase helper is missing."
        case .passphrase: return "The SSH passphrase must be valid single-line text shorter than 64 KiB."
        case .socketPath: return "The private SSH agent socket path is too long."
        case .startup(let details): return "The private SSH agent could not start. " + details
        case .closed: return "The private SSH agent session is closed."
        case .command(let code, let details): return "SSH agent command failed (\(code)).\n" + details
        case .key: return "Choose an absolute private key file path."
        }
    }
}
public struct SSHAgentRuntime: Sendable {
    public let agent: URL
    public let add: URL
    public let askpass: URL?
    public init(agent: URL, add: URL, askpass: URL? = nil) { self.agent = agent; self.add = add; self.askpass = askpass }
    public static func resolve(bundle: Bundle = .main, appStore: Bool = GitRuntime.isAppStoreBuild) throws -> Self {
        let bin = bundle.bundleURL.appendingPathComponent("Contents/Helpers/OpenSSH/bin")
        let helper = bundle.bundleURL.appendingPathComponent("Contents/Helpers/SSHAskpass/TurtleGitSSHAskpass")
        let askpass = FileManager.default.isExecutableFile(atPath: helper.path) ? helper : nil
        let runtime = Self(agent: bin.appendingPathComponent("ssh-agent"), add: bin.appendingPathComponent("ssh-add"), askpass: askpass)
        if [runtime.agent, runtime.add].allSatisfy({ FileManager.default.isExecutableFile(atPath: $0.path) }) { return runtime }
        guard !appStore else { throw SSHAgentFailure.runtimeMissing }
        return Self(agent: URL(fileURLWithPath: "/usr/bin/ssh-agent"), add: URL(fileURLWithPath: "/usr/bin/ssh-add"), askpass: askpass)
    }
}
/// Preparatory transport primitive for the Pageant port. A session owns a
/// foreground agent process group and a private socket. It never modifies the
/// user's login agent. Callers must hold key security-scope leases while loading.
/// Serialize use on the repository actor; close can interrupt a running add.
public final class SSHAgentSession: @unchecked Sendable {
    private let runtime: SSHAgentRuntime
    public let directory: URL
    public let socket: URL
    public var environment: [String: String] { ["SSH_AUTH_SOCK": socket.path] }
    private let lifetime = OperationCancellation()
    private final class State: @unchecked Sendable {
        let lock = NSLock()
        let finished = DispatchSemaphore(value: 0)
        var result: Result<Int32, Error>?
        var started = false
        var invalidated = false
        var operation: OperationCancellation?
        var operationFinished: DispatchSemaphore?
    }
    private let state = State()

    public init(runtime: SSHAgentRuntime, temporaryRoot: URL = FileManager.default.temporaryDirectory, cancellation: OperationCancellation? = nil) throws {
        try cancellation?.check(); self.runtime = runtime
        // Short names keep sockaddr_un's macOS 104-byte path limit usable inside
        // ordinary app-container temporary directories.
        let templatePath = temporaryRoot.appendingPathComponent("tg-agent-XXXXXX").path
        guard temporaryRoot.isFileURL, templatePath.utf8.count + 2 < 104 else { throw SSHAgentFailure.socketPath }
        var template = Array(templatePath.utf8CString)
        let createdPath = try template.withUnsafeMutableBufferPointer { buffer -> String in
            guard let created = mkdtemp(buffer.baseAddress!) else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
            return String(cString: created)
        }
        directory = URL(fileURLWithPath: createdPath, isDirectory: true)
        socket = directory.appendingPathComponent("s")
        let output = directory.appendingPathComponent("agent.out"), error = directory.appendingPathComponent("agent.err")
        FileManager.default.createFile(atPath: output.path, contents: nil); FileManager.default.createFile(atPath: error.path, contents: nil)
        do {
            let out = try FileHandle(forWritingTo: output), err = try FileHandle(forWritingTo: error)
            let executable = runtime.agent, arguments = ["-D", "-a", socket.path], token = lifetime, state = self.state
            var environment = ProcessInfo.processInfo.environment; environment.removeValue(forKey: "SSH_AUTH_SOCK"); environment.removeValue(forKey: "SSH_AGENT_PID")
            let capturedEnvironment = environment
            state.started = true
            DispatchQueue.global(qos: .utility).async {
                let value = Result { try CancellableGitProcess.run(executable: executable, arguments: arguments, environment: capturedEnvironment, output: out.fileDescriptor, error: err.fileDescriptor, cancellation: token) }
                try? out.close(); try? err.close(); state.lock.lock(); state.result = value; state.lock.unlock(); state.finished.signal()
            }
            for _ in 0..<500 {
                try cancellation?.check()
                state.lock.lock(); let result = state.result; state.lock.unlock()
                if result != nil { throw SSHAgentFailure.startup((try? String(contentsOf: error, encoding: .utf8)) ?? "") }
                if FileManager.default.fileExists(atPath: socket.path) { return }
                Thread.sleep(forTimeInterval: 0.01)
            }
            throw SSHAgentFailure.startup("Timed out waiting for its socket.")
        } catch { close(); throw error }
    }
    /// A supplied passphrase uses a private, one-use helper channel. Native
    /// prompting/Keychain integration remains pending. Without a response, an
    /// encrypted key fails without terminal interaction. Earlier keys remain.
    public func add(keys: [URL], passphrase: String? = nil, cancellation: OperationCancellation? = nil) throws {
        for key in keys {
            guard key.isFileURL, key.path.hasPrefix("/"), !key.path.utf8.contains(0) else { throw SSHAgentFailure.key }
        }
        for key in keys { _ = try command([key.path], passphrase: passphrase, cancellation: cancellation) }
    }
    public func publicIdentities(cancellation: OperationCancellation? = nil) throws -> String {
        try command(["-L"], successfulExitCodes: 0...1, cancellation: cancellation)
    }
    private func command(_ arguments: [String], passphrase: String? = nil, successfulExitCodes: ClosedRange<Int32> = 0...0, cancellation: OperationCancellation?) throws -> String {
        try cancellation?.check()
        let request = OperationCancellation()
        let operationFinished = DispatchSemaphore(value: 0)
        state.lock.lock()
        guard !state.invalidated, state.result == nil, state.operation == nil else { state.lock.unlock(); throw SSHAgentFailure.closed }
        state.operation = request; state.operationFinished = operationFinished; state.lock.unlock()
        defer { state.lock.lock(); if state.operation === request { state.operation = nil; state.operationFinished = nil }; state.lock.unlock(); operationFinished.signal() }
        let outURL = directory.appendingPathComponent("command-" + UUID().uuidString), errURL = directory.appendingPathComponent("command-error-" + UUID().uuidString)
        FileManager.default.createFile(atPath: outURL.path, contents: nil); FileManager.default.createFile(atPath: errURL.path, contents: nil)
        defer { try? FileManager.default.removeItem(at: outURL); try? FileManager.default.removeItem(at: errURL) }
        let out = try FileHandle(forWritingTo: outURL), err = try FileHandle(forWritingTo: errURL); defer { try? out.close(); try? err.close() }
        var environment = ProcessInfo.processInfo.environment; environment.merge(self.environment) { _, value in value }; environment.removeValue(forKey: "SSH_AGENT_PID")
        environment["SSH_ASKPASS_REQUIRE"] = "force"; environment["SSH_ASKPASS"] = "/usr/bin/false"; environment["DISPLAY"] = "TurtleGit-headless"
        environment.removeValue(forKey: "TURTLEGIT_SSH_CREDENTIAL_FILE")
        environment["LC_ALL"] = "C" // Stable loader diagnostics for native passphrase decisions.
        var credentialFile: URL?
        defer { if let credentialFile { try? FileManager.default.removeItem(at: credentialFile) } }
        if let passphrase {
            let bytes = Data(passphrase.utf8), magic = Data("TurtleGitSSHAskpass\0".utf8)
            guard !bytes.contains(0), !bytes.contains(10), !bytes.contains(13), bytes.count + magic.count <= 65_536 else { throw SSHAgentFailure.passphrase }
            guard let helper = runtime.askpass, FileManager.default.isExecutableFile(atPath: helper.path) else { throw SSHAgentFailure.askpassMissing }
            let file = directory.appendingPathComponent("credential-" + UUID().uuidString)
            let descriptor = open(file.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
            guard descriptor >= 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
            credentialFile = file
            guard fchmod(descriptor, 0o600) == 0 else { let code = errno; Darwin.close(descriptor); throw NSError(domain: NSPOSIXErrorDomain, code: Int(code)) }
            let writer = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
            do { try writer.write(contentsOf: magic + bytes); try writer.close() }
            catch { try? writer.close(); throw error }
            environment["SSH_ASKPASS"] = helper.path; environment["TURTLEGIT_SSH_CREDENTIAL_FILE"] = file.path
        }
        let code = try CancellableGitProcess.run(executable: runtime.add, arguments: arguments, environment: environment, output: out.fileDescriptor, error: err.fileDescriptor, cancellation: request, pollOutput: { if cancellation?.isCancelled == true { request.cancel() } })
        try request.check(); try cancellation?.check()
        guard successfulExitCodes.contains(code) else { throw SSHAgentFailure.command(code, (try? String(contentsOf: errURL, encoding: .utf8)) ?? "") }
        return String(decoding: try Data(contentsOf: outURL), as: UTF8.self)
    }
    public func close() {
        state.lock.lock(); if state.invalidated { state.lock.unlock(); return }; state.invalidated = true
        let active = state.operation, operationFinished = state.operationFinished, started = state.started; state.lock.unlock()
        active?.cancel(); lifetime.cancel()
        if started { state.finished.wait() }
        operationFinished?.wait()
        try? FileManager.default.removeItem(at: directory)
    }

    deinit { close() }
}
