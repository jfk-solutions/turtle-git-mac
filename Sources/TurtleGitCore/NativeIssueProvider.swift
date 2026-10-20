// SPDX-License-Identifier: GPL-2.0-or-later
// Native provider contracts adapted from IBugTraqProvider/IBugTraqProvider2.
import Foundation

public enum NativeIssueProviderFailure: LocalizedError {
    case configuration(String), unavailable(String), selection
    public var errorDescription: String? {
        switch self { case .configuration(let text): return "Issue provider configuration: " + text
        case .unavailable(let id): return "The native issue provider is not available: " + id
        case .selection: return "Select at least one issue from this provider's catalog." }
    }
}
public struct NativeIssueAssociation: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var path: String
    public var provider: String
    public var parameters: String
    public var enabled: Bool
    public init(id: UUID = UUID(), path: String, provider: String = NativeIssueCatalogProvider.identifier, parameters: String = NativeIssueCatalogProvider.exampleParameters, enabled: Bool = true) {
        self.id = id; self.path = path; self.provider = provider; self.parameters = parameters; self.enabled = enabled
    }
}
public enum NativeIssueAssociations {
    public static let key = "TurtleGit.IssueProviderAssociations"
    private struct Archive: Codable { let version: Int; let rows: [NativeIssueAssociation] }
    public static func load(from preferences: UserDefaults) throws -> [NativeIssueAssociation] {
        guard let data = preferences.data(forKey: key) else { return [] }
        let archive: Archive
        do { archive = try JSONDecoder().decode(Archive.self, from: data) } catch { throw NativeIssueProviderFailure.configuration("The saved associations cannot be read. They have not been replaced.") }
        guard archive.version == 1, Set(archive.rows.map(\.id)).count == archive.rows.count else { throw NativeIssueProviderFailure.configuration("Unsupported association archive or duplicate identity.") }
        return archive.rows
    }
    public static func save(_ rows: [NativeIssueAssociation], to preferences: UserDefaults) throws {
        guard Set(rows.map(\.id)).count == rows.count else { throw NativeIssueProviderFailure.configuration("Duplicate association identity.") }
        let data = try JSONEncoder().encode(Archive(version: 1, rows: rows)); preferences.set(data, forKey: key)
    }
    public static func matching(_ rows: [NativeIssueAssociation], root: URL) -> NativeIssueAssociation? {
        let path = root.standardizedFileURL.resolvingSymlinksInPath().path
        return rows.first { $0.enabled && URL(fileURLWithPath: $0.path).standardizedFileURL.resolvingSymlinksInPath().path == path }
    }
    public static func validate(_ row: NativeIssueAssociation) throws {
        guard row.path.hasPrefix("/"), !row.path.contains("\0"), (try? URL(fileURLWithPath: row.path).resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { throw NativeIssueProviderFailure.configuration("Choose an existing absolute working-tree folder.") }
        _ = try NativeIssueProviderSession(identifier:row.provider,parameters:row.parameters)
    }
}
public struct NativeIssueProviderContext: Equatable, Sendable {
    public let repositoryRoot: URL
    public let commonRoot:URL
    public let paths: [String]
    public let message: String
    public let issueID: String
    public init(repositoryRoot: URL, paths: [String], message: String, issueID: String,commonRoot:URL?=nil) {
        self.repositoryRoot=repositoryRoot;self.paths=paths;self.message=message;self.issueID=issueID
        if let commonRoot {self.commonRoot=commonRoot}
        else {
            let parents=paths.map {path->[String] in
                guard !path.hasPrefix("/"),!path.split(separator:"/").contains("..") else{return []}
                return path.utf8.split(separator:47).dropLast().map{String(decoding:$0,as:UTF8.self)}
            }
            var common=parents.first ?? []
            for parent in parents.dropFirst() {var count=0;while count<common.count && count<parent.count && GitReferenceName.equal(common[count],parent[count]) {count += 1};common=Array(common.prefix(count))}
            self.commonRoot=common.isEmpty ? repositoryRoot:FileTransferPaths.fileURL(repositoryRoot.path+"/"+common.joined(separator:"/"))
        }
    }
}
public struct NativeIssueProviderResult: Equatable, Sendable {
    public let message: String
    public let issueID: String
    public init(message: String, issueID: String) { self.message = message; self.issueID = issueID }
}
/// Providers are embedded native implementations, not downloaded code/Windows COM.
/// Hosts own presentation and cancellation; providers return data and diagnostics.
public protocol NativeIssueProvider: Sendable {
    var linkText: String { get }
    func commitMessage(context: NativeIssueProviderContext, selected: Set<String>) throws -> NativeIssueProviderResult
    func checkCommit(context: NativeIssueProviderContext) throws
    func commitFinished(context: NativeIssueProviderContext, revision: String) throws
}
public struct NativeIssueCatalogItem: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let summary: String
    public init(id: String, summary: String) { self.id = id; self.summary = summary }
}
public struct NativeIssueCatalogProvider: NativeIssueProvider {
    public static let identifier = "org.turtlegit.issue-catalog"
    public static let name = "Native issue catalog"
    public static let exampleParameters = #"{"linkText":"Choose issues…","messageTemplate":"Issue: %BUGID%","requireIssue":false,"issues":[{"id":"1","summary":"Example issue"}]}"#
    private struct Parameters: Codable { var linkText: String?; var messageTemplate: String?; var requireIssue: Bool?; let issues: [NativeIssueCatalogItem] }
    public let issues: [NativeIssueCatalogItem]
    public let linkText: String
    public let messageTemplate: String
    public let requireIssue: Bool
    public init(parameters: String, identifier: String = Self.identifier) throws {
        guard identifier == Self.identifier else { throw NativeIssueProviderFailure.unavailable(identifier) }
        guard parameters.utf8.count <= 1_048_576, let data = parameters.data(using: .utf8) else { throw NativeIssueProviderFailure.configuration("Parameters exceed the supported size.") }
        let value: Parameters
        do { value = try JSONDecoder().decode(Parameters.self, from: data) } catch { throw NativeIssueProviderFailure.configuration("Enter a JSON issue catalog with id and summary fields.") }
        guard value.issues.count <= 10_000, Set(value.issues.map(\.id)).count == value.issues.count,
              value.issues.allSatisfy({ !$0.id.isEmpty && $0.id == $0.id.trimmingCharacters(in: .whitespacesAndNewlines) && !$0.id.contains(where: { $0 == "," || $0 == "\n" || $0 == "\r" || $0 == "\0" }) && !$0.summary.contains("\0") }) else { throw NativeIssueProviderFailure.configuration("Issue IDs must be unique and cannot contain commas, line breaks or NUL.") }
        linkText = value.linkText?.isEmpty == false ? value.linkText! : "Choose issues…"
        messageTemplate = value.messageTemplate ?? "Issue: %BUGID%"; requireIssue = value.requireIssue ?? false; issues = value.issues
        guard !messageTemplate.contains("\n"), !messageTemplate.contains("\r"), messageTemplate.isEmpty || messageTemplate.contains("%BUGID%") else { throw NativeIssueProviderFailure.configuration("Use an empty message template or one line containing %BUGID%.") }
        guard !linkText.contains("\0"), !messageTemplate.contains("\0") else { throw NativeIssueProviderFailure.configuration("Text cannot contain NUL.") }
    }
    public func selectedIDs(in text: String) -> Set<String> { Set(text.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }).intersection(Set(issues.map(\.id))) }
    public func commitMessage(context: NativeIssueProviderContext, selected: Set<String>) throws -> NativeIssueProviderResult {
        guard !selected.isEmpty, selected.isSubset(of: Set(issues.map(\.id))) else { throw NativeIssueProviderFailure.selection }
        // Retain provider catalog order, independently of UI filtering/sorting.
        let ids = issues.filter { selected.contains($0.id) }.map(\.id).joined(separator: ",")
        var message = context.message
        if !messageTemplate.isEmpty {
            let line = messageTemplate.replacingOccurrences(of: "%BUGID%", with: ids)
            if !context.issueID.isEmpty && context.issueID != ids {
                let previous = messageTemplate.replacingOccurrences(of: "%BUGID%", with: context.issueID)
                message = message.components(separatedBy: "\n").filter { $0 != previous }.joined(separator: "\n")
            }
            if !message.components(separatedBy: "\n").contains(line) { message += (message.isEmpty || message.hasSuffix("\n") ? "" : "\n") + line + "\n" }
        }
        return NativeIssueProviderResult(message: message, issueID: ids)
    }
    public func checkCommit(context: NativeIssueProviderContext) throws {
        if requireIssue && selectedIDs(in: context.issueID).isEmpty { throw NativeIssueProviderFailure.selection }
    }
    public func commitFinished(context: NativeIssueProviderContext, revision: String) throws { /* Embedded catalog has no remote write side effects. */ }
}
extension GitRepository {
    public func nativeIssueAssociation(rows: [NativeIssueAssociation], cancellation: OperationCancellation? = nil) throws -> NativeIssueAssociation? {
        try cancellation?.check()
        if let row = NativeIssueAssociations.matching(rows, root: root) { return row }
        let settings = try issueTrackerSettings(source: .effective, cancellation: cancellation)
        let id = settings.fields[.nativeProvider]?.value ?? ""
        guard !id.isEmpty else { return nil }
        return NativeIssueAssociation(path: root.path, provider: id, parameters: settings.fields[.nativeParameters]?.value ?? "")
    }
}
