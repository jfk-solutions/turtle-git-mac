import Foundation
import XCTest
@testable import TurtleGitCore

final class ScopedWorkingStatusTests:XCTestCase {
    private let folder="chosen[*] 雪",destination="chosen[*] 雪/new\t\n?.txt",outside="outside/source"
    private var bytes:Data {Data((0..<100).map{"scope source \($0) abcdefghijklmnopqrstuvwxyz\n"}.joined().utf8)}
    private func fixture()async throws->(URL,GitRepository) {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("TurtleGit-scoped-status-"+UUID().uuidString).standardizedFileURL
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        let executable=URL(fileURLWithPath:ProcessInfo.processInfo.environment["TURTLEGIT_GROUP_TEST_GIT"] ?? "/usr/bin/git")
        let repo=GitRepository(root:root,executable:executable,askpass:nil,libgit2Configuration:.init(enabled:false))
        do {
            _=try await repo.run(["init","--template=","-b","main"])
            for (key,value) in [("user.name","Scoped status QA"),("user.email","scope@example.invalid"),("commit.gpgsign","false"),("core.hooksPath","/dev/null")] {_=try await repo.run(["config",key,value])}
            for directory in [folder,"outside","chosenx 雪","generated"] {try FileManager.default.createDirectory(at:root.appendingPathComponent(directory),withIntermediateDirectories:true)}
            try bytes.write(to:root.appendingPathComponent(outside));try Data("clean\n".utf8).write(to:root.appendingPathComponent(folder+"/clean"))
            try Data("independent base\n".utf8).write(to:root.appendingPathComponent("outside/independent"))
            try Data("unstaged base\n".utf8).write(to:root.appendingPathComponent("outside/unstaged"))
            try await repo.stage([outside,"outside/independent","outside/unstaged",folder]);_=try await repo.commit(message:"base")
            _=try await repo.run(["mv","--",outside,destination])
            try Data("local\n".utf8).write(to:root.appendingPathComponent(folder+"/local"))
            try Data("unrelated\n".utf8).write(to:root.appendingPathComponent("generated/untracked"))
            try Data("glob collision\n".utf8).write(to:root.appendingPathComponent("chosenx 雪/local"))
            return(root,repo)
        } catch {try? FileManager.default.removeItem(at:root);throw error}
    }
    private func counted(_ repo:GitRepository)throws->(GitRepository,URL) {
        let wrapper=repo.root.appendingPathComponent(".git/scoped-status-git"),log=repo.root.appendingPathComponent(".git/scoped-status-argv")
        func quote(_ value:String)->String {"'"+value.replacingOccurrences(of:"'",with:"'\\''")+"'"}
        let script="""
        #!/bin/sh
        printf '%s\\0' "$@" >> \(quote(log.path))
        printf '\\0' >> \(quote(log.path))
        exec \(quote(repo.executable.path)) "$@"
        """
        try Data(script.utf8).write(to:wrapper);try FileManager.default.setAttributes([.posixPermissions:0o700],ofItemAtPath:wrapper.path)
        return(GitRepository(root:repo.root,executable:wrapper,askpass:nil,libgit2Configuration:.init(enabled:false)),log)
    }
    private func commands(_ log:URL)throws->[[String]] {
        var result:[[String]]=[],current:[String]=[]
        for packet in try Data(contentsOf:log).split(separator:0,omittingEmptySubsequences:false) {
            if packet.isEmpty {if !current.isEmpty {result.append(current);current=[]}}
            else {current.append(String(decoding:packet,as:UTF8.self))}
        }
        return result
    }
    func testScopedAddWorkingFlagsAndStatisticsNeverReadUnrelatedTrees()async throws {
        let(root,initial)=try await fixture();defer{try? FileManager.default.removeItem(at:root)}
        let(repo,log)=try counted(initial),index=root.appendingPathComponent(".git/index"),before=try Data(contentsOf:index)
        let rows=try await repo.workingTreeStatus(readPolicy:.automatic,paths:[folder])
        XCTAssertEqual(GitPathSet(rows.map(\.id)),GitPathSet([destination,folder+"/clean",folder+"/local"]))
        let added=try XCTUnwrap(rows.first{$0.id==destination})
        XCTAssertEqual(added.entry.index,"A");XCTAssertEqual(added.entry.reportingActions,[.added]);XCTAssertNil(added.entry.reportingOriginalPath)
        let direct=try await repo.addDialogSelection(paths:[destination],includeIgnored:false)
        XCTAssertEqual(direct.entries.map(\.path),[destination]);XCTAssertEqual(direct.entries.first?.status.reportingActions,[.added])
        let files=try await repo.workingTreeFiles(paths:[folder]);XCTAssertEqual(files.map(\.path),[destination])
        _=try await repo.workingTreeIndexFlags(entries:direct.entries.map(\.status))
        _=try await repo.submodulePaths(paths:[destination])
        for arguments in try commands(log) where arguments.contains("status") || arguments.contains("diff") || arguments.contains("diff-index") || arguments.contains("ls-files") {
            XCTAssertTrue(arguments.contains("--literal-pathspecs"))
            let separator=try XCTUnwrap(arguments.firstIndex(of:"--"),arguments.description)
            let paths=Array(arguments.dropFirst(separator+1))
            XCTAssertFalse(paths.isEmpty,arguments.description)
            XCTAssertTrue(paths.allSatisfy{GitReferenceName.equal($0,folder) || GitReferenceName.equal($0,destination)},arguments.description)
        }
        XCTAssertEqual(try Data(contentsOf:index),before)
    }
    func testRawScopesLoopIndividuallyAndIncludedStagedOnlyWidensCachedRead()async throws {
        let(root,initial)=try await fixture();defer{try? FileManager.default.removeItem(at:root)}
        let(repo,log)=try counted(initial)
        let report=try await repo.status(readPolicy:.automatic,paths:[destination,outside],includedStaged:false)
        XCTAssertEqual(report.first{$0.path==destination}?.reportingActions,[.added])
        XCTAssertEqual(report.first{$0.path==destination}?.index,"A")
        XCTAssertEqual(report.first{$0.path==outside}?.index,"D")
        XCTAssertEqual(report.count,2,"Separate source scopes must retain both independent A and D rows")
        let porcelain=try commands(log).filter{$0.contains("status")}
        XCTAssertEqual(porcelain.count,2)
        XCTAssertEqual(porcelain.map{Array($0.dropFirst($0.firstIndex(of:"--")!+1))},[[destination],[outside]])
        let raw=try commands(log).filter{$0.contains("diff-index")}
        XCTAssertEqual(raw.count,4)
        for (i,arguments) in raw.enumerated() {
            let separator=try XCTUnwrap(arguments.firstIndex(of:"--"))
            XCTAssertEqual(Array(arguments.dropFirst(separator+1)),[i<2 ? destination:outside])
            XCTAssertEqual(arguments.contains("--cached"),i%2==0)
        }
        try Data().write(to:log)
        let staged=try await repo.status(readPolicy:.automatic,paths:[destination],includedStaged:true)
        let row=try XCTUnwrap(staged.first{$0.path==destination})
        XCTAssertTrue(row.isRenamed);XCTAssertEqual(row.reportingOriginalPath,outside)
        let wider=try commands(log).filter{$0.contains("diff-index")}
        XCTAssertEqual(wider.count,2)
        for arguments in wider {
            let separator=try XCTUnwrap(arguments.firstIndex(of:"--"))
            XCTAssertEqual(Array(arguments.dropFirst(separator+1)),arguments.contains("--cached") ? []:[destination])
        }
    }
    func testScopedFreshRevertAndRetryNeverAcquireOutsideRenameSource()async throws {
        let(root,initial)=try await fixture();defer{try? FileManager.default.removeItem(at:root)}
        let(repo,log)=try counted(initial)
        let current=try await repo.status(readPolicy:.automatic,paths:[folder])
        let selected=try XCTUnwrap(current.first{$0.path==destination})
        XCTAssertEqual(selected.reportingActions,[.added]);XCTAssertNil(selected.reportingOriginalPath)
        let global=try await initial.status(readPolicy:.automatic)
        XCTAssertTrue(try XCTUnwrap(global.first{$0.path==destination}).isRenamed)
        let fresh=try await repo.workingFileRevertSelection([selected],paths:[folder])
        XCTAssertEqual(fresh,[selected])
        let before=try await repo.run(["ls-files","--stage","-z","--",outside]).stdout
        _=try await repo.revertWorkingFiles(fresh,policy:.init(recycle:false),paths:[folder])
        XCTAssertFalse(FileManager.default.fileExists(atPath:root.appendingPathComponent(outside).path),"Scoped Added must not restore the global rename's old name")
        XCTAssertEqual(try Data(contentsOf:root.appendingPathComponent(destination)),bytes)
        let after=try await repo.run(["ls-files","--stage","-z","--",outside]).stdout
        XCTAssertEqual(after,before)
        let retry=try await repo.workingFileRevertSelection(fresh,paths:[folder])
        XCTAssertEqual(retry.first?.state,.untracked)
        var safetyInventories=0
        for arguments in try commands(log) where arguments.contains("status") || arguments.contains("diff-index") || arguments.contains("ls-files") {
            if arguments.contains("ls-files"),arguments.contains("--cached"),!arguments.contains("--") {
                safetyInventories += 1 // Intentional raw tracked-name/inode ownership check for local Retry.
                continue
            }
            let separator=try XCTUnwrap(arguments.firstIndex(of:"--"),arguments.description)
            let paths=Array(arguments.dropFirst(separator+1))
            XCTAssertFalse(paths.isEmpty)
            // The explicit outside ls-files witness before/after mutation is
            // a test observation, not discovery; all status/raw reads stay in.
            if !arguments.contains("ls-files") {XCTAssertTrue(paths.allSatisfy{GitReferenceName.equal($0,folder) || GitReferenceName.equal($0,destination)},arguments.description)}
        }
        XCTAssertGreaterThan(safetyInventories,0,"Present local Retry must retain its canonical/inode safety inventory")
    }
    func testScopedIgnoredCleanDirectEmptyAndCancellationContracts()async throws {
        let(root,repo)=try await fixture();defer{try? FileManager.default.removeItem(at:root)}
        try FileManager.default.createDirectory(at:root.appendingPathComponent(".git/info"),withIntermediateDirectories:true)
        try Data("*.ignored\n".utf8).write(to:root.appendingPathComponent(".git/info/exclude"))
        for name in [folder+"/note.ignored","generated/outside.ignored"] {try Data("ignored\n".utf8).write(to:root.appendingPathComponent(name))}
        let selection=try await repo.addDialogSelection(paths:[folder],includeIgnored:true)
        XCTAssertTrue(selection.entries.contains{$0.path==folder+"/note.ignored" && $0.state == .ignored})
        XCTAssertFalse(selection.entries.contains{$0.path.hasPrefix("generated/")})
        let clean=try await repo.addDialogSelection(paths:[folder+"/clean"],includeIgnored:false)
        XCTAssertEqual(clean.entries.first?.state,.normal)
        let empty=try await repo.status(readPolicy:.automatic,paths:[]);XCTAssertTrue(empty.isEmpty)
        let token=OperationCancellation();token.cancel()
        do {_=try await repo.workingTreeStatus(readPolicy:.automatic,paths:[folder],cancellation:token);XCTFail("Cancelled scoped read admitted")}catch is OperationCancellationFailure {}
        do {_=try await repo.status(readPolicy:.automatic,paths:["../outside"]);XCTFail("Escaping scope admitted")}catch WorkingFileRestoreFailure.location {}
    }
}

