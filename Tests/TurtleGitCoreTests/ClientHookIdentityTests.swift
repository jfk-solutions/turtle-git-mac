// SPDX-License-Identifier: GPL-2.0-or-later
import XCTest
@testable import TurtleGitCore

final class ClientHookIdentityTests:XCTestCase {
    private let composed = "caf\u{e9}"
    private let decomposed = "cafe\u{301}"
    private func literalURL(_ path:String)throws->URL {
        // fileURLWithPath uses filesystem representation normalization on macOS.
        // Explicit URL octets retain both spellings for the selection contract.
        let encoded = path.utf8.map {$0 == 47 ? "/":String(format:"%%%02X",$0)}.joined()
        let url = try XCTUnwrap(URL(string:"file://" + encoded))
        XCTAssertEqual(Array(url.path.utf8),Array(path.utf8))
        return url
    }

    func testConfigurationKeepsExactScopesAndSelectsNearestOriginalSpelling() throws {
        let first = ClientHook(type:.preCommit,path:"/work/" + composed,command:"/bin/echo " + composed)
        let second = ClientHook(type:.preCommit,path:"/work/" + decomposed,command:"/bin/echo " + decomposed)
        let parent = ClientHook(type:.preCommit,path:"/work",command:"/bin/echo parent")
        let wildcard = ClientHook(type:.preCommit,path:"*",command:"/bin/echo fallback")
        XCTAssertNotEqual(first,second)
        XCTAssertEqual(Set([first.id,second.id]).count,2)
        let hooks = [second,wildcard,first,parent]
        let serialized = try ClientHookConfiguration.serialize(hooks)
        let restored = ClientHookConfiguration.parse(serialized)
        XCTAssertEqual(restored.count,4)
        XCTAssertEqual(restored,ClientHookConfiguration.sorted(hooks))
        for original in [first,second] {
            let workingTree = try literalURL(original.path + "/nested/repo")
            let selected = try XCTUnwrap(ClientHookConfiguration.selected(type:.preCommit,workingTree:workingTree,hooks:restored))
            XCTAssertEqual(selected,original)
            XCTAssertEqual(Array(selected.path.utf8),Array(original.path.utf8))
            let relativeSegments = try literalURL(original.path + "/nested/.././repo")
            XCTAssertEqual(ClientHookConfiguration.selected(type:.preCommit,workingTree:relativeSegments,hooks:restored),original)
            // A canonically equivalent sibling must not shadow the real parent.
            let sibling = original == first ? second:first
            XCTAssertEqual(ClientHookConfiguration.selected(type:.preCommit,workingTree:workingTree,hooks:[sibling,parent,wildcard]),parent)
        }
        XCTAssertThrowsError(try ClientHookConfiguration.validate([first,first]))
        var local = first;local.local = true
        XCTAssertNotEqual(local.id,first.id)
        XCTAssertEqual(ClientHookConfiguration.parse("pre_commit_hook\n?\n/bin/echo local\ntrue\nshow\n",local:true,root:second.path).first?.path.utf8.map { $0 },Array(second.path.utf8))
    }

