import XCTest
import Darwin
@testable import TurtleGitCore

final class RepositoryBrowserWorkingIdentityTests:XCTestCase {
    private func write(_ bytes:Data,path:String)throws {
        let descriptor=path.withCString {Darwin.open($0,O_WRONLY|O_CREAT|O_TRUNC,0o600)}
        guard descriptor >= 0 else {throw NSError(domain:NSPOSIXErrorDomain,code:Int(errno))}
        defer {Darwin.close(descriptor)}
        try bytes.withUnsafeBytes {buffer in
            var offset=0
            while offset < buffer.count {
                let count=Darwin.write(descriptor,buffer.baseAddress!.advanced(by:offset),buffer.count-offset)
                guard count > 0 else {throw NSError(domain:NSPOSIXErrorDomain,code:Int(errno))}
                offset += count
            }
        }
    }
    private func sameLookup(_ first:String,_ second:String)->Bool {
        var a=stat(),b=stat()
        return first.withCString {lstat($0,&a)} == 0 && second.withCString {lstat($0,&b)} == 0 && a.st_dev == b.st_dev && a.st_ino == b.st_ino
    }
    private func read(_ path:String)throws->Data {
        let descriptor=path.withCString {Darwin.open($0,O_RDONLY)}
        guard descriptor >= 0 else {throw NSError(domain:NSPOSIXErrorDomain,code:Int(errno))}
        let handle=FileHandle(fileDescriptor:descriptor,closeOnDealloc:true)
        return try handle.readToEnd() ?? Data()
    }
    private func snapshot(_ repository:GitRepository,path:String,bytes:Data)async throws->(RepositoryBrowserSnapshot,RepositoryBrowserEntry) {
        let blob=try await repository.run(["hash-object","-w","--stdin"],input:bytes).text.trimmingCharacters(in:.newlines)
        let components=path.split(separator:"/").map(String.init)
        var object=blob,mode="100644",type="blob"
        for name in components.reversed() {
            object=try await repository.run(["mktree","-z"],input:Data("\(mode) \(type) \(object)\t\(name)\0".utf8)).text.trimmingCharacters(in:.newlines)
            mode="040000";type="tree"
        }
        var listing=try await repository.browseRepository(revision:object)
        if components.count > 1 {listing=try await repository.browseRepositoryDirectory(listing,directory:components.dropLast().joined(separator:"/"))}
        return (listing,try XCTUnwrap(listing.entries.first))
    }
    private func checkAlias(requested:String,actual:String,ignored:Bool,tracked:Bool)async throws {
        let (root,repository,_) = try await GitPatchTests().fixture()
        defer {try? FileManager.default.removeItem(at:root)}
        let actualParts=actual.split(separator:"/").map(String.init)
        if actualParts.count > 1 {
            let parent=root.path + "/" + actualParts.dropLast().joined(separator:"/")
            guard parent.withCString({Darwin.mkdir($0,0o700)}) == 0 else {throw NSError(domain:NSPOSIXErrorDomain,code:Int(errno))}
        }
        let original=Data("keep actual working bytes\n".utf8),historical=Data("historical requested bytes\n".utf8)
        try write(original,path:root.path + "/" + actual)
        if ignored {try Data((actualParts[0] + "\n").utf8).write(to:root.appendingPathComponent(".gitignore"))}
        if tracked {_ = try await repository.run(["-c","core.precomposeUnicode=false","add","--",actual])}
        let (listing,entry)=try await snapshot(repository,path:requested,bytes:historical)
        let head=try await repository.run(["rev-parse","HEAD"]).stdout
        let index=try Data(contentsOf:root.appendingPathComponent(".git/index"))
        let shared=sameLookup(root.path + "/" + requested,root.path + "/" + actual)
        if !shared {
            let requestedParent=requested.split(separator:"/").dropLast().joined(separator:"/")
            if !requestedParent.isEmpty {
                let directory=root.path + "/" + requestedParent
                if directory.withCString({Darwin.mkdir($0,0o700)}) != 0 && errno != EEXIST {throw NSError(domain:NSPOSIXErrorDomain,code:Int(errno))}
            }
            try write(Data("separate requested working file\n".utf8),path:root.path + "/" + requested)
            XCTAssertFalse(sameLookup(root.path + "/" + requested,root.path + "/" + actual))
        }
        if shared {
            for restore in [false,true] {
                do {
                    if restore {try await repository.revertRepositoryBrowserFile(listing,entry:entry)}
                    else {try await repository.validateRepositoryBrowserWorkingPath(listing,entry:entry)}
                    XCTFail("A different filesystem entry spelling was accepted: \(requested) / \(actual)")
                } catch RepositoryBrowserFailure.normalizationCollision(let path) {XCTAssertTrue(GitReferenceName.equal(path,requested))}
            }
            XCTAssertEqual(try Data(contentsOf:root.appendingPathComponent(".git/index")),index)
        } else {
            // A sensitive volume can keep both names. Text resemblance alone
            // must not disable a legitimate historical checkout.
            try await repository.validateRepositoryBrowserWorkingPath(listing,entry:entry)
            try await repository.revertRepositoryBrowserFile(listing,entry:entry)
            XCTAssertEqual(try read(root.path + "/" + requested),historical)
        }
        let unchangedHead=try await repository.run(["rev-parse","HEAD"]).stdout
        XCTAssertEqual(unchangedHead,head)
        XCTAssertEqual(try read(root.path + "/" + actual),original)
    }
    func testUntrackedIgnoredUnicodeAndCaseAliasesIncludingDirectoryPrefixes()async throws {
        for ignored in [false,true] {
            try await checkAlias(requested:"caf\u{e9}.txt",actual:"cafe\u{301}.txt",ignored:ignored,tracked:false)
            try await checkAlias(requested:"Historical.txt",actual:"historical.txt",ignored:ignored,tracked:false)
            try await checkAlias(requested:"Folder/file.txt",actual:"folder/file.txt",ignored:ignored,tracked:false)
            try await checkAlias(requested:"d\u{e9}/file.txt",actual:"de\u{301}/file.txt",ignored:ignored,tracked:false)
        }
    }
    func testTrackedAliasesUseActualVolumeIdentity()async throws {
        try await checkAlias(requested:"Tracked.txt",actual:"tracked.txt",ignored:false,tracked:true)
        try await checkAlias(requested:"caf\u{e9}.txt",actual:"cafe\u{301}.txt",ignored:false,tracked:true)
        try await checkAlias(requested:"Folder/file.txt",actual:"folder/file.txt",ignored:false,tracked:true)
    }
    func testExactPinnedRevertCancellationAndContainment()async throws {
        let (root,repository,path)=try await GitPatchTests().fixture()
        defer {try? FileManager.default.removeItem(at:root)}
        let pinned=try await repository.browseRepository(),entry=try XCTUnwrap(pinned.entries.first {GitReferenceName.equal($0.path,path)})
        let original=try Data(contentsOf:root.appendingPathComponent(path)),changed=Data("local change\n".utf8)
        try changed.write(to:root.appendingPathComponent(path))
        let head=try await repository.run(["rev-parse","HEAD"]).stdout,index=try Data(contentsOf:root.appendingPathComponent(".git/index"))
        let cancelled=OperationCancellation();cancelled.cancel()
        do {try await repository.validateRepositoryBrowserWorkingPath(pinned,entry:entry,cancellation:cancelled);XCTFail("Cancelled validation succeeded")} catch OperationCancellationFailure.cancelled {}
        do {try await repository.revertRepositoryBrowserFile(pinned,entry:entry,cancellation:cancelled);XCTFail("Cancelled restore succeeded")} catch OperationCancellationFailure.cancelled {}
        XCTAssertEqual(try Data(contentsOf:root.appendingPathComponent(path)),changed)
        XCTAssertEqual(try Data(contentsOf:root.appendingPathComponent(".git/index")),index)
        try await repository.revertRepositoryBrowserFile(pinned,entry:entry)
        XCTAssertEqual(try Data(contentsOf:root.appendingPathComponent(path)),original)
        let after=try await repository.run(["rev-parse","HEAD"]).stdout;XCTAssertEqual(after,head)
        let outside=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:outside,withIntermediateDirectories:true)
        defer {try? FileManager.default.removeItem(at:outside)}
        try FileManager.default.createSymbolicLink(atPath:root.path + "/outside",withDestinationPath:outside.path)
        let (unsafe,item)=try await snapshot(repository,path:"outside/file",bytes:original)
        do {try await repository.validateRepositoryBrowserWorkingPath(unsafe,entry:item);XCTFail("Outside symlink parent accepted")} catch WorkingFileRestoreFailure.location {}
        let adminItem=RepositoryBrowserEntry(path:".git/config",name:"config",mode:"100644",objectID:entry.objectID,size:entry.size)
        // Hand-built snapshots must use the repository's standardized owner URL,
        // just as browseRepository does, rather than the temporary-directory URL.
        let admin=RepositoryBrowserSnapshot(root:pinned.root,revision:pinned.revision,objectID:pinned.objectID,treeID:pinned.treeID,directory:".git",bare:false,entries:[adminItem])
        do {try await repository.validateRepositoryBrowserWorkingPath(admin,entry:adminItem);XCTFail("Administrative path accepted")} catch WorkingFileRestoreFailure.location {}
    }
}
