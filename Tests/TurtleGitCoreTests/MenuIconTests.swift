import XCTest
import AppKit
@testable import TurtleGitCore

final class MenuIconTests: XCTestCase {
    func testAllBundledUpstreamIconsDecodeAtMenuAndRetinaSizes() {
        for icon in MenuIcon.allCases {
            guard let image = icon.image() else { XCTFail("Missing or unreadable icon: \(icon.rawValue)"); continue }
            XCTAssertEqual(image.size, NSSize(width: 16, height: 16))
            XCTAssertEqual(image.isTemplate, icon == .cherryPick, "Preserve colors; tint only the monochrome glyph")
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
        let distinctActions = RepositoryAction.allCases.filter { ![.stashApply, .stashList, .reflog].contains($0) }
        XCTAssertEqual(Set(distinctActions.map { $0.icon.rawValue }).count, distinctActions.count)
    }
}
