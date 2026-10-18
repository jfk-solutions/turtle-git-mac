// SPDX-License-Identifier: GPL-2.0-or-later
import XCTest
@testable import TurtleGitCore

final class HistoryContextMenuPolicyTests: XCTestCase {
    func testNormalLogConstructorMask() {
        let omitted: Set<HistoryContextCommand> = [.rebasePick, .rebaseSquash, .rebaseEdit, .rebaseSkip, .showLog, .blame, .blamePrevious]
        XCTAssertEqual(HistoryContextMenuPolicy.log.commands, Set(HistoryContextCommand.allCases).subtracting(omitted))
        XCTAssertTrue(HistoryContextMenuPolicy.log.contains(.comparePrevious))
        XCTAssertTrue(HistoryContextMenuPolicy.log.contains(.find))
    }
    func testBlameExclusiveSourceConsumerAndRebaseRestrictions() {
        XCTAssertEqual(HistoryContextMenuPolicy.blame.commands, [.comparePrevious, .unifiedDiff, .blamePrevious, .copyClipboard, .export, .createBranch, .createTag, .checkout, .showLog, .showBranches, .repositoryBrowser])
        for command in [HistoryContextCommand.cherryPick, .checkout, .reset, .revert, .merge, .rebase, .revertToRevision, .combine, .rollup] {
            XCTAssertFalse(HistoryContextMenuPolicy.rebase.contains(command), command.rawValue)
        }
        XCTAssertTrue(HistoryContextMenuPolicy.rebase.contains(.createPatch))
        XCTAssertTrue(HistoryContextMenuPolicy.rebase.contains(.copyClipboard))
    }
    func testExclusiveShowIntersectsRatherThanEnablingMaskedCommands() {
        var policy = HistoryContextMenuPolicy.log
        policy.hide([.copyClipboard, .showLog, .blamePrevious], exclusivelyShow: true)
        XCTAssertEqual(policy.commands, [.copyClipboard])
        policy.hide([.copyClipboard])
        XCTAssertTrue(policy.commands.isEmpty)
    }
    func testShowLogUsesSourceMaskOrNamedRevisionOrShift() {
        let empty = HistoryContextMenuPolicy(commands: [])
        XCTAssertFalse(empty.showsLog(hasReferences: false, isStash: false, extended: false))
        XCTAssertTrue(empty.showsLog(hasReferences: true, isStash: false, extended: false))
        XCTAssertFalse(empty.showsLog(hasReferences: true, isStash: true, extended: false))
        XCTAssertTrue(empty.showsLog(hasReferences: false, isStash: true, extended: true))
        XCTAssertTrue(HistoryContextMenuPolicy.blame.showsLog(hasReferences: false, isStash: true, extended: false))
    }
    func testFilteringPreservesSourceInsertionAndRepeatedParentOrder() {
        let policy = HistoryContextMenuPolicy(commands: [.comparePrevious, .copyClipboard, .repositoryBrowser])
        XCTAssertEqual(policy.filtering([.compareWorkingTree, .unifiedDiff, .comparePrevious, .comparePrevious, .repositoryBrowser, .reset, .copyClipboard, .find]), [.comparePrevious, .comparePrevious, .repositoryBrowser, .copyClipboard])
    }
}
