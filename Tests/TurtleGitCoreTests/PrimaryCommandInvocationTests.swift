import XCTest
@testable import TurtleGitCore

final class PrimaryCommandInvocationTests: XCTestCase {
    func parse(_ arguments: [String], cwd: String = "/repo") throws -> PrimaryCommandInvocation {
        let value = try PrimaryCommandInvocation.parse(arguments: arguments, currentDirectory: cwd)
        return try XCTUnwrap(value)
    }
    func testOrdinaryLaunchDoesNotTreatMacArgumentsAsCommands() throws {
        for arguments in [[], ["-psn_0_123"], ["-ApplePersistenceIgnoreState", "YES"], ["--path", "/repo"]] {
            XCTAssertNil(try PrimaryCommandInvocation.parse(arguments: arguments, currentDirectory: "/repo"))
        }
    }
    func testAllSixPrimaryDialogsAndDefaultDirectory() throws {
        for (name, action) in [("commit",RepositoryAction.commit),("repostatus",.status),("log",.log),("diff",.diff),("revert",.revert),("resolve",.resolve)] {
            let invocation = try parse(["/command:" + name])
            XCTAssertEqual(invocation.request.action, action)
            XCTAssertEqual(invocation.request.paths.map(\.path), ["/repo"])
        }
    }
    func testLiteralNativePathsAndLegacyMultipleSelections() throws {
        let first = "space &?\n雪[*].txt", a = "café", b = "cafe\u{301}"
        let invocation = try parse(["--command=commit", "--path", first, "--path=" + a, "--path", b])
        XCTAssertEqual(invocation.request.paths.map { Data($0.path.utf8) }, [first,a,b].map { Data(("/repo/" + $0).utf8) })
        let legacy = try parse(["/COMMAND:REVERT", "/path:one*dir/two"])
        XCTAssertEqual(legacy.request.paths.map(\.path), ["/repo/one", "/repo/dir/two"])
        let lexical = try parse(["--command", "repostatus", "--path", "child/../leaf"])
        XCTAssertEqual(lexical.request.paths.first?.path, "/repo/leaf")
    }
    func testCommitPresetsAreLiteralAndExclusive() throws {
        let invocation = try parse(["/command:commit", "/logmsg:Subject:\n$HOME `shell`", "/bugid:123", "/wholeproject"])
        XCTAssertEqual(invocation.message, "Subject:\n$HOME `shell`")
        XCTAssertEqual(invocation.issueID,"123"); XCTAssertTrue(invocation.wholeProject)
        XCTAssertThrowsError(try parse(["/command:commit", "/logmsg:", "/logmsgfile:message"]))
        XCTAssertEqual(try parse(["/command:commit", "/logmsgfile:message"]).messageFile?.path, "/repo/message")
    }
    func testLogRangeLimitsAndSourceMaskTranslation() throws {
        let invocation = try parse(["/command:log", "/startrev:old", "/endrev:new", "/range:main...topic", "/rev:HEAD~1", "/limit:2 weeks", "/findstring:a.*b", "/findtype:262", "/findtext", "/findregex"])
        XCTAssertEqual(invocation.historyExpression,"main...topic")
        XCTAssertEqual(invocation.selectedRevision,"HEAD~1")
        XCTAssertEqual(invocation.historyLimit?.scale,.weeks); XCTAssertEqual(invocation.historyLimit?.number,2)
        XCTAssertEqual(invocation.search,"a.*b"); XCTAssertEqual(invocation.searchRegex,true)
        XCTAssertEqual(invocation.searchFields,[.paths,.authors,.emails])
        XCTAssertEqual(try parse(["/command:log","/startrev:topic"]).historyExpression,"topic..HEAD")
        XCTAssertEqual(try parse(["/command:log","/endrev:topic"]).historyExpression,"topic")
        XCTAssertEqual(try parse(["/command:log","/revstart:main","/revend:topic"]).historyExpression,"main..topic")
        for (text,scale) in [("0",HistoryLimitScale.noLimit),("12",.commits),("3months",.months),("1 year",.years)] {
            XCTAssertEqual(try parse(["/command:log","/limit:"+text]).historyLimit?.scale,scale)
        }
    }
    func testDiffPairsAndRevisions() throws {
        let pair = try parse(["/command:diff", "/path:one", "/path2:two", "/alternative"])
        XCTAssertEqual(pair.request.paths.map(\.path),["/repo/one","/repo/two"]); XCTAssertEqual(pair.request.alternateTool,true)
        let revision = try parse(["/command:diff","/startrev:HEAD~1","/endrev:HEAD"])
        XCTAssertEqual(revision.diffFrom,"HEAD~1"); XCTAssertEqual(revision.diffTo,"HEAD")
    }
    func testInvalidOptionsAreNeverSilentlyDropped() throws {
        let invalid: [[String]] = [
            ["/command:clone"], ["/command:commit","/command:commit"], ["/command:commit","--logmsg"],
            ["/command:commit","/path:a**b"], ["/command:commit","--path="], ["/command:commit","/wholeproject:true"],
            ["/command:commit","/unknown"], ["/command:resolve","/silent"], ["/command:resolve","/noquestion"],
            ["/command:repostatus","/logmsg:bad"], ["/command:commit","--path","x\0y"],
            ["/command:log","/range:--all"], ["/command:log","/rev:-bad"], ["/command:log","/limit:999999999999999"],
            ["/command:log","/limit:0 weeks"], ["/command:log","/limit:1fortnight"], ["/command:log","/findtype:4096"],
            ["/command:diff","/startrev:HEAD"], ["/command:diff","/path:a*b","/path2:c"], ["/command:diff","/path:a","/path2:a"],
            ["/command:diff","/path2:b","/startrev:main","/endrev:topic"]]
        for arguments in invalid { XCTAssertThrowsError(try parse(arguments),arguments.joined(separator:" ")) }
    }
    func testMessageFileReadAndCancellationWithoutMutation() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
        defer {try? FileManager.default.removeItem(at:folder)}
        let file = folder.appendingPathComponent("message")
        let bytes = Data([0xEF,0xBB,0xBF]) + Data("literal\r\n雪\n".utf8) + Data([0xFF])
        try bytes.write(to:file)
        let invocation = try parse(["--command=commit","--logmsgfile",file.path])
        XCTAssertEqual(try invocation.readMessageFile(cancellation:OperationCancellation()),String(decoding:bytes,as:UTF8.self))
        XCTAssertEqual(try Data(contentsOf:file),bytes)
        let token=OperationCancellation();token.cancel()
        XCTAssertThrowsError(try invocation.readMessageFile(cancellation:token))
        let directory = try parse(["--command=commit","--logmsgfile",folder.path])
        XCTAssertThrowsError(try directory.readMessageFile(cancellation:OperationCancellation()))
        try Data(repeating:65,count:16*1024*1024+1).write(to:file)
        XCTAssertThrowsError(try invocation.readMessageFile(cancellation:OperationCancellation()))
    }
    func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("TurtleGitCommandIO-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
    func testFileTransportOptionsAndIncompatibleInputs() throws {
        let log = try parse(["/command:log", "/pathfile:paths", "/deletepathfile", "/outfile:result"])
        XCTAssertEqual(log.pathFile?.path,"/repo/paths"); XCTAssertEqual(log.outputFile?.path,"/repo/result"); XCTAssertTrue(log.deletePathFile)
        let diff = try parse(["--command=diff","--unified","--line=123"])
        XCTAssertTrue(diff.unified); XCTAssertEqual(diff.line,123)
        XCTAssertNil(try parse(["--command=diff","--line=0"]).line)
        for arguments in [["/command:log","/path:a","/pathfile:list"],["/command:log","/deletepathfile"],["/command:commit","/outfile:x"],["/command:revert","/unified"],["/command:diff","/line:-1"],["/command:diff","/line:2147483648"],["/command:log","/pathfile0"]] { XCTAssertThrowsError(try parse(arguments)) }
    }
    func testUTF8AndUTF16PathListsKeepLiteralNamesAndOrder() throws {
        let root = try temporaryDirectory();defer {try? FileManager.default.removeItem(at:root)}
        let a = "café[*]", b = "cafe\u{301}[*]", file = root.appendingPathComponent("paths")
        let text = "\n" + a + "\r\n" + b + "\n space \n"
        let formats = [Data(text.utf8), Data([0xEF,0xBB,0xBF])+Data(text.utf8), try XCTUnwrap(text.data(using:.utf16LittleEndian)), Data([0xFF,0xFE])+(try XCTUnwrap(text.data(using:.utf16LittleEndian))), Data([0xFE,0xFF])+(try XCTUnwrap(text.data(using:.utf16BigEndian)))]
        for data in formats {
            try data.write(to:file)
            let invocation = try parse(["/command:commit","/pathfile:"+file.path],cwd:root.path)
            let resolved = try invocation.resolvingPathFile(cancellation:OperationCancellation())
            XCTAssertNil(resolved.pathFile)
            XCTAssertEqual(resolved.request.paths.map {Data($0.path.utf8)},[a,b," space "].map {Data((root.path+"/"+$0).utf8)})
            XCTAssertEqual(try Data(contentsOf:file),data)
        }
    }
    func testNULPathFileSupportsNewlinesAndPairResolution() throws {
        let root = try temporaryDirectory();defer {try? FileManager.default.removeItem(at:root)}
        let file = root.appendingPathComponent("paths"), names = ["line\nname[*]", "other"]
        try Data((names.joined(separator:"\0")+"\0").utf8).write(to:file)
        let invocation = try parse(["/command:revert","/pathfile:"+file.path,"/pathfile0"],cwd:root.path)
        XCTAssertEqual(try invocation.resolvingPathFile(cancellation:OperationCancellation()).request.paths.map(\.path),names.map {root.path+"/"+$0})
        try Data("first\n".utf8).write(to:file)
        let pair = try parse(["--command=diff","--pathfile",file.path,"--path2=second"],cwd:root.path)
        XCTAssertEqual(try pair.resolvingPathFile(cancellation:OperationCancellation()).request.paths.map(\.path),[root.path+"/first",root.path+"/second"])
    }
    func testPathFileDeletionRequiresSuccessfulReadAndLiveCancellation() throws {
        let root = try temporaryDirectory();defer {try? FileManager.default.removeItem(at:root)}
        let file = root.appendingPathComponent("paths")
        let invocation = try parse(["/command:commit","/pathfile:"+file.path,"/deletepathfile"],cwd:root.path)
        for bad in [Data(),Data([0xFF]),Data("\0".utf8)] {
            try bad.write(to:file);XCTAssertThrowsError(try invocation.resolvingPathFile(cancellation:OperationCancellation()));XCTAssertTrue(FileManager.default.fileExists(atPath:file.path))
        }
        try Data("valid\n".utf8).write(to:file)
        let token = OperationCancellation();token.cancel()
        XCTAssertThrowsError(try invocation.resolvingPathFile(cancellation:token));XCTAssertTrue(FileManager.default.fileExists(atPath:file.path))
        _ = try invocation.resolvingPathFile(cancellation:OperationCancellation());XCTAssertFalse(FileManager.default.fileExists(atPath:file.path))
        let target = root.appendingPathComponent("target");try Data("valid\n".utf8).write(to:target)
        try FileManager.default.createSymbolicLink(at:file,withDestinationURL:target)
        XCTAssertThrowsError(try invocation.resolvingPathFile(cancellation:OperationCancellation()));XCTAssertTrue(FileManager.default.fileExists(atPath:target.path));XCTAssertNotNil(try? FileManager.default.destinationOfSymbolicLink(atPath:file.path))
    }
    func testRevisionOutputProtocolAndCancelledWrite() throws {
        let root = try temporaryDirectory();defer {try? FileManager.default.removeItem(at:root)}
        let file=root.appendingPathComponent("selected"),hash=String(repeating:"a",count:40)
        try PrimaryCommandInvocation.writeSelectedRevision(hash,to:file,cancellation:OperationCancellation())
        XCTAssertEqual(try Data(contentsOf:file),Data(hash.utf8))
        let token=OperationCancellation();token.cancel()
        XCTAssertThrowsError(try PrimaryCommandInvocation.writeSelectedRevision(nil,to:file,cancellation:token));XCTAssertEqual(try Data(contentsOf:file),Data(hash.utf8))
        XCTAssertThrowsError(try PrimaryCommandInvocation.writeSelectedRevision("HEAD\n",to:file,cancellation:OperationCancellation()))
        try PrimaryCommandInvocation.writeSelectedRevision(nil,to:file,cancellation:OperationCancellation());XCTAssertEqual(try Data(contentsOf:file),Data())
    }
    func testUnifiedDiffUsesExactScopeAndCapturedRevisions() async throws {
        let root = try temporaryDirectory();defer {try? FileManager.default.removeItem(at:root)}
        let repo=GitRepository(root:root)
        _ = try await repo.run(["init","-b","main"])
        for (key,value) in [("user.name","Command QA"),("user.email","qa@example.invalid"),("commit.gpgsign","false"),("core.hooksPath","/dev/null")] {_ = try await repo.run(["config",key,value])}
        let paths=["[match].txt","m.txt"]
        for path in paths {try Data("base\n".utf8).write(to:root.appendingPathComponent(path))}
        try await repo.stage(paths);_ = try await repo.commit(message:"base");let base=try await repo.rebaseCommit("HEAD")
        try Data("selected revision\n".utf8).write(to:root.appendingPathComponent(paths[0]));try Data("excluded revision\n".utf8).write(to:root.appendingPathComponent(paths[1]))
        try await repo.stage(paths);_ = try await repo.commit(message:"next");let head=try await repo.rebaseCommit("HEAD")
        try Data("selected working\n".utf8).write(to:root.appendingPathComponent(paths[0]));try Data("excluded working\n".utf8).write(to:root.appendingPathComponent(paths[1]))
        let index=try Data(contentsOf:root.appendingPathComponent(".git/index"))
        let historical=String(decoding:try await repo.commandUnifiedDiff(from:base.hash,to:head.hash,paths:[paths[0]],cancellation:OperationCancellation()),as:UTF8.self)
        XCTAssertTrue(historical.contains("+selected revision"));XCTAssertFalse(historical.contains("excluded"));XCTAssertFalse(historical.contains("selected working"))
        let working=String(decoding:try await repo.commandUnifiedDiff(from:nil,to:nil,paths:[paths[0]],cancellation:OperationCancellation()),as:UTF8.self)
        XCTAssertTrue(working.contains("+selected working"));XCTAssertFalse(working.contains("excluded"))
        XCTAssertEqual(try Data(contentsOf:root.appendingPathComponent(".git/index")),index)
    }

}
