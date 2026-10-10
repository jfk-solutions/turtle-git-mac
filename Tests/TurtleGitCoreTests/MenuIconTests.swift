import XCTest
import AppKit
@testable import TurtleGitCore

final class MenuIconTests: XCTestCase {
    func testFindReferenceTilesPreserveOriginalPixelsAndWhiteMask() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let data = try Data(contentsOf: root.appendingPathComponent("Sources/TurtleGitCore/Resources/Icons/reftype.bmp"))
        XCTAssertEqual(data.count, 3126) // 64x16 BGR, 192-byte bottom-up rows.
        for (icon, index, name) in [(ReferenceTypeIcon.tag, 0, "refs/tags/v1"), (.localBranch, 1, "refs/heads/main"), (.remoteBranch, 2, "refs/remotes/origin/main")] {
            XCTAssertEqual(ReferenceTypeIcon(referenceName: name), icon)
            let image = try XCTUnwrap(icon.image()); XCTAssertFalse(image.isTemplate)
            XCTAssertEqual(image.size, NSSize(width: 16, height: 16))
            let bitmap = try XCTUnwrap(image.representations.first as? NSBitmapImageRep), pixels = try XCTUnwrap(bitmap.bitmapData)
            var opaque = 0, transparent = 0
            for y in 0..<16 { for x in 0..<16 {
                let source = 54 + (15 - y) * 192 + (index * 16 + x) * 3, target = y * bitmap.bytesPerRow + x * 4
                XCTAssertEqual(pixels[target], data[source + 2]); XCTAssertEqual(pixels[target + 1], data[source + 1]); XCTAssertEqual(pixels[target + 2], data[source])
                let white = data[source] == 255 && data[source + 1] == 255 && data[source + 2] == 255
                XCTAssertEqual(pixels[target + 3], white ? 0 : 255)
                if white { transparent += 1 } else { opaque += 1 }
            } }
            XCTAssertGreaterThan(opaque, 0); XCTAssertGreaterThan(transparent, 0)
        }
        XCTAssertNil(ReferenceTypeIcon(referenceName: "refs/stash")); XCTAssertNil(ReferenceTypeIcon(referenceName: "refs/custom/other"))
    }
    func testRevisionGraphToolbarPreservesSourceTilesAndColorKey() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let data = try Data(contentsOf: root.appendingPathComponent("Sources/TurtleGitCore/Resources/Icons/revgraphbar.bmp"))
        // Independent oracle for the pinned resource: 460x20 BGR, bottom-up,
        // 1380-byte rows, pixel offset 54, gray RGB(192,192,192) color key.
        let tiles: [(RevisionGraphToolbarIcon, Int)] = [(.zoomIn, 0), (.zoomOut, 1), (.zoom100, 2), (.fitHeight, 3), (.fitWidth, 4), (.fitGraph, 5), (.filter, 7), (.overview, 8), (.find, 9)]
        XCTAssertEqual(data.count, 27654)
        for (icon, tile) in tiles {
            let image = try XCTUnwrap(icon.image())
            XCTAssertEqual(image.size, NSSize(width: 20, height: 20)); XCTAssertFalse(image.isTemplate)
            let bitmap = try XCTUnwrap(image.representations.first as? NSBitmapImageRep)
            let pixels = try XCTUnwrap(bitmap.bitmapData)
            var opaque = 0, transparent = 0
            for y in 0..<20 {
                for x in 0..<20 {
                    let source = 54 + (19 - y) * 1380 + (tile * 20 + x) * 3
                    let target = y * bitmap.bytesPerRow + x * 4
                    XCTAssertEqual(pixels[target], data[source + 2]); XCTAssertEqual(pixels[target + 1], data[source + 1]); XCTAssertEqual(pixels[target + 2], data[source])
                    let masked = data[source] == 192 && data[source + 1] == 192 && data[source + 2] == 192
                    XCTAssertEqual(pixels[target + 3], masked ? 0 : 255)
                    if masked { transparent += 1 } else { opaque += 1 }
                }
            }
            XCTAssertGreaterThan(transparent, 0); XCTAssertGreaterThan(opaque, 0)
        }
    }
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
