// SPDX-License-Identifier: GPL-2.0-or-later
import XCTest
@testable import TurtleGitCore

final class CommandProgressAutoCloseTests:XCTestCase {
    private enum ParseFixtureFailure:Error { case missingInvocation }
    private func parse(_ arguments:[String],cwd:String="/repo")throws->PrimaryCommandInvocation {
        guard let invocation=try PrimaryCommandInvocation.parse(arguments:arguments,currentDirectory:cwd) else {throw ParseFixtureFailure.missingInvocation}
        return invocation
    }
    func testAbsentAndExplicitManualRemainDifferentAcrossLegacyAndNativeSyntax()throws {
        XCTAssertNil(try parse(["--command=commit"]).progressAutoClose)
        for option in [["/closeonend"],["/closeonend:"],["/closeonend:0"],["--closeonend"],["--closeonend="],["--closeonend","0"],["--closeonend=0"]] {
            XCTAssertEqual(try parse(["--command=commit"]+option).progressAutoClose,.manual,option.description)
        }
        XCTAssertEqual(try parse(["/closeonend","/command:commit"]).progressAutoClose,.manual)
        XCTAssertEqual(try parse(["--closeonend","--command=commit"]).progressAutoClose,.manual)
        for (raw,expected) in [("1",CommandProgressAutoClose.noOptions),("2",.noErrors)] {
            XCTAssertEqual(try parse(["/command:commit","/closeonend:"+raw]).progressAutoClose,expected)
            XCTAssertEqual(try parse(["--command=commit","--closeonend",raw]).progressAutoClose,expected)
            XCTAssertEqual(try parse(["--command=commit","--closeonend="+raw]).progressAutoClose,expected)
        }
    }
    func testSourceDecimalPrefixMappingDoesNotInventStrictEnumValidation()throws {
        let active:[(String,CommandProgressAutoClose)]=[("  +01tail",.noOptions),("\t\r\n\u{b}\u{c}+0002ignored",.noErrors),("1.5",.noOptions),("2e10",.noErrors),(String(repeating:"0",count:256)+"1",.noOptions)]
        for(raw,expected)in active {
            XCTAssertEqual(CommandProgressAutoClose(sourceArgument:raw),expected,raw.debugDescription)
            XCTAssertEqual(try parse(["--command=commit","--closeonend="+raw]).progressAutoClose,expected,raw.debugDescription)
        }
        let manual=[""," ","not-a-number","+","-","-1","-2","-0","3","4","-999","2147483647","2147483648","4294967297",String(repeating:"9",count:256),"0x2","--1","+ 1","\u{0661}","\u{ff12}"]
        for raw in manual {
            XCTAssertEqual(CommandProgressAutoClose(sourceArgument:raw),.manual,raw.debugDescription)
            XCTAssertEqual(try parse(["--command=commit","--closeonend="+raw]).progressAutoClose,.manual,raw.debugDescription)
        }
    }
    func testGlobalPolicyOptionPreservesCommandValidationAndDoesNotBecomeACommand()throws {
        for command in ["commit","fetch","pull","push","clone","switch","cleanup","log","settings","firststartwizard"] {
            XCTAssertEqual(try parse(["--command="+command,"--closeonend=2"]).progressAutoClose,.noErrors,command)
        }
        XCTAssertNil(try PrimaryCommandInvocation.parse(arguments:["--closeonend=2"],currentDirectory:"/repo"))
        for arguments in [["--command=commit","--closeonend=1","--closeonend=2"],["--command=commit","/closeonend:1","--closeonend=1"],["--command=commit","--closeonend=2\0tail"],["--command=commit","--closeonend=2","--unsupported"],["--command=log","--closeonend=2","--remote=origin"]] {
            XCTAssertThrowsError(try parse(arguments),arguments.debugDescription)
        }
    }
    func testCapturedPolicySurvivesAuthorizedPathFileResolutionAndTransportSplits()throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("TurtleGitProgressPolicy-"+UUID().uuidString,isDirectory:true)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:false,attributes:[.posixPermissions:0o700])
        defer{try? FileManager.default.removeItem(at:root)}
        let file=root.appendingPathComponent("paths");try Data("first\0second\0".utf8).write(to:file)
        for value in ["0","2"] {
            let invocation=try parse(["--command=fetch","--remote=origin","--pathfile",file.path,"--pathfile0","--closeonend="+value],cwd:root.path)
            let resolved=try invocation.resolvingPathFile(cancellation:.init())
            XCTAssertEqual(resolved.progressAutoClose,invocation.progressAutoClose)
            XCTAssertEqual(resolved.transportPaths.count,2)
            let split=resolved.selecting([root.appendingPathComponent("other")])
            XCTAssertEqual(split.progressAutoClose,invocation.progressAutoClose)
            XCTAssertEqual(split.remote,"origin");XCTAssertEqual(split.transportPaths,split.request.paths)
            XCTAssertNil(try parse(["--command=fetch"],cwd:root.path).progressAutoClose)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath:file.path))
    }
}
