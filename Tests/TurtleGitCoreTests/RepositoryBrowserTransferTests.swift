import XCTest
@testable import TurtleGitCore

final class RepositoryBrowserTransferTests:XCTestCase {
    func testInventoryPinsPeeledTreeAndPreservesLiteralLeavesAndModes()async throws {
        let(root,repo,path)=try await GitPatchTests().fixture();defer{try? FileManager.default.removeItem(at:root)}
        let literal="folder/literal\tline\n雪.txt"
        try FileManager.default.createDirectory(at:root.appendingPathComponent("folder/deep"),withIntermediateDirectories:true)
        try Data("literal\n".utf8).write(to:root.appendingPathComponent(literal))
        try Data("#!/bin/sh\n".utf8).write(to:root.appendingPathComponent("folder/deep/run"))
        try FileManager.default.setAttributes([.posixPermissions:0o755],ofItemAtPath:root.appendingPathComponent("folder/deep/run").path)
        try await repo.stage(["."]);_=try await repo.commit(message:"inventory tree")
        let old=try await repo.rebaseCommit("HEAD").hash
        _=try await repo.run(["update-index","--add","--cacheinfo","160000",old,"folder/module"])
        _=try await repo.commit(message:"gitlink leaf");_=try await repo.run(["tag","-a","inventory-tag","-m","snapshot"])
        let snapshot=try await repo.browseRepository(revision:"inventory-tag")
        let head=try await repo.run(["rev-parse","HEAD"]).stdout,index=try Data(contentsOf:root.appendingPathComponent(".git/index"))
        let inventory=try await repo.repositoryBrowserTransferInventory(snapshot)
        XCTAssertTrue(inventory.contains{$0.path==literal && $0.name=="literal\tline\n雪.txt"})
        XCTAssertEqual(inventory.first{$0.path=="folder/module"}?.kind,.submodule)
        XCTAssertEqual(inventory.first{$0.path=="folder/deep/run"}?.kind,.executable)
        XCTAssertEqual(inventory.first{$0.path=="folder"}?.kind,.directory)
        let nested=try await repo.browseRepositoryDirectory(snapshot,directory:"folder")
        let same=try await repo.repositoryBrowserTransferInventory(nested)
        XCTAssertEqual(same,inventory)
        let subtree=try await repo.repositoryBrowserTransferInventory(nested,directory:"folder/deep")
        XCTAssertEqual(subtree.map(\.path),["folder/deep/run"])
        XCTAssertEqual(try Data(contentsOf:root.appendingPathComponent(".git/index")),index)
        let after=try await repo.run(["rev-parse","HEAD"]).stdout;XCTAssertEqual(after,head)
        try Data("new mutable head\n".utf8).write(to:root.appendingPathComponent(path));try await repo.stage([path]);_=try await repo.commit(message:"move branch")
        let pinned=try await repo.repositoryBrowserTransferInventory(snapshot)
        let newer=try await repo.rebaseCommit("HEAD").hash;XCTAssertEqual(pinned,inventory);XCTAssertNotEqual(snapshot.objectID,newer)
    }
    func testInventoryBoundCancellationAndForeignSnapshotDoNotMutateInputs()async throws {
        let(root,repo,_)=try await GitPatchTests().fixture();defer{try? FileManager.default.removeItem(at:root)}
        try Data([1,2]).write(to:root.appendingPathComponent("second"));try await repo.stage(["second"]);_=try await repo.commit(message:"two entries")
        let snapshot=try await repo.browseRepository(),index=try Data(contentsOf:root.appendingPathComponent(".git/index"))
        do{_=try await repo.repositoryBrowserTransferInventory(snapshot,maximumEntries:1);XCTFail("Partial inventory was accepted")}catch RepositoryBrowserFailure.transferLimit{}
        let token=OperationCancellation();token.cancel()
        do{_=try await repo.repositoryBrowserTransferInventory(snapshot,cancellation:token);XCTFail("Cancellation ignored")}catch is OperationCancellationFailure{}
        let foreign=GitRepository(root:root.appendingPathComponent("unrelated"))
        do{_=try await foreign.repositoryBrowserTransferInventory(snapshot);XCTFail("Foreign root accepted")}catch RepositoryBrowserFailure.selection{}
        do{_=try await repo.repositoryBrowserTransferInventory(snapshot,directory:"../escape");XCTFail("Traversal accepted")}catch RepositoryBrowserFailure.selection{}
        XCTAssertEqual(try Data(contentsOf:root.appendingPathComponent(".git/index")),index)
        let complete=try await repo.repositoryBrowserTransferInventory(snapshot);XCTAssertEqual(complete.count,2)
    }
    func testSmallSubtreeRemainsAvailableWhenWholeInventoryExceedsBudget()async throws {
        let(root,repo,_)=try await GitPatchTests().fixture();defer{try? FileManager.default.removeItem(at:root)}
        try FileManager.default.createDirectory(at:root.appendingPathComponent("small"),withIntermediateDirectories:true)
        try Data("small\n".utf8).write(to:root.appendingPathComponent("small/leaf"));try await repo.stage(["."]);_=try await repo.commit(message:"small subtree")
        let snapshot=try await repo.browseRepository()
        do{_=try await repo.repositoryBrowserTransferInventory(snapshot,maximumEntries:1);XCTFail("Expected bounded refusal")}catch RepositoryBrowserFailure.transferLimit{}
        let result=try await repo.repositoryBrowserTransferInventory(snapshot,directory:"small",maximumEntries:1)
        XCTAssertEqual(result.map(\.path),["small/leaf"])
    }
    func testSubtreeArgumentsRetainDistinctCanonicalUnicodeIdentity()async throws {
        let(root,repo,_)=try await GitPatchTests().fixture();defer{try? FileManager.default.removeItem(at:root)}
        let composed="caf\u{e9}",decomposed="cafe\u{301}"
        let a=try await repo.run(["hash-object","-w","--stdin"],input:Data("one".utf8)).text.trimmingCharacters(in:.newlines)
        let b=try await repo.run(["hash-object","-w","--stdin"],input:Data("two".utf8)).text.trimmingCharacters(in:.newlines)
        let at=try await repo.run(["mktree","-z"],input:Data("100644 blob \(a)\tfirst\0".utf8)).text.trimmingCharacters(in:.newlines)
        let bt=try await repo.run(["mktree","-z"],input:Data("100644 blob \(b)\tsecond\0".utf8)).text.trimmingCharacters(in:.newlines)
        let tree=try await repo.run(["mktree","-z"],input:Data("040000 tree \(at)\t\(composed)\0".utf8)+Data("040000 tree \(bt)\t\(decomposed)\0".utf8)).text.trimmingCharacters(in:.newlines)
        _=try await repo.run(["config","core.precomposeUnicode","true"])
        let snapshot=try await repo.browseRepository(revision:tree)
        let first=try await repo.repositoryBrowserTransferInventory(snapshot,directory:composed)
        let second=try await repo.repositoryBrowserTransferInventory(snapshot,directory:decomposed)
        XCTAssertEqual(first.first?.objectID,a);XCTAssertEqual(second.first?.objectID,b)
        XCTAssertEqual(first.map{Data($0.path.utf8)},[Data((composed+"/first").utf8)])
        XCTAssertEqual(second.map{Data($0.path.utf8)},[Data((decomposed+"/second").utf8)])
        let preference=try await repo.run(["config","--get","core.precomposeUnicode"]).text
        XCTAssertEqual(preference,"true\n")
    }

}
