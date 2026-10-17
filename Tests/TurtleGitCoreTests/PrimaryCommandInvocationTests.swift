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
            ["/command:log","/outfile:result"], ["/command:repostatus","/logmsg:bad"], ["/command:commit","--path","x\0y"],
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
}
