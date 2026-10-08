import XCTest
@testable import TurtleGitCore

final class SavedDataTests: XCTestCase {
    func fixture(_ body: (UserDefaults, SavedDataStore) throws -> Void) throws {
        let suite = "TurtleGit.SavedData.Tests." + UUID().uuidString, defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        try body(defaults, SavedDataStore(preferences: defaults))
    }
    func testCatalogueMatchesPinnedSavedDataDecisionLists() throws {
        struct Fixture: Decodable { let sourceDecisions: [String]; let sourceMergeDecisions: [String] }
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let fixture = try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: root.appendingPathComponent("docs/upstream-saved-decisions.json")))
        XCTAssertEqual(SavedDataStore.sourceDecisionKeys, fixture.sourceDecisions)
        XCTAssertTrue(fixture.sourceMergeDecisions.allSatisfy { SavedDataStore.nativeDecisionKeys.contains($0) })
    }
    func testMessageClearReachesEveryRepositoryAndExistingHistoryObject() throws {
        try fixture { defaults, store in
            let first = CommitMessageHistory(repositoryIdentity: "/repo/雪", defaults: defaults)
            let second = CommitMessageHistory(repositoryIdentity: "/repo/two", defaults: defaults)
            first.add("first"); first.add("second"); second.add("third")
            defaults.set("draft", forKey: "Commit.Draft"); defaults.set(25, forKey: "Commit.MaxHistoryItems")
            XCTAssertEqual(store.summary(.messageHistory), SavedDataSummary(entries: 3, histories: 2))
            store.clear(.messageHistory)
            XCTAssertTrue(first.entries.isEmpty); XCTAssertTrue(second.entries.isEmpty)
            XCTAssertEqual(defaults.string(forKey: "Commit.Draft"), "draft"); XCTAssertEqual(defaults.integer(forKey: "Commit.MaxHistoryItems"), 25)
            first.add("fresh"); XCTAssertEqual(first.entries, ["fresh"])
        }
    }
    func testURLClearIncludesMappedGlobalAndRepositoryHistoriesOnly() throws {
        try fixture { defaults, store in
            for key in ["Clone.URLHistory", "FormatPatchDirectories", "History.PullURLS", "History.RequestPull.url", "History.PushURLS./repo"] { defaults.set(["one", "two"], forKey: key) }
            let preserved = ["Clone.KeyHistory", "Clone.Directory", "History.PullRemoteBranch", "History.RemoteBranch./repo", "History.PushOption./repo", "FormatPatchFrom", "FormatPatchSince:/repo", "History.PushURLSOther", "MaxLinesInLogfile"]
            for key in preserved { defaults.set("preserved", forKey: key) }
            XCTAssertEqual(store.summary(.urlHistory), SavedDataSummary(entries: 10, histories: 5))
            store.clear(.urlHistory); XCTAssertFalse(store.summary(.urlHistory).available)
            for key in preserved { XCTAssertEqual(defaults.string(forKey: key), "preserved", key) }
        }
    }
    func testDecisionClearRemovesSourceAndNativeAliasesIncludingFalseAnswers() throws {
        try fixture { defaults, store in
            let keys = SavedDataStore.sourceDecisionKeys + SavedDataStore.nativeDecisionKeys
            XCTAssertEqual(SavedDataStore.sourceDecisionKeys.count, 21)
            for key in keys { defaults.set(false, forKey: key) }
            defaults.set(7, forKey: "OpenRebaseRemoteBranchEqualsHEAD")
            let preserved = ["ConfirmKillProcess", "AutoCloseGitProgress", "CommitLastAction", "AddBeforeCommit", "EnableGravatar", "Merge.UseUTF8", "PushAllBranchesExtra"]
            for key in preserved { defaults.set(true, forKey: key) }
            XCTAssertEqual(store.summary(.storedDecisions).entries, keys.count)
            store.clear(.storedDecisions)
            for key in keys { XCTAssertNil(defaults.object(forKey: key), key) }
            for key in preserved { XCTAssertEqual(defaults.object(forKey: key) as? Bool, true, key) }
            store.clear(.storedDecisions); XCTAssertFalse(store.summary(.storedDecisions).available)
        }
    }
}