extension ScopedWorkingStatusTests {
    func testSeparateDestinationAndOldNameScopesRevertBothWithoutDroppingDeletion()async throws {
        let(root,repo)=try await fixture();defer{try? FileManager.default.removeItem(at:root)}
        let scope=[destination,outside]
        let accepted=try await repo.status(readPolicy:.automatic,paths:scope)
        XCTAssertEqual(accepted.count,2)
        XCTAssertEqual(accepted.first{$0.path==destination}?.reportingActions,[.added])
        XCTAssertEqual(accepted.first{$0.path==outside}?.reportingActions,[.deleted])
        let fresh=try await repo.workingFileRevertSelection(accepted,paths:scope)
        XCTAssertEqual(GitPathSet(fresh.map(\.path)),GitPathSet(scope))
        _=try await repo.revertWorkingFiles(fresh,policy:.init(recycle:false),paths:scope)
        XCTAssertEqual(try Data(contentsOf:root.appendingPathComponent(outside)),bytes)
        XCTAssertEqual(try Data(contentsOf:root.appendingPathComponent(destination)),bytes)
        let status=try await repo.status(readPolicy:.automatic,paths:scope)
        XCTAssertEqual(status.count,1);XCTAssertEqual(status.first?.path,destination);XCTAssertEqual(status.first?.state,.untracked)
    }
    func testIncludedStagedPublishesIndependentOutsideRowsWithoutUntrackedTraversal()async throws {
        let(root,initial)=try await fixture();defer{try? FileManager.default.removeItem(at:root)}
        try Data("independent staged edit\n".utf8).write(to:root.appendingPathComponent("outside/independent"))
        try Data("independent addition\n".utf8).write(to:root.appendingPathComponent("outside/added"))
        try Data("must not enumerate\n".utf8).write(to:root.appendingPathComponent("outside/untracked"))
        try await initial.stage(["outside/independent","outside/added"])
        let(repo,log)=try counted(initial)
        let report=try await repo.status(readPolicy:.automatic,paths:[destination],includedStaged:true)
        XCTAssertEqual(report.first{$0.path==destination}?.index,"A","Original selected-path XY must survive included-staged enrichment")
        XCTAssertEqual(report.first{$0.path==destination}?.reportingActions,[.renamed])
        XCTAssertEqual(report.first{$0.path==destination}?.reportingOriginalPath,outside)
        XCTAssertFalse(report.contains{$0.path==outside},"Global cached Rename consumes redundant old-name deletion")
        XCTAssertEqual(report.first{$0.path=="outside/independent"}?.index,"M")
        XCTAssertEqual(report.first{$0.path=="outside/added"}?.index,"A")
        XCTAssertFalse(report.contains{$0.path=="outside/untracked" || $0.path.hasPrefix("generated/")})
        let reads=try commands(log).filter{$0.contains("status")}
        XCTAssertGreaterThan(reads.count,1)
        for arguments in reads {
            let separator=try XCTUnwrap(arguments.firstIndex(of:"--"))
            let paths=Array(arguments.dropFirst(separator+1));XCTAssertFalse(paths.isEmpty)
            if paths != [destination] {XCTAssertTrue(arguments.contains("--untracked-files=no"))}
        }
        // These index flags coexist with already staged changes; inspect real
        // ls-files output before asserting the report's admitted flag facts.
        _=try await initial.run(["update-index","--assume-unchanged","--","outside/independent"])
        _=try await initial.run(["update-index","--skip-worktree","--","outside/added"])
        let actualFlags=try await initial.run(["ls-files","-v","-z","--","outside/independent","outside/added"]).stdout
        let flagRecords=actualFlags.split(separator:0).map{String(decoding:$0,as:UTF8.self)}
        XCTAssertTrue(flagRecords.contains{"h outside/independent" == $0})
        XCTAssertTrue(flagRecords.contains{"S outside/added" == $0})
        let withFlags=try await repo.workingTreeStatus(readPolicy:.automatic,paths:[destination],includedStaged:true)
        XCTAssertTrue(try XCTUnwrap(withFlags.first{$0.id=="outside/independent"}).assumeUnchanged)
        XCTAssertTrue(try XCTUnwrap(withFlags.first{$0.id=="outside/added"}).skipWorktree)
        let plain=try await repo.status(readPolicy:.automatic,paths:[destination],includedStaged:false)
        XCTAssertEqual(plain.map(\.path),[destination]);XCTAssertEqual(plain.first?.reportingActions,[.added])
    }
}

