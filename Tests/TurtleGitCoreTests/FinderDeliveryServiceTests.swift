import XCTest
@testable import TurtleGitCore

final class FinderDeliveryServiceTests:XCTestCase {
    private let commands:[FinderServiceCommand]=[.diffLater,.clearComparisonMark,.export,.formatPatch,.importPatch,.reviewPatch,.sendMail,.requestPull]

    func testDeliveryEnvelopesPreserveLiteralScopesAndRejectExecutionParameters() throws {
        let paths=["/outside/é [one]\n.patch","/outside/e\u{301} [two]&?.diff"].map {FileTransferPaths.fileURL($0)}
        for command in commands {
            let multiple=command == .importPatch || command == .sendMail
            XCTAssertEqual(command.requiresSingleSelection,!multiple)
            XCTAssertEqual(command.capturesAlternateTool,command == .diffLater)
            let selected=multiple ? paths:[paths[0]]
            let url=try command.serviceURL(paths:selected)
            let result=try FinderServiceCommand.request(serviceURL:url)
            XCTAssertEqual(result.action,command.action)
            XCTAssertEqual(result.paths.map{Data($0.path.utf8)},selected.map{Data($0.path.utf8)})
            XCTAssertTrue(result.sources.isEmpty);XCTAssertNil(result.clipboardPatch)
            XCTAssertNil(result.requestPullEnd);XCTAssertNil(result.requestPullURL)
            XCTAssertThrowsError(try command.request(paths:[]))
            if !multiple {XCTAssertThrowsError(try command.request(paths:paths))}
            for extra in ["&source=/other","&url=https://example.invalid/repo","&endrev=main","&clipboard=secret","&output=/other","&force=1"] {
                XCTAssertThrowsError(try FinderServiceCommand.request(serviceURL:XCTUnwrap(URL(string:url.absoluteString+extra))))
            }
            if command == .diffLater {
                for tool in [false,true] {
                    XCTAssertEqual(try FinderServiceCommand.request(serviceURL:command.serviceURL(paths:selected,alternateTool:tool)).alternateTool,tool)
                }
            } else {XCTAssertThrowsError(try command.request(paths:selected,alternateTool:true))}
        }
        XCTAssertEqual(FinderServiceCommand.diffLater.selectionRoute,.comparisonFile)
        XCTAssertEqual(FinderServiceCommand.clearComparisonMark.selectionRoute,.comparisonMarkClear)
        XCTAssertEqual(FinderServiceCommand.reviewPatch.selectionRoute,.patchReview)
        XCTAssertEqual(FinderServiceCommand.sendMail.selectionRoute,.mailFiles)
        XCTAssertEqual(FinderServiceCommand.importPatch.selectionRoute,.patchImport)
        for command in [FinderServiceCommand.export,.formatPatch,.requestPull] {XCTAssertEqual(command.selectionRoute,.repository)}
    }

