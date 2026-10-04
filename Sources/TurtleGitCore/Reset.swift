import Foundation

public enum ResetMode: String, CaseIterable, Sendable { case soft, mixed, hard }
public struct ResetPlan: Sendable {
    public let revision: String
    public let originalHead: String
    public let originalReference: String?
    public let mode: ResetMode
}
public enum ResetFailure: LocalizedError {
    case invalidRevision, workingTreeRequired, changedHead
    public var errorDescription: String? {
        switch self {
        case .invalidRevision: return "Choose a branch, tag or commit that exists in this repository."
        case .workingTreeRequired: return "A bare repository supports only Soft reset."
        case .changedHead: return "HEAD or the current branch changed while reviewing the reset. Review the target again before continuing."
        }
    }
}
extension GitRepository {
    public func prepareReset(to revision: String, mode: ResetMode) throws -> ResetPlan {
        guard !revision.isEmpty, !revision.contains("\0") else { throw ResetFailure.invalidRevision }
        if mode != .soft, try isBare() { throw ResetFailure.workingTreeRequired }
        let target: String
        do { target = try run(["rev-parse", "--verify", "--end-of-options", revision + "^{commit}"]).text.trimmingCharacters(in: .newlines) }
        catch { throw ResetFailure.invalidRevision }
        let head = try run(["rev-parse", "--verify", "HEAD"]).text.trimmingCharacters(in: .newlines)
        let reference = try? run(["symbolic-ref", "--quiet", "HEAD"]).text.trimmingCharacters(in: .newlines)
        return ResetPlan(revision: target, originalHead: head, originalReference: reference, mode: mode)
    }
    public func reset(_ plan: ResetPlan) throws -> String {
        let head = try run(["rev-parse", "--verify", "HEAD"]).text.trimmingCharacters(in: .newlines)
        let reference = try? run(["symbolic-ref", "--quiet", "HEAD"]).text.trimmingCharacters(in: .newlines)
        guard head == plan.originalHead, reference == plan.originalReference else { throw ResetFailure.changedHead }
        if plan.mode != .soft, try isBare() { throw ResetFailure.workingTreeRequired }
        return try run(["reset", "--" + plan.mode.rawValue, plan.revision, "--"]).text
    }
    public func submoduleResetTarget(_ entry: ConflictEntry, using choice: ResolveChoice) throws -> (URL, String) {
        guard let current = try conflicts().first(where: { $0.path == entry.path }), current == entry,
              let destination = entry.stages.first(where: { $0.number == choice.rawValue }), destination.mode == "160000" else { throw ResolveFailure.stale }
        let url = root.appendingPathComponent(entry.path)
        guard RepositoryAccessLease.pathIsContained(url, by: root), FileManager.default.fileExists(atPath: url.appendingPathComponent(".git").path) else { throw ResolveFailure.outsideWorkingTree }
        var bytes = try run(["-C", url.path, "rev-parse", "--show-toplevel"]).stdout
        if bytes.last == 10 { bytes.removeLast() }
        guard URL(fileURLWithPath: String(decoding: bytes, as: UTF8.self), isDirectory: true).standardizedFileURL == url.standardizedFileURL else { throw ResolveFailure.outsideWorkingTree }
        return (url, destination.object)
    }
}