    func testApprovalSetAndCodableBindOriginalRootTypeAndCommandBytes() throws {
        let root = "/work/" + composed, otherRoot = "/work/" + decomposed
        let command = "/bin/echo " + composed, otherCommand = "/bin/echo " + decomposed
        let original = ClientHookApprovalIdentity(root:root,type:.preCommit,command:command)
        let aliases = [original,
            ClientHookApprovalIdentity(root:otherRoot,type:.preCommit,command:command),
            ClientHookApprovalIdentity(root:root,type:.preCommit,command:otherCommand),
            ClientHookApprovalIdentity(root:root,type:.prePush,command:command)]
        XCTAssertEqual(Set(aliases).count,4)
        let encoded = try JSONEncoder().encode(aliases)
        let restored = try JSONDecoder().decode([ClientHookApprovalIdentity].self,from:encoded)
        XCTAssertEqual(restored,aliases)
        XCTAssertEqual(Set(restored).count,4)
        let savedApproval = Set([restored[0]])
        XCTAssertTrue(savedApproval.contains(original))
        for unapproved in aliases.dropFirst() { XCTAssertFalse(savedApproval.contains(unapproved)) }
        let fields = try XCTUnwrap(JSONSerialization.jsonObject(with:JSONEncoder().encode(original)) as? [String:Any])
        XCTAssertEqual(Set(fields.keys),Set(["root","type","command"]))
        let legacy = Data(#"{"root":"/work/repo","type":"pre_commit_hook","command":"/bin/echo approved"}"#.utf8)
        XCTAssertEqual(try JSONDecoder().decode(ClientHookApprovalIdentity.self,from:legacy),ClientHookApprovalIdentity(root:"/work/repo",type:.preCommit,command:"/bin/echo approved"))
    }

    func testHookEqualityAndDeterministicSortPreserveCommandAndFlagChanges() throws {
        let base = ClientHook(type:.preCommit,path:"/work/" + composed,command:"/bin/echo " + composed)
        var commandAlias = base;commandAlias.command = "/bin/echo " + decomposed
        var pathAlias = base;pathAlias.path = "/work/" + decomposed
        var disabled = base;disabled.enabled = false
        var noWait = base;noWait.wait = false
        var hidden = base;hidden.show = false
        let hooks = [base,commandAlias,pathAlias,disabled,noWait,hidden]
        for changed in hooks.dropFirst() { XCTAssertNotEqual(base,changed) }
        let sorted = ClientHookConfiguration.sorted(hooks)
        XCTAssertEqual(ClientHookConfiguration.sorted(hooks.reversed()),sorted)
        XCTAssertEqual(ClientHookConfiguration.sorted(Array(hooks.dropFirst()) + [base]),sorted)
        XCTAssertEqual(try JSONDecoder().decode([ClientHook].self,from:JSONEncoder().encode(hooks)),hooks)
        let arguments = try ClientHookCommand.arguments("/bin/echo '%root%' '" + decomposed + "'",root:pathAlias.path)
        XCTAssertEqual(Array(arguments[1].utf8),Array(pathAlias.path.utf8))
        XCTAssertEqual(Array(arguments[2].utf8),Array(decomposed.utf8))
    }

    func testProjectSaveRetainsExactCommandAndRejectsDifferentScopeBytes() async throws {
        let (storage,_,isolated) = try GeneralSetupBatchTests().fixture("")
        defer { try? FileManager.default.removeItem(at:storage) }
        let directory = storage.appendingPathComponent(composed)
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
        let repository = GitRepository(root:directory,executable:isolated.executable)
        _ = try await repository.run(["init","-b","main"])
        let configuration = directory.appendingPathComponent(".tgitconfig")
        try Data("[other]\nvalue = retained\n".utf8).write(to:configuration)
        var hook = ClientHook(type:.preCommit,path:repository.root.path,command:"/bin/echo " + decomposed,local:true)
        try await repository.saveProjectClientHooks([hook])
        var restored = try await repository.projectClientHooks()
        XCTAssertEqual(restored,[hook])
        XCTAssertEqual(Array(restored[0].command.utf8),Array(hook.command.utf8))
        let previousApproval = hook.approvalIdentity
        hook.command = "/bin/echo " + composed
        try await repository.saveProjectClientHooks([hook])
        restored = try await repository.projectClientHooks()
        XCTAssertEqual(restored,[hook])
        XCTAssertNotEqual(restored[0].approvalIdentity,previousApproval)
        let before = try Data(contentsOf:configuration)
        let nfc = repository.root.path.precomposedStringWithCanonicalMapping
        let nfd = repository.root.path.decomposedStringWithCanonicalMapping
        hook.path = GitReferenceName.equal(repository.root.path,nfc) ? nfd:nfc
        XCTAssertFalse(GitReferenceName.equal(hook.path,repository.root.path))
        do {
            try await repository.saveProjectClientHooks([hook])
            XCTFail("A different scope spelling was accepted for this repository")
        } catch ClientHookFailure.configuration {}
        XCTAssertEqual(try Data(contentsOf:configuration),before)
        let other = try await repository.run(["config","--file",configuration.path,"--get","other.value"])
        XCTAssertEqual(other.text,"retained\n")
    }
}
