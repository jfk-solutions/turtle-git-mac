import Foundation
import Darwin

/// A cancellable child owns a new process group from the moment it is spawned.
/// Cancellation targets that group while its leader PID is still unreaped, so
/// helper children stop too and the numeric ID cannot be reused by another job.
enum CancellableGitProcess {
    static func run(executable: URL, arguments: [String], argumentBytes: [Int: Data] = [:], environment: [String: String], output: Int32, error: Int32, input: Int32? = nil, cancellation: OperationCancellation? = nil, pollOutput: (() -> Void)? = nil, terminateDescendantsOnExit: Bool = false, workingDirectory: URL? = nil, didStart: (() -> Void)? = nil, cancellationReady: (() -> Bool)? = nil) throws -> Int32 {
        try cancellation?.check()
        guard argumentBytes.keys.allSatisfy(arguments.indices.contains) else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(EINVAL))
        }
        func check(_ code: Int32) throws {
            guard code == 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(code)) }
        }
        // A GUI host may have closed a standard descriptor. Keep our spawn
        // sources above 2 so remapping stdin/stdout/stderr cannot clobber them.
        let outputCopy = fcntl(output, F_DUPFD_CLOEXEC, 3)
        guard outputCopy >= 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        defer { close(outputCopy) }
        let errorCopy = fcntl(error, F_DUPFD_CLOEXEC, 3)
        guard errorCopy >= 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        defer { close(errorCopy) }
        let inputCopy=input.map { fcntl($0,F_DUPFD_CLOEXEC,3) }
        if let inputCopy, inputCopy < 0 { throw NSError(domain:NSPOSIXErrorDomain,code:Int(errno)) }
        defer { if let inputCopy { close(inputCopy) } }
        func strings<T>(_ values: [Data], _ body: (UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>) throws -> T) throws -> T {
            guard values.allSatisfy({ !$0.contains(0) }) else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(EINVAL)) }
            var pointers: [UnsafeMutablePointer<CChar>?] = values.map { value in
                guard let pointer = malloc(value.count + 1)?.assumingMemoryBound(to: CChar.self) else { return nil }
                value.withUnsafeBytes { bytes in
                    if let base = bytes.baseAddress { memcpy(pointer, base, value.count) }
                }
                pointer[value.count] = 0
                return pointer
            }
            defer { for pointer in pointers { free(pointer) } }
            guard pointers.allSatisfy({ $0 != nil }) else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(ENOMEM)) }
            pointers.append(nil)
            return try pointers.withUnsafeMutableBufferPointer { try body($0.baseAddress!) }
        }
        var actions: posix_spawn_file_actions_t?
        var attributes: posix_spawnattr_t?
        try check(posix_spawn_file_actions_init(&actions))
        defer { posix_spawn_file_actions_destroy(&actions) }
        try check(posix_spawnattr_init(&attributes))
        defer { posix_spawnattr_destroy(&attributes) }
        if let workingDirectory { try check(posix_spawn_file_actions_addchdir_np(&actions, workingDirectory.path)) }
        if let inputCopy { try check(posix_spawn_file_actions_adddup2(&actions,inputCopy,STDIN_FILENO)) }
        else { try check(posix_spawn_file_actions_addopen(&actions, STDIN_FILENO, "/dev/null", O_RDONLY, 0)) }
        try check(posix_spawn_file_actions_adddup2(&actions, outputCopy, STDOUT_FILENO))
        try check(posix_spawn_file_actions_adddup2(&actions, errorCopy, STDERR_FILENO))
        try check(posix_spawnattr_setpgroup(&attributes, 0))
        var mask = sigset_t(), defaults = sigset_t()
        sigemptyset(&mask); sigemptyset(&defaults)
        for signal in [SIGINT, SIGTERM, SIGQUIT, SIGHUP, SIGPIPE] { sigaddset(&defaults, signal) }
        try check(posix_spawnattr_setsigmask(&attributes, &mask))
        try check(posix_spawnattr_setsigdefault(&attributes, &defaults))
        let flags = Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_CLOEXEC_DEFAULT)
        try check(posix_spawnattr_setflags(&attributes, flags))
        var pid: pid_t = 0
        let argvBytes = [Data(executable.path.utf8)] + arguments.enumerated().map { argumentBytes[$0.offset] ?? Data($0.element.utf8) }
        try strings(argvBytes) { argv in
            try strings(environment.keys.sorted().map { Data(($0 + "=" + environment[$0]!).utf8) }) { env in
                try cancellation?.check()
                try check(posix_spawn(&pid, executable.path, &actions, &attributes, argv, env))
            }
        }
        didStart?()
        var status: Int32 = 0
        func exitCode() -> Int32 { status & 0x7f == 0 ? (status >> 8) & 0xff : 128 + (status & 0x7f) }
        // Ordinary commands block on their own PID without a Foundation run-loop
        // termination notification. Preserve Process.terminationStatus for signals.
        if cancellation == nil && pollOutput == nil && !terminateDescendantsOnExit {
            while waitpid(pid, &status, 0) < 0 {
                if errno != EINTR { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
            }
            return status & 0x7f == 0 ? (status >> 8) & 0xff : status & 0x7f
        }
        while true {
            pollOutput?()
            if cancellation?.isCancelled == true {
                if cancellationReady?() == false { usleep(10_000); continue }
                // Give Git a brief chance to handle interruption, then enforce
                // termination like upstream's Ctrl-C plus KillProcessTree.
                // Do not reap the leader before the final group signal.
                kill(-pid, SIGINT); usleep(100_000)
                kill(-pid, SIGTERM); usleep(100_000)
                kill(-pid, SIGKILL)
                while waitpid(pid, &status, 0) < 0 {
                    if errno != EINTR { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
                }
                return exitCode()
            }
            if terminateDescendantsOnExit {
                // Observe an exited leader without reaping it. Its PID still
                // reserves the group ID while remaining workers are killed.
                var info = siginfo_t()
                let observed = waitid(P_PID, id_t(pid), &info, WEXITED | WNOHANG | WNOWAIT)
                if observed < 0 && errno != EINTR { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
                if observed == 0 && info.si_pid == pid {
                    kill(-pid, SIGKILL)
                    while waitpid(pid, &status, 0) < 0 {
                        if errno != EINTR { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
                    }
                    return exitCode()
                }
                usleep(10_000); continue
            }
            let waited = waitpid(pid, &status, WNOHANG)
            if waited == pid { return exitCode() }
            if waited < 0, errno != EINTR { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
            usleep(10_000)
        }
    }
}

public struct GitCommandCancellationFailure: LocalizedError, Sendable {
    public let result:GitResult
    public let outputWasDelivered:Bool
    public init(result:GitResult,outputWasDelivered:Bool=false) {self.result=result;self.outputWasDelivered=outputWasDelivered}
    public var errorDescription:String? {"Operation cancelled."}
    public func markingOutputDelivered()->Self {.init(result:result,outputWasDelivered:true)}
}

/// Shell-free external comparison tool. Start reports a successful spawn; completion
/// reports the real status after reaping the owned child. Cancellation stops its group.
public final class ExternalToolExecution: @unchecked Sendable {
    public let cancellation: OperationCancellation
    public let completion: Task<Int32, Error>
    private let gate: ExternalToolLaunchGate
    private let state: ExternalToolCompletionState
    private init(executable: URL, arguments: [String], directory: URL, cancellation: OperationCancellation) {
        self.cancellation = cancellation
        let gate = ExternalToolLaunchGate(); self.gate = gate
        let state = ExternalToolCompletionState(); self.state = state
        completion = Task.detached {
            defer { state.finish() }
            do {
                let output = try FileHandle(forWritingTo: URL(fileURLWithPath: "/dev/null"))
                defer { try? output.close() }
                let status = try CancellableGitProcess.run(executable: executable, arguments: arguments,
                    environment: ProcessInfo.processInfo.environment, output: output.fileDescriptor, error: output.fileDescriptor,
                    cancellation: cancellation, workingDirectory: directory, didStart: { gate.complete(.success(())) })
                try cancellation.check()
                return status
            } catch { gate.complete(.failure(error)); throw error }
        }
    }
    public static func start(executable: URL, arguments: [String], directory: URL, cancellation: OperationCancellation = OperationCancellation()) async throws -> ExternalToolExecution {
        let execution = ExternalToolExecution(executable: executable, arguments: arguments, directory: directory, cancellation: cancellation)
        do { try await execution.gate.wait(); return execution }
        catch { execution.cancel(); _ = try? await execution.completion.value; throw error }
    }
    public func cancel() { if !state.isFinished { cancellation.cancel() } }
    deinit { cancel() }
}
private final class ExternalToolLaunchGate: @unchecked Sendable {
    private let lock = NSLock()
    private var result: Result<Void, Error>?
    private var waiter: CheckedContinuation<Void, Error>?
    func complete(_ value: Result<Void, Error>) {
        lock.lock()
        guard result == nil else { lock.unlock(); return }
        result = value; let waiter = waiter; self.waiter = nil; lock.unlock()
        waiter?.resume(with: value)
    }
    func wait() async throws {
        try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            if let result { lock.unlock(); continuation.resume(with: result) }
            else { waiter = continuation; lock.unlock() }
        }
    }
}
private final class ExternalToolCompletionState: @unchecked Sendable {
    private let lock = NSLock()
    private var finished = false
    func finish() { lock.lock(); finished = true; lock.unlock() }
    var isFinished: Bool { lock.lock(); defer { lock.unlock() }; return finished }
}
