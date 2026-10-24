import XCTest
@testable import TurtleGitCore

final class ReferenceRefreshTests:XCTestCase {
    func testFetchDefaultsRequireExactTrackedRemoteMembership()async throws {
        let (root,repository,_)=try await GitPatchTests().fixture();defer{try? FileManager.default.removeItem(at:root)}
        let nfc="caf\u{e9}",nfd="cafe\u{301}"
        XCTAssertFalse(nfc.utf8.elementsEqual(nfd.utf8))
        let branch=try await repository.branch()
        for name in [nfc,nfd,"other"] {_ = try await repository.run(["-c","core.precomposeunicode=false","remote","add",name,root.appendingPathComponent("unused.git").path])}
        _ = try await repository.run(["-c","core.precomposeunicode=false","config","branch."+branch+".remote",nfd])
        _ = try await repository.run(["-c","core.precomposeunicode=false","config","branch."+branch+".merge","refs/heads/topic"])
        _ = try await repository.run(["-c","core.precomposeunicode=false","config","core.precomposeunicode","true"])
        let first=try await repository.fetchDefaults()
        XCTAssertTrue(first.remote.utf8.elementsEqual(nfd.utf8))
        try await repository.removeRemote(name:nfd)
        // Keep the stale branch mapping to exercise the display-default gate,
        // rather than relying on `remote remove`'s branch-config cleanup policy.
        _ = try await repository.run(["-c","core.precomposeunicode=false","config","branch."+branch+".remote",nfd])
        _ = try await repository.run(["-c","core.precomposeunicode=false","config","branch."+branch+".merge","refs/heads/topic"])
        let names=try await repository.remoteNames()
        XCTAssertTrue(names.contains{ $0.utf8.elementsEqual(nfc.utf8) })
        XCTAssertFalse(names.contains{ $0.utf8.elementsEqual(nfd.utf8) })
        let config=try Data(contentsOf:root.appendingPathComponent(".git/config"))
        let refreshed=try await repository.fetchDefaults()
        XCTAssertTrue(refreshed.remote.isEmpty,"An NFC sibling must not validate the removed NFD remote")
        XCTAssertTrue(refreshed.trackedRemote.utf8.elementsEqual(nfd.utf8),"Raw configured tracking remains distinguishable from missing configuration")
        XCTAssertEqual(refreshed.branch,"topic")
        let push=try await repository.pushDefaults(source:branch)
        XCTAssertTrue(push.remote.isEmpty,"Push defaults must also reject the removed NFD remote's NFC sibling")
        var fetch=FetchOptions();fetch.remote=nfd
        do {_ = try await repository.fetch(fetch);XCTFail("Removed NFD remote passed named Fetch validation")}catch FetchFailure.remote{}
        var options=PushOptions();options.source=branch;options.remote=nfd
        do {try await repository.validatePushOptions(options);XCTFail("Removed NFD remote passed named Push validation")}catch PushValidationFailure.remote{}
        XCTAssertEqual(config,try Data(contentsOf:root.appendingPathComponent(".git/config")))
        let cancelled=OperationCancellation();cancelled.cancel()
        do {_ = try await repository.fetchDefaults(cancellation:cancelled);XCTFail("Cancelled refresh returned defaults")}catch is OperationCancellationFailure{}
        XCTAssertEqual(config,try Data(contentsOf:root.appendingPathComponent(".git/config")))
    }
}
