import Foundation

/// Source CGitMailmap::ShouldLoadMailmap. Display identities are independent of
/// the raw signatures retained by commit/amend/rebase mutation workflows.
public struct GitIdentityDisplay: Equatable, Sendable {
    public var useMailmap: Bool
    public init(useMailmap: Bool) { self.useMailmap = useMailmap }
    public init(defaults: UserDefaults = .standard) { useMailmap = (defaults.object(forKey: "UseMailmap") as? NSNumber)?.boolValue ?? true }
    public var authorName: String { useMailmap ? "%aN" : "%an" }
    public var authorEmail: String { useMailmap ? "%aE" : "%ae" }
    public var committerName: String { useMailmap ? "%cN" : "%cn" }
    public var committerEmail: String { useMailmap ? "%cE" : "%ce" }
}
