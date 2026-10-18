import XCTest
@testable import TurtleGitCore

final class PrimaryCommandInvocationTests: XCTestCase {
    func parse(_ arguments: [String], cwd: String = "/repo") throws -> PrimaryCommandInvocation {
        let value = try PrimaryCommandInvocation.parse(arguments: arguments, currentDirectory: cwd)
        return try XCTUnwrap(value)
    }
    func testBisectCommandOptionalTermsAndPreservedPathList() throws {
        let start=try parse(["--command=bisect","--start","--good","base","--bad=tip"])
        XCTAssertEqual(start.request.action,.bisect);XCTAssertEqual(start.bisectCommand, .init(start:true,good:"base",bad:"tip"))
        let flags=try parse(["/command:bisect","/good","/bad:","/skip","/reset","/ref:HEAD~2"])
        XCTAssertEqual(flags.bisectCommand,.init(good:"",bad:"",skip:true,reset:true,reference:"HEAD~2"))
        XCTAssertEqual(try parse(["--command=bisect","--good","--path=folder"]).bisectCommand?.good,"")
        let folder=try temporaryDirectory();defer {try? FileManager.default.removeItem(at:folder)}
        let list=folder.appendingPathComponent("paths");try Data("one\ntwo\n".utf8).write(to:list)
        let value=try parse(["--command=bisect","--start","--bad=tip","--pathfile",list.path])
        let resolved=try value.resolvingPathFile(cancellation:OperationCancellation())
        XCTAssertEqual(resolved.bisectCommand,value.bisectCommand);XCTAssertEqual(resolved.request.paths.count,2)
        XCTAssertEqual(resolved.selecting([folder]).bisectCommand,value.bisectCommand)
    }
    func testBisectCommandRejectsInvalidAndForeignOptions() throws {
        for args in [["/command:bisect","/start:true"],["/command:bisect","/skip:true"],["/command:bisect","/good:-invalid"],["--command=bisect","--bad","bad name"],["/command:bisect","/good","/good:one"],["/command:bisect","/rev:HEAD"],["/command:commit","/good"],["/command:merge","/reset"],["/command:bisect","/ref:-bad"]] {XCTAssertThrowsError(try parse(args),args.joined(separator:" "))}
    }
    func testBisectCommandUsesActualStateAndSourcePrecedence() throws {
        typealias Request=BisectCommandRequest
        XCTAssertEqual(try Request(start:true).action(active:false),.start(good:nil,bad:nil))
        XCTAssertEqual(try Request(start:true,good:"",bad:"").action(active:false),.start(good:nil,bad:nil))
        let all=Request(start:true,good:"base",bad:"tip",skip:true,reset:true,reference:"selected")
        XCTAssertEqual(try all.action(active:false),.start(good:"base",bad:"tip"))
        XCTAssertEqual(try all.action(active:true),.operation(.good,revisions:["selected"]))
        XCTAssertEqual(try Request(bad:"ignored",skip:true,reset:true,reference:"selected").action(active:true),.operation(.bad,revisions:["selected"]))
        XCTAssertEqual(try Request(skip:true,reset:true,reference:"selected").action(active:true),.operation(.skip,revisions:["selected"]))
        XCTAssertEqual(try Request(reset:true,reference:"ignored").action(active:true),.operation(.reset,revisions:[]))
        XCTAssertEqual(try Request(good:"").action(active:true),.operation(.good,revisions:[]))
        for request in [Request(),Request(good:""),Request(bad:""),Request(skip:true),Request(reset:true)] {XCTAssertThrowsError(try request.action(active:false))}
        XCTAssertThrowsError(try Request(start:true).action(active:true));XCTAssertThrowsError(try Request().action(active:true))
    }
    func testPatchCommandFamilyPresetsAndDestination() throws {
        for (command,action) in [("formatpatch",RepositoryAction.formatPatch),("export",.export),("importpatch",.importPatch)] {
            XCTAssertEqual(try parse(["--command="+command]).request.action,action)
        }
        let since=try parse(["/command:formatpatch","/startrev:topic"])
        XCTAssertEqual(since.formatPatchPreset?.selection,.since("topic"));XCTAssertEqual(since.formatPatchPreset?.from,"topic~1");XCTAssertEqual(since.formatPatchPreset?.to,"topic")
        let range=try parse(["--command=formatpatch","--startrev=base","--endrev=tip"])
        XCTAssertEqual(range.formatPatchPreset?.selection,.range(from:"base",to:"tip"));XCTAssertNil(range.diffFrom)
        for flags in [[],["/endrev:tip"],["/startrev:"],["/startrev:base","/endrev:"]] {
            let value=try parse(["/command:formatpatch"]+flags)
            XCTAssertEqual(value.formatPatchPreset?.selection,flags.first=="/startrev:base" ? .since("base"):nil)
        }
        XCTAssertEqual(try parse(["/command:export","/rev:topic~1"]).selectedRevision,"topic~1")
        let imported=try parse(["--command=importpatch","--path=mailbox.dat","--droptarget=target/../work"])
        XCTAssertEqual(imported.importTarget?.path,"/repo/work");XCTAssertEqual(imported.request.paths.first?.path,"/repo/mailbox.dat")
        XCTAssertNil(try parse(["/command:importpatch","/droptarget:"]).importTarget)
    }
    func testPatchCommandFamilyRejectsForeignFlagsAndInvalidRevisions() throws {
        for args in [["/command:export","/startrev:HEAD"],["/command:export","/path:a*b"],["/command:formatpatch","/rev:HEAD"],["/command:formatpatch","/startrev:-bad"],["/command:formatpatch","/startrev:topic with spaces"],["/command:formatpatch","/endrev:-bad"],["/command:importpatch","/rev:HEAD"],["/command:importpatch","/droptarget:one","/droptarget:two"],["/command:commit","/droptarget:repo"]] {XCTAssertThrowsError(try parse(args))}
    }
    func testPatchCommandPathFileRetainsPresetsAndValidatesBeforeDelete() throws {
        let folder=try temporaryDirectory();defer {try? FileManager.default.removeItem(at:folder)}
        let list=folder.appendingPathComponent("paths")
        try Data("one\ntwo\n".utf8).write(to:list)
        let export=try parse(["--command=export","--pathfile",list.path,"--deletepathfile"])
        XCTAssertThrowsError(try export.resolvingPathFile(cancellation:OperationCancellation()));XCTAssertTrue(FileManager.default.fileExists(atPath:list.path))
        for command in ["formatpatch","importpatch"] {
            let flags=command=="formatpatch" ? ["--startrev=base","--endrev=tip"]:["--droptarget=work"]
            let value=try parse(["--command="+command,"--pathfile",list.path]+flags)
            let resolved=try value.resolvingPathFile(cancellation:OperationCancellation())
            XCTAssertEqual(resolved.request.paths.count,2);XCTAssertEqual(resolved.formatPatchPreset,value.formatPatchPreset);XCTAssertEqual(resolved.importTarget,value.importTarget)
            XCTAssertEqual(resolved.selecting([folder]).formatPatchPreset,value.formatPatchPreset)
        }
    }
    func testIntegrationCommandFamilySourceFlagsAndMessage() throws {
        for (command,action) in [("merge",RepositoryAction.merge),("stashsave",.stash),("stashapply",.stashApply),("stashpop",.stashPop),("stashlist",.stashList)] {
            let value=try parse(["--command="+command,"--path","folder[*] 雪"])
            XCTAssertEqual(value.request.action,action)
            XCTAssertEqual(value.request.paths.first?.path,"/repo/folder[*] 雪")
        }
        XCTAssertEqual(try parse(["/command:merge","/abort"]).request.action,.mergeAbort)
        let message="shelf 🐢\n`literal` $(literal)"
        XCTAssertEqual(try parse(["--command=stashsave","--msg",message]).message,message)
        XCTAssertEqual(try parse(["/command:stashsave","/msg:"]).message,"")
        XCTAssertNil(try parse(["/command:stashsave"]).message)
    }
    func testIntegrationCommandRejectsForeignAndInventedOptions() throws {
        for arguments in [["/command:merge","/abort:true"],["/command:merge","/rev:topic"],["/command:merge","/msg:text"],["/command:stashsave","/logmsg:text"],["/command:stashsave","/includeuntracked"],["/command:stashapply","/ref:stash@{1}"],["/command:stashpop","/msg:text"],["/command:stashlist","/abort"],["/command:commit","/msg:text"],["/command:stashsave","/msg:one","/msg:two"]] {
            XCTAssertThrowsError(try parse(arguments),arguments.joined(separator:" "))
        }
    }
    func testIntegrationCommandPathFileRetainsActionAndMessage() throws {
        let folder=try temporaryDirectory();defer {try? FileManager.default.removeItem(at:folder)}
        let file=folder.appendingPathComponent("selections")
        try Data("folder[*] 雪\0".utf8).write(to:file)
        let value=try parse(["--command=stashsave","--msg=message","--pathfile",file.path,"--pathfile0"])
        let resolved=try value.resolvingPathFile(cancellation:OperationCancellation())
        XCTAssertEqual(resolved.request.action,.stash);XCTAssertEqual(resolved.message,"message")
        XCTAssertEqual(resolved.request.paths.first?.path,"/repo/folder[*] 雪")
        XCTAssertEqual(resolved.selecting([folder]).message,"message")
        let abort=try parse(["--command=merge","--abort","--pathfile",file.path,"--pathfile0"])
        XCTAssertEqual(try abort.resolvingPathFile(cancellation:OperationCancellation()).request.action,.mergeAbort)
    }
    func testSourceFileCommandRoutingAndPresets() throws {
        for (name,action) in [("add",RepositoryAction.add),("rename",.rename),("remove",.remove),("blame",.blame),("prevdiff",.previousDiff)] {
            let value = try parse(["--command="+name,"--path","literal 雪[*].txt"])
            XCTAssertEqual(value.request.action,action)
            XCTAssertEqual(value.request.paths.map(\.path),["/repo/literal 雪[*].txt"])
        }
        let blame=try parse(["/command:blame","/endrev:topic~2","/line:21"])
        XCTAssertEqual(blame.blameRevision,"topic~2");XCTAssertEqual(blame.line,21)
        XCTAssertNil(blame.diffTo);XCTAssertNil(blame.selectedRevision)
        XCTAssertNil(try parse(["/command:blame","/endrev:","/line:0"]).blameRevision)
        let previous=try parse(["/command:prevdiff","/alternative","/unified"])
        XCTAssertEqual(previous.request.alternateTool,true);XCTAssertTrue(previous.unified)
        XCTAssertEqual(try parse(["/command:remove","/keep"]).request.action,.removeKeep)
        XCTAssertEqual(try parse(["/command:remove","/path:a*b"]).request.paths.count,2)
        XCTAssertEqual(try parse(["/command:add","/path:a*b"]).request.paths.count,2)
    }
    func testSourceFileInvalidOptionsAndCardinality() throws {
        for args in [["/command:add","/noui"],["/command:remove","/keep:true"],["/command:add","/keep"],["/command:rename","/name:new"],["/command:blame","/rev:HEAD"],["/command:blame","/endrev:-invalid"],["/command:blame","/line:-1"],["/command:blame","/line:2147483648"],["/command:prevdiff","/line:1"],["/command:prevdiff","/startrev:HEAD"],["/command:remove","/force"]] {
            XCTAssertThrowsError(try parse(args),args.joined(separator:" "))
        }
        for command in ["blame","prevdiff","rename","clone"] {
            XCTAssertThrowsError(try parse(["--command="+command,"--path","one","--path","two"]))
        }
    }
    func testSourceFileListsValidateBeforeDeletionAndKeepPresets() throws {
        let folder=try temporaryDirectory();defer {try? FileManager.default.removeItem(at:folder)}
        let file=folder.appendingPathComponent("paths")
        for command in ["blame","prevdiff","rename"] {
            try Data("one\ntwo\n".utf8).write(to:file)
            let value=try parse(["--command="+command,"--pathfile",file.path,"--deletepathfile"])
            XCTAssertThrowsError(try value.resolvingPathFile(cancellation:OperationCancellation()))
            XCTAssertEqual(try Data(contentsOf:file),Data("one\ntwo\n".utf8))
        }
        try Data("literal 雪[*]\nname\0".utf8).write(to:file)
        let value=try parse(["--command=blame","--pathfile",file.path,"--pathfile0","--endrev","HEAD~3","--line=12"])
        let resolved=try value.resolvingPathFile(cancellation:OperationCancellation())
        XCTAssertEqual(resolved.blameRevision,"HEAD~3");XCTAssertEqual(resolved.line,12)
        XCTAssertEqual(resolved.request.paths.first?.path,"/repo/literal 雪[*]\nname")
        XCTAssertEqual(resolved.selecting([folder]).blameRevision,"HEAD~3")
        let previous=try parse(["--command=prevdiff","--pathfile",file.path,"--pathfile0","--alternative","--unified"])
        let comparison=try previous.resolvingPathFile(cancellation:OperationCancellation())
        XCTAssertTrue(comparison.unified);XCTAssertEqual(comparison.request.alternateTool,true)
        let removal=try parse(["--command=remove","--pathfile",file.path,"--pathfile0","--keep"])
        XCTAssertEqual(try removal.resolvingPathFile(cancellation:OperationCancellation()).request.action,.removeKeep)
    }
    func testMaintenanceCommandFamilyOptionsAndSelections() throws {
        XCTAssertEqual(try parse(["/command:repocreate"]).request.action,.initialize)
        XCTAssertEqual(try parse(["/command:cleanup","/path:folder*other"]).request.action,.clean)
        for (flags,action) in [([],RepositoryAction.ignore),(["/onlymask"],.ignoreMask),(["/delete"],.ignoreDelete),(["/onlymask","/delete"],.ignoreDeleteMask)] {
            let value=try parse(["/command:ignore","/path:literal[1].tmp"]+flags)
            XCTAssertEqual(value.request.action,action);XCTAssertEqual(value.request.paths.first?.path,"/repo/literal[1].tmp")
        }
        for args in [["/command:repocreate","/bare"],["/command:repocreate","/path:a*b"],["/command:cleanup","/dryrun"],["/command:cleanup","/delete"],["/command:ignore","/keep"],["/command:ignore","/onlymask:true"],["/command:remove","/delete"]] {XCTAssertThrowsError(try parse(args))}
        let folder=try temporaryDirectory();defer {try? FileManager.default.removeItem(at:folder)}
        let list=folder.appendingPathComponent("paths");try Data("one\ntwo\n".utf8).write(to:list)
        let create=try parse(["--command=repocreate","--pathfile",list.path,"--deletepathfile"])
        XCTAssertThrowsError(try create.resolvingPathFile(cancellation:OperationCancellation()))
        XCTAssertTrue(FileManager.default.fileExists(atPath:list.path))
        let ignore=try parse(["--command=ignore","--pathfile",list.path,"--onlymask","--delete"])
        let resolved=try ignore.resolvingPathFile(cancellation:OperationCancellation())
        XCTAssertEqual(resolved.request.action,.ignoreDeleteMask);XCTAssertEqual(resolved.request.paths.count,2)
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
            ["/command:unsupported"], ["/command:commit","/command:commit"], ["/command:commit","--logmsg"],
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
        let previous=String(decoding:try await repo.commandUnifiedDiff(from:base.hash,to:nil,paths:[paths[0]],cancellation:OperationCancellation()),as:UTF8.self)
        XCTAssertTrue(previous.contains("-base"));XCTAssertTrue(previous.contains("+selected working"));XCTAssertFalse(previous.contains("excluded"))
        do {_ = try await repo.commandUnifiedDiff(from:nil,to:head.hash,paths:[paths[0]],cancellation:OperationCancellation());XCTFail("Missing base accepted")} catch {}
        XCTAssertEqual(try Data(contentsOf:root.appendingPathComponent(".git/index")),index)
    }

