import XCTest
@testable import TurtleGitCore

final class ResetOperationTests:XCTestCase {
    func testSuccessfulAmbiguousRefWarningIsNotPartOfCanonicalResetTarget() async throws {
        let (root,repo,base,latest)=try await ResetTests().fixture()
        defer {try? FileManager.default.removeItem(at:root)}
        _ = try await repo.run(["config","core.warnAmbiguousRefs","true"])
        _ = try await repo.run(["branch","collision",latest])
        _ = try await repo.run(["tag","collision",base])
        let resolved=try await repo.run(["rev-parse","--verify","--end-of-options","collision^{commit}"])
        XCTAssertFalse(resolved.stderr.isEmpty,"Real Git must exercise its successful ambiguity diagnostic")
        let plan=try await repo.prepareReset(to:"collision",mode:.soft)
        XCTAssertEqual(plan.revision,base)
        XCTAssertEqual(plan.originalHead,latest)
        XCTAssertEqual(plan.originalReference,"refs/heads/main")
        let index=try Data(contentsOf:root.appendingPathComponent(".git/index"))
        let file=try Data(contentsOf:root.appendingPathComponent("file.txt"))
        _ = try await repo.reset(plan)
        let head=try await repo.run(["rev-parse","HEAD"]).stdout
        XCTAssertEqual(head,Data((base+"\n").utf8))
        XCTAssertEqual(try Data(contentsOf:root.appendingPathComponent(".git/index")),index)
        XCTAssertEqual(try Data(contentsOf:root.appendingPathComponent("file.txt")),file)
    }

    func testSuccessfulHeadAndSymbolicReferenceDiagnosticsDoNotInvalidateReceipt() async throws {
        let (root,repo,base,latest)=try await ResetTests().fixture()
        defer {try? FileManager.default.removeItem(at:root)}
        // The wrapper adds a harmless successful stderr diagnostic to actual Git
        // plumbing, exercising both preparation and the final HEAD/ref recheck.
        let wrapper=root.appendingPathComponent("git-reset-diagnostic")
        let quote="'"+repo.executable.path.replacingOccurrences(of:"'",with:"'\\''")+"'"
        let script="""
        #!/bin/sh
        for task_argument do
          case "$task_argument" in
            rev-parse|symbolic-ref) printf '%s\\n' 'successful plumbing diagnostic' >&2; break;;
          esac
        done
        exec \(quote) "$@"
        """
        try Data(script.utf8).write(to:wrapper)
        try FileManager.default.setAttributes([.posixPermissions:0o755],ofItemAtPath:wrapper.path)
        let noisy=GitRepository(root:root,executable:wrapper)
        let plan=try await noisy.prepareReset(to:base,mode:.mixed)
        XCTAssertEqual(plan.revision,base);XCTAssertEqual(plan.originalHead,latest)
        XCTAssertEqual(plan.originalReference,"refs/heads/main")
        _ = try await noisy.reset(plan)
        let head=try await repo.run(["rev-parse","HEAD"]).stdout
        XCTAssertEqual(head,Data((base+"\n").utf8))
        let working=try String(contentsOf:root.appendingPathComponent("file.txt"))
        XCTAssertEqual(working,"working\n")
        let detached=try await repo.run(["checkout","--detach",base]);_ = detached
        let detachedPlan=try await noisy.prepareReset(to:base,mode:.soft)
        XCTAssertNil(detachedPlan.originalReference)
        _ = try await noisy.reset(detachedPlan)
    }
}
