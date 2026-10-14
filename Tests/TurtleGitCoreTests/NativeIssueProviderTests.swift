import XCTest
@testable import TurtleGitCore

final class NativeIssueProviderTests: XCTestCase {
    let parameters = #"{"linkText":"Select tickets","messageTemplate":"Ticket: %BUGID%","requireIssue":true,"issues":[{"id":"2","summary":"Second"},{"id":"1","summary":"First 雪"}]}"#
    func testCatalogOrderSelectionReplacementAndValidation() throws {
        let provider = try NativeIssueCatalogProvider(parameters: parameters)
        let root = URL(fileURLWithPath: "/repo"), initial = NativeIssueProviderContext(repositoryRoot: root, paths: ["a"], message: "body\n", issueID: "")
        XCTAssertThrowsError(try provider.checkCommit(context: initial))
        let result = try provider.commitMessage(context: initial, selected: ["1", "2"])
        XCTAssertEqual(result.issueID, "2,1"); XCTAssertEqual(result.message, "body\nTicket: 2,1\n")
        let changed = try provider.commitMessage(context: NativeIssueProviderContext(repositoryRoot: root, paths: [], message: result.message + "keep line\n", issueID: result.issueID), selected: ["1"])
        XCTAssertFalse(changed.message.contains("Ticket: 2,1")); XCTAssertTrue(changed.message.contains("keep line\n")); XCTAssertTrue(changed.message.contains("Ticket: 1\n"))
        try provider.checkCommit(context: NativeIssueProviderContext(repositoryRoot: root, paths: [], message: changed.message, issueID: changed.issueID))
        XCTAssertThrowsError(try provider.commitMessage(context: initial, selected: ["unknown"]))
        XCTAssertThrowsError(try NativeIssueCatalogProvider(parameters: #"{"issues":[{"id":"1","summary":"x"},{"id":"1","summary":"y"}]}"#))
        XCTAssertThrowsError(try NativeIssueCatalogProvider(parameters: "{}", identifier: "windows-provider"))
    }
    func testAssociationExactMatchArchiveAndMalformedPreservation() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString), child = root.appendingPathComponent("child")
        try FileManager.default.createDirectory(at: child, withIntermediateDirectories: true); defer { try? FileManager.default.removeItem(at: root) }
        let suite = "TurtleGit.NativeIssue." + UUID().uuidString, prefs = UserDefaults(suiteName: suite)!; defer { prefs.removePersistentDomain(forName: suite) }
        var disabled = NativeIssueAssociation(path: root.path, parameters: parameters); disabled.enabled = false
        let enabled = NativeIssueAssociation(path: root.path, parameters: parameters)
        try NativeIssueAssociations.save([disabled, enabled], to: prefs)
        let loaded = try NativeIssueAssociations.load(from: prefs)
        XCTAssertEqual(loaded, [disabled, enabled]); XCTAssertEqual(NativeIssueAssociations.matching(loaded, root: root), enabled); XCTAssertNil(NativeIssueAssociations.matching(loaded, root: child))
        try NativeIssueAssociations.validate(enabled)
        let invalid = Data("unreadable".utf8); prefs.set(invalid, forKey: NativeIssueAssociations.key)
        XCTAssertThrowsError(try NativeIssueAssociations.load(from: prefs)); XCTAssertEqual(prefs.data(forKey: NativeIssueAssociations.key), invalid)
    }
    func testLocalAndProjectFallbackAndAssociationPriority() async throws {
        let (root, _, repo) = try await IssueTrackerSettingsTests().fixture(); defer { try? FileManager.default.removeItem(at: root) }
        var settings = IssueTrackerSettings(); settings.fields[.nativeProvider] = GitConfigurationIdentity(value: NativeIssueCatalogProvider.identifier, inherit: false); settings.fields[.nativeParameters] = GitConfigurationIdentity(value: parameters, inherit: false)
        settings.fields[.provider64] = GitConfigurationIdentity(value: "{preserved-Windows-UUID}", inherit: false)
        try await repo.saveIssueTrackerSettings(settings, destination: .project)
        let project = try await repo.nativeIssueAssociation(rows: []); XCTAssertEqual(project?.parameters, parameters)
        settings.fields[.nativeParameters] = GitConfigurationIdentity(value: NativeIssueCatalogProvider.exampleParameters, inherit: false)
        try await repo.saveIssueTrackerSettings(settings, destination: .local)
        let local = try await repo.nativeIssueAssociation(rows: []); XCTAssertEqual(local?.parameters, NativeIssueCatalogProvider.exampleParameters)
        let override = NativeIssueAssociation(path: root.path, parameters: parameters); let preferred = try await repo.nativeIssueAssociation(rows: [override]); XCTAssertEqual(preferred, override)
        let preserved = try await repo.issueTrackerSettings(source: .local); XCTAssertEqual(preserved.fields[.provider64]?.value, "{preserved-Windows-UUID}")
    }
}
