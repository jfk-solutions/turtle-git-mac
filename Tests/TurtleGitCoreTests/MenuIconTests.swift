import XCTest
import AppKit
@testable import TurtleGitCore

final class MenuIconTests: XCTestCase {
    func testAllBundledUpstreamIconsDecodeAtMenuAndRetinaSizes() throws {
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
        let backdrop = try XCTUnwrap(MenuIcon.repositoryBackdrop.image(size: 128))
        var backdropRect = NSRect(x: 0, y: 0, width: 128, height: 128)
        let backdropPixels = NSBitmapImageRep(cgImage: try XCTUnwrap(backdrop.cgImage(forProposedRect: &backdropRect, context: nil, hints: nil)))
        XCTAssertTrue(backdropPixels.hasAlpha)
        XCTAssertLessThan(try XCTUnwrap(backdropPixels.colorAt(x: 0, y: 0)).alphaComponent, 0.01, "Watermark corners must preserve the list background")
        XCTAssertEqual(try XCTUnwrap(backdropPixels.colorAt(x: backdropPixels.pixelsWide / 2, y: backdropPixels.pixelsHigh / 2)).alphaComponent, 128.0 / 255.0, accuracy: 1.0 / 255.0, "Preserve the original watermark's translucent center")
        // BI_RGB ribbon bitmaps carry real alpha despite AppKit's default BMP
        // decoder discarding it. Their empty corners must remain transparent.
        for icon in [MenuIcon.mergePaste, .mergeReload, .mergeSave, .mergeSaveAs, .mergeResolved, .mergeUndo, .mergeRedo, .mergeFind, .mergePreviousConflict, .mergeNextConflict, .mergeUseMine, .mergeUseTheirs, .mergeMineThenTheirs, .mergeTheirsThenMine] {
            guard let image = icon.image(), let bitmap = image.representations.first as? NSBitmapImageRep else { XCTFail("Missing ribbon bitmap: \(icon)"); continue }
            XCTAssertTrue(bitmap.hasAlpha, icon.rawValue)
            XCTAssertLessThan(bitmap.colorAt(x: 0, y: 0)?.alphaComponent ?? 1, 0.01, icon.rawValue)
            XCTAssertTrue((0..<bitmap.pixelsHigh).contains { y in (0..<bitmap.pixelsWide).contains { x in (bitmap.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.9 } }, icon.rawValue)
        }
        // Upstream Apply and Pop share the unshelve artwork.
        XCTAssertEqual(RepositoryAction.stashApply.icon, RepositoryAction.stashPop.icon)
        XCTAssertEqual(RepositoryAction.stashList.icon, RepositoryAction.log.icon)
        XCTAssertEqual(RepositoryAction.reflog.icon, RepositoryAction.log.icon)
        XCTAssertEqual(RepositoryAction.remove.icon, RepositoryAction.removeKeep.icon)
        for action in [RepositoryAction.ignoreMask, .ignoreDelete, .ignoreDeleteMask] { XCTAssertEqual(action.icon, RepositoryAction.ignore.icon) }
        for action in [RepositoryAction.resolveCurrent, .resolveMine, .resolveTheirs] { XCTAssertEqual(action.icon, RepositoryAction.resolve.icon) }
        XCTAssertEqual(RepositoryAction.submoduleUpdate.icon, RepositoryAction.fetch.icon)
        XCTAssertEqual(RepositoryAction.diffLater.icon, RepositoryAction.diff.icon)
        XCTAssertEqual(RepositoryAction.clearComparisonMark.icon, RepositoryAction.diff.icon)
        XCTAssertEqual(RepositoryAction.worktreeCreate.icon, RepositoryAction.branch.icon)
        XCTAssertEqual(RepositoryAction.worktreeList.icon, RepositoryAction.branch.icon)
        // The pinned shell MenuInfo.cpp assigns IDI_BISECT to both Start and Skip.
        XCTAssertEqual(RepositoryAction.bisectStart.icon, RepositoryAction.bisect.icon)
        XCTAssertEqual(RepositoryAction.bisectSkip.icon, RepositoryAction.bisect.icon)
        XCTAssertEqual(RepositoryAction.requestPull.icon, RepositoryAction.formatPatch.icon)
        XCTAssertEqual(RepositoryAction.referenceBrowser.icon, RepositoryAction.repositoryBrowser.icon)
        XCTAssertEqual(RepositoryAction.submoduleAdd.icon, RepositoryAction.add.icon)
        XCTAssertEqual(RepositoryAction.submoduleSync.icon, .sync)
        let distinctActions = RepositoryAction.allCases.filter { ![.referenceBrowser, .submoduleAdd, .requestPull, .bisectStart, .bisectSkip, .worktreeCreate, .worktreeList, .diffLater, .clearComparisonMark, .submoduleUpdate, .stashApply, .stashList, .reflog, .removeKeep, .ignoreMask, .ignoreDelete, .ignoreDeleteMask, .resolveCurrent, .resolveMine, .resolveTheirs].contains($0) }
        XCTAssertEqual(Set(distinctActions.map { $0.icon.rawValue }).count, distinctActions.count)
    }
}
