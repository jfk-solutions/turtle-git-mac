import XCTest
@testable import TurtleGitCore

final class HistoryReferenceLabelTests: XCTestCase {
    func testPairedAndSingleRemoteNamesKeepCanonicalReferences() {
        let refs = [RevisionReference(name: "refs/heads/main", isCurrent: true), RevisionReference(name: "refs/remotes/origin/main"), RevisionReference(name: "refs/tags/release")]
        let context = HistoryReferenceContext(remotes: ["origin"], tracking: ["main": .init(remote: "origin", branch: "main")])
        let plain = context.labels(refs)
        XCTAssertEqual(plain.map(\.text), ["main", "origin/main", "release"])
        XCTAssertEqual(plain.map(\.hasTracking), [true, true, false])
        let symbolized = context.labels(refs, symbolize: true)
        XCTAssertEqual(symbolized.map(\.text), ["main", "/≡", "release"])
        XCTAssertTrue(symbolized[1].singleRemote); XCTAssertTrue(symbolized[1].sameName)
        XCTAssertEqual(symbolized.map(\.reference), refs)
        let multi = HistoryReferenceContext(remotes: ["origin", "backup"], tracking: context.tracking).labels(refs, symbolize: true)
        XCTAssertEqual(multi[1].text, "origin/≡"); XCTAssertFalse(multi[1].singleRemote)
        XCTAssertEqual(context.labels(refs, visibility: [.remoteBranches], symbolize: true).map(\.text), ["/main"])
        XCTAssertTrue(context.labels(refs, visibility: [.localBranches])[0].hasTracking)
    }
    func testSharedUpstreamPairOrderMissingUpstreamAndPrefixBoundaries() {
        let refs = [RevisionReference(name: "refs/heads/a"), RevisionReference(name: "refs/heads/b"), RevisionReference(name: "refs/remotes/origin/topic"), RevisionReference(name: "refs/remotes/original/topic")]
        let context = HistoryReferenceContext(remotes: ["origin"], tracking: ["a": .init(remote: "origin", branch: "topic"), "b": .init(remote: "origin", branch: "topic")])
        let labels = context.labels(refs, symbolize: true)
        XCTAssertEqual(labels.map(\.text), ["a", "/topic", "b", "/topic", "original/topic"])
        XCTAssertTrue(labels[1].singleRemote); XCTAssertFalse(labels[1].sameName)
        let missing = context.labels([refs[0]], symbolize: true)
        XCTAssertEqual(missing.map(\.text), ["a"]); XCTAssertTrue(missing[0].hasTracking)
        XCTAssertEqual(context.labels([refs[2], refs[0]], symbolize: true).map(\.text), ["/topic", "a"], "Only later co-located remote refs pair upstream")
    }
    func testIncompleteTrackingAndDotRemoteDoNotInventRemoteRefs() {
        let refs = [RevisionReference(name: "refs/heads/main"), RevisionReference(name: "refs/notes/commits")]
        for tracking in [HistoryBranchTracking(remote: "", branch: "main"), .init(remote: "origin", branch: "")] {
            XCTAssertFalse(HistoryReferenceContext(tracking: ["main": tracking]).labels(refs)[0].hasTracking)
        }
        let local = HistoryReferenceContext(tracking: ["main": .init(remote: ".", branch: "main")]).labels(refs, symbolize: true)
        XCTAssertEqual(local.map(\.text), ["main", "commits"]); XCTAssertTrue(local[0].hasTracking)
        XCTAssertTrue(HistoryReferenceContext().labels(refs, visibility: []).isEmpty)
    }
    func testAllShortNameKindsBoundariesAndCanonicalIdentity() {
        for (name, text, kind) in [
            ("refs/heads/main^{}", "main", HistoryReferenceKind.localBranch),
            ("refs/remotes/origin/雪^{}", "origin/雪", .remoteBranch),
            ("refs/tags/v1^{}", "v1", .annotatedTag), ("refs/tags/v2", "v2", .tag),
            ("refs/stash-extra", "stash", .stash), ("refs/bisect/good-a", "good", .bisectGood),
            ("refs/bisect/bad", "bad", .bisectBad), ("refs/bisect/skip-a", "skip", .bisectSkip),
            ("refs/bisect/goodish", "goodish", .unknown), ("refs/notes/commits^{}", "commits", .notes),
            ("refs/custom/雪^{}", "custom/雪", .unknown), ("HEAD^{}", "HEAD^{}", .unknown)
        ] {
            let result = HistoryReferenceLabel.shortName(name)
            XCTAssertEqual(result.text, text); XCTAssertEqual(result.kind, kind)
            let reference = RevisionReference(name: name), label = HistoryReferenceLabel(reference: reference)
            XCTAssertEqual(label.reference.name, name); XCTAssertEqual(label.text, text); XCTAssertEqual(label.kind, kind)
        }
        let terms = HistoryBisectTerms(good: "old", bad: "new")
        XCTAssertEqual(HistoryReferenceLabel.shortName("refs/bisect/old-a", terms: terms).text, "old")
        XCTAssertEqual(HistoryReferenceLabel.shortName("refs/bisect/good-a", terms: terms).kind, .unknown)
        let ambiguous = HistoryBisectTerms(good: "skip", bad: "skip")
        XCTAssertEqual(HistoryReferenceLabel.shortName("refs/bisect/skip-a", terms: ambiguous).kind, .bisectSkip)
        XCTAssertFalse(HistoryReferenceVisibility.bisect.shows(RevisionReference(name: "refs/bisect/goodish")))
        XCTAssertTrue(HistoryReferenceVisibility.otherRefs.shows(RevisionReference(name: "refs/bisect/goodish")))
        XCTAssertFalse(HistoryReferenceVisibility.all.keepsCommit(RevisionReference(name: "refs/bisect/goodish")))
    }
    func testBoundedTermFileReadsAndSourceLFHandling() {
        XCTAssertEqual(HistoryBisectTerms.parse(nil), HistoryBisectTerms())
        XCTAssertEqual(HistoryBisectTerms.parse(Data()), .init(good: "", bad: ""))
        XCTAssertEqual(HistoryBisectTerms.parse(Data("new\nold\nignored\n".utf8)), .init(good: "old", bad: "new"))
        XCTAssertEqual(HistoryBisectTerms.parse(Data("new\r\nold\r\n".utf8)), .init(good: "old\r", bad: "new\r"))
        XCTAssertEqual(HistoryBisectTerms.parse(Data("bad\0ignored\n雪\n".utf8)), .init(good: "雪", bad: "bad"))
        XCTAssertEqual(HistoryBisectTerms.parse(Data((String(repeating: "x", count: 260) + "\ngood\n").utf8)), .init(good: "x", bad: String(repeating: "x", count: 259)))
    }
    func testRealAnnotatedTagsAndCustomBisectNamesPreserveRefs() async throws {
        let (root, repo, path) = try await GitPatchTests().fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let hash = try await repo.run(["rev-parse", "HEAD"]).text.trimmingCharacters(in: .newlines)
        _ = try await repo.run(["tag", "-a", "annotated", "-m", "tag message"])
        _ = try await repo.run(["tag", "light"])
        for name in ["refs/bisect/old-" + hash, "refs/bisect/new", "refs/bisect/unknown", "refs/notes/custom", "refs/custom/extra"] { _ = try await repo.run(["update-ref", name, hash]) }
        try Data("new\nold\n".utf8).write(to: root.appendingPathComponent(".git/BISECT_TERMS"))
        let paths = [".git/HEAD", ".git/index", ".git/config", ".git/BISECT_TERMS", ".git/refs/tags/annotated", path], before = try paths.map { try Data(contentsOf: root.appendingPathComponent($0)) }
        let entries = try await repo.history(), entry = try XCTUnwrap(entries.first { $0.hash == hash })
        let refs = Dictionary(uniqueKeysWithValues: entry.references.map { ($0.name, $0) })
        XCTAssertEqual(refs["refs/tags/annotated"]?.kind, .annotatedTag); XCTAssertEqual(refs["refs/tags/light"]?.kind, .tag)
        XCTAssertEqual(refs["refs/bisect/old-" + hash]?.kind, .bisectGood); XCTAssertEqual(refs["refs/bisect/new"]?.displayName, "new")
        XCTAssertEqual(refs["refs/bisect/unknown"]?.kind, .unknown); XCTAssertEqual(refs["refs/notes/custom"]?.displayName, "custom")
        XCTAssertEqual(refs["refs/custom/extra"]?.displayName, "custom/extra")
        XCTAssertEqual(HistoryReferenceLabel(reference: refs["refs/bisect/old-" + hash]!).text, "old", "Loaded alias survives consumers with default term state")
        XCTAssertEqual(try paths.map { try Data(contentsOf: root.appendingPathComponent($0)) }, before)
    }
    func testRealConfigContextReadPreservesRepositoryBytes() async throws {
        let (root, repo, path) = try await GitPatchTests().fixture(); defer { try? FileManager.default.removeItem(at: root) }
        _ = try await repo.run(["remote", "add", "origin", root.path])
        for (key, value) in [("branch.main.remote", "origin"), ("branch.main.merge", "refs/heads/main"), ("branch.雪/topic.remote", "origin"), ("branch.雪/topic.merge", "refs/heads/other"), ("branch.local.remote", "."), ("branch.local.merge", "refs/tags/tag  ")] { _ = try await repo.run(["config", key, value]) }
        let paths = [".git/HEAD", ".git/index", ".git/config", path], before = try paths.map { try Data(contentsOf: root.appendingPathComponent($0)) }
        let context = try await repo.historyReferenceContext()
        XCTAssertEqual(context.remotes, ["origin"])
        XCTAssertEqual(context.tracking["main"], .init(remote: "origin", branch: "main"))
        XCTAssertEqual(context.tracking["雪/topic"], .init(remote: "origin", branch: "other"))
        XCTAssertEqual(context.tracking["local"], .init(remote: ".", branch: "tags/tag"))
        XCTAssertEqual(try paths.map { try Data(contentsOf: root.appendingPathComponent($0)) }, before)
    }
}
