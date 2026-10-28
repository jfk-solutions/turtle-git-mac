// SPDX-License-Identifier: GPL-2.0-or-later
import Foundation
import Darwin

public struct GitDaemonConfiguration: Equatable, Sendable {
    public var listenAddresses: [String] = []
    public var port: UInt16 = 9418
    public init() {}
    public func arguments(root: URL) throws -> [String] {
        guard root.isFileURL, !root.path.contains("\0"), port != 0 else { throw GitDaemonFailure.configuration }
        for address in listenAddresses {
            var v4 = in_addr(), v6 = in6_addr()
            guard inet_pton(AF_INET, address, &v4) == 1 || inet_pton(AF_INET6, address, &v6) == 1 else { throw GitDaemonFailure.configuration }
        }
        return ["daemon", "--verbose", "--export-all", "--base-path=" + root.path]
            + (port == 9418 ? [] : ["--port=\(port)"]) + listenAddresses.map { "--listen=" + $0 }
    }
    public func urls(addresses: [String] = GitDaemon.networkAddresses()) -> [String] {
        let hosts = listenAddresses.isEmpty ? (addresses.isEmpty ? ["localhost"] : addresses) : listenAddresses
        return hosts.map { "git://" + ($0.contains(":") ? "[" + $0 + "]" : $0) + (port == 9418 ? "" : ":\(port)") + "/" }
    }
}
public enum GitDaemonFailure: LocalizedError {
    case configuration, failed(Int32, String)
    public var errorDescription: String? {
        switch self {
        case .configuration: return "Choose a valid repository, numeric listen address and nonzero Git daemon port."
        case .failed(let code, let output): return "Git daemon exited with status \(code).\n" + output
        }
    }
}
public enum GitDaemon {
    /// Native counterpart of the source's host-address discovery, without DNS
    /// blocking the main thread. IPv6 zone IDs are omitted in the displayed URL.
    public static func networkAddresses() -> [String] {
        var interfaces: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&interfaces) == 0 else { return [] }
        defer { freeifaddrs(interfaces) }
        var cursor = interfaces, addresses = Set<String>()
        while let entry = cursor {
            defer { cursor = entry.pointee.ifa_next }
            guard let address = entry.pointee.ifa_addr,
                  entry.pointee.ifa_flags & UInt32(IFF_UP) != 0,
                  [AF_INET, AF_INET6].contains(Int32(address.pointee.sa_family)) else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(address, socklen_t(address.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 {
                addresses.insert(String(cString: host).components(separatedBy: "%")[0])
            }
        }
        return addresses.sorted()
    }
    /// Foreground daemon owns a process group. Pipes are drained throughout its
    /// lifetime; only a bounded diagnostic tail is retained, with no spool files.
    public static func run(repository: GitRepository, configuration: GitDaemonConfiguration = .init(), cancellation: OperationCancellation,
                           onOutput: @escaping @Sendable (GitOutputChunk) -> Void) throws -> Int32 {
        try cancellation.check()
        // Daemon owns a direct Git process rather than GitRepository.run.
        try GitRuntime.prepareForGitReads(cancellation: cancellation)
        let arguments = try configuration.arguments(root: repository.root)
        let stdout = Pipe(), stderr = Pipe()
        defer {
            try? stdout.fileHandleForReading.close(); try? stdout.fileHandleForWriting.close()
            try? stderr.fileHandleForReading.close(); try? stderr.fileHandleForWriting.close()
        }
        for pipe in [stdout, stderr] {
            let fd = pipe.fileHandleForReading.fileDescriptor, flags = fcntl(fd, F_GETFL)
            guard flags >= 0, fcntl(fd, F_SETFL, flags | O_NONBLOCK) == 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        }
        var tail = Data()
        func drain(_ pipe: Pipe, stream: GitOutputChunk.Stream) {
            var buffer = [UInt8](repeating: 0, count: 16 * 1024)
            // Bound each poll so cancellation cannot starve under log flooding.
            for _ in 0..<8 {
                let count = Darwin.read(pipe.fileHandleForReading.fileDescriptor, &buffer, buffer.count)
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { return }
                let data = Data(buffer.prefix(count)); tail.append(data)
                if tail.count > 64 * 1024 { tail.removeFirst(tail.count - 64 * 1024) }
                onOutput(GitOutputChunk(stream: stream, data: data))
            }
        }
        var environment = ProcessInfo.processInfo.environment
        environment["GIT_TERMINAL_PROMPT"] = "0"; environment["LC_ALL"] = "C"
        environment.merge(GitRuntime.environment(executable: repository.executable)) { _, value in value }
        let status = try CancellableGitProcess.run(executable: repository.executable,
            arguments: ["--literal-pathspecs", "-C", repository.root.path] + arguments, environment: environment,
            output: stdout.fileHandleForWriting.fileDescriptor, error: stderr.fileHandleForWriting.fileDescriptor,
            cancellation: cancellation, pollOutput: { drain(stdout, stream: .stdout); drain(stderr, stream: .stderr) }, terminateDescendantsOnExit: true)
        drain(stdout, stream: .stdout); drain(stderr, stream: .stderr)
        if !cancellation.isCancelled && status != 0 { throw GitDaemonFailure.failed(status, String(decoding: tail, as: UTF8.self)) }
        return status
    }
}