extension ScopedWorkingStatusTests {
    func testOutsideOrEmptyCapturedRevertScopeRefusesBeforeLaunchingGit()async throws {
        let(root,initial)=try await fixture();defer{try? FileManager.default.removeItem(at:root)}
        let(repo,log)=try counted(initial)
        let outsideEntry=StatusEntry(path:outside,index:"D",worktree:" ")
        let destinationEntry=StatusEntry(path:destination,index:"A",worktree:" ")
        let forgedRename=StatusEntry(path:destination,index:"R",worktree:" ",sourceActions:.renamed,sourceOriginalPath:outside)
        for (selected,scope) in [([outsideEntry],[folder]),([destinationEntry],[]),([forgedRename],[folder])] {
            do {_=try await repo.workingFileRevertSelection(selected,paths:scope);XCTFail("Outside Revert retry admitted")}catch is GitFailure {}
            do {_=try await repo.revertWorkingFiles(selected,policy:.init(recycle:false),paths:scope);XCTFail("Outside Revert mutation admitted")}catch is GitFailure {}
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath:log.path),"Scope refusal must precede even Git metadata/status reads")
        XCTAssertEqual(try Data(contentsOf:root.appendingPathComponent(destination)),bytes)
    }
}

extension ScopedWorkingStatusTests {
    func testScopedCommitReusesCachedRosterAndKeepsOutsidePartialStateAndNumbers()async throws {
        let(root,initial)=try await fixture();defer{try? FileManager.default.removeItem(at:root)}
        try Data("independent staged edit\n".utf8).write(to:root.appendingPathComponent("outside/independent"))
        try await initial.stage(["outside/independent"])
        try Data("independent working edit\nextra working line\n".utf8).write(to:root.appendingPathComponent("outside/independent"))
        // Only the clean file's working modification is unrelated to Commit's scope.
        try Data("outside unstaged only\n".utf8).write(to:root.appendingPathComponent("outside/unstaged"))
        let(repo,log)=try counted(initial)
        let captured=try await repo.commitDialogRead(amend:false,amendDiffToLastCommit:true,paths:[folder])
        let partial=try XCTUnwrap(captured.entries.first{$0.path=="outside/independent"})
        XCTAssertEqual(String([partial.index,partial.worktree]),"MM")
        XCTAssertFalse(captured.entries.contains{$0.path=="generated/untracked" || $0.path=="outside/unstaged" || $0.path.hasPrefix("chosenx 雪/")})
        XCTAssertTrue(captured.entries.contains{$0.path==folder+"/local" && $0.state == .untracked})
        let staged=try XCTUnwrap(captured.staged.first{$0.path==partial.path})
        let unstaged=try XCTUnwrap(captured.unstaged.first{$0.path==partial.path})
        let classic=try XCTUnwrap(captured.working.first{$0.path==partial.path})
        XCTAssertEqual(staged.added,1);XCTAssertEqual(staged.removed,1)
        XCTAssertEqual(unstaged.added,2);XCTAssertEqual(unstaged.removed,1)
        XCTAssertEqual(classic.added,staged.added);XCTAssertEqual(classic.removed,staged.removed)
        let commands=try commands(log)
        XCTAssertEqual(commands.filter{$0.contains("diff-index") && $0.contains("--cached")}.count,1,"One captured global cached stream must supply reporting and staged roster")
        XCTAssertFalse(commands.contains{$0.contains("--name-only")},"Captured Commit must not reread a global cached-name roster")
        for arguments in commands where arguments.contains("status") {
            let separator=try XCTUnwrap(arguments.firstIndex(of:"--"))
            let paths=Array(arguments.dropFirst(separator+1));XCTAssertFalse(paths.isEmpty)
            if paths != [folder] {XCTAssertTrue(arguments.contains("--untracked-files=no"))}
        }
        for arguments in commands where arguments.contains("diff-index") && !arguments.contains("--cached") {
            let separator=try XCTUnwrap(arguments.firstIndex(of:"--"))
            XCTAssertEqual(Array(arguments.dropFirst(separator+1)),[folder])
        }
        let whole=try await initial.commitDialogRead(amend:false,amendDiffToLastCommit:true)
        XCTAssertTrue(whole.entries.contains{$0.path=="generated/untracked"})
    }
    func testScopedParentAmendKeepsGlobalParentChangesAndMultiScopeAAndD()async throws {
        let(root,initial)=try await fixture();defer{try? FileManager.default.removeItem(at:root)}
        try Data("outside HEAD-only commit change\n".utf8).write(to:root.appendingPathComponent("outside/independent"))
        try await initial.stage(["outside/independent"])
        _=try await initial.commit(message:"outside HEAD changes")
        let(repo,log)=try counted(initial)
        let amended=try await repo.commitDialogRead(amend:true,amendDiffToLastCommit:false,paths:[folder])
        XCTAssertNotNil(amended.comparisonBase)
        let outsideEntry=try XCTUnwrap(amended.entries.first{$0.path=="outside/independent"})
        XCTAssertEqual(outsideEntry.comparisonAction,"M")
        XCTAssertTrue(amended.staged.contains{$0.path==outsideEntry.path})
        XCTAssertTrue(amended.working.contains{$0.path==outsideEntry.path},"Classic needs cached parent-relative counts for an outside HEAD-only row")
        XCTAssertFalse(amended.entries.contains{$0.path=="generated/untracked"})
        for arguments in try commands(log) where arguments.contains("status") {
            XCTAssertTrue(arguments.contains("--"))
            if !arguments.contains("--untracked-files=no") {XCTAssertEqual(Array(arguments.dropFirst(arguments.firstIndex(of:"--")!+1)),[folder])}
        }
        // Per-invocation whole streams cannot invent a cross-scope pairing.
        let(base,second)=try await fixture();defer{try? FileManager.default.removeItem(at:base)}
        let split=try await second.commitDialogRead(amend:false,amendDiffToLastCommit:true,paths:[destination,self.outside])
        let raw=try await second.status(readPolicy:.automatic,paths:[destination,self.outside],includedStaged:false)
        XCTAssertEqual(raw.first{$0.path==destination}?.index,"A");XCTAssertEqual(raw.first{$0.path==self.outside}?.index,"D")
        // Commit includes the source-required global cached R, so its report
        // merges the old alias while retaining the originally selected XY A.
        XCTAssertEqual(split.entries.first{$0.path==destination}?.index,"A")
        XCTAssertTrue(try XCTUnwrap(split.entries.first{$0.path==destination}).isRenamed)
        XCTAssertFalse(split.entries.contains{$0.path==self.outside})
    }
}

