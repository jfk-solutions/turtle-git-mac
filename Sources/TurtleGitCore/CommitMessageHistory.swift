import Foundation

public protocol MessageHistory {
    var entries: [String] { get }
    func remove(_ messages: Set<String>)
    func removeExact(_ messages: [String])
}

extension MessageHistory {
    public func removeExact(_ messages:[String]) { remove(Set(messages)) }
}

/// User-local message history. Each mutation reloads storage so other open dialogs aren't overwritten.
public final class CommitMessageHistory: MessageHistory {
    private let defaults: UserDefaults
    private let key: String
    public let limit: Int
    public init(repositoryIdentity: String, defaults: UserDefaults = .standard, limit: Int = 25) {
        self.defaults = defaults; self.limit = max(0, limit)
        key = "Commit.MessageHistory." + Data(repositoryIdentity.utf8).base64EncodedString()
    }
    public var entries: [String] { Array((defaults.stringArray(forKey: key) ?? []).prefix(limit)) }
    public func add(_ message: String) {
        guard !message.isEmpty else { return }
        var values = entries.filter { !GitReferenceName.equal($0,message) }; values.insert(message, at: 0)
        defaults.set(Array(values.prefix(limit)), forKey: key)
    }
    public func remove(_ messages: Set<String>) {
        removeExact(Array(messages))
    }
    public func removeExact(_ messages:[String]) {
        let removed = Set(messages.map { GitReferenceName($0) })
        defaults.set(entries.filter { !removed.contains(GitReferenceName($0)) },forKey:key)
    }
}

extension GitRepository {
    public func commitMessageHistoryIdentity(cancellation: OperationCancellation? = nil) throws -> String {
        try cancellation?.check()
        var bytes = try run(["rev-parse", "--path-format=absolute", "--git-common-dir"], cancellation: cancellation).stdout
        if bytes.last == 10 { bytes.removeLast() }
        return URL(fileURLWithPath: String(decoding: bytes, as: UTF8.self)).resolvingSymlinksInPath().path
    }
}
