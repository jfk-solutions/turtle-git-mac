// SPDX-License-Identifier: GPL-2.0-or-later
import Foundation

public enum RemoteReferenceChoicesFailure: LocalizedError {
    case output
    public var errorDescription: String? { "Git returned an invalid remote reference record." }
}
public enum RemoteReferenceChoices {
    public static func parse(_ data: Data, includingHead: Bool = false) throws -> [String] {
        var names: [String] = [], seen = Set<Data>()
        for row in data.split(separator: 10) {
            guard let tab = row.firstIndex(of: 9) else { throw RemoteReferenceChoicesFailure.output }
            let hash = row[..<tab], bytes = Data(row[row.index(after: tab)...])
            guard [40,64].contains(hash.count), hash.allSatisfy({ (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0) }),
                  let full = String(data: bytes, encoding: .utf8), full.hasPrefix("refs/") || (includingHead && full == "HEAD"), !bytes.contains(where: { $0 < 33 || $0 == 127 }) else { throw RemoteReferenceChoicesFailure.output }
            if full.hasPrefix("refs/tags/") { continue }
            let name = full.hasPrefix("refs/heads/") ? String(full.dropFirst(11)) : full
            guard !name.isEmpty else { throw RemoteReferenceChoicesFailure.output }
            if seen.insert(Data(name.utf8)).inserted { names.append(name) }
        }
        return names.sorted {
            let order = $0.localizedStandardCompare($1)
            return order == .orderedSame ? $0.utf8.lexicographicallyPrecedes($1.utf8) : order == .orderedAscending
        }
    }
}
extension GitRepository {
    /// Source libgit2 includes advertised HEAD; the CLI branch uses --refs.
    public func remoteReferenceChoices(remote: String, cancellation: OperationCancellation? = nil, prepareTransport: SSHTransportPreparation? = nil, backend: GitLibGit2Configuration? = nil) async throws -> [String] {
        let backend = backend ?? libgit2Configuration ?? .load()
        let token = cancellation ?? OperationCancellation(); try token.check()
        guard !remote.isEmpty, !remote.utf8.contains(0) else { throw FetchFailure.remote }
        let executor = try backend.executor(for: .fetch)
        let session = try await prepareSSHTransport([remote], cancellation: token, preparation: prepareTransport)
        defer { withExtendedLifetime(session) {} }
        let arguments = ["ls-remote"] + (executor == nil ? ["--refs"] : []) + ["--", remote]
        return try RemoteReferenceChoices.parse(run(arguments, environmentOverrides: session?.transportEnvironment ?? [:], cancellation: token, executorOverride: executor).stdout, includingHead: executor != nil)
    }
}
