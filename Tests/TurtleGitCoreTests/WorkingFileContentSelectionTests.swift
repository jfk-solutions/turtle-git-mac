import XCTest
@testable import TurtleGitCore

final class WorkingFileContentSelectionTests:XCTestCase {
    // comparisonFile represents a Git null side by empty bytes + nil mode,
    // selected by the CommitFile A/D action. isDeleted is a separate mutable
    // merge-output save intent; it is not the read-only comparison-null flag.
    private func fixture()async throws->(URL,GitRepository) {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("working-selection-"+UUID().uuidString,isDirectory:true)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        let repository=GitRepository(root:root,libgit2Configuration:.init(enabled:false))
        _=try await repository.run(["init","-b","main"])
        for(key,value)in [("user.name","Selected file QA"),("user.email","qa@example.invalid"),("commit.gpgsign","false"),("core.hooksPath","/dev/null")]{_=try await repository.run(["config",key,value])}
        return(root,repository)
    }
    private func write(_ bytes:Data,_ path:String,_ root:URL)throws {try bytes.write(to:root.appendingPathComponent(path))}
    private func preserved(_ repository:GitRepository,root:URL,head:Data,index:Data,working:[String:Data])async throws {
        let finalHead=try await repository.run(["rev-parse","HEAD"]).stdout
        XCTAssertEqual(finalHead,head);XCTAssertEqual(try Data(contentsOf:root.appendingPathComponent(".git/index")),index)
        for(path,bytes)in working {XCTAssertEqual(try Data(contentsOf:root.appendingPathComponent(path)),bytes)}
    }
    func testExplicitMixedSelectionDisplaysUnchangedAddedDeletedAndIndexDeletedWorkingBytes()async throws {
        let(root,repository)=try await fixture();defer{try? FileManager.default.removeItem(at:root)}
        let clean="unchanged 雪\t[*].txt",equal="effective equal.txt",modified="modified.txt",deleted="deleted.txt",retained="cached deletion.txt",added="-new.bin"
        let original:[String:Data]=[clean:Data("same selected bytes\r\n".utf8),equal:Data("equal HEAD and working\n".utf8),modified:Data("base modified\n".utf8),deleted:Data("deleted base\n".utf8),retained:Data("retained base\n".utf8)]
        for(path,bytes)in original{try write(bytes,path,root)}
        try await repository.stage(Array(original.keys));_=try await repository.commit(message:"selection base")
        let changed=Data("modified working\n".utf8),live=Data("retained working despite cached delete\n".utf8),binary=Data([0,255,13,10,0x80])
        try write(changed,modified,root);try write(live,retained,root);try write(binary,added,root);try FileManager.default.removeItem(at:root.appendingPathComponent(deleted))
        _=try await repository.run(["rm","--cached","--",retained])
        try write(Data("different staged content\n".utf8),equal,root);try await repository.stage([equal]);try write(original[equal]!,equal,root)
        let head=try await repository.run(["rev-parse","HEAD"]).stdout,index=try Data(contentsOf:root.appendingPathComponent(".git/index"))
        let snapshot=try await repository.workingFileComparison(paths:[clean,equal,modified,added,deleted,retained,clean])
        XCTAssertEqual(GitPathSet(snapshot.files.map(\.path)),GitPathSet([clean,equal,modified,added,deleted,retained]));XCTAssertEqual(snapshot.files.count,6)
        let unchanged=try await repository.comparisonFile(snapshot,path:clean)
        XCTAssertEqual(unchanged.base.bytes,original[clean]);XCTAssertEqual(unchanged.destination.bytes,original[clean]);XCTAssertEqual(unchanged.destination.mode,"100644")
        let effectiveEqual=try await repository.comparisonFile(snapshot,path:equal)
        XCTAssertEqual(effectiveEqual.base.bytes,original[equal]);XCTAssertEqual(effectiveEqual.destination.bytes,original[equal])
        let modifiedDocument=try await repository.comparisonFile(snapshot,path:modified)
        XCTAssertEqual(modifiedDocument.base.bytes,original[modified]);XCTAssertEqual(modifiedDocument.destination.bytes,changed)
        let addition=try await repository.comparisonFile(snapshot,path:added)
        XCTAssertTrue(addition.base.bytes.isEmpty);XCTAssertNil(addition.base.mode);XCTAssertEqual(snapshot.files.first{$0.path==added}?.action,"A");XCTAssertEqual(addition.destination.bytes,binary)
        let removal=try await repository.comparisonFile(snapshot,path:deleted)
        XCTAssertEqual(removal.base.bytes,original[deleted]);XCTAssertTrue(removal.destination.bytes.isEmpty);XCTAssertNil(removal.destination.mode);XCTAssertEqual(snapshot.files.first{$0.path==deleted}?.action,"D")
        let indexDeleted=try await repository.comparisonFile(snapshot,path:retained)
        XCTAssertEqual(indexDeleted.base.bytes,original[retained]);XCTAssertEqual(indexDeleted.destination.bytes,live);XCTAssertEqual(indexDeleted.destination.mode,"100644")
        try await preserved(repository,root:root,head:head,index:index,working:[clean:original[clean]!,equal:original[equal]!,modified:changed,retained:live,added:binary])
        XCTAssertFalse(FileManager.default.fileExists(atPath:root.appendingPathComponent(deleted).path))
    }
    func testAmendRootLinearAndMergeFirstParentAreDisplayedForUnchangedWorkingFile()async throws {
        let(root,repository)=try await fixture();defer{try? FileManager.default.removeItem(at:root)}
        let path="selected.txt",rootBytes=Data("root selected\n".utf8),nextBytes=Data("head selected\n".utf8)
        try write(rootBytes,path,root);try await repository.stage([path]);_=try await repository.commit(message:"root")
        let rootHash=try await repository.run(["rev-parse","HEAD"]).text.trimmingCharacters(in:.whitespacesAndNewlines)
        let initial=try await repository.workingFileComparison(paths:[path],amendToParent:true),rootDocument=try await repository.comparisonFile(initial,path:path)
        XCTAssertEqual(initial.from,.emptyTree);XCTAssertTrue(rootDocument.base.bytes.isEmpty);XCTAssertNil(rootDocument.base.mode);XCTAssertEqual(initial.files.first?.action,"A");XCTAssertEqual(rootDocument.destination.bytes,rootBytes)
        try write(nextBytes,path,root);try await repository.stage([path]);_=try await repository.commit(message:"next")
        let amended=try await repository.workingFileComparison(paths:[path],amendToParent:true),amendedDocument=try await repository.comparisonFile(amended,path:path)
        XCTAssertEqual(amended.from,.revision(rootHash));XCTAssertEqual(amendedDocument.base.bytes,rootBytes);XCTAssertEqual(amendedDocument.destination.bytes,nextBytes)
        let normal=try await repository.workingFileComparison(paths:[path]),normalDocument=try await repository.comparisonFile(normal,path:path)
        XCTAssertEqual(normalDocument.base.bytes,nextBytes);XCTAssertEqual(normalDocument.destination.bytes,nextBytes)
        _=try await repository.run(["switch","-c","side",rootHash]);try write(Data("side content\n".utf8),"side.txt",root);try await repository.stage(["side.txt"]);_=try await repository.commit(message:"side")
        _=try await repository.run(["switch","main"])
        let firstParent=try await repository.run(["rev-parse","HEAD"]).text.trimmingCharacters(in:.whitespacesAndNewlines)
        _=try await repository.run(["merge","--no-ff","side","-m","merge side"])
        let head=try await repository.run(["rev-parse","HEAD"]).stdout,index=try Data(contentsOf:root.appendingPathComponent(".git/index"))
        let merge=try await repository.workingFileComparison(paths:[path,"side.txt"],amendToParent:true)
        XCTAssertEqual(merge.from,.revision(firstParent))
        let selected=try await repository.comparisonFile(merge,path:path),side=try await repository.comparisonFile(merge,path:"side.txt")
        XCTAssertEqual(selected.base.bytes,nextBytes);XCTAssertEqual(selected.destination.bytes,nextBytes);XCTAssertTrue(side.base.bytes.isEmpty);XCTAssertNil(side.base.mode);XCTAssertEqual(merge.files.first{$0.path=="side.txt"}?.action,"A");XCTAssertEqual(side.destination.bytes,Data("side content\n".utf8))
        try await preserved(repository,root:root,head:head,index:index,working:[path:nextBytes,"side.txt":Data("side content\n".utf8)])
    }
    func testAmendReaddedParentPathRetainsParentContentAfterHeadDeletion()async throws {
        let(root,repository)=try await fixture();defer{try? FileManager.default.removeItem(at:root)}
        let path="re-added.txt",parent=Data("parent contents\n".utf8),working=Data("re-added working\n".utf8)
        try write(parent,path,root);try await repository.stage([path]);_=try await repository.commit(message:"parent contains file")
        let parentHash=try await repository.run(["rev-parse","HEAD"]).text.trimmingCharacters(in:.whitespacesAndNewlines)
        _=try await repository.run(["rm","--",path]);_=try await repository.commit(message:"head deletes file")
        try write(working,path,root);try await repository.stage([path])
        let head=try await repository.run(["rev-parse","HEAD"]).stdout,index=try Data(contentsOf:root.appendingPathComponent(".git/index"))
        let normal=try await repository.workingFileComparison(paths:[path]),normalDocument=try await repository.comparisonFile(normal,path:path)
        XCTAssertTrue(normalDocument.base.bytes.isEmpty);XCTAssertNil(normalDocument.base.mode);XCTAssertEqual(normal.files.first?.action,"A");XCTAssertEqual(normalDocument.destination.bytes,working)
        let amend=try await repository.workingFileComparison(paths:[path],amendToParent:true),amendDocument=try await repository.comparisonFile(amend,path:path)
        XCTAssertEqual(amend.from,.revision(parentHash));XCTAssertEqual(amendDocument.base.bytes,parent);XCTAssertEqual(amendDocument.destination.bytes,working)
        try await preserved(repository,root:root,head:head,index:index,working:[path:working])
    }
    func testSelectedRenameAndCopyKeepHistoricalSourceAndWorkingDestination()async throws {
        let(root,repository)=try await fixture();defer{try? FileManager.default.removeItem(at:root)}
        let old="old 雪.txt",renamed="renamed 雪.txt",source="copy source.txt",copy="copy target.txt"
        let original=Data((0..<70).map{"rename original \($0)\n"}.joined().utf8),sourceBytes=Data((0..<70).map{"copy distinct \($0)\n"}.joined().utf8)
        try write(original,old,root);try write(sourceBytes,source,root);try await repository.stage([old,source]);_=try await repository.commit(message:"base names")
        _=try await repository.run(["mv","--",old,renamed]);let working=original+Data("working after rename\n".utf8)
        try write(working,renamed,root);try write(sourceBytes,copy,root);try write(sourceBytes+Data("source changed\n".utf8),source,root);try await repository.stage([renamed,source,copy])
        let head=try await repository.run(["rev-parse","HEAD"]).stdout,index=try Data(contentsOf:root.appendingPathComponent(".git/index"))
        let snapshot=try await repository.workingFileComparison(paths:[renamed,copy,source])
        let renameDocument=try await repository.comparisonFile(snapshot,path:renamed),copyDocument=try await repository.comparisonFile(snapshot,path:copy)
        XCTAssertEqual(renameDocument.base.path,old);XCTAssertEqual(renameDocument.base.bytes,original);XCTAssertEqual(renameDocument.destination.bytes,working)
        XCTAssertEqual(copyDocument.base.path,source);XCTAssertEqual(copyDocument.base.bytes,sourceBytes);XCTAssertEqual(copyDocument.destination.bytes,sourceBytes)
        XCTAssertTrue(snapshot.files.first{$0.path==copy}?.action.hasPrefix("C")==true)
        let sourceDocument=try await repository.comparisonFile(snapshot,path:source)
        XCTAssertEqual(sourceDocument.base.path,source);XCTAssertEqual(sourceDocument.destination.path,source)
        XCTAssertEqual(sourceDocument.base.bytes,sourceBytes);XCTAssertEqual(sourceDocument.destination.bytes,sourceBytes+Data("source changed\n".utf8))
        XCTAssertEqual(GitPathSet(snapshot.files.map(\.path)),GitPathSet([renamed,copy,source]))
        try await preserved(repository,root:root,head:head,index:index,working:[renamed:working,copy:sourceBytes,source:sourceBytes+Data("source changed\n".utf8)])
    }
    func testUnbornGitlinkAndRefusedSelectionsPreserveStorage()async throws {
        let(root,repository)=try await fixture();defer{try? FileManager.default.removeItem(at:root)}
        let path="new.txt",bytes=Data("unborn bytes\n".utf8)
        try write(bytes,path,root);try await repository.stage([path])
        let unbornIndex=try Data(contentsOf:root.appendingPathComponent(".git/index")),unbornHead=try Data(contentsOf:root.appendingPathComponent(".git/HEAD"))
        let unborn=try await repository.workingFileComparison(paths:[path]),document=try await repository.comparisonFile(unborn,path:path)
        XCTAssertEqual(unborn.from,.emptyTree);XCTAssertTrue(document.base.bytes.isEmpty);XCTAssertNil(document.base.mode);XCTAssertEqual(unborn.files.first?.action,"A");XCTAssertEqual(document.destination.bytes,bytes)
        try FileManager.default.createDirectory(at:root.appendingPathComponent("ordinary-directory",isDirectory:true),withIntermediateDirectories:true)
        for paths in [[],["missing.txt"],["ordinary-directory"],["../escape"],["/absolute"],["bad\0path"]] {
            do{_=try await repository.workingFileComparison(paths:paths);XCTFail("Invalid/missing selection accepted: \(paths)")}catch{}
        }
        do{_=try await repository.revisionFileComparison(from:.revision("refs/heads/not-present"),to:.workingTree,paths:[path]);XCTFail("Invalid selected comparison revision accepted")}catch{}
        let cancellation=OperationCancellation();cancellation.cancel()
        do{_=try await repository.workingFileComparison(paths:[path],cancellation:cancellation);XCTFail("Canceled selected-file read accepted")}catch is OperationCancellationFailure{}
        do{_=try await repository.comparisonFile(unborn,path:path,cancellation:cancellation);XCTFail("Canceled displayed-content read accepted")}catch is OperationCancellationFailure{}
        XCTAssertEqual(try Data(contentsOf:root.appendingPathComponent(".git/index")),unbornIndex);XCTAssertEqual(try Data(contentsOf:root.appendingPathComponent(".git/HEAD")),unbornHead)
        _=try await repository.commit(message:"parent")
        let moduleRoot=root.appendingPathComponent("module",isDirectory:true);try FileManager.default.createDirectory(at:moduleRoot,withIntermediateDirectories:true)
        let child=GitRepository(root:moduleRoot,libgit2Configuration:.init(enabled:false));_=try await child.run(["init","-b","main"])
        for(key,value)in [("user.name","Child QA"),("user.email","qa@example.invalid"),("commit.gpgsign","false"),("core.hooksPath","/dev/null")]{_=try await child.run(["config",key,value])}
        try write(Data("child\n".utf8),"child.txt",moduleRoot);try await child.stage(["child.txt"]);_=try await child.commit(message:"child")
        let childHash=try await child.run(["rev-parse","HEAD"]).text.trimmingCharacters(in:.whitespacesAndNewlines)
        _=try await repository.run(["update-index","--add","--cacheinfo","160000,"+childHash+",module"]);_=try await repository.commit(message:"gitlink")
        let head=try await repository.run(["rev-parse","HEAD"]).stdout,index=try Data(contentsOf:root.appendingPathComponent(".git/index"))
        let selected=try await repository.workingFileComparison(paths:[path,"module"])
        XCTAssertEqual(GitPathSet(selected.files.map(\.path)),GitPathSet([path,"module"]));XCTAssertTrue(selected.files.first{$0.path=="module"}?.isSubmodule==true)
        try await preserved(repository,root:root,head:head,index:index,working:[path:bytes])
    }
    func testAddedGitlinkUsesIndexRatherThanChildHeadAndNullKindsSurviveUninitializedCheckout()async throws {
        let(root,repository)=try await fixture();defer{try? FileManager.default.removeItem(at:root)}
        let parentBytes=Data("parent\n".utf8);try write(parentBytes,"parent.txt",root);try await repository.stage(["parent.txt"]);_=try await repository.commit(message:"parent")
        let childRoot=root.appendingPathComponent("module",isDirectory:true);try FileManager.default.createDirectory(at:childRoot,withIntermediateDirectories:true)
        let child=GitRepository(root:childRoot,libgit2Configuration:.init(enabled:false));_=try await child.run(["init","-b","main"])
        for(key,value)in [("user.name","Child QA"),("user.email","qa@example.invalid"),("commit.gpgsign","false"),("core.hooksPath","/dev/null")]{_=try await child.run(["config",key,value])}
        try write(Data("child index commit\n".utf8),"child.txt",childRoot);try await child.stage(["child.txt"]);_=try await child.commit(message:"index child")
        let indexOID=try await child.run(["rev-parse","HEAD"]).text.trimmingCharacters(in:.whitespacesAndNewlines)
        _=try await repository.run(["update-index","--add","--cacheinfo","160000,"+indexOID+",module"])
        try write(Data("child newer commit\n".utf8),"child.txt",childRoot);try await child.stage(["child.txt"]);_=try await child.commit(message:"newer child")
        let childOID=try await child.run(["rev-parse","HEAD"]).text.trimmingCharacters(in:.whitespacesAndNewlines)
        try write(Data("child dirty\n".utf8),"child.txt",childRoot)
        let head=try await repository.run(["rev-parse","HEAD"]).stdout,index=try Data(contentsOf:root.appendingPathComponent(".git/index")),childIndex=try Data(contentsOf:childRoot.appendingPathComponent(".git/index"))
        let added=try await repository.submoduleComparison(path:"module",from:"",toIndex:true)
        XCTAssertNotEqual(indexOID,childOID);XCTAssertNil(added.from.revision);XCTAssertEqual(added.to.revision,indexOID)
        XCTAssertFalse(added.toWorkingTree);XCTAssertTrue(added.dirty);XCTAssertEqual(added.change,.newSubmodule)
        let working=try await repository.submoduleComparison(path:"module",from:"")
        XCTAssertEqual(working.to.revision,childOID);XCTAssertTrue(working.toWorkingTree)
        XCTAssertEqual(try Data(contentsOf:childRoot.appendingPathComponent(".git/index")),childIndex)
        try await preserved(repository,root:root,head:head,index:index,working:["parent.txt":parentBytes])
        _=try await repository.commit(message:"record child index gitlink")
        let committedHead=try await repository.run(["rev-parse","HEAD"]).stdout,committedIndex=try Data(contentsOf:root.appendingPathComponent(".git/index"))
        try FileManager.default.moveItem(at:childRoot,to:root.appendingPathComponent("detached-child",isDirectory:true))
        let uninitialized=try await repository.submoduleComparison(path:"module",from:"",toIndex:true)
        XCTAssertEqual(uninitialized.change,.newSubmodule);XCTAssertEqual(uninitialized.to.revision,indexOID);XCTAssertFalse(uninitialized.to.available);XCTAssertFalse(uninitialized.toWorkingTree)
        let deleted=try await repository.submoduleComparison(path:"module",from:"HEAD",to:"")
        XCTAssertEqual(deleted.change,.deleteSubmodule);XCTAssertEqual(deleted.from.revision,indexOID);XCTAssertNil(deleted.to.revision);XCTAssertFalse(deleted.toWorkingTree)
        try await preserved(repository,root:root,head:committedHead,index:committedIndex,working:["parent.txt":parentBytes])
    }
}
