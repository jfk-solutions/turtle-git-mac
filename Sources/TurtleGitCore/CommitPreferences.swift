import Foundation

public struct CommitPreferences: Sendable {
    public let staging: Bool
    public let showPatch: Bool
}

extension GitRepository {
    public func commitPreferences(cancellation: OperationCancellation? = nil) throws -> CommitPreferences {
        try cancellation?.check()
        func value(_ key: String) -> Bool {
            (try? run(["config","--bool","--get",key],cancellation:cancellation).stdout).map {String(decoding:$0,as:UTF8.self).trimmingCharacters(in:.newlines)} == "true"
        }
        let preferences = CommitPreferences(staging: value("tgit.commitstagingsupport"), showPatch: value("tgit.commitshowpatch"))
        try cancellation?.check()
        return preferences
    }
    public func saveCommitPreferences(staging:Bool? = nil,showPatch:Bool? = nil,cancellation:OperationCancellation? = nil) throws {
        try cancellation?.check()
        if let staging { _ = try run(["config", "--local", "tgit.commitstagingsupport", staging ? "true" : "false"],cancellation:cancellation) }
        if let showPatch { _ = try run(["config", "--local", "tgit.commitshowpatch", showPatch ? "true" : "false"],cancellation:cancellation) }
    }
}
