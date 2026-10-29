// SPDX-License-Identifier: GPL-2.0-or-later
import XCTest
@testable import TurtleGitCore

final class ImageToolInvocationTests:XCTestCase {
    func testSelectionLiteralPathsTitlesAndSourceStatusValues()throws {
        let name="mine e\u{301} 🐢:x.png"
        let value=try XCTUnwrap(ImageToolInvocation.parse(arguments:["--image-tool","--base","base.png","--mine",name,"--theirs","../theirs.png","--result","output.png","--mine-title","Local title: e\u{301}","--base-title","Original","--theirs-title","Remote"],currentDirectory:"/fixture/sub"))
        XCTAssertTrue(value.isSelection)
        XCTAssertTrue(value.mine!.path.utf8.elementsEqual(("/fixture/sub/"+name).utf8))
        XCTAssertEqual(value.theirs?.path,"/fixture/theirs.png");XCTAssertEqual(value.result?.path,"/fixture/sub/output.png")
        XCTAssertEqual(value.titles[.mine],"Local title: e\u{301}")
        XCTAssertEqual(ImageToolInvocation.selectionExitCode(.mine),1)
        XCTAssertEqual(ImageToolInvocation.selectionExitCode(.theirs),2)
        XCTAssertEqual(ImageToolInvocation.selectionExitCode(.base),3)
    }
    func testLegacyAliasesAndComparisonPresentationOptions()throws {
        let value=try XCTUnwrap(ImageToolInvocation.parse(arguments:["/left:a.gif","/right:b.wmf","/lefttitle:Original","/righttitle:Changed","/overlay","/fit","/showinfo"],currentDirectory:"/fixture"))
        XCTAssertFalse(value.isSelection);XCTAssertEqual(value.left?.path,"/fixture/a.gif");XCTAssertEqual(value.rightTitle,"Changed")
        XCTAssertTrue(value.overlay);XCTAssertTrue(value.fitWidths);XCTAssertTrue(value.fitHeights);XCTAssertTrue(value.showInfo)
        let positional=try XCTUnwrap(ImageToolInvocation.parse(arguments:["--image-tool","--","/a b.png","-literal.png"],currentDirectory:"/fixture"))
        XCTAssertEqual(positional.left?.path,"/a b.png");XCTAssertEqual(positional.right?.path,"/fixture/-literal.png")
        XCTAssertNotNil(try ImageToolInvocation.parse(arguments:["--image-tool"],currentDirectory:"/fixture"))
    }
    func testBaseOnlyOpensSeededComparisonChooserWithoutCoercingPartialSelection()throws {
        let source=try XCTUnwrap(ImageToolInvocation.parse(arguments:["--image-tool","/base:original 🐢.png","/basetitle:Original image"],currentDirectory:"/fixture"))
        XCTAssertTrue(source.opensChooser);XCTAssertFalse(source.isSelection)
        XCTAssertNil(source.base);XCTAssertEqual(source.left?.path,"/fixture/original 🐢.png");XCTAssertEqual(source.leftTitle,"Original image")
        let empty=try XCTUnwrap(ImageToolInvocation.parse(arguments:["--image-tool"],currentDirectory:"/fixture"))
        XCTAssertTrue(empty.opensChooser)
        let left=try XCTUnwrap(ImageToolInvocation.parse(arguments:["/left:only.png"],currentDirectory:"/fixture"))
        XCTAssertFalse(left.opensChooser);XCTAssertEqual(left.left?.path,"/fixture/only.png")
        XCTAssertThrowsError(try ImageToolInvocation.parse(arguments:["--image-tool","--base=b","--result=out"],currentDirectory:"/fixture"))
        XCTAssertThrowsError(try ImageToolInvocation.parse(arguments:["--image-tool","--base=b","--delete-inputs-on-close"],currentDirectory:"/fixture"))
        XCTAssertThrowsError(try ImageToolInvocation.parse(arguments:["--image-tool","--base=b","--theirs=t"],currentDirectory:"/fixture"))
    }
    func testParsingDoesNotStealRepositoryOrMergeCommands()throws {
        XCTAssertNil(try ImageToolInvocation.parse(arguments:["--command=commit"],currentDirectory:"/fixture"))
        XCTAssertNil(try ImageToolInvocation.parse(arguments:["/base:b","/mine:m","/theirs:t"],currentDirectory:"/fixture"))
        XCTAssertNil(try ImageToolInvocation.parse(arguments:["ordinary.png"],currentDirectory:"/fixture"))
        for marker in ["--merge-tool","--unified-diff-tool","--unified-diff"] {
            XCTAssertNil(try ImageToolInvocation.parse(arguments:[marker,"--left=invalid-other-tool-option"],currentDirectory:"/fixture"))
            XCTAssertNil(try ImageToolInvocation.parse(arguments:[marker,"/right:invalid-other-tool-option"],currentDirectory:"/fixture"))
            XCTAssertThrowsError(try ImageToolInvocation.parse(arguments:["--image-tool",marker,"--left=file"],currentDirectory:"/fixture"))
        }
        let literal=try XCTUnwrap(ImageToolInvocation.parse(arguments:["--image-tool","--","--merge-tool","--unified-diff-tool"],currentDirectory:"/fixture"))
        XCTAssertEqual(literal.left?.path,"/fixture/--merge-tool");XCTAssertEqual(literal.right?.path,"/fixture/--unified-diff-tool")
    }
    func testMalformedDuplicateMixedAndWindowsNotificationRequestsRefuse()throws {
        let invalid:[[String]]=[
            ["--image-tool","--image-tool"],["--image-tool=yes"],["--image-tool","--base","b","--mine","m"],
            ["--image-tool","--base=b","--mine=m","--theirs=t","--left=l"],
            ["--image-tool","--result=r"],["--image-tool","--left=l","/left:again"],
            ["--image-tool","--left="],["--image-tool","--left"],["--image-tool","--overlay=true"],
            ["--image-tool","--left=a\0b"],["--image-tool","--resolvemsghwnd=1"],
            ["--image-tool","--delete-inputs-on-close"],["--image-tool","one"]]
        for arguments in invalid {XCTAssertThrowsError(try ImageToolInvocation.parse(arguments:arguments,currentDirectory:"/fixture"),arguments.joined(separator:" "))}
        XCTAssertThrowsError(try ImageToolInvocation.parse(arguments:["--image-tool"],currentDirectory:"relative"))
    }
}
