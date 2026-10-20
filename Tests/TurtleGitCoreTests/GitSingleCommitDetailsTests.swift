import XCTest
@testable import TurtleGitCore

final class GitSingleCommitDetailsTests:XCTestCase {
    private let sampleOID=String(repeating:"a",count:40)
    private let treeOID=String(repeating:"b",count:40)
    private func engine()->GitLibGit2Configuration {.init(enabled:true,mask:GitLibGit2Operation.getCommit.mask)}
    private func frame(_ value:[String:Any]) throws -> Data {
        GitSingleCommitProtocol.prefix+(try JSONSerialization.data(withJSONObject:value,options:[.sortedKeys])).base64EncodedData()+Data([10])
    }
    private func packet(fields:[String:Data],encoding:Bool=true,changes:[String:Any]=[:]) throws -> Data {
        var metadata:[String:Any]=["kind":"commit","oid":sampleOID,"objectType":"commit","tree":treeOID,"parents":[sampleOID],"authorTime":-1,"authorOffset":330,"committerTime":1700000000,"committerOffset":-420]
        for field in GitSingleCommitProtocol.fieldOrder {metadata[field+"Bytes"]=field=="encoding" && !encoding ? NSNull():(fields[field]?.count ?? 0) as Any}
        for(key,value) in changes {metadata[key]=value}
        var data=try frame(["kind":"header"])+frame(metadata),count=1
        for field in GitSingleCommitProtocol.fieldOrder {
            let bytes=fields[field] ?? Data();var position=0
            while position<bytes.count {let end=min(position+512*1024,bytes.count);data.append(try frame(["kind":"bytes","field":field,"data":bytes[position..<end].base64EncodedString()]));position=end;count+=1}
        }
        data.append(try frame(["kind":"end","count":count]));return data
    }
    private func commit(_ details:GitSingleCommitDetails,file:StaticString=#filePath,line:UInt=#line) throws -> GitSingleCommit {
        guard case .commit(let value)=details else {XCTFail("Expected commit",file:file,line:line);throw GitSingleCommitFailure.notCommit};return value
    }
    private func raw(tree:String,parents:[String]=[],encoding:String?="ISO-8859-1",authorTime:Int64 = -1,authorOffset:String="+0530",message:Data=Data([67,97,102,233,10,10,32,98,111,100,121,32,10,10]))->Data {
        var bytes=Data(("tree "+tree+"\n"+parents.map{"parent "+$0+"\n"}.joined()+"author Caf").utf8)
        bytes.append(233);bytes.append(Data((" <cafe@example.invalid> "+String(authorTime)+" "+authorOffset+"\ncommitter Other <other@example.invalid> 1700000000 -0700\n").utf8))
        if let encoding {bytes.append(Data(("encoding "+encoding+"\n").utf8))}
        bytes.append(Data("gpgsig -----BEGIN PGP SIGNATURE-----\n not verified\n -----END PGP SIGNATURE-----\n\n".utf8));bytes.append(message);return bytes
    }
    private func object(_ repo:GitRepository,type:String="commit",data:Data) async throws -> String {
        // Historical objects can contain negative signature epochs which modern
        // hash-object's fsck gate refuses; the reader must still preserve them.
        try await repo.run(["hash-object","--literally","-t",type,"-w","--stdin"],input:data).text.trimmingCharacters(in:.newlines)
    }
    func testProtocolPreservesRawEncodedSignaturesAndFirstLFMessage() throws {
        let fields=["encoding":Data("ISO-8859-1".utf8),"authorName":Data([67,97,102,233]),"authorEmail":Data("a@example.invalid".utf8),"committerName":Data("Other".utf8),"committerEmail":Data("o@example.invalid".utf8),"message":Data([67,97,102,233,10,10,32,98,111,100,121,32,10,10])]
        let value=try commit(GitSingleCommitProtocol.decode(packet(fields:fields)))
        XCTAssertEqual(value.author.name,"Café");XCTAssertEqual(value.author.nameBytes,fields["authorName"]);XCTAssertEqual(value.messageBytes,fields["message"])
        XCTAssertEqual(value.subject,"Café");XCTAssertEqual(value.message,"Café\n\n body \n\n");XCTAssertEqual(value.body,"\n body \n\n")
        XCTAssertEqual(value.author.date,"1970-01-01T05:29:59+05:30");XCTAssertEqual(value.committer.offsetMinutes,-420)
        let entry=value.asLogEntry();XCTAssertEqual(entry.message,value.message);XCTAssertEqual(entry.committer,"Other");XCTAssertEqual(entry.parents,[sampleOID])
    }
    func testChunkedFieldsEmptyEncodingAndUnknownEncodingKeepEveryByte() throws {
        let message=Data(repeating:120,count:512*1024+19)+Data([10,32,10])
        let value=try commit(GitSingleCommitProtocol.decode(packet(fields:["message":message])))
        XCTAssertEqual(value.messageBytes,message);XCTAssertEqual(value.encodingBytes,Data())
        let unknown=try commit(GitSingleCommitProtocol.decode(packet(fields:["encoding":Data("not-a-codepage".utf8),"message":Data([255,10])])) )
        XCTAssertEqual(unknown.message,"�\n")
        let absent=try commit(GitSingleCommitProtocol.decode(packet(fields:[:],encoding:false)));XCTAssertNil(absent.encodingBytes)
    }
    func testProtocolRefusesWrongWidthsTypesBudgetsAndIncompleteFrames() throws {
        for change in [["tree":String(repeating:"b",count:64)],["parents":[String(repeating:"a",count:64)]],["authorOffset":true],["committerOffset":1440],["messageBytes":16*1024*1024+1],["authorNameBytes":-1],["objectType":"tag"],["extra":0]] as [[String:Any]] {
            XCTAssertThrowsError(try GitSingleCommitProtocol.decode(packet(fields:[:],changes:change)))
        }
        let valid=try packet(fields:["message":Data("body".utf8)])
        XCTAssertThrowsError(try GitSingleCommitProtocol.decode(valid.dropLast()))
        XCTAssertThrowsError(try GitSingleCommitProtocol.decode(valid+frame(["kind":"end","count":2])))
        let token=OperationCancellation();token.cancel();XCTAssertThrowsError(try GitSingleCommitProtocol.decode(valid,cancellation:token))
    }
    func testProtocolRejectsReorderedChunksDuplicateMetadataAndNoncanonicalBase64() throws {
        let original=try packet(fields:["authorName":Data("A".utf8),"message":Data("M".utf8)])
        var lines=original.split(separator:10).map {Data($0)}
        lines.swapAt(2,3)
        XCTAssertThrowsError(try GitSingleCommitProtocol.decode(lines.reduce(into:Data()){$0.append($1);$0.append(10)}))
        let header=try frame(["kind":"header"])
        XCTAssertThrowsError(try GitSingleCommitProtocol.decode(header+original))
        var noncanonical=header;noncanonical.insert(32,at:GitSingleCommitProtocol.prefix.count)
        XCTAssertThrowsError(try GitSingleCommitProtocol.decode(noncanonical+original.dropFirst(header.count)))
    }
    func testRawParserRetainsContinuationHeadersOffsetsWhitespaceAndCStringBoundary() throws {
        let message=Data("subject\r\n\n body \n\n".utf8)+Data([0])+Data("ignored".utf8)
        let value=try GitSingleCommitProtocol.parseCommit(raw(tree:treeOID,message:message),oid:sampleOID).decoded()
        XCTAssertEqual(value.messageBytes,Data("subject\r\n\n body \n\n".utf8));XCTAssertEqual(value.author.name,"Café");XCTAssertEqual(value.author.time,-1);XCTAssertEqual(value.author.offsetMinutes,330)
        XCTAssertEqual(value.subject,"subject\r");XCTAssertEqual(value.body,"\n body \n\n")
        XCTAssertThrowsError(try GitSingleCommitProtocol.parseCommit(raw(tree:String(repeating:"b",count:64)),oid:sampleOID))
        XCTAssertThrowsError(try GitSingleCommitProtocol.parseCommit(Data("tree invalid\n\nmessage".utf8),oid:sampleOID))
    }
    func testExtremeValidOffsetFormattingNeverUsesMachineTimezone() throws {
        let value=try commit(GitSingleCommitProtocol.decode(packet(fields:[:],changes:["authorTime":0,"authorOffset":1439,"committerTime":0,"committerOffset":-1439])))
        XCTAssertEqual(value.author.date,"1970-01-01T23:59:00+23:59");XCTAssertEqual(value.committer.date,"1969-12-31T00:01:00-23:59")
    }
    func testRealSelectedAndCLIDetailsPreserveLegacyCommitRawMessageAndIdentities() async throws {
        let(root,repo,_)=try await GitPatchTests().fixture();defer{try? FileManager.default.removeItem(at:root)}
        let tree=try await repo.run(["rev-parse","HEAD^{tree}"]).text.trimmingCharacters(in:.newlines)
        let oid=try await object(repo,data:raw(tree:tree))
        for backend in [engine(),GitLibGit2Configuration(enabled:false)] {
            let value=try commit(await repo.singleCommitDetails(revision:oid,backend:backend))
            XCTAssertEqual(value.objectID,oid);XCTAssertEqual(value.tree,tree);XCTAssertEqual(value.author.name,"Café");XCTAssertEqual(value.message,"Café\n\n body \n\n");XCTAssertEqual(value.author.date,"1970-01-01T05:29:59+05:30");XCTAssertEqual(value.committer.date,"2023-11-14T15:13:20-07:00")
        }
    }
    func testNestedSignedStyleTagsPeelButTreeFallbackRetainsSelectedBranchSemantics() async throws {
        let(root,repo,_)=try await GitPatchTests().fixture();defer{try? FileManager.default.removeItem(at:root)}
        let head=try await repo.run(["rev-parse","HEAD"]).text.trimmingCharacters(in:.newlines),tree=try await repo.run(["rev-parse","HEAD^{tree}"]).text.trimmingCharacters(in:.newlines)
        let tag=try await object(repo,type:"tag",data:Data(("object "+head+"\ntype commit\ntag signed\ntagger Tag <tag@example.invalid> 1700000000 +0000\n\ntag\n-----BEGIN PGP SIGNATURE-----\nnot verified\n-----END PGP SIGNATURE-----\n").utf8))
        let nested=try await object(repo,type:"tag",data:Data(("object "+tag+"\ntype tag\ntag nested\ntagger Tag <tag@example.invalid> 1700000000 +0000\n\nnested\n").utf8))
        let treeTag=try await object(repo,type:"tag",data:Data(("object "+tree+"\ntype tree\ntag tree\ntagger Tag <tag@example.invalid> 1700000000 +0000\n\ntree\n").utf8))
        for backend in [engine(),GitLibGit2Configuration(enabled:false)] {
            let peeled=try commit(await repo.singleCommitDetails(revision:nested,backend:backend));XCTAssertEqual(peeled.objectID,head)
            guard case .tree(let oid)=try await repo.singleCommitDetails(revision:tree,allowTree:true,backend:backend) else{return XCTFail("Direct tree refused")};XCTAssertEqual(oid,tree)
            guard case .tree=try await repo.singleCommitDetails(revision:treeTag+"^{tree}",allowTree:true,backend:backend) else{return XCTFail("Explicit tree expression refused")}
        }
        do {_ = try await repo.singleCommitDetails(revision:treeTag,allowTree:true,backend:engine());XCTFail("Selected source fallback must not peel annotated tag to tree")}catch{}
        guard case .tree=try await repo.singleCommitDetails(revision:treeTag,allowTree:true,backend:.init(enabled:false)) else{return XCTFail("CLI tree fallback refused")}
    }
    func testWorkingTreeTypedBypassMissingHelperAndRawZeroRevisionRefusal() async throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString),missing=GitLibGit2Configuration(enabled:true,mask:GitLibGit2Operation.getCommit.mask,helperURL:root.appendingPathComponent("missing"))
        let repo=GitRepository(root:root,libgit2Configuration:missing)
        guard case .workingTree=try await repo.singleCommitDetails(revision:ComparisonRevision.workingTree) else{return XCTFail("Working tree must bypass Git")}
        do {_ = try await repo.singleCommitDetails(revision:String(repeating:"0",count:40));XCTFail("Raw zero must not bypass Git/helper")}catch{}
        let cancelled=OperationCancellation();cancelled.cancel()
        do {_ = try await repo.singleCommitDetails(revision:ComparisonRevision.workingTree,cancellation:cancelled);XCTFail("Cancelled typed input succeeded")}catch{}
    }
    func testFileDiffResolvesOriginalTaggedTreeThroughSelectedCommitReader() async throws {
        let(root,base,_)=try await GitPatchTests().fixture();defer{try? FileManager.default.removeItem(at:root)}
        let head=try await base.run(["rev-parse","HEAD"]).text.trimmingCharacters(in:.newlines),tree=try await base.run(["rev-parse","HEAD^{tree}"]).text.trimmingCharacters(in:.newlines)
        let taggedTree=try await object(base,type:"tag",data:Data(("object "+tree+"\ntype tree\ntag tree\ntagger Tag <tag@example.invalid> 1700000000 +0000\n\ntree\n").utf8))
        _ = try await base.run(["tag","-a","commit-tag","-m","commit tag",head])
        for backend in [engine(),GitLibGit2Configuration(enabled:false)] {
            let repo=GitRepository(root:root,libgit2Configuration:backend)
            for expression in [tree,taggedTree+"^{tree}"] {
                let snapshot=try await repo.revisionComparison(from:.revision(expression),to:.revision("commit-tag"))
                XCTAssertEqual(snapshot.from,.revision(tree));XCTAssertEqual(snapshot.to,.revision(head));XCTAssertEqual(snapshot.fromDetails?.isTree,true);XCTAssertEqual(snapshot.toDetails?.subject,"base");XCTAssertTrue(snapshot.files.isEmpty)
            }
            if backend.requests(.getCommit) {
                do {_ = try await repo.revisionComparison(from:.revision(taggedTree),to:.revision("HEAD"));XCTFail("FileDiff pre-peeled original tree tag and bypassed source14 refusal")}catch{}
            } else {
                let snapshot=try await repo.revisionComparison(from:.revision(taggedTree),to:.revision("HEAD"));XCTAssertEqual(snapshot.from,.revision(tree));XCTAssertEqual(snapshot.fromDetails?.isTree,true)
            }
        }
    }
    func testMailmapChangesPresentationWithoutChangingRawSignatures() async throws {
        let(root,repo,_)=try await GitPatchTests().fixture();defer{try? FileManager.default.removeItem(at:root)}
        try Data("Mapped Person <mapped@example.invalid> <patch@example.invalid>\n".utf8).write(to:root.appendingPathComponent(".mailmap"))
        for backend in [engine(),GitLibGit2Configuration(enabled:false)] {
            let original=try commit(await repo.singleCommitDetails(revision:"HEAD",backend:backend)),mapped=try commit(await repo.singleCommitDetails(revision:"HEAD",useMailmap:true,backend:backend))
            XCTAssertEqual(mapped.author.name,"Mapped Person");XCTAssertEqual(mapped.author.email,"mapped@example.invalid");XCTAssertEqual(mapped.author.nameBytes,original.author.nameBytes);XCTAssertEqual(mapped.author.emailBytes,original.author.emailBytes);XCTAssertEqual(mapped.messageBytes,original.messageBytes)
        }
    }
    func testContainingParentTitlesAndRebaseAddConsumeCapturedSingleCommitBackend() async throws {
        let(root,base,_)=try await GitPatchTests().fixture();defer{try? FileManager.default.removeItem(at:root)}
        let repo=GitRepository(root:root,libgit2Configuration:engine())
        let head=try await base.run(["rev-parse","HEAD"]).text.trimmingCharacters(in:.newlines),tree=try await base.run(["rev-parse","HEAD^{tree}"]).text.trimmingCharacters(in:.newlines)
        let oid=try await object(base,data:raw(tree:tree,parents:[head]))
        let contained=try await repo.commitContainingReferences(oid,includeCompletion:false,useMailmap:false);XCTAssertEqual(contained.subject,"Café");XCTAssertEqual(contained.author,"Café")
        let comparison=try await repo.revisionComparison(from:.revision(oid),to:.revision(head))
        XCTAssertEqual(comparison.fromDetails?.subject,"Café");XCTAssertEqual(comparison.fromDetails?.author,"Café");XCTAssertEqual(comparison.fromDetails?.authorDate?.timeIntervalSince1970,-1)
        let added=try await repo.addingRebaseEntries([],revisions:[oid]);XCTAssertEqual(added.first?.commit.message,"Café\n\n body \n\n")
        let child=try await base.run(["commit-tree",tree,"-p",oid],input:Data("child\n".utf8)).text.trimmingCharacters(in:.newlines)
        let entry=try await repo.singleCommitDetails(revision:child).asLogEntry(),parents=try await repo.logParentChoices(entry),reflog=try await repo.referenceLogDiffParents(child)
        XCTAssertEqual(parents.first?.subject,"Café");XCTAssertEqual(reflog.first?.subject,"Café")
    }
    func testMissingSelectedHelperDoesNotInterceptImmutableHashRebaseReads() async throws {
        let(root,base,_)=try await GitPatchTests().fixture();defer{try? FileManager.default.removeItem(at:root)}
        let repo=GitRepository(root:root,libgit2Configuration:.init(enabled:true,mask:GitLibGit2Operation.getCommit.mask,helperURL:root.appendingPathComponent("missing-helper")))
        let head=try await base.run(["rev-parse","HEAD"]).text.trimmingCharacters(in:.newlines)
        let immutable=try await repo.rebaseCommit(head);XCTAssertEqual(immutable.hash,head)
        do {_ = try await repo.singleCommitDetails(revision:"HEAD");XCTFail("Selected helper absence silently fell back")}catch{}
        do {_ = try await repo.addingRebaseEntries([],revisions:[head]);XCTFail("Source Add silently bypassed selected helper")}catch{}
    }
    func testEditThenSquashUsesSelectedFirstAuthorForEveryDatePolicy() async throws {
        let helper=try XCTUnwrap(engine().executor(for:.getCommit))
        for policy in [RebaseSquashDate.first,.latest,.current] {
            let(root,base,_)=try await GitPatchTests().fixture();defer{try? FileManager.default.removeItem(at:root)}
            let initial=try await base.rebaseCommit("HEAD")
            for(name,date) in [("first","2001-01-01T01:02:03+02:00"),("second","2002-02-02T02:03:04-03:00")] {
                try Data(name.utf8).write(to:root.appendingPathComponent(name));try await base.stage([name])
                _ = try await base.run(["commit","-m",name],environmentOverrides:["GIT_AUTHOR_DATE":date,"GIT_AUTHOR_NAME":"First Author","GIT_AUTHOR_EMAIL":"first@example.invalid"])
            }
            let latest=try await base.rebaseCommit("HEAD")
            let marker=root.appendingPathComponent("read14"),wrapper=root.appendingPathComponent("reader")
            func quote(_ value:String)->String {"'"+value.replacingOccurrences(of:"'",with:"'\\''")+"'"}
            try Data(("#!/bin/sh\nprintf x >> "+quote(marker.path)+"\nexec "+quote(helper.path)+" \"$@\"\n").utf8).write(to:wrapper);try FileManager.default.setAttributes([.posixPermissions:0o700],ofItemAtPath:wrapper.path)
            let config=GitLibGit2Configuration(enabled:true,mask:GitLibGit2Operation.getCommit.mask,helperURL:wrapper)
            let repo=GitRepository(root:root,libgit2Configuration:config)
            var options=RebaseOptions();options.upstream=initial.hash;options.force=true;options.squashDate=policy
            var plan=try await repo.rebasePlan(options);plan.entries[0].action = .edit;plan.entries[1].action = .squash
            let edit=try await repo.startRebase(plan,editorExecutable:RebaseTests().editor);XCTAssertTrue(edit.state.isEditPause)
            _ = try await repo.amendRebaseCommit(message:"Edited first")
            let edited=try await repo.rebaseCommit("HEAD")
            let pause=try await repo.continueRebase();XCTAssertNotNil(pause.state.squashMessage)
            XCTAssertFalse(FileManager.default.fileExists(atPath:marker.path),"No unused post-Edit GetCommit query")
            let pausedHead=try await repo.rebaseCommit("HEAD")
            let unavailable=GitRepository(root:root,libgit2Configuration:.init(enabled:true,mask:GitLibGit2Operation.getCommit.mask,helperURL:root.appendingPathComponent("missing-reader")))
            do {_ = try await unavailable.continueRebase(squashMessage:"Must not apply",expectedSquashHead:pausedHead.hash,expectedSquashState:pause.state);XCTFail("Every source squash policy requires its selected first-author reader")}catch{}
            let unchanged=try await repo.rebaseCommit("HEAD"),pending=try await repo.rebaseState()
            XCTAssertEqual(unchanged.hash,pausedHead.hash);XCTAssertEqual(pending.squashMessage?.message,pause.state.squashMessage?.message)
            let before=Date().timeIntervalSince1970
            let result=try await repo.continueRebase(squashMessage:"Approved",expectedSquashHead:pausedHead.hash,expectedSquashState:pause.state)
            XCTAssertEqual(result.exitCode,0,result.output);XCTAssertFalse(result.state.active)
            let final=try await repo.rebaseCommit("HEAD");XCTAssertEqual(final.author,edited.author);XCTAssertEqual(final.email,edited.email)
            XCTAssertTrue(FileManager.default.fileExists(atPath:marker.path),"First author is supplied by source14 for every date policy")
            switch policy {
            case .first:XCTAssertEqual(final.date,edited.date)
            case .latest:XCTAssertEqual(final.date,latest.date)
            case .current:
                let time=try XCTUnwrap(ISO8601DateFormatter().date(from:final.date)).timeIntervalSince1970
                XCTAssertGreaterThanOrEqual(time,before-1);XCTAssertLessThanOrEqual(time,Date().timeIntervalSince1970+1)
            }
        }
    }
    func testBackendIdentityTracksHelperReplacementWithoutExecutingIt() throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString);try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true);defer{try? FileManager.default.removeItem(at:root)}
        let helper=root.appendingPathComponent("helper");try Data("#!/bin/sh\nexit 0\n".utf8).write(to:helper);try FileManager.default.setAttributes([.posixPermissions:0o700],ofItemAtPath:helper.path)
        let repo=GitRepository(root:root),config=GitLibGit2Configuration(enabled:true,mask:GitLibGit2Operation.getCommit.mask,helperURL:helper)
        let before=try repo.singleCommitBackendIdentity(backend:config)
        let replacement=root.appendingPathComponent("replacement");try Data("#!/bin/sh\nexit 1\n".utf8).write(to:replacement);try FileManager.default.setAttributes([.posixPermissions:0o700],ofItemAtPath:replacement.path);try FileManager.default.removeItem(at:helper);try FileManager.default.moveItem(at:replacement,to:helper)
        XCTAssertNotEqual(before,try repo.singleCommitBackendIdentity(backend:config));XCTAssertEqual(try repo.singleCommitBackendIdentity(backend:.init(enabled:false)),"single-commit-cli-v1")
        try FileManager.default.setAttributes([.modificationDate:Date(timeIntervalSince1970:1700000000.125)],ofItemAtPath:helper.path)
        let fractional=try repo.singleCommitBackendIdentity(backend:config)
        try FileManager.default.setAttributes([.modificationDate:Date(timeIntervalSince1970:1700000000.875)],ofItemAtPath:helper.path)
        XCTAssertNotEqual(fractional,try repo.singleCommitBackendIdentity(backend:config),"Same-second helper changes invalidate cached metadata")
    }
    func testSquashRetainsRawLatin1FirstAuthorBytesForEveryDatePolicy() async throws {
        for policy in [RebaseSquashDate.first,.latest,.current] {
            let(root,base,_)=try await GitPatchTests().fixture();defer{try? FileManager.default.removeItem(at:root)}
            _ = try await base.run(["config","i18n.commitEncoding","ISO-8859-1"])
            let initial=try await base.rebaseCommit("HEAD")
            try Data("first".utf8).write(to:root.appendingPathComponent("first"));try await base.stage(["first"])
            let firstTree=try await base.run(["write-tree"]).text.trimmingCharacters(in:.newlines)
            let firstOID=try await object(base,data:raw(tree:firstTree,parents:[initial.hash],authorTime:978307323,authorOffset:"+0200"))
            _ = try await base.run(["update-ref","HEAD",firstOID,initial.hash])
            try Data("second".utf8).write(to:root.appendingPathComponent("second"));try await base.stage(["second"])
            _ = try await base.run(["commit","-m","second"],environmentOverrides:["GIT_AUTHOR_DATE":"2002-02-02T02:03:04-03:00"])
            let repo=GitRepository(root:root,libgit2Configuration:engine())
            let original=try commit(await repo.singleCommitDetails(revision:firstOID)),latest=try await base.rebaseCommit("HEAD")
            XCTAssertEqual(original.author.nameBytes,Data([67,97,102,233]));XCTAssertEqual(original.author.name,"Café")
            var options=RebaseOptions();options.upstream=initial.hash;options.force=true;options.squashDate=policy
            var plan=try await repo.rebasePlan(options);plan.entries[1].action = .squash
            let paused=try await repo.startRebase(plan,editorExecutable:RebaseTests().editor)
            XCTAssertNotNil(paused.state.squashMessage)
            let before=Date().timeIntervalSince1970
            let done=try await repo.continueRebase(squashMessage:"Approved Latin1")
            XCTAssertEqual(done.exitCode,0,done.output);XCTAssertFalse(done.state.active)
            let actual=try commit(await repo.singleCommitDetails(revision:"HEAD"))
            XCTAssertEqual(actual.author.nameBytes,original.author.nameBytes);XCTAssertEqual(actual.author.emailBytes,original.author.emailBytes);XCTAssertEqual(actual.author.name,"Café");XCTAssertEqual(actual.encodingBytes,Data("ISO-8859-1".utf8))
            switch policy {
            case .first:XCTAssertEqual(actual.author.date,original.author.date)
            case .latest:XCTAssertEqual(actual.author.date,latest.date)
            case .current:
                XCTAssertGreaterThanOrEqual(Double(actual.author.time),before-1);XCTAssertLessThanOrEqual(Double(actual.author.time),Date().timeIntervalSince1970+1)
            }
        }
    }
}
