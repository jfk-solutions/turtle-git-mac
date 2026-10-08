import Foundation
import Darwin

/// A cancellable child owns a new process group from the moment it is spawned.
/// Cancellation targets that group while its leader PID is still unreaped, so
/// helper children stop too and the numeric ID cannot be reused by another job.
enum CancellableGitProcess {
    static func run(executable: URL, arguments: [String], environment: [String: String], output: Int32, error: Int32, cancellation: OperationCancellation, pollOutput: (() -> Void)? = nil) throws -> Int32 {
        try cancellation.check()
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
        func strings<T>(_ values: [String], _ body: (UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>) throws -> T) throws -> T {
            guard values.allSatisfy({ !$0.contains("\0") }) else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(EINVAL)) }
            var pointers = values.map { strdup($0) }
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
        try check(posix_spawn_file_actions_addopen(&actions, STDIN_FILENO, "/dev/null", O_RDONLY, 0))
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
        try strings([executable.path] + arguments) { argv in
            try strings(environment.keys.sorted().map { $0 + "=" + environment[$0]! }) { env in
                try cancellation.check()
                try check(posix_spawn(&pid, executable.path, &actions, &attributes, argv, env))
            }
        }
        var status: Int32 = 0
        func exitCode() -> Int32 { status & 0x7f == 0 ? (status >> 8) & 0xff : 128 + (status & 0x7f) }
        while true {
            pollOutput?()
            if cancellation.isCancelled {
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
            let waited = waitpid(pid, &status, WNOHANG)
            if waited == pid { return exitCode() }
            if waited < 0, errno != EINTR { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
            usleep(10_000)
        }
    }
}

public struct GitCommandCancellationFailure: LocalizedError, Sendable {
    public let result: GitResult
    public var errorDescription: String? { "Operation cancelled." }
}
