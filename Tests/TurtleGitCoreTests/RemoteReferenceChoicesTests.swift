import XCTest
@testable import TurtleGitCore

final class RemoteReferenceChoicesTests: XCTestCase {
    func testSourceNamespacesNaturalOrderAndExactUnicodeIdentity() throws {
        let hash = String(repeating: "a",count: 40)
        let names = ["refs/heads/branch10","refs/heads/branch2","refs/tags/v1","refs/notes/review","refs/heads/é","refs/heads/e\u{301}","refs/heads/branch2"]
        let values = try RemoteReferenceChoices.parse(Data(names.map { hash + "\t" + $0 + "\n" }.joined().utf8))
        XCTAssertTrue(values.contains("refs/notes/review")); XCTAssertFalse(values.contains("v1"))
        XCTAssertLessThan(values.firstIndex(of: "branch2")!,values.firstIndex(of: "branch10")!)
        XCTAssertEqual(Set(values.map { Data($0.utf8) }).count,5)
    }
    func testMalformedRecordsAreNotSilentlyListed() {
        for value in ["invalid\n",String(repeating: "g",count: 40)+"\trefs/heads/main\n",String(repeating: "a",count: 40)+"\trefs/heads/\n",String(repeating: "a",count: 40)+"\trefs/heads/bad name\n"] {
            XCTAssertThrowsError(try RemoteReferenceChoices.parse(Data(value.utf8)))
        }
    }
    func testRealLocalRemoteChoicesDoNotFetchOrChangeIndex() async throws {
        let (root,repository,_) = try await GitPatchTests().fixture(); defer { try? FileManager.default.removeItem(at: root) }
        _ = try await repository.run(["branch","branch2"]); _ = try await repository.run(["tag","v1"])
        _ = try await repository.run(["update-ref","refs/notes/review","HEAD"])
        let index = try Data(contentsOf: root.appendingPathComponent(".git/index"))
        let choices = try await repository.remoteReferenceChoices(remote: root.path)
        XCTAssertTrue(choices.contains("main") && choices.contains("branch2") && choices.contains("refs/notes/review")); XCTAssertFalse(choices.contains("v1"))
        XCTAssertEqual(index,try Data(contentsOf: root.appendingPathComponent(".git/index")))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent(".git/FETCH_HEAD").path))
    }
}
