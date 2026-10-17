import XCTest
@testable import TurtleGitCore
final class GitCertificateDetailsTests: XCTestCase {
    func testCertificateInspectionAndBothFingerprintsWithoutImport() throws {
        let file = try XCTUnwrap(Bundle.module.url(forResource: "server", withExtension: "der", subdirectory: "Certificates")), data = try Data(contentsOf: file)
        let details = try GitCertificateDetails(base64DER: data.base64EncodedString())
        XCTAssertEqual(details.subject, "turtlegit.example.invalid")
        XCTAssertEqual(details.sha1, "49:5F:7D:46:AB:DF:94:CE:2C:05:93:EA:4C:A3:33:20:CC:1A:57:4F")
        XCTAssertEqual(details.sha256, "1D:48:06:5D:B6:F9:AF:08:86:8A:4E:27:66:34:20:F6:40:C0:37:88:84:BC:B4:94:9A:CD:27:CA:EB:BC:86:F1")
        XCTAssertEqual(details.der, data); XCTAssertTrue(details.description.contains("SHA-256:")); XCTAssertTrue(details.description.contains("TurtleGit public fixture"))
        let prompt = GitSVNAuthenticationPrompt(kind: .trust, realm: "fixture", failures: 8, hostname: "turtlegit.example.invalid", issuer: "fixture", fingerprint: "SVN fingerprint", certificate: data.base64EncodedString())
        let decoded = try XCTUnwrap(GitSVNAuthenticationPrompt.decode(prompt.encoded(), enabled: true)); XCTAssertEqual(try decoded.certificateDetails()?.der, data)
    }
    func testPublicCertificateExportDERAndPEMRoundTrip() throws {
        let file = try XCTUnwrap(Bundle.module.url(forResource: "server", withExtension: "der", subdirectory: "Certificates"))
        let original = try Data(contentsOf: file), details = try GitCertificateDetails(base64DER: original.base64EncodedString())
        XCTAssertEqual(details.encoded(as: .der), original)
        let pem = String(decoding: details.encoded(as: .pem), as: UTF8.self)
        XCTAssertTrue(pem.hasPrefix("-----BEGIN CERTIFICATE-----\n")); XCTAssertTrue(pem.hasSuffix("\n-----END CERTIFICATE-----\n"))
        let lines = pem.split(separator: "\n").map(String.init), body = Array(lines.dropFirst().dropLast())
        XCTAssertTrue(body.dropLast().allSatisfy { $0.utf8.count == 64 }); XCTAssertLessThanOrEqual(body.last!.utf8.count, 64)
        XCTAssertEqual(Data(base64Encoded: body.joined()), original)
        XCTAssertEqual(details.fingerprints, "SHA-1: " + details.sha1 + "\nSHA-256: " + details.sha256)
        XCTAssertEqual(try GitCertificateDetails(base64DER: body.joined()).sha256, details.sha256)
        XCTAssertFalse(pem.contains("PRIVATE KEY")); XCTAssertEqual(try Data(contentsOf: file), original)
    }
    func testInvalidCertificateIsRefusedAndLegacyRequestStillWorks() throws {
        XCTAssertThrowsError(try GitCertificateDetails(base64DER: "invalid certificate"))
        let bad = GitSVNAuthenticationPrompt(kind: .trust, realm: "fixture", failures: 8, hostname: "host", issuer: "issuer", fingerprint: "fp", certificate: Data("not DER".utf8).base64EncodedString())
        XCTAssertThrowsError(try GitSVNAuthenticationPrompt.decode(bad.encoded(), enabled: true))
        let legacy = GitSVNAuthenticationPrompt(kind: .trust, realm: "fixture", failures: 8, hostname: "host", issuer: "issuer", fingerprint: "fp")
        XCTAssertNotNil(try GitSVNAuthenticationPrompt.decode(legacy.encoded(), enabled: true)); XCTAssertNil(try legacy.certificateDetails())
    }
}