    func testNetworkAndReferenceCommandFamilyPresets() throws {
        let actions: [(String, RepositoryAction)] = [("clone",.clone),("fetch",.fetch),("pull",.pull),("push",.push),("branch",.branch),("tag",.tag),("switch",.switchBranch),("refbrowse",.referenceBrowser),("repobrowser",.repositoryBrowser),("reflog",.reflog),("rebase",.rebase)]
        for (name,action) in actions {XCTAssertEqual(try parse(["/command:"+name]).request.action,action)}
        let clone=try parse(["/command:clone","/url:https://example.invalid/team/repo.git","/exactpath"])
        XCTAssertEqual(clone.sourceURL,"https://example.invalid/team/repo.git");XCTAssertTrue(clone.exactClonePath)
        XCTAssertEqual(try parse(["--command=fetch","--remote","team remote"]).remote,"team remote")
        XCTAssertEqual(try parse(["--command=push","--branch=refs/heads/topic"]).pushBranch,"refs/heads/topic")
        let name="cafe\u{301}",branch=try parse(["/command:branch","/rev:refs/heads/main","/name:"+name])
        XCTAssertEqual(branch.selectedRevision,"refs/heads/main");XCTAssertEqual(branch.creationName.map {Data($0.utf8)},Data(name.utf8))
        XCTAssertEqual(try parse(["/command:tag","/rev:HEAD~1","/name:v1"]).creationName,"v1")
        XCTAssertEqual(try parse(["/command:switch","/rev:topic"]).selectedRevision,"topic")
        XCTAssertEqual(try parse(["/command:repobrowser","/rev:v1"]).selectedRevision,"v1")
        XCTAssertEqual(try parse(["/command:reflog","/ref:refs/heads/main"]).reflogReference,"refs/heads/main")
        let replay=try parse(["/command:rebase","/upstream:refs/heads/main","/force"])
        XCTAssertEqual(replay.upstream,"refs/heads/main");XCTAssertTrue(replay.forceRebase)
    }
    func testRepositoryBatchKeepsCapturedTransportOptions() throws {
        let invocation=try parse(["--command=push","--path=/first","--path=/second","--branch=topic"])
        XCTAssertEqual(invocation.request.paths.map(\.path),["/first","/second"])
        let second=invocation.selecting([FileTransferPaths.fileURL("/second")])
        XCTAssertEqual(second.request.paths.map(\.path),["/second"]);XCTAssertEqual(second.request.action,.push);XCTAssertEqual(second.pushBranch,"topic")
        for args in [["/command:clone","/path:a*b"],["/command:pull","/remote:origin"],["/command:push","/force"],["/command:branch","/url:x"],["/command:fetch","/rev:HEAD"],["/command:rebase","/upstream:-bad"],["/command:reflog","/ref:-bad"]] {XCTAssertThrowsError(try parse(args))}
    }

}