extension ScopedWorkingStatusTests {
    func testScopedSubmoduleModeInventoryUsesLiteralAcceptedPathsAndRetainsGlobalDefault()async throws {
        let(root,initial)=try await fixture();defer{try? FileManager.default.removeItem(at:root)}
        let head=try await initial.run(["rev-parse","HEAD"]).text.trimmingCharacters(in:.newlines)
        let inside=folder+"/module",other="outside/module"
        for path in [inside,other] {_=try await initial.run(["update-index","--add","--cacheinfo","160000,"+head+","+path])}
        let(repo,log)=try counted(initial)
        let scoped=try await repo.submodulePaths(paths:[inside])
        XCTAssertEqual(scoped,[inside])
        let folderNames=try await repo.submodulePathNames(paths:[folder])
        XCTAssertEqual(folderNames,[GitReferenceName(inside)])
        let all=try await initial.submodulePaths()
        XCTAssertTrue(all.contains(inside));XCTAssertTrue(all.contains(other))
        let empty=try await repo.submodulePaths(paths:[]);XCTAssertTrue(empty.isEmpty)
        let queries=try commands(log).filter{$0.contains("ls-files")}
        XCTAssertEqual(queries.count,2)
        for (query,path) in zip(queries,[inside,folder]) {
            XCTAssertTrue(query.contains("--literal-pathspecs"))
            let separator=try XCTUnwrap(query.firstIndex(of:"--"))
            XCTAssertEqual(Array(query.dropFirst(separator+1)),[path])
        }
    }
}
