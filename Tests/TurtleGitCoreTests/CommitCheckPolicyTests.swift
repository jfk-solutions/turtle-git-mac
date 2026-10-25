import XCTest
@testable import TurtleGitCore

final class CommitCheckPolicyTests:XCTestCase {
    func row(_ name:String,_ x:Character=" ",_ y:Character=" ")->StatusEntry{.init(path:name,originalPath:x == "R" || x == "C" ? "old-"+name:nil,index:x,worktree:y)}
    func testRawActionUnionKeepsCopyRenameConflictAndTypeChangeDistinct(){
        let rows=[row("copy","C"),row("rename","R"),row("rename-modified","R","M"),row("new-edited","A","M"),row("type"," ","T"),row("conflict","U","U"),row("add-conflict","A","A")]
        XCTAssertEqual(CommitCheckPolicy.paths(.added,entries:rows,submodules:[],checking:true,doNotAutoselectSubmodules:false),["copy","new-edited","add-conflict"])
        XCTAssertEqual(CommitCheckPolicy.paths(.modified,entries:rows,submodules:[],checking:true,doNotAutoselectSubmodules:false),["rename-modified","new-edited","type"])
        XCTAssertEqual(CommitCheckPolicy.paths(.versioned,entries:rows,submodules:[],checking:true,doNotAutoselectSubmodules:false),GitPathSet(rows.map(\.id)))
    }
    func testSourceShownCountsAndCheckMasksAreDeliberatelyDifferent(){
        let rename=row("renamed","R"),conflict=row("conflict","U","U"),copy=row("copy","C")
        XCTAssertTrue(CommitCheckPolicy.isAvailable(.modified,entries:[rename],submodules:[]))
        XCTAssertFalse(CommitCheckPolicy.matches(.modified,entry:rename,submodules:[]))
        XCTAssertFalse(CommitCheckPolicy.isAvailable(.modified,entries:[conflict],submodules:[]))
        XCTAssertTrue(CommitCheckPolicy.isAvailable(.added,entries:[copy],submodules:[]))
        XCTAssertTrue(CommitCheckPolicy.matches(.added,entry:copy,submodules:[]))
        XCTAssertFalse(CommitCheckPolicy.isAvailable(.added,entries:[row("add-conflict","A","A")],submodules:[]))
    }
    func testDoNotAutoselectSkipsCategoryGitlinksButExplicitMasksOverride(){
        let rows=[row("file"," ","M"),row("module"," ","M")],modules:GitPathSet=["module"]
        for category in [CommitCheckCategory.versioned,.modified] {
            XCTAssertEqual(CommitCheckPolicy.paths(category,entries:rows,submodules:modules,checking:true,doNotAutoselectSubmodules:true),["file"])
            XCTAssertEqual(CommitCheckPolicy.paths(category,entries:rows,submodules:modules,checking:false,doNotAutoselectSubmodules:true),["file","module"])
        }
        for category in [CommitCheckCategory.all,.none,.submodules] {
            XCTAssertTrue(CommitCheckPolicy.paths(category,entries:rows,submodules:modules,checking:true,doNotAutoselectSubmodules:true).contains("module"))
        }
        XCTAssertEqual(CommitCheckPolicy.paths(.files,entries:rows,submodules:modules,checking:true,doNotAutoselectSubmodules:true),["file"])
    }
    func testAllNineSourceAvailabilityRulesAndEmptyAllNone(){
        let rows=[row("modified"," ","M"),row("new","?","?"),row("add","A"),row("delete","D"),row("module"," ","M")]
        for category in CommitCheckCategory.allCases {XCTAssertTrue(CommitCheckPolicy.isAvailable(category,entries:rows,submodules:["module"]),category.rawValue)}
        for category in CommitCheckCategory.allCases {XCTAssertEqual(CommitCheckPolicy.isAvailable(category,entries:[],submodules:[]),category == .all || category == .none,category.rawValue)}
        XCTAssertEqual(CommitCheckPolicy.paths(.unversioned,entries:rows,submodules:["module"],checking:true,doNotAutoselectSubmodules:false),["new"])
        XCTAssertEqual(CommitCheckPolicy.paths(.deleted,entries:rows,submodules:["module"],checking:true,doNotAutoselectSubmodules:false),["delete"])
    }
    func testRenameMergeSuppressesCompanionAddDeleteButPreservesModified(){
        for code:Character in ["A","D"] {
            let value=row("rename","R",code)
            XCTAssertFalse(CommitCheckPolicy.matches(.added,entry:value,submodules:[]))
            XCTAssertFalse(CommitCheckPolicy.matches(.deleted,entry:value,submodules:[]))
            XCTAssertTrue(CommitCheckPolicy.matches(.versioned,entry:value,submodules:[]))
        }
        XCTAssertTrue(CommitCheckPolicy.matches(.modified,entry:row("rename","R","M"),submodules:[]))
    }
    func testExactSubmoduleMembershipAndSelectionIdentity(){
        let nfc="Café",nfd="Cafe\u{301}",rows=[row(nfc," ","M"),row(nfd," ","M")]
        XCTAssertEqual(CommitCheckPolicy.paths(.modified,entries:rows,submodules:GitPathSet([nfd]),checking:true,doNotAutoselectSubmodules:true),GitPathSet([nfc]))
        XCTAssertEqual(CommitCheckPolicy.paths(.submodules,entries:rows,submodules:GitPathSet([nfd]),checking:true,doNotAutoselectSubmodules:true),GitPathSet([nfd]))
    }
}
