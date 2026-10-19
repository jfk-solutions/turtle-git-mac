// SPDX-License-Identifier: GPL-2.0-or-later
import XCTest
import Darwin
@testable import TurtleGitCore

final class GitRemoteCertificateAcceptanceTests: XCTestCase {
    private func record(_ host: String = "example.invalid", port: UInt16 = 443) throws -> GitRemoteCertificateAcceptance {
        try .init(hostname: host, port: port, certificateDER: Data(contentsOf: XCTUnwrap(Bundle.module.url(forResource: "server", withExtension: "der", subdirectory: "Certificates"))))
    }
    private func directory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700]); return root
    }
    private func append(_ value: GitRemoteCertificateAcceptance, to url: URL) throws {
        let handle = try FileHandle(forWritingTo: url); defer { try? handle.close() }
        try handle.seekToEnd(); try handle.write(contentsOf: value.encodedLine())
    }
    func testExactAuthorityAndCertificateFramingAndBoundedProcessMemory() throws {
        let cache = GitRemoteCertificateAcceptanceCache(), nfc = try record("é.invalid"), nfd = try record("e\u{301}.invalid"), port = try record("é.invalid", port: 8443)
        XCTAssertNotEqual(nfc.key, nfd.key); XCTAssertNotEqual(nfc.key, port.key)
        var altered = nfc.certificateDER;altered[altered.count-1] ^= 1
        let changedDER = try GitRemoteCertificateAcceptance(hostname:nfc.hostname,port:nfc.port,certificateDER:altered)
        XCTAssertNotEqual(nfc.key,changedDER.key)
        cache.merge([nfc,nfd,port,changedDER]); XCTAssertEqual(cache.snapshot().count,4)
        for index in 0..<128 { cache.merge([try record("host-\(index).invalid")]) }
        XCTAssertEqual(cache.snapshot().count,128); XCTAssertFalse(cache.snapshot().contains { $0.key == nfc.key })
        XCTAssertTrue(GitRemoteCertificateAcceptanceCache().snapshot().isEmpty)
        XCTAssertThrowsError(try record("bad\u{1b}.invalid")); XCTAssertThrowsError(try record("",port:0))
        XCTAssertThrowsError(try GitRemoteCertificateAcceptance(hostname:"host",port:443,certificateDER:Data("not DER".utf8)))
        XCTAssertThrowsError(try GitRemoteCertificateAcceptance.decode(Data("{}\n".utf8)))
        XCTAssertThrowsError(try GitRemoteCertificateAcceptance.decode(nfc.encodedLine().dropLast()))
        XCTAssertThrowsError(try GitRemoteCertificateAcceptance.decode(Data(repeating:10,count:GitRemoteCertificateAcceptance.maximumRecords+1)))
    }
    func testPrivateExchangeImportsAfterRemoteFailureButNeverCancellationOrMalformedTail() throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at:root) }
        let cache = GitRemoteCertificateAcceptanceCache(), first = try record(), second = try record("second.invalid")
        let exchange = try GitRemoteCertificateAcceptanceExchange(directory:root,cache:cache)
        try append(first,to:exchange.url); exchange.consume(cancelled:false)
        XCTAssertEqual(cache.snapshot().map(\.key),[first.key],"A drained nonzero remote result must retain an actual earlier acceptance")
        try append(second,to:exchange.url); exchange.consume(cancelled:true)
        XCTAssertEqual(cache.snapshot().map(\.key),[first.key])
        let handle = try FileHandle(forWritingTo:exchange.url); try handle.seekToEnd(); try handle.write(contentsOf:Data("malformed\n".utf8)); try handle.close()
        exchange.consume(cancelled:false); XCTAssertEqual(cache.snapshot().map(\.key),[first.key],"Malformed exchange must not partially import")
    }
    func testExchangeRejectsPermissionAndReplacedSymlinkAndContainsOnlyPublicCertificates() throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at:root) }
        let cache = GitRemoteCertificateAcceptanceCache(), value = try record();cache.merge([value])
        let exchange = try GitRemoteCertificateAcceptanceExchange(directory:root,cache:cache)
        let bytes = try Data(contentsOf:exchange.url)
        XCTAssertEqual(try GitRemoteCertificateAcceptance.decode(bytes).map(\.key),[value.key]);XCTAssertFalse(String(decoding:bytes,as:UTF8.self).contains("password"))
        let other = try record("other.invalid");try append(other,to:exchange.url)
        try FileManager.default.setAttributes([.posixPermissions:0o644],ofItemAtPath:exchange.url.path)
        exchange.consume(cancelled:false);XCTAssertEqual(cache.snapshot().count,1)
        let replacement = root.appendingPathComponent("replacement");try other.encodedLine().write(to:replacement)
        try FileManager.default.removeItem(at:exchange.url);try FileManager.default.createSymbolicLink(at:exchange.url,withDestinationURL:replacement)
        exchange.consume(cancelled:false);XCTAssertEqual(cache.snapshot().count,1)
    }
    func testUnchangedConcurrentSnapshotCannotResurrectEvictedAcceptance() throws {
        let root=try directory();defer{try? FileManager.default.removeItem(at:root)}
        let cache=GitRemoteCertificateAcceptanceCache()
        for index in 0..<128{cache.merge([try record("old-\(index).invalid")])}
        let exchange=try GitRemoteCertificateAcceptanceExchange(directory:root,cache:cache)
        let latest=try record("latest.invalid");cache.merge([latest]);let before=cache.snapshot().map(\.key)
        exchange.consume(cancelled:false);XCTAssertEqual(cache.snapshot().map(\.key),before);XCTAssertEqual(cache.snapshot().last?.key,latest.key)
        // The snapshot itself is immutable, not a helper-controlled rewrite.
        let handle=try FileHandle(forWritingTo:exchange.url);try handle.seek(toOffset:0);try handle.write(contentsOf:Data("X".utf8));try handle.close()
        exchange.consume(cancelled:false);XCTAssertEqual(cache.snapshot().map(\.key),before)
    }

}
