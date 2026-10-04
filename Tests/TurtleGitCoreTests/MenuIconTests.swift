import XCTest
import AppKit
@testable import TurtleGitCore

final class MenuIconTests: XCTestCase {
    func testAllBundledUpstreamIconsDecodeAtMenuAndRetinaSizes() {
        for icon in MenuIcon.allCases {
            guard let image = icon.image() else { XCTFail("Missing or unreadable icon: \(icon.rawValue)"); continue }
            XCTAssertEqual(image.size, NSSize(width: 16, height: 16))
            XCTAssertEqual(image.isTemplate, [.cherryPick, .log, .help].contains(icon), "Preserve colors; tint the monochrome glyphs")
            XCTAssertFalse(image.representations.isEmpty)
            // Ask AppKit for actual pixels rather than accepting an ICO file that
            // exists but cannot render its Windows alpha mask on macOS.
            let rect = NSRect(x: 0, y: 0, width: 16, height: 16)
            var proposed = rect
            XCTAssertNotNil(image.cgImage(forProposedRect: &proposed, context: nil, hints: nil), icon.rawValue)
        }
        // Upstream Apply and Pop share the unshelve artwork.
        XCTAssertEqual(RepositoryAction.stashApply.icon, RepositoryAction.stashPop.icon)
        XCTAssertEqual(RepositoryAction.stashList.icon, RepositoryAction.log.icon)
        XCTAssertEqual(RepositoryAction.reflog.icon, RepositoryAction.log.icon)
        XCTAssertEqual(RepositoryAction.remove.icon, RepositoryAction.removeKeep.icon)
        for action in [RepositoryAction.ignoreMask, .ignoreDelete, .ignoreDeleteMask] { XCTAssertEqual(action.icon, RepositoryAction.ignore.icon) }
        for action in [RepositoryAction.resolveCurrent, .resolveMine, .resolveTheirs] { XCTAssertEqual(action.icon, RepositoryAction.resolve.icon) }
        let distinctActions = RepositoryAction.allCases.filter { ![.stashApply, .stashList, .reflog, .removeKeep, .ignoreMask, .ignoreDelete, .ignoreDeleteMask, .resolveCurrent, .resolveMine, .resolveTheirs].contains($0) }
        XCTAssertEqual(Set(distinctActions.map { $0.icon.rawValue }).count, distinctActions.count)
    }
}
