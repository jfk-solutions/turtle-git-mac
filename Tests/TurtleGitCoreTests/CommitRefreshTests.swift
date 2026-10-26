import XCTest
@testable import TurtleGitCore

final class CommitRefreshTests:XCTestCase {
    func testCommitOmitsIgnoredRowsWithoutChangingDefaultStatusOrRealChanges()async throws {
        let (root,repo,path)=try await GitPatchTests().fixture();defer {try? FileManager.default.removeItem(at:root)}
        try Data("*.ignored\n".utf8).write(to:root.appendingPathComponent(".gitignore"))
        try Data("ignored\n".utf8).write(to:root.appendingPathComponent("hidden.ignored"))
        try Data("untracked\n".utf8).write(to:root.appendingPathComponent("untracked 雪\n.txt"))
        try Data("changed\n".utf8).write(to:root.appendingPathComponent(path))
        let full=try await repo.status(readPolicy:.automatic),commit=try await repo.commitDialogStatus(amendToParent:false,refreshIndex:false)
        XCTAssertTrue(full.contains{$0.path=="hidden.ignored" && $0.state == .ignored})
        XCTAssertFalse(commit.contains{$0.state == .ignored})
        XCTAssertEqual(commit.map{Data($0.path.utf8)},full.filter{$0.state != .ignored}.map{Data($0.path.utf8)})
        XCTAssertTrue(commit.contains{$0.path==path && $0.worktree == "M"})
        XCTAssertTrue(commit.contains{$0.path=="untracked 雪\n.txt" && $0.state == .untracked})
        let scoped=try await repo.workingTreeIndexFlags(entries:commit)
        XCTAssertEqual(scoped.map{Data($0.entry.path.utf8)},commit.map{Data($0.path.utf8)})
        XCTAssertTrue(scoped.allSatisfy{$0.modificationDate==nil})
        let amended=try await repo.commitDialogStatus(amendToParent:true,refreshIndex:false)
        XCTAssertFalse(amended.contains{$0.state == .ignored})
    }
    func testIgnoredRecreatedDeletedCopiesSurviveFastOrdinaryAndAmendStatus()async throws {
        let (root,repo,_)=try await GitPatchTests().fixture();defer {try? FileManager.default.removeItem(at:root)}
        let names=["recreated 雪\n.ignored","broken-link.ignored","missing.ignored","directory.ignored"]
        for name in names {try Data("tracked baseline\n".utf8).write(to:root.appendingPathComponent(name))}
        try await repo.stage(names);_=try await repo.commit(message:"tracked ignored-name baselines")
        _=try await repo.run(["commit","--allow-empty","-m","amend comparison boundary"])
        _=try await repo.run(["rm","--cached","--"]+names)
        for name in names {try FileManager.default.removeItem(at:root.appendingPathComponent(name))}
        let local=Data("local recreated bytes\n".utf8)
        try local.write(to:root.appendingPathComponent(names[0]))
        try FileManager.default.createSymbolicLink(atPath:root.appendingPathComponent(names[1]).path,withDestinationPath:"missing target")
        try FileManager.default.createDirectory(at:root.appendingPathComponent(names[3]),withIntermediateDirectories:false)
        try Data("*.ignored\n".utf8).write(to:root.appendingPathComponent(".git/info/exclude"))
        let beforeHead=try await repo.run(["rev-parse","HEAD"]).stdout,beforeIndex=try await repo.run(["ls-files","--stage","-z"]).stdout
        let fast=try await repo.status(readPolicy:.automatic,includeIgnored:false)
        XCTAssertEqual(fast.filter{names.contains($0.path)}.count,names.count)
        XCTAssertTrue(fast.filter{names.contains($0.path)}.allSatisfy{$0.index == "D" && !$0.hasUnversionedCopy})
        for amend in [false,true] {
            let rows=try await repo.commitDialogStatus(amendToParent:amend,refreshIndex:false)
            XCTAssertFalse(rows.contains{$0.state == .ignored})
            for (offset,name) in names.enumerated() {
                let row=try XCTUnwrap(rows.first{Data($0.path.utf8)==Data(name.utf8)})
                XCTAssertEqual(row.index,"D")
                XCTAssertEqual(row.hasUnversionedCopy,offset<2,"Local-copy metadata for \(name)")
            }
        }
        XCTAssertEqual(try Data(contentsOf:root.appendingPathComponent(names[0])),local)
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath:root.appendingPathComponent(names[1]).path),"missing target")
        XCTAssertFalse(FileManager.default.fileExists(atPath:root.appendingPathComponent(names[2]).path))
        let afterHead=try await repo.run(["rev-parse","HEAD"]).stdout,afterIndex=try await repo.run(["ls-files","--stage","-z"]).stdout
        XCTAssertEqual(afterHead,beforeHead);XCTAssertEqual(afterIndex,beforeIndex)
    }
    func testScopedFlagsUseOneIndexReadAndKeepLiteralCaseUnicodeRenameIdentities()async throws {
        let (root,repo,_)=try await GitPatchTests().fixture();defer {try? FileManager.default.removeItem(at:root)}
        _ = try await repo.run(["config","core.precomposeunicode","false"])
        _ = try await repo.run(["config","core.ignorecase","false"])
        let names=["Case.txt","case.txt","Caf\u{e9}.txt","Cafe\u{301}.txt","renamed\n雪.txt"]
        let blob=try await repo.run(["hash-object","-w","--stdin"],input:Data("index only\n".utf8)).text.trimmingCharacters(in:.newlines)
        let packet=Data(names.flatMap{Array(("100644 "+blob+"\t"+$0).utf8)+[0]})
        _ = try await repo.run(["update-index","-z","--index-info"],input:packet)
        _ = try await repo.run(["update-index","--assume-unchanged","--",names[0],names[2]])
        _ = try await repo.run(["update-index","--skip-worktree","--",names[1],names[3]])
        let supplied=names.enumerated().map{StatusEntry(path:$0.element,originalPath:$0.offset==4 ? "old literal.txt":nil,index:$0.offset==4 ? "R":" ",worktree:" ")}+[StatusEntry(path:"untracked.txt",originalPath:nil,index:"?",worktree:"?")]
        let wrapper=root.appendingPathComponent(".git/scoped-flags-git"),log=root.appendingPathComponent(".git/scoped-flags-commands")
        func quote(_ value:String)->String {"'"+value.replacingOccurrences(of:"'",with:"'\\''")+"'"}
        let script="#!/bin/sh\nprintf '%s\\n' \"$@\" >> "+quote(log.path)+"\nexec "+quote(repo.executable.path)+" \"$@\"\n"
        try Data(script.utf8).write(to:wrapper);try FileManager.default.setAttributes([.posixPermissions:0o700],ofItemAtPath:wrapper.path)
        let captured=GitRepository(root:root,executable:wrapper,libgit2Configuration:.init(enabled:false))
        let flags=try await captured.workingTreeIndexFlags(entries:supplied)
        XCTAssertEqual(flags.map{Data($0.id.utf8)},supplied.map{Data($0.path.utf8)})
        XCTAssertEqual(flags.map(\.assumeUnchanged),[true,false,true,false,false,false])
        XCTAssertEqual(flags.map(\.skipWorktree),[false,true,false,true,false,false])
        XCTAssertEqual(flags[4].entry.originalPath,"old literal.txt");XCTAssertEqual(flags[4].entry.index,"R")
        XCTAssertEqual(flags.last?.entry.state,.untracked);XCTAssertTrue(flags.allSatisfy{$0.modificationDate==nil})
        let commands=try String(contentsOf:log,encoding:.utf8).split(separator:"\n").map(String.init)
        XCTAssertEqual(commands.filter{$0=="ls-files"}.count,1);XCTAssertFalse(commands.contains("status"))
        try FileManager.default.removeItem(at:log)
        let empty=try await captured.workingTreeIndexFlags(entries:[])
        XCTAssertTrue(empty.isEmpty);XCTAssertFalse(FileManager.default.fileExists(atPath:log.path))
        let token=OperationCancellation();token.cancel()
        do {_ = try await captured.workingTreeIndexFlags(entries:supplied,cancellation:token);XCTFail("Cancelled flag read spawned Git")}catch OperationCancellationFailure.cancelled {}
        XCTAssertFalse(FileManager.default.fileExists(atPath:log.path))
    }
    func testConflictRowsAndStagesSurviveCommitRefreshWithoutIgnoredInventory()async throws {
        let (root,repo,path)=try await GitPatchTests().fixture();defer {try? FileManager.default.removeItem(at:root)}
        _ = try await repo.run(["checkout","-b","other"])
        try Data("other\n".utf8).write(to:root.appendingPathComponent(path));try await repo.stage([path]);_ = try await repo.commit(message:"other")
        _ = try await repo.run(["checkout","main"])
        try Data("main\n".utf8).write(to:root.appendingPathComponent(path));try await repo.stage([path]);_ = try await repo.commit(message:"main")
        _ = try await repo.run(["merge","other"],successfulExitCodes:0...1)
        try Data("*.ignored\n".utf8).write(to:root.appendingPathComponent(".gitignore"));try Data("hidden".utf8).write(to:root.appendingPathComponent("conflict.ignored"))
        let before=try await repo.run(["ls-files","--stage","-z"]).stdout
        let entries=try await repo.commitDialogStatus(amendToParent:false,refreshIndex:false),flags=try await repo.workingTreeIndexFlags(entries:entries)
        XCTAssertTrue(entries.contains{$0.path==path && $0.state == .conflicted});XCTAssertFalse(entries.contains{$0.state == .ignored})
        XCTAssertTrue(flags.contains{$0.entry.path==path && $0.entry.state == .conflicted})
        let after=try await repo.run(["ls-files","--stage","-z"]).stdout
        XCTAssertEqual(after,before,"Display refresh must not stage a resolution")
    }
}
