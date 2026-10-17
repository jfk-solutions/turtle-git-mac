// SPDX-License-Identifier: GPL-2.0-or-later
import XCTest
import CryptoKit
@testable import TurtleGitCore

final class ReleaseDownloadTests: XCTestCase {
    let repository = "jfk-solutions/turtle-git-mac", tag = "v2.0.0"
    let bytes = Data("private archive bytes\n".utf8)
    func asset(_ changes: [String:Any] = [:]) throws -> ReleaseAsset {
        var value: [String:Any] = ["id":1,"name":"TurtleGit-Mac.zip","size":bytes.count,"state":"uploaded","browser_download_url":"https://github.com/\(repository)/releases/download/\(tag)/TurtleGit-Mac.zip","digest":"sha256:" + SHA256.hash(data: bytes).map { String(format:"%02x",$0) }.joined()]
        value.merge(changes) { _,new in new }
        return try JSONDecoder().decode(ReleaseAsset.self,from:JSONSerialization.data(withJSONObject:value))
    }
    func folder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("TurtleGitReleaseTest-" + UUID().uuidString)
        try FileManager.default.createDirectory(at:url,withIntermediateDirectories:true);addTeardownBlock { try? FileManager.default.removeItem(at:url) };return url
    }
    func testAssetIdentityAndPathMetadata() throws {
        let valid = try asset();try valid.validate(repository:repository,tag:tag);XCTAssertTrue(valid.downloadable)
        for changes: [String:Any] in [["id":0],["name":"../bad"],["name":"bad\\name"],["name":"bad\nname"],["size":-1],["browser_download_url":"http://github.com/\(repository)/releases/download/\(tag)/TurtleGit-Mac.zip"],["browser_download_url":"https://github.com/other/repository/releases/download/\(tag)/TurtleGit-Mac.zip"],["browser_download_url":"https://github.com/\(repository)/releases/download/\(tag)/TurtleGit-Mac.zip?unexpected=1"]] {
            XCTAssertThrowsError(try asset(changes).validate(repository:repository,tag:tag))
        }
    }
    func testDigestSizeAndUploadEligibility() throws {
        for changes: [String:Any] in [["digest":NSNull()],["digest":"sha256:bad"],["digest":"sha512:" + String(repeating:"0",count:64)],["state":"open"],["size":0],["size":ReleaseAssetDownload.maximumSize+1]] { XCTAssertFalse(try asset(changes).downloadable) }
        XCTAssertTrue(try asset(["digest":"sha256:" + String(repeating:"A",count:64)]).downloadable)
    }
    func testVerifyAndAtomicInstallPreserveExistingDestination() throws {
        let root=try folder(),stage=root.appendingPathComponent("stage"),destination=root.appendingPathComponent("archive.zip")
        try bytes.write(to:stage);try ReleaseAssetDownload.verify(stage,asset:asset());try ReleaseAssetDownload.install(stage,to:destination)
        XCTAssertEqual(try Data(contentsOf:destination),bytes)
        try Data("later user's file".utf8).write(to:destination)
        XCTAssertThrowsError(try ReleaseAssetDownload.install(stage,to:destination))
        XCTAssertEqual(try Data(contentsOf:destination),Data("later user's file".utf8))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath:root.path).sorted(),["archive.zip","stage"])
    }
    func testWrongBytesSizeAndSymlinkRejected() throws {
        let root=try folder(),stage=root.appendingPathComponent("stage"),link=root.appendingPathComponent("link")
        try Data(repeating:0,count:bytes.count).write(to:stage);XCTAssertThrowsError(try ReleaseAssetDownload.verify(stage,asset:asset()))
        try bytes.dropLast().write(to:stage);XCTAssertThrowsError(try ReleaseAssetDownload.verify(stage,asset:asset()))
        try bytes.write(to:stage);try FileManager.default.createSymbolicLink(at:link,withDestinationURL:stage)
        XCTAssertThrowsError(try ReleaseAssetDownload.verify(link,asset:asset()))
        XCTAssertEqual(try Data(contentsOf:stage),bytes)
    }
    func testFeedRetainsAssetsRejectsDuplicatesAndAllowsOldMetadata() throws {
        let a=try asset()
        let value:[String:Any] = ["tag_name":tag,"html_url":"https://github.com/\(repository)/releases/tag/\(tag)","draft":false,"prerelease":false]
        let old=try ReleaseUpdateFeed.releases(JSONSerialization.data(withJSONObject:[value]),repository:repository,includePreview:false)
        XCTAssertTrue(old[0].assets.isEmpty)
        var release=value
        let encoded:[String:Any] = ["id":a.id,"name":a.name,"size":a.size,"state":a.state,"browser_download_url":a.url.absoluteString,"digest":a.digest!]
        release["assets"]=[encoded];XCTAssertEqual(try ReleaseUpdateFeed.releases(JSONSerialization.data(withJSONObject:[release]),repository:repository,includePreview:false)[0].assets,[a])
        release["assets"]=[encoded,encoded];XCTAssertThrowsError(try ReleaseUpdateFeed.releases(JSONSerialization.data(withJSONObject:[release]),repository:repository,includePreview:false))
    }
    func testRealURLSessionDownloadAndHTTPIntegrityFailures() async throws {
        let root=try folder(),stage=root.appendingPathComponent("stage"),config=URLSessionConfiguration.ephemeral
        config.protocolClasses=[ReleaseProtocol.self]
        ReleaseProtocol.handler={ task in
            task.client?.urlProtocol(task,didReceive:HTTPURLResponse(url:task.request.url!,statusCode:200,httpVersion:nil,headerFields:["Content-Length":"\(self.bytes.count)"])!,cacheStoragePolicy:.notAllowed)
            task.client?.urlProtocol(task,didLoad:self.bytes);task.client?.urlProtocolDidFinishLoading(task)
        }
        defer {ReleaseProtocol.handler=nil}
        try await ReleaseAssetDownload.fetch(asset(),to:stage,configuration:config)
        XCTAssertEqual(try Data(contentsOf:stage),bytes)
        try FileManager.default.removeItem(at:stage)
        ReleaseProtocol.handler={ task in
            task.client?.urlProtocol(task,didReceive:HTTPURLResponse(url:task.request.url!,statusCode:503,httpVersion:nil,headerFields:nil)!,cacheStoragePolicy:.notAllowed)
            task.client?.urlProtocolDidFinishLoading(task)
        }
        do { try await ReleaseAssetDownload.fetch(asset(),to:stage,configuration:config);XCTFail("HTTP failure accepted") } catch {}
        XCTAssertFalse(FileManager.default.fileExists(atPath:stage.path))
    }
    func testDownloadCancellationDrainsURLSession() async throws {
        let root=try folder(),stage=root.appendingPathComponent("stage"),config=URLSessionConfiguration.ephemeral
        config.protocolClasses=[ReleaseProtocol.self]
        let started=expectation(description:"Private download started"),stopped=expectation(description:"Private download stopped")
        ReleaseProtocol.handler={ task in task.stopped={stopped.fulfill()};started.fulfill() }
        defer {ReleaseProtocol.handler=nil}
        let asset=try asset(),task=Task { try await ReleaseAssetDownload.fetch(asset,to:stage,configuration:config) }
        await fulfillment(of:[started],timeout:5);task.cancel()
        do {try await task.value;XCTFail("Cancelled download accepted")}catch {}
        await fulfillment(of:[stopped],timeout:5)
        XCTAssertFalse(FileManager.default.fileExists(atPath:stage.path))
    }
}
private final class ReleaseProtocol: URLProtocol, @unchecked Sendable {
    static var handler: ((ReleaseProtocol)->Void)?
    var stopped: (() -> Void)?
    override class func canInit(with request:URLRequest)->Bool {true}
    override class func canonicalRequest(for request:URLRequest)->URLRequest {request}
    override func startLoading() {Self.handler?(self)}
    override func stopLoading() {let callback=stopped;stopped=nil;callback?()}
}
