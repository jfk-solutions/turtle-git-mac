// SPDX-License-Identifier: GPL-2.0-or-later
import XCTest
@testable import TurtleGitCore

final class StatisticsGraphExportTests:XCTestCase {
    func testPicturesEnhancedMetafileDefaultAndAllFilesJPEGDefaultFollowSourceFilterContract() throws {
        let parent=URL(fileURLWithPath:"/private/parent.with.dots",isDirectory:true)
        let pictures=try StatisticsGraphExportDestination(url:parent.appendingPathComponent("statistics 雪"),filter:.pictures)
        XCTAssertEqual(pictures.url.path,"/private/parent.with.dots/statistics 雪.wmf");XCTAssertEqual(pictures.format,.wmf)
        let all=try StatisticsGraphExportDestination(url:parent.appendingPathComponent("statistics 雪"),filter:.allFiles)
        XCTAssertEqual(all.url.path,"/private/parent.with.dots/statistics 雪.jpg");XCTAssertEqual(all.format,.jpeg)
        XCTAssertEqual(StatisticsGraphFormat.allCases,[.pdf,.png,.jpeg,.bmp,.gif,.wmf,.emf])
    }

    func testTypedSupportedSuffixDeterminesEncoderRegardlessOfFilter() throws {
        for filter in StatisticsGraphExportFilter.allCases {for (suffix,format) in [("PDF",StatisticsGraphFormat.pdf),("pNg",.png),("jpg",.jpeg),("JPEG",.jpeg),("BMP",.bmp),("gif",.gif),("WMF",.wmf),("emf",.emf)] {
            let url=URL(fileURLWithPath:"/private/export").appendingPathComponent("name."+suffix)
            let result=try StatisticsGraphExportDestination(url:url,filter:filter)
            XCTAssertEqual(result.url,url);XCTAssertEqual(result.format,format)
            XCTAssertEqual(try StatisticsGraphExportDestination.normalizedFilename(result.url.lastPathComponent,filter:filter),url.lastPathComponent)
        }}
        XCTAssertEqual(StatisticsGraphFormat.jpeg.fileExtension,"jpg")
        XCTAssertEqual(StatisticsGraphFormat(fileExtension:"wmf"),.wmf);XCTAssertNil(StatisticsGraphFormat(fileExtension:"svg"))
    }

    func testUnknownLiteralNamesFallbackAndMetafileAcceptancePreserveExactFilenameIntent() throws {
        for filter in StatisticsGraphExportFilter.allCases {for name in ["graph.unknown","graph.",".hidden","graph.tar.gz","literal\n\t雪[*].type","graph.\u{301}"] {
            let actual=try StatisticsGraphExportDestination.normalizedFilename(name,filter:filter)
            XCTAssertEqual(Data(actual.utf8),Data((name+".jpg").utf8))
            let result=try StatisticsGraphExportDestination(url:URL(fileURLWithPath:"/private/export").appendingPathComponent(name),filter:filter)
            XCTAssertEqual(result.format,.jpeg);XCTAssertEqual(Data(result.url.lastPathComponent.utf8),Data(actual.utf8))
        }}
        let nfc=try StatisticsGraphExportDestination.normalizedFilename("caf\u{e9}.unknown"),nfd=try StatisticsGraphExportDestination.normalizedFilename("cafe\u{301}.unknown")
        XCTAssertNotEqual(Data(nfc.utf8),Data(nfd.utf8))
        for filter in StatisticsGraphExportFilter.allCases {for suffix in ["wmf","WMF","emf","EMF"] {
            let url=URL(fileURLWithPath:"/private/graph."+suffix),value=try StatisticsGraphExportDestination(url:url,filter:filter)
            XCTAssertEqual(value.url,url);XCTAssertEqual(value.format,StatisticsGraphFormat(fileExtension:suffix))
        }}
        for invalid in ["",".","..","nested/name","name\0tail"] {XCTAssertThrowsError(try StatisticsGraphExportDestination.normalizedFilename(invalid))}
        XCTAssertThrowsError(try StatisticsGraphExportDestination(url:URL(string:"https://example.invalid/graph.png")!))
        XCTAssertThrowsError(try StatisticsGraphExportDestination(url:URL(fileURLWithPath:"/private/export",isDirectory:true)))
    }

    func testCapturedBackendMeasuresActualCommitsAndBinaryChangesWithoutMutatingRepository() async throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("StatisticsExport-"+UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true);defer{try? FileManager.default.removeItem(at:root)}
        let executable=URL(fileURLWithPath:ProcessInfo.processInfo.environment["TURTLEGIT_GROUP_TEST_GIT"] ?? "/usr/bin/git"),raw=GitLibGit2Configuration(enabled:false)
        let repo=GitRepository(root:root,executable:executable,askpass:nil,libgit2Configuration:raw)
        _ = try await repo.run(["init","-b","main"])
        for(key,value)in[("user.name","Statistics"),("user.email","statistics@example.invalid"),("commit.gpgsign","false"),("core.hooksPath","/dev/null")] {_ = try await repo.run(["config",key,value])}
        let path="literal 雪\n[*].txt"
        try Data("one\ntwo\n".utf8).write(to:root.appendingPathComponent(path));try Data([0,255,1]).write(to:root.appendingPathComponent("binary"))
        try await repo.stage([path,"binary"]);_ = try await repo.commit(message:"base")
        try Data("one\ntwo\nthree\n".utf8).write(to:root.appendingPathComponent(path));try Data([0,254,1]).write(to:root.appendingPathComponent("binary"))
        try await repo.stage([path,"binary"]);_ = try await repo.commit(message:"changes")
        let entries=try await repo.history(),index=try Data(contentsOf:root.appendingPathComponent(".git/index")),head=try await repo.run(["rev-parse","HEAD"]).stdout
        try Data("uncommitted remains\n".utf8).write(to:root.appendingPathComponent(path))
        let unavailable=GitLibGit2Configuration(mask:1<<15,helperURL:root.appendingPathComponent("missing-helper"))
        let captured=GitRepository(root:root,executable:executable,askpass:nil,libgit2Configuration:unavailable)
        let changes=try await captured.logStatisticsChanges(entries,backend:raw)
        XCTAssertEqual(changes[entries[0].hash]?.files,2);XCTAssertEqual(changes[entries[0].hash]?.added,1);XCTAssertEqual(changes[entries[0].hash]?.removed,0)
        let summary=try LogStatistics.analyze(entries,changes:changes)
        XCTAssertEqual(summary.totalChanges.files,4);XCTAssertEqual(summary.totalChanges.newFileLines,2);XCTAssertEqual(summary.totalChanges.linesWithoutNewDeletedFiles,1)
        do{_ = try await captured.logStatisticsChanges(entries);XCTFail("Configured missing selected helper silently fell back")}catch GitLibGit2Failure.runtimeMissing{}
        let token=OperationCancellation();token.cancel()
        do{_ = try await captured.logStatisticsChanges(entries,cancellation:token,backend:raw);XCTFail("Cancelled calculation returned partial data")}catch is OperationCancellationFailure{}
        XCTAssertEqual(try Data(contentsOf:root.appendingPathComponent(".git/index")),index)
        let after=try await repo.run(["rev-parse","HEAD"]).stdout;XCTAssertEqual(after,head)
        XCTAssertEqual(try Data(contentsOf:root.appendingPathComponent(path)),Data("uncommitted remains\n".utf8))
    }
}
