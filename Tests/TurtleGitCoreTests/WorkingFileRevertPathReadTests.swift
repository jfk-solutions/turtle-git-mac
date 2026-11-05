import XCTest
import Darwin
@testable import TurtleGitCore

final class WorkingFileRevertPathReadTests:XCTestCase {
    private struct Call {
        let kind:String,locks:String,arguments:[String]
    }
    private func fixture()async throws->(URL,GitRepository) {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("revert-path-read-"+UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        let git=URL(fileURLWithPath:ProcessInfo.processInfo.environment["TURTLEGIT_GROUP_TEST_GIT"] ?? "/usr/bin/git")
        let repo=GitRepository(root:root,executable:git,askpass:nil,libgit2Configuration:.init(enabled:false))
        do {
            _=try await repo.run(["init","--template=","-b","main"])
            for (key,value) in [("user.name","Revert Path QA"),("user.email","revert-path@example.invalid"),("commit.gpgsign","false"),("core.hooksPath","/dev/null"),("core.precomposeunicode","true")] {
                _=try await repo.run(["config",key,value])
            }
            try Data("seed\n".utf8).write(to:root.appendingPathComponent("seed"))
            try await repo.stage(["seed"]);_=try await repo.commit(message:"seed")
            return(root,repo)
        } catch {try? FileManager.default.removeItem(at:root);throw error}
    }
    private func reader(_ repo:GitRepository,mode:String="normal")throws->(GitRepository,URL,URL,URL) {
        let wrapper=repo.root.appendingPathComponent(".git/revert-reader"),log=repo.root.appendingPathComponent(".git/revert-reader-arguments")
        let ready=repo.root.appendingPathComponent(".git/revert-reader-ready"),hold=repo.root.appendingPathComponent(".git/revert-reader-hold")
        func quote(_ value:String)->String {"'"+value.replacingOccurrences(of:"'",with:"'\\''")+"'"}
        let script="""
        #!/bin/sh
        kind=ordinary
        for argument in "$@"; do
          if [ "$argument" = --ignored ]; then kind=status; fi
          if [ "$argument" = ls-files ]; then kind=index; fi
          if [ "$argument" = --cached ]; then kind=ownership; fi
        done
        locks=unset
        if [ -n "$GIT_OPTIONAL_LOCKS" ]; then locks="$GIT_OPTIONAL_LOCKS"; fi
        printf '%s\\0' "$kind" "$locks" "$#" "$@" >> \(quote(log.path))
        if [ \(quote(mode)) = malformed-status ] && [ "$kind" = status ]; then
          printf '?? truncated'; exit 0
        fi
        if [ \(quote(mode)) = malformed-index ] && [ "$kind" = index ]; then
          printf 'seed'; exit 0
        fi
        if [ \(quote(mode)) = invalid-utf8-index ] && [ "$kind" = index ]; then
          printf '\\377\\0'; exit 0
        fi
        if [ \(quote(mode)) = malformed-ownership ] && [ "$kind" = ownership ]; then
          printf 'seed'; exit 0
        fi
        if [ \(quote(mode)) = invalid-utf8-ownership ] && [ "$kind" = ownership ]; then
          printf '\\377\\0'; exit 0
        fi
        if [ \(quote(mode)) = duplicate-local-last ] && [ "$kind" = status ]; then
          printf 'D  seed\\0!! seed\\0'; exit 0
        fi
        if [ \(quote(mode)) = duplicate-local-first ] && [ "$kind" = status ]; then
          printf '!! seed\\0D  seed\\0'; exit 0
        fi
        if { [ \(quote(mode)) = hold-status ] && [ "$kind" = status ]; } || { [ \(quote(mode)) = hold-ownership ] && [ "$kind" = ownership ]; }; then
          printf '%s' "$$" > \(quote(ready.path))
          while [ -f \(quote(hold.path)) ]; do /bin/sleep 0.01; done
        fi
        exec \(quote(repo.executable.path)) "$@"
        """
        try Data(script.utf8).write(to:wrapper)
        try FileManager.default.setAttributes([.posixPermissions:0o700],ofItemAtPath:wrapper.path)
        return(GitRepository(root:repo.root,executable:wrapper,askpass:nil,diffDetection:repo.diffDetection,libgit2Configuration:.init(enabled:false)),log,ready,hold)
    }
    private func calls(_ url:URL)throws->[Call] {
        let bytes=try Data(contentsOf:url)
        XCTAssertEqual(bytes.last,0,"Argument receipt must end at a complete NUL boundary")
        let fields=bytes.split(separator:0,omittingEmptySubsequences:false).dropLast().map{String(decoding:$0,as:UTF8.self)}
        var cursor=0,result:[Call]=[]
        while cursor<fields.count {
            guard cursor+3<=fields.count,let count=Int(fields[cursor+2]),count>=0,cursor+3+count<=fields.count else {
                XCTFail("Truncated argument receipt");return []
            }
            let arguments=Array(fields[(cursor+3)..<(cursor+3+count)])
            XCTAssertGreaterThanOrEqual(arguments.count,3)
            XCTAssertEqual(arguments.first,"--literal-pathspecs")
            result.append(.init(kind:fields[cursor],locks:fields[cursor+1],arguments:Array(arguments.dropFirst(3))))
            cursor += 3+count
        }
        return result
    }
    private func raw(_ values:[String])->[Data] {values.map{Data($0.utf8)}}

    func testScopedRetryQueriesKeepCanonicalIndexPeerAndLiteralControlCharacters()async throws {
        let (root,repo)=try await fixture();defer{try? FileManager.default.removeItem(at:root)}
        let nfc=":(glob)* café\t\n.txt",nfd=":(glob)* cafe\u{301}\t\n.txt"
        let blob=try await repo.run(["hash-object","-w","--stdin"],input:Data("base\n".utf8)).text.trimmingCharacters(in:.newlines)
        func packet(_ hash:String,_ path:String)->Data {Data("100644 \(hash)\t\(path)\0".utf8)}
        _=try await repo.run(["update-index","-z","--index-info"],input:packet(blob,nfc)+packet(blob,nfd))
        _=try await repo.commit(message:"raw canonical pair")
        let neighbor=try await repo.run(["hash-object","-w","--stdin"],input:Data("neighbor staged\n".utf8)).text.trimmingCharacters(in:.newlines)
        _=try await repo.run(["update-index","-z","--index-info"],input:packet(neighbor,nfc))
        let selected=try await repo.status().filter{GitReferenceName.equal($0.path,nfd)}
        XCTAssertEqual(selected.count,1)
        _=try await repo.revertWorkingFiles(selected,policy:.init(recycle:false))
        _=try await repo.run(["-c","core.precomposeunicode=false","update-index","--skip-worktree","-z","--stdin"],input:Data((nfc+"\0"+nfd+"\0").utf8))
        let index=try Data(contentsOf:root.appendingPathComponent(".git/index")),head=try await repo.run(["rev-parse","HEAD"]).stdout
        let (wrapped,log,_,_)=try reader(repo)
        let refreshed=try await wrapped.workingFileRevertSelection(selected)
        XCTAssertEqual(raw(refreshed.map(\.path)),raw([nfd]))
        XCTAssertEqual(refreshed.first?.index," ");XCTAssertEqual(refreshed.first?.worktree," ")
        let receipts=try calls(log),scoped=receipts.filter{$0.kind=="status"},tracked=receipts.filter{$0.kind=="index"}
        XCTAssertEqual(scoped.count,1);XCTAssertEqual(tracked.count,1)
        for call in scoped+tracked {
            XCTAssertEqual(Array(call.arguments.prefix(2)),["-c","core.precomposeunicode=false"])
            XCTAssertEqual(call.locks,"0")
            let separator=try XCTUnwrap(call.arguments.firstIndex(of:"--"))
            XCTAssertEqual(raw(Array(call.arguments.dropFirst(separator+1))),raw([nfd]))
            XCTAssertFalse(call.arguments.contains{GitReferenceName.equal($0,nfc)})
        }
        let trackedCall=try XCTUnwrap(tracked.first)
        XCTAssertEqual(Array(trackedCall.arguments.dropFirst(2).prefix(3)),["ls-files","-z","--"])
        let beforeCancel=try Data(contentsOf:log),token=OperationCancellation();token.cancel()
        do {_=try await wrapped.workingFileRevertSelection(selected,cancellation:token);XCTFail("Pre-cancelled Retry launched a scoped query")}
        catch OperationCancellationFailure.cancelled {}
        XCTAssertEqual(try Data(contentsOf:log),beforeCancel)
        XCTAssertEqual(try Data(contentsOf:root.appendingPathComponent(".git/index")),index)
        let afterHead=try await repo.run(["rev-parse","HEAD"]).stdout;XCTAssertEqual(afterHead,head)
    }

    func testIgnoredAndAbsentRetryNamesRetainTheirExactScopedSpelling()async throws {
        let (root,repo)=try await fixture();defer{try? FileManager.default.removeItem(at:root)}
        let path="ignored cafe\u{301}.txt",sibling="ignored sibling.txt"
        try FileManager.default.createDirectory(at:root.appendingPathComponent(".git/info"),withIntermediateDirectories:true)
        try Data("ignored*\n".utf8).write(to:root.appendingPathComponent(".git/info/exclude"))
        for name in [path,sibling] {try Data("private\n".utf8).write(to:root.appendingPathComponent(name))}
        let selected=[StatusEntry(path:path,originalPath:nil,index:"!",worktree:"!")]
        let (wrapped,log,_,_)=try reader(repo)
        let present=try await wrapped.workingFileRevertSelection(selected)
        XCTAssertEqual(present,selected)
        try FileManager.default.removeItem(at:root.appendingPathComponent(path))
        let absent=try await wrapped.workingFileRevertSelection(selected)
        XCTAssertEqual(absent,selected,"Absent ignored names must remain requested rather than disappear from Retry")
        let receipts=try calls(log),scoped=receipts.filter{$0.kind=="status" || $0.kind=="index"},ownership=receipts.filter{$0.kind=="ownership"}
        XCTAssertEqual(scoped.filter{$0.kind=="status"}.count,2)
        XCTAssertEqual(scoped.filter{$0.kind=="index"}.count,1)
        XCTAssertEqual(ownership.count,1,"Only the present local file needs a full ownership inventory")
        for call in ownership {
            XCTAssertEqual(call.arguments,["-c","core.precomposeunicode=false","ls-files","--cached","-z"])
            XCTAssertEqual(call.locks,"0")
        }
        for call in scoped {
            XCTAssertEqual(Array(call.arguments.prefix(2)),["-c","core.precomposeunicode=false"])
            XCTAssertEqual(call.locks,"0")
            let separator=try XCTUnwrap(call.arguments.firstIndex(of:"--"))
            XCTAssertEqual(raw(Array(call.arguments.dropFirst(separator+1))),raw([path]))
        }
        XCTAssertEqual(try Data(contentsOf:root.appendingPathComponent(sibling)),Data("private\n".utf8))
    }

    func testStaleUnknownOrIgnoredCanonicalAliasCannotBecomeATrackedPeer()async throws {
        let cases:[(Character,String,String)]=[("?","café.txt","cafe\u{301}.txt"),("!","café.txt","cafe\u{301}.txt"),
            ("?","café/file.txt","cafe\u{301}/file.txt"),("!","café/file.txt","cafe\u{301}/file.txt")]
        for (code,nfc,nfd) in cases {
            let (root,repo)=try await fixture();var copies:[URL]=[]
            defer{for copy in copies {try? FileManager.default.removeItem(at:copy)};try? FileManager.default.removeItem(at:root)}
            let working=Data("working peer\n".utf8)
            try FileManager.default.createDirectory(at:root.appendingPathComponent(nfc).deletingLastPathComponent(),withIntermediateDirectories:true)
            if code=="!" {
                try FileManager.default.createDirectory(at:root.appendingPathComponent(".git/info"),withIntermediateDirectories:true)
                try Data("*.txt\n".utf8).write(to:root.appendingPathComponent(".git/info/exclude"))
            }
            try working.write(to:root.appendingPathComponent(nfc))
            let blob=try await repo.run(["hash-object","-w","--stdin"],input:Data("indexed peer\n".utf8)).text.trimmingCharacters(in:.newlines)
            _=try await repo.run(["update-index","-z","--index-info"],input:Data("100644 \(blob)\t\(nfc)\0".utf8))
            let selected=[StatusEntry(path:nfd,originalPath:nil,index:code,worktree:code)]
            let index=try Data(contentsOf:root.appendingPathComponent(".git/index"))
            do {_=try await repo.workingFileRevertSelection(selected);XCTFail("Retry admitted an unversioned projection of a tracked peer")}
            catch let failure as GitFailure {XCTAssertTrue(failure.localizedDescription.contains("shares a filesystem entry"))}
            do {
                let unexpected=try await repo.revertWorkingFiles(selected);copies += unexpected.trashedFiles
                XCTFail("Stale unknown alias was allowed to replace its tracked peer")
            } catch let failure as WorkingFileRevertFailure {
                copies += failure.trashedFiles
                XCTFail("Alias must be refused before any Git/Trash effects: "+failure.localizedDescription)
            } catch let failure as GitFailure {XCTAssertTrue(failure.localizedDescription.contains("shares a filesystem entry"))}
            XCTAssertEqual(try Data(contentsOf:root.appendingPathComponent(nfc)),working)
            XCTAssertEqual(try Data(contentsOf:root.appendingPathComponent(".git/index")),index)
        }
    }

    func testScopedReadRejectsIncompleteStatusOrIndexPacketsWithoutMutation()async throws {
        for mode in ["malformed-status","malformed-index","invalid-utf8-index"] {
            let (root,repo)=try await fixture();defer{try? FileManager.default.removeItem(at:root)}
            let (wrapped,_,_,_)=try reader(repo,mode:mode),index=try Data(contentsOf:root.appendingPathComponent(".git/index"))
            let selected=[StatusEntry(path:"seed",originalPath:nil,index:" ",worktree:" ")]
            do {_=try await wrapped.workingFileRevertSelection(selected);XCTFail("Incomplete scoped inventory accepted")}
            catch let failure as GitFailure {XCTAssertTrue(failure.localizedDescription.contains("invalid Revert"))}
            XCTAssertEqual(try Data(contentsOf:root.appendingPathComponent(".git/index")),index)
            XCTAssertEqual(try Data(contentsOf:root.appendingPathComponent("seed")),Data("seed\n".utf8))
        }
    }

    func testOwnershipReadRejectsIncompleteOrNonUTF8PacketsBeforeDisposal()async throws {
        for mode in ["malformed-ownership","invalid-utf8-ownership"] {
            let (root,repo)=try await fixture();defer{try? FileManager.default.removeItem(at:root)}
            let local=root.appendingPathComponent("unknown"),bytes=Data("private unknown\n".utf8)
            try bytes.write(to:local)
            let (wrapped,log,_,_)=try reader(repo,mode:mode),index=try Data(contentsOf:root.appendingPathComponent(".git/index"))
            let selected=[StatusEntry(path:"unknown",originalPath:nil,index:"?",worktree:"?")]
            do {_=try await wrapped.workingFileRevertSelection(selected);XCTFail("Incomplete ownership inventory accepted")}
            catch let failure as GitFailure {XCTAssertTrue(failure.localizedDescription.contains("invalid Revert"))}
            XCTAssertEqual(try calls(log).filter{$0.kind=="ownership"}.count,1)
            XCTAssertEqual(try Data(contentsOf:local),bytes)
            XCTAssertEqual(try Data(contentsOf:root.appendingPathComponent(".git/index")),index)
            XCTAssertFalse(FileManager.default.fileExists(atPath:root.appendingPathComponent(".git/index.lock").path))
        }
    }

    func testDistinctUnversionedHardlinksKeepMixedGitFailureAndRecoveryPolicy()async throws {
        let (root,repo)=try await fixture();var copies:[URL]=[]
        defer{for copy in copies {try? FileManager.default.removeItem(at:copy)};try? FileManager.default.removeItem(at:root)}
        let names=["hardlink one","hardlink two"],seed=root.appendingPathComponent("seed"),marker=root.appendingPathComponent("marker")
        try Data("base marker\n".utf8).write(to:marker)
        try await repo.stage(["marker"]);_=try await repo.commit(message:"marker")
        let markerBytes=Data("working marker\n".utf8)
        try markerBytes.write(to:marker)
        var seedInfo=stat();XCTAssertEqual(lstat(seed.path,&seedInfo),0)
        for name in names {
            let location=root.appendingPathComponent(name)
            try FileManager.default.linkItem(at:seed,to:location)
            var info=stat();XCTAssertEqual(lstat(location.path,&info),0)
            XCTAssertEqual(info.st_dev,seedInfo.st_dev);XCTAssertEqual(info.st_ino,seedInfo.st_ino)
        }
        let selected=try await repo.status().filter{names.contains($0.path) || $0.path=="marker"}
        XCTAssertEqual(selected.count,3)
        let index=try Data(contentsOf:root.appendingPathComponent(".git/index")),head=try await repo.run(["rev-parse","HEAD"]).stdout
        let refreshed=try await repo.workingFileRevertSelection(selected)
        XCTAssertEqual(Set(refreshed.map(\.path)),Set(names+["marker"]),"Separate hardlink names must remain eligible")
        do {
            let unexpected=try await repo.revertWorkingFiles(refreshed);copies += unexpected.trashedFiles
            XCTFail("Mixed unknown request must retain Git's pathspec error")
        } catch let failure as WorkingFileRevertFailure {
            copies += failure.trashedFiles
            XCTAssertTrue(failure.gitError.contains("pathspec"));XCTAssertFalse(failure.wasCancelled)
        }
        XCTAssertEqual(copies.count,3,"Both distinct hardlinks and the selected working file retain their recovery receipts")
        let recovered=try copies.map{try Data(contentsOf:$0)}
        XCTAssertEqual(recovered.filter{$0==Data("seed\n".utf8)}.count,2)
        XCTAssertEqual(recovered.filter{$0==markerBytes}.count,1)
        XCTAssertEqual(try Data(contentsOf:seed),Data("seed\n".utf8),"Unselected tracked hardlink entry must survive")
        XCTAssertEqual(try Data(contentsOf:root.appendingPathComponent(".git/index")),index)
        let after=try await repo.run(["rev-parse","HEAD"]).stdout;XCTAssertEqual(after,head)
        XCTAssertFalse(FileManager.default.fileExists(atPath:root.appendingPathComponent(".git/index.lock").path))
    }

    func testScopedDeletionAndLocalCopyCoalesceAfterCounterpartFilteringInEitherOrder()async throws {
        for mode in ["duplicate-local-last","duplicate-local-first"] {
            let (root,repo)=try await fixture();defer{try? FileManager.default.removeItem(at:root)}
            let (wrapped,_,_,_)=try reader(repo,mode:mode),index=try Data(contentsOf:root.appendingPathComponent(".git/index"))
            let selected=[StatusEntry(path:"seed",originalPath:nil,index:" ",worktree:" ")]
            let refreshed=try await wrapped.workingFileRevertSelection(selected)
            XCTAssertEqual(refreshed.count,1)
            XCTAssertEqual(refreshed.first?.index,"D");XCTAssertEqual(refreshed.first?.worktree," ")
            XCTAssertEqual(refreshed.first?.hasUnversionedCopy,true,"A complete D/local packet pair must retain the independent working-copy fact")
            XCTAssertEqual(try Data(contentsOf:root.appendingPathComponent(".git/index")),index)
            XCTAssertEqual(try Data(contentsOf:root.appendingPathComponent("seed")),Data("seed\n".utf8))
        }
    }

    func testOrdinaryParentDirectoryWithGitlinkDescendantIsRejectedBeforeMutation()async throws {
        let (root,repo)=try await fixture();defer{try? FileManager.default.removeItem(at:root)}
        let parent=root.appendingPathComponent("folder"),privateFile=parent.appendingPathComponent("child/private.txt"),privateBytes=Data("private untracked child contents\n".utf8)
        try Data("ordinary HEAD file\n".utf8).write(to:parent)
        try await repo.stage(["folder"]);_=try await repo.commit(message:"ordinary parent")
        let head=try await repo.run(["rev-parse","HEAD"]).stdout,oid=String(decoding:head,as:UTF8.self).trimmingCharacters(in:.newlines)
        _=try await repo.run(["rm","--cached","--","folder"])
        try FileManager.default.removeItem(at:parent)
        try FileManager.default.createDirectory(at:privateFile.deletingLastPathComponent(),withIntermediateDirectories:true)
        try privateBytes.write(to:privateFile)
        _=try await repo.run(["update-index","--add","--cacheinfo","160000,"+oid+",folder/child"])
        let selected=try await repo.status().filter{GitReferenceName.equal($0.path,"folder")}
        XCTAssertEqual(selected.count,1);XCTAssertEqual(selected.first?.index,"D")
        let index=try Data(contentsOf:root.appendingPathComponent(".git/index"))
        do {
            _=try await repo.revertWorkingFiles(selected,policy:.init(recycle:false))
            XCTFail("A descendant gitlink was mistaken for the selected parent itself")
        } catch WorkingFileRestoreFailure.unsupported {}
        XCTAssertEqual(try Data(contentsOf:root.appendingPathComponent(".git/index")),index)
        XCTAssertEqual(try Data(contentsOf:privateFile),privateBytes)
        XCTAssertEqual((try FileManager.default.attributesOfItem(atPath:parent.path)[.type]) as? FileAttributeType,.typeDirectory)
        XCTAssertFalse(FileManager.default.fileExists(atPath:root.appendingPathComponent(".git/index.lock").path))
        let afterHead=try await repo.run(["rev-parse","HEAD"]).stdout;XCTAssertEqual(afterHead,head)
    }

    func testRawRenameCounterpartKeepsItsPolicyUnlessItsIgnoredObstructionWasSelected()async throws {
        for explicitOldName in [false,true] {
            let (root,repo)=try await fixture()
            var copies:[URL]=[]
            defer {for copy in copies {try? FileManager.default.removeItem(at:copy)};try? FileManager.default.removeItem(at:root)}
            let old="old cafe\u{301}\n160000 fake",new="moved café.txt",base=Data("original contents\n".utf8),obstruction=Data("independent old-name draft\n".utf8)
            try base.write(to:root.appendingPathComponent(old))
            try Data("old*\n".utf8).write(to:root.appendingPathComponent(".gitignore"))
            _=try await repo.run(["-c","core.precomposeunicode=false","add","-f","--",old,".gitignore"])
            _=try await repo.commit(message:"raw rename source")
            _=try await repo.run(["-c","core.precomposeunicode=false","mv","--",old,new])
            try obstruction.write(to:root.appendingPathComponent(old))
            let actual=StatusEntry.parse(try await repo.run(["-c","core.precomposeunicode=false","status","--porcelain=v1","-z","--untracked-files=all","--ignored"]).stdout)
            let selected=actual.filter{GitReferenceName.equal($0.path,new) || explicitOldName && GitReferenceName.equal($0.path,old)}
            XCTAssertEqual(selected.count,explicitOldName ? 2:1)
            XCTAssertEqual(raw(selected.compactMap(\.originalPath)),raw([old]))
            let refreshed=try await repo.workingFileRevertSelection(selected)
            XCTAssertEqual(GitPathSet(refreshed.map(\.path)),GitPathSet(explicitOldName ? [new,old]:[new]))
            XCTAssertEqual(raw(refreshed.compactMap(\.originalPath)),raw([old]))
            if explicitOldName {XCTAssertEqual(refreshed.first{GitReferenceName.equal($0.path,old)}?.state,.ignored)}
            let result=try await repo.revertWorkingFiles(refreshed,policy:.init(recycle:true,recycleRenamedFiles:false))
            copies=result.trashedFiles
            XCTAssertEqual(copies.count,explicitOldName ? 1:0,"An implicit counterpart must not acquire an independent ordinary-file recycling policy")
            if let copy=copies.first {XCTAssertEqual(try Data(contentsOf:copy),obstruction)}
            XCTAssertTrue(result.submodulePaths.isEmpty,"A newline containing mode-like text cannot create a gitlink")
            XCTAssertEqual(try Data(contentsOf:root.appendingPathComponent(old)),base)
            XCTAssertFalse(FileManager.default.fileExists(atPath:root.appendingPathComponent(new).path))
            let index=try await repo.run(["-c","core.precomposeunicode=false","ls-files","-z"]).stdout
            XCTAssertTrue(index.split(separator:0).contains{$0.elementsEqual(Data(old.utf8))})
            XCTAssertFalse(index.split(separator:0).contains{$0.elementsEqual(Data(new.utf8))})
        }
    }

    func testCancellationDrainsAnInFlightScopedStatusWithoutPublishingASelection()async throws {
        for mode in ["hold-status","hold-ownership"] {
            let (root,repo)=try await fixture();defer{try? FileManager.default.removeItem(at:root)}
            let local=root.appendingPathComponent("unknown"),bytes=Data("private unknown\n".utf8)
            try bytes.write(to:local)
            let (wrapped,_,ready,hold)=try reader(repo,mode:mode)
            try Data().write(to:hold)
            let index=try Data(contentsOf:root.appendingPathComponent(".git/index")),token=OperationCancellation()
            let selected=[StatusEntry(path:mode=="hold-status" ? "seed":"unknown",originalPath:nil,index:mode=="hold-status" ? " ":"?",worktree:mode=="hold-status" ? " ":"?")]
            let operation=Task{try await wrapped.workingFileRevertSelection(selected,cancellation:token)}
            var reached=false
            for _ in 0..<1000 {
                if FileManager.default.fileExists(atPath:ready.path) {reached=true;break}
                try? await Task.sleep(nanoseconds:10_000_000)
            }
            token.cancel()
            do {_=try await operation.value;XCTFail("Cancelled read published a Retry selection")}
            catch let failure as GitCommandCancellationFailure {XCTAssertEqual(failure.result.exitCode,130);XCTAssertTrue(token.isCancelled)}
            catch OperationCancellationFailure.cancelled {XCTAssertTrue(token.isCancelled)}
            try? FileManager.default.removeItem(at:hold)
            XCTAssertTrue(reached,"The read never reached its owned cancellation gate: "+mode)
            if let text=try? String(contentsOf:ready,encoding:.utf8),let pid=Int32(text) {
                XCTAssertEqual(kill(pid,0),-1);XCTAssertEqual(errno,ESRCH,"Cancelled Git wrapper was not reaped")
            }
            XCTAssertEqual(try Data(contentsOf:root.appendingPathComponent(".git/index")),index)
            XCTAssertEqual(try Data(contentsOf:root.appendingPathComponent("seed")),Data("seed\n".utf8))
            XCTAssertEqual(try Data(contentsOf:local),bytes)
        }
    }
}
