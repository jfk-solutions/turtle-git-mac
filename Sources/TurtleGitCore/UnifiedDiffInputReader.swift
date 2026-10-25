import Foundation
import Darwin

public enum UnifiedDiffInputFailure: LocalizedError {
    case input
    case descriptor(Int32)
    case read(Int32)
    case limit(Int)
    case unsupportedFile
    public var errorDescription: String? {
        switch self {
        case .input: return "Invalid Unified Diff input limit."
        case .descriptor(let code): return "Could not open Unified Diff input: \(String(cString: strerror(code)))"
        case .read(let code): return "Could not read Unified Diff input: \(String(cString: strerror(code)))"
        case .limit(let bytes): return "Unified Diff input exceeds the \(bytes)-byte limit."
        case .unsupportedFile: return "Choose a regular file for Unified Diff."
        }
    }
}

/// Synchronous worker API: dispatch off the main actor. The caller must not
/// concurrently consume the same input stream. Only the duplicated descriptor
/// is owned here; descriptor status flags and the caller's stdin stay unchanged.
public enum UnifiedDiffInputReader {
    public static let maximumBytes = 250 * 1024 * 1024 - 1
    /// Admit the opened object, not a preceding path check. Nonblocking open
    /// prevents an unconnected FIFO from trapping the document worker before
    /// cancellation is possible. Symlinks to regular files remain supported.
    public static func readFile(_ url: URL, maxBytes: Int = maximumBytes,
                                cancellation: OperationCancellation? = nil) throws -> Data {
        try cancellation?.check()
        guard url.isFileURL, !url.path.utf8.contains(0), maxBytes >= 0, maxBytes <= maximumBytes else { throw UnifiedDiffInputFailure.input }
        let owned = open(url.path, O_RDONLY | O_NONBLOCK | O_CLOEXEC)
        guard owned >= 0 else { throw UnifiedDiffInputFailure.descriptor(errno) }
        defer { close(owned) }
        var information = stat()
        guard fstat(owned, &information) == 0 else { throw UnifiedDiffInputFailure.read(errno) }
        guard information.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG) else { throw UnifiedDiffInputFailure.unsupportedFile }
        try cancellation?.check()
        guard information.st_size <= off_t(maxBytes) else { throw UnifiedDiffInputFailure.limit(maxBytes) }
        return try read(descriptor: owned, maxBytes: maxBytes, cancellation: cancellation)
    }
    public static func read(descriptor: Int32 = STDIN_FILENO, maxBytes: Int = maximumBytes,
                            cancellation: OperationCancellation? = nil) throws -> Data {
        try cancellation?.check()
        guard maxBytes >= 0, maxBytes <= maximumBytes else { throw UnifiedDiffInputFailure.input }
        let owned = fcntl(descriptor, F_DUPFD_CLOEXEC, 0)
        guard owned >= 0 else { throw UnifiedDiffInputFailure.descriptor(errno) }
        defer { close(owned) }
        var result = Data(), buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            try cancellation?.check()
            var ready = pollfd(fd: owned, events: Int16(POLLIN), revents: 0)
            let count = poll(&ready, 1, 100)
            if count < 0 {
                if errno == EINTR { continue }
                throw UnifiedDiffInputFailure.read(errno)
            }
            if count == 0 { continue }
            try cancellation?.check()
            if ready.revents & Int16(POLLNVAL) != 0 { throw UnifiedDiffInputFailure.read(EBADF) }
            // Reading once after HUP drains final bytes before observing EOF.
            let available = min(buffer.count, maxBytes - result.count + 1)
            let received = buffer.withUnsafeMutableBytes { Darwin.read(owned, $0.baseAddress, available) }
            if received < 0 {
                if errno == EINTR || errno == EAGAIN { continue }
                throw UnifiedDiffInputFailure.read(errno)
            }
            if received == 0 { try cancellation?.check(); return result }
            guard received <= maxBytes - result.count else { throw UnifiedDiffInputFailure.limit(maxBytes) }
            result.append(contentsOf: buffer.prefix(received))
        }
    }
}