    func testFileFirstDeliveryEligibilityNeedsNoGitNamespace() throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString,isDirectory:true)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        defer {try? FileManager.default.removeItem(at:root)}
        let file=root.appendingPathComponent("ordinary 雪\n.txt"),patch=root.appendingPathComponent("first.PATCH"),other=root.appendingPathComponent("second.diff")
        let bytes=Data("literal unchanged bytes".utf8)
        for url in [file,patch,other] {try bytes.write(to:url)}
        let snapshot=FinderSnapshot(roots:[],states:[:])
        for command in [FinderServiceCommand.diffLater,.clearComparisonMark,.reviewPatch,.sendMail] {
            XCTAssertTrue(command.isEligible(paths:[file],snapshot:snapshot),command.rawValue)
            XCTAssertTrue(command.isEligible(paths:[patch],snapshot:snapshot),command.rawValue)
            XCTAssertFalse(command.isEligible(paths:[root],snapshot:snapshot),command.rawValue)
        }
        XCTAssertFalse(FinderServiceCommand.diffLater.isEligible(paths:[file,patch],snapshot:snapshot))
        XCTAssertFalse(FinderServiceCommand.reviewPatch.isEligible(paths:[patch,other],snapshot:snapshot))
        XCTAssertTrue(FinderServiceCommand.sendMail.isEligible(paths:[file,patch],snapshot:snapshot))
        XCTAssertTrue(FinderServiceCommand.importPatch.isEligible(paths:[patch,other],snapshot:snapshot))
        XCTAssertFalse(FinderServiceCommand.importPatch.isEligible(paths:[file],snapshot:snapshot),"Import's source file clause requires a patch extension")
        for command in [FinderServiceCommand.export,.formatPatch,.requestPull] {
            XCTAssertFalse(command.isEligible(paths:[root],snapshot:snapshot))
            XCTAssertFalse(command.isEligible(paths:[file],snapshot:snapshot))
        }
        XCTAssertEqual(try Data(contentsOf:file),bytes)
        XCTAssertFalse(FileManager.default.fileExists(atPath:root.appendingPathComponent(".git").path))
    }

    func testDeliverySourceFolderAndExtendedClausesRemainDistinct() {
        // MenuInfo.cpp:65–66,164–165,200–212. RequestPull has no Shell
        // entry; its explicit Services folder adaptation follows Export.
        for command in [FinderServiceCommand.diffLater,.clearComparisonMark] {
            XCTAssertTrue(command.isEligible(flags:[.onlyOne]))
            XCTAssertFalse(command.isEligible(flags:[.folder,.onlyOne]))
            XCTAssertFalse(command.isEligible(flags:[.two]))
        }
        for command in [FinderServiceCommand.export,.requestPull] {
            XCTAssertTrue(command.isEligible(flags:[.folderInGit,.onlyOne]))
            XCTAssertTrue(command.isEligible(flags:[.bare]))
            XCTAssertFalse(command.isEligible(flags:[.inGit,.onlyOne]))
        }
        XCTAssertTrue(FinderServiceCommand.formatPatch.isEligible(flags:[.folderInGit,.onlyOne,.merge,.bisect]))
        XCTAssertFalse(FinderServiceCommand.formatPatch.isEligible(flags:[.bare]))
        XCTAssertTrue(FinderServiceCommand.importPatch.isEligible(flags:[.patchFile,.two]))
        XCTAssertTrue(FinderServiceCommand.importPatch.isEligible(flags:[.folderInGit,.onlyOne]))
        XCTAssertFalse(FinderServiceCommand.importPatch.isEligible(flags:[.extended,.onlyOne]))
        XCTAssertTrue(FinderServiceCommand.reviewPatch.isEligible(flags:[.onlyOne]))
        XCTAssertFalse(FinderServiceCommand.reviewPatch.isEligible(flags:[.two]))
        XCTAssertTrue(FinderServiceCommand.sendMail.isEligible(flags:[.two]))
        XCTAssertFalse(FinderServiceCommand.sendMail.isEligible(flags:[.folder,.onlyOne]))
        XCTAssertTrue(FinderServiceCommand.sendMail.isEligible(flags:[.folder,.patchFile,.two]),"Representative folder metadata does not erase the independent source PATCHFILE clause")
    }

    func testRepositoryDeliveryUsesLiveFolderAndBareContexts() throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString,isDirectory:true)
        let nested=root.appendingPathComponent("nested",isDirectory:true),file=root.appendingPathComponent("tracked")
        try FileManager.default.createDirectory(at:nested,withIntermediateDirectories:true)
        defer {try? FileManager.default.removeItem(at:root)}
        try Data().write(to:file)
        let snapshot=FinderSnapshot(roots:[root.path],states:[root.path:.modified,nested.path:.normal,file.path:.normal],repositories:[root.path:FinderRepositoryMetadata(bare:false,bisectActive:true,mergeActive:true)])
        for command in [FinderServiceCommand.export,.formatPatch,.requestPull] {
            XCTAssertTrue(command.isEligible(paths:[root],snapshot:snapshot))
            XCTAssertTrue(command.isEligible(paths:[nested],snapshot:snapshot))
            XCTAssertFalse(command.isEligible(paths:[file],snapshot:snapshot))
            XCTAssertFalse(command.isEligible(paths:[root,nested],snapshot:snapshot))
        }
        XCTAssertTrue(FinderServiceCommand.importPatch.isEligible(paths:[nested],snapshot:snapshot))
        let bare=FinderSnapshot(roots:[root.path],states:[:],repositories:[root.path:FinderRepositoryMetadata(bare:true)])
        XCTAssertTrue(FinderServiceCommand.export.isEligible(paths:[root],snapshot:bare))
        XCTAssertTrue(FinderServiceCommand.requestPull.isEligible(paths:[root],snapshot:bare))
        XCTAssertFalse(FinderServiceCommand.formatPatch.isEligible(paths:[root],snapshot:bare))
        XCTAssertFalse(FinderServiceCommand.importPatch.isEligible(paths:[root],snapshot:bare))
    }

    func testDeliveryServicesAppendEightDeclarationsWithRestrictedSelector() throws {
        let root=URL(fileURLWithPath:#filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let bytes=try Data(contentsOf:root.appendingPathComponent("Configuration/App-Info.plist"))
        let plist=try XCTUnwrap(PropertyListSerialization.propertyList(from:bytes,format:nil) as? [String:Any])
        let services=try XCTUnwrap(plist["NSServices"] as? [[String:Any]])
        XCTAssertEqual(services.count,56)
        let originalServices=Array(services.prefix(55))
        let registration=try XCTUnwrap(services.last)
        XCTAssertEqual(registration["NSUserData"] as? String,"registerRepository")
        XCTAssertEqual(registration["NSMessage"] as? String,"performFinderAction")
        XCTAssertEqual(registration["NSPortName"] as? String,"TurtleGit")
        XCTAssertEqual(registration["NSSendFileTypes"] as? [String],["public.folder"])
        XCTAssertEqual(registration["NSRestricted"] as? Bool,true)
        XCTAssertEqual((registration["NSRequiredContext"] as? [String:Any])?.count,0)
        XCTAssertEqual((registration["NSMenuItem"] as? [String:String])?["default"],"TurtleGit: Add to TurtleGit…")
        XCTAssertEqual(originalServices.suffix(8).compactMap{$0["NSUserData"] as? String},commands.map(\.rawValue))
        XCTAssertEqual(services[42..<47].compactMap{$0["NSUserData"] as? String},["reflog","referenceBrowser","repositoryBrowser","revisionGraph","daemon"])
        XCTAssertEqual(originalServices.filter{($0["NSSendFileTypes"] as? [String]) == ["public.folder"]}.count,15)
        XCTAssertEqual(originalServices.filter{($0["NSSendFileTypes"] as? [String]) == ["public.item"]}.count,40)
        for entry in originalServices.suffix(8) {
            let command=try XCTUnwrap(FinderServiceCommand(rawValue:XCTUnwrap(entry["NSUserData"] as? String)))
            XCTAssertEqual(entry["NSMessage"] as? String,"performFinderAction")
            XCTAssertEqual(entry["NSPortName"] as? String,"TurtleGit")
            XCTAssertEqual(entry["NSRestricted"] as? Bool,true)
            XCTAssertEqual((entry["NSRequiredContext"] as? [String:Any])?.count,0)
            XCTAssertEqual(entry["NSSendFileTypes"] as? [String],[command == .export || command == .formatPatch || command == .requestPull ? "public.folder":"public.item"])
            XCTAssertTrue(((entry["NSMenuItem"] as? [String:String])?["default"] ?? "").hasPrefix("TurtleGit: "))
        }
    }
}
