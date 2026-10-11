// SPDX-License-Identifier: GPL-2.0-or-later
import Foundation

public struct RemoteTag: Hashable, Sendable {
    public let name: GitReferenceName
    public let hash: String
}
public enum RemoteTagFailure: LocalizedError {
    case selection, output
    public var errorDescription: String? {
        switch self { case .selection: return "Choose a remote and one or more valid tags."; case .output: return "Git returned an invalid remote tag record." }
    }
}
public enum RemoteTagConfirmation {
    public static func message(_ names: [GitReferenceName]) -> String {
        names.count == 1 ? "Do you really want to delete \"\(names[0].rawValue)\"?" : "Do you really want to permanently delete the \(names.count) selected refs? It can NOT be recovered!"
    }
}
extension GitRepository {
    public func remoteTags(remote: String, includingPeeled: Bool = false, reversed: Bool = false, cancellation: OperationCancellation? = nil, prepareTransport: SSHTransportPreparation? = nil) async throws -> [RemoteTag] {
        let token = cancellation ?? OperationCancellation(); try token.check()
        guard !remote.isEmpty, !remote.utf8.contains(0) else { throw RemoteTagFailure.selection }
        let session = try await prepareSSHTransport([remote], cancellation: token, preparation: prepareTransport)
        defer { withExtendedLifetime(session) {} }
        let output = try run(["ls-remote", "-t", "--", remote], environmentOverrides: session?.transportEnvironment ?? [:], cancellation: token).stdout
        var result: [RemoteTag] = [], names = Set<GitReferenceName>()
        for line in output.split(separator: 10) {
            try token.check()
            guard let tab = line.firstIndex(of: 9), let hash = String(data: line[..<tab], encoding: .utf8), let reference = String(data: line[line.index(after: tab)...], encoding: .utf8), [40, 64].contains(hash.utf8.count), hash.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else { throw RemoteTagFailure.output }
            guard let short = GitReferenceName.removingPrefix("refs/tags/", from: reference), includingPeeled || !short.hasSuffix("^{}") else { continue }
            let name = GitReferenceName(short); guard !short.isEmpty, !short.utf8.contains(0), names.insert(name).inserted else { throw RemoteTagFailure.output }
            result.append(RemoteTag(name: name, hash: hash))
        }
        return result.sorted { a, b in
            if a.name == b.name { return false }
            let order = a.name.rawValue.localizedStandardCompare(b.name.rawValue)
            let less = order == .orderedSame ? a.name.rawValue.utf8.lexicographicallyPrecedes(b.name.rawValue.utf8) : order == .orderedAscending
            return reversed ? !less : less
        }
    }
    public func deleteRemoteTags(remote: String, tags: [GitReferenceName], cancellation: OperationCancellation? = nil, prepareTransport: SSHTransportPreparation? = nil) async throws {
        let token = cancellation ?? OperationCancellation(); try token.check()
        guard !remote.isEmpty, !remote.utf8.contains(0), !tags.isEmpty, Set(tags).count == tags.count else { throw RemoteTagFailure.selection }
        for tag in tags {
            guard !tag.rawValue.isEmpty, !tag.rawValue.utf8.contains(0) else { throw RemoteTagFailure.selection }
            _ = try run(["check-ref-format", "refs/tags/" + tag.rawValue], cancellation: token)
        }
        let session = try await prepareSSHTransport([remote], cancellation: token, preparation: prepareTransport)
        defer { withExtendedLifetime(session) {} }
        _ = try run(["-c", "core.precomposeunicode=false", "push", "--", remote] + tags.map { ":refs/tags/" + $0.rawValue }, environmentOverrides: session?.transportEnvironment ?? [:], cancellation: token)
    }
}
