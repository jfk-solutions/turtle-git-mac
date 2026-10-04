import Foundation

public struct SubmoduleComparisonSide: Sendable {
    public let revision: String?
    public let subject: String
    public let available: Bool
    public var canShowLog: Bool { available && revision != nil }
}

/// A read-only comparison of superproject gitlinks and the child checkout.
public struct SubmoduleComparison: Sendable {
    public let path: String
    public let checkout: URL?
    public let from: SubmoduleComparisonSide
    public let to: SubmoduleComparisonSide
    public let toWorkingTree: Bool
    public let dirty: Bool
    public let change: SubmoduleChangeType
}

public enum SubmoduleComparisonFailure: LocalizedError {
    case unsupported, unsafeCheckout, conflicted
    public var errorDescription: String? {
        switch self {
        case .unsupported: return "Choose a path that is a submodule in at least one revision."
        case .unsafeCheckout: return "The submodule checkout is outside its expected working-tree location."
        case .conflicted: return "Resolve the submodule index conflict before comparing its working checkout."
        }
    }
}

extension GitRepository {
    /// `from` and `to` are revisions of this superproject; nil `to` compares
    /// against the actual child HEAD (or indexed gitlink if uninitialized).
    public func submoduleComparison(path: String, from: String = "HEAD", to: String? = nil) throws -> SubmoduleComparison {
        let location = try restoreLocation(path)
        func gitlink(_ revision: String) throws -> String? {
            if revision.isEmpty { return nil }
            let tree = try run(["rev-parse", "--verify", "--end-of-options", revision + "^{tree}"]).text.trimmingCharacters(in: .newlines)
            let records = try run(["ls-tree", "--full-tree", "-z", tree, "--", path]).stdout.split(separator: 0)
            for record in records {
                let parts = record.split(separator: 9, maxSplits: 1)
                guard parts.count == 2, String(decoding: parts[1], as: UTF8.self) == path else { continue }
                let header = String(decoding: parts[0], as: UTF8.self).split(separator: " ")
                if header.count == 3 && header[0] == "160000" { return String(header[2]) }
            }
            return nil
        }
        func workingGitlink() throws -> String? {
            var hash: String?
            let records = try run(["ls-files", "--stage", "-z", "--", path]).stdout.split(separator: 0)
            for record in records {
                let parts = record.split(separator: 9, maxSplits: 1)
                guard parts.count == 2, String(decoding: parts[1], as: UTF8.self) == path else { continue }
                let header = String(decoding: parts[0], as: UTF8.self).split(separator: " ")
                guard header.count == 3 else { continue }
                guard header[2] == "0" else { throw SubmoduleComparisonFailure.conflicted }
                if header[0] == "160000" { hash = String(header[1]) }
            }
            return hash
        }
        var fromHash = try from == "Working tree" ? workingGitlink() : gitlink(from)
        var toHash = try to.map(gitlink) ?? workingGitlink()
        guard fromHash != nil || toHash != nil else { throw SubmoduleComparisonFailure.unsupported }
        var checkout: URL?
        if FileManager.default.fileExists(atPath: location.appendingPathComponent(".git").path) {
            let attributes = try FileManager.default.attributesOfItem(atPath: location.path)
            guard attributes[.type] as? FileAttributeType == .typeDirectory else { throw SubmoduleComparisonFailure.unsafeCheckout }
            var bytes = try run(["-C", location.path, "rev-parse", "--show-toplevel"]).stdout
            if bytes.last == 10 { bytes.removeLast() }
            let discovered = URL(fileURLWithPath: String(decoding: bytes, as: UTF8.self)).resolvingSymlinksInPath().standardizedFileURL
            guard discovered == location.resolvingSymlinksInPath().standardizedFileURL else { throw SubmoduleComparisonFailure.unsafeCheckout }
            checkout = location
            if to == nil, toHash != nil { toHash = try run(["-C", location.path, "rev-parse", "--verify", "HEAD^{commit}"]).text.trimmingCharacters(in: .newlines) }
            if from == "Working tree", fromHash != nil { fromHash = try run(["-C", location.path, "rev-parse", "--verify", "HEAD^{commit}"]).text.trimmingCharacters(in: .newlines) }
        }
        let dirty = try to == nil && checkout != nil && !run(["-C", location.path, "status", "--porcelain=v1", "-z", "--untracked-files=all", "--ignore-submodules=none"], environmentOverrides: ["GIT_OPTIONAL_LOCKS": "0"]).stdout.isEmpty
        func metadata(_ hash: String?) -> (SubmoduleComparisonSide, Int64) {
            guard checkout != nil else { return (SubmoduleComparisonSide(revision: hash, subject: "not initialized", available: false), 0) }
            guard let hash else { return (SubmoduleComparisonSide(revision: nil, subject: "", available: true), 0) }
            do {
                let bytes = try run(["-C", location.path, "log", "-1", "--format=%ct%x00%s", hash, "--"]).stdout
                let fields = bytes.split(separator: 0, maxSplits: 1, omittingEmptySubsequences: false)
                guard fields.count == 2, let time = Int64(String(decoding: fields[0], as: UTF8.self)) else { throw SubmoduleComparisonFailure.unsupported }
                var subject = Data(fields[1]); if subject.last == 10 { subject.removeLast() }
                return (SubmoduleComparisonSide(revision: hash, subject: String(decoding: subject, as: UTF8.self), available: true), time)
            } catch { return (SubmoduleComparisonSide(revision: hash, subject: error.localizedDescription, available: false), 0) }
        }
        let old = metadata(fromHash), new = metadata(toHash)
        var change = SubmoduleChangeType.unknown
        if old.0.available && new.0.available {
            if fromHash == nil { change = .newSubmodule }
            else if toHash == nil { change = .deleteSubmodule }
            else if fromHash == toHash { change = .identical }
            else if let fromHash, let toHash {
                if (try? run(["-C", location.path, "merge-base", "--is-ancestor", fromHash, toHash])) != nil { change = .fastForward }
                else if (try? run(["-C", location.path, "merge-base", "--is-ancestor", toHash, fromHash])) != nil { change = .rewind }
                else { change = new.1 > old.1 ? .newerTime : new.1 < old.1 ? .olderTime : .sameTime }
            }
        }
        return SubmoduleComparison(path: path, checkout: checkout, from: old.0, to: new.0, toWorkingTree: to == nil, dirty: dirty, change: change)
    }
}
