import Foundation

public struct CommitPreferences: Sendable {
    public let staging: Bool
    public let showPatch: Bool
}

extension GitRepository {
    public func commitPreferences(cancellation: OperationCancellation? = nil) throws -> CommitPreferences {
        try cancellation?.check()
        func value(_ key: String) -> Bool {
            (try? run(["config", "--bool", "--get", key], cancellation: cancellation).text.trimmingCharacters(in: .newlines)) == "true"
        }
        let preferences = CommitPreferences(staging: value("tgit.commitstagingsupport"), showPatch: value("tgit.commitshowpatch"))
        try cancellation?.check()
        return preferences
    }
    public func saveCommitPreferences(staging: Bool? = nil, showPatch: Bool? = nil) throws {
        if let staging { _ = try run(["config", "--local", "tgit.commitstagingsupport", staging ? "true" : "false"]) }
        if let showPatch { _ = try run(["config", "--local", "tgit.commitshowpatch", showPatch ? "true" : "false"]) }
    }
}
