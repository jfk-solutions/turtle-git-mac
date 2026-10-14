import XCTest
@testable import TurtleGitCore
final class GitSVNAuthenticationPromptTests: XCTestCase {
    func testTypedPromptGateAndCredentialResponseAreOneLineAndBounded() throws {
        let prompt = GitSVNAuthenticationPrompt(kind: .credentials, realm: "<https://example.invalid> realm 雪", username: "name", maySave: true)
        let encoded = try prompt.encoded(); XCTAssertNil(try GitSVNAuthenticationPrompt.decode(encoded, enabled: false)); XCTAssertEqual(try GitSVNAuthenticationPrompt.decode(encoded, enabled: true), prompt)
        let answer = try GitSVNAuthenticationResponse(username: "name", password: "private fixture", save: true).encoded(for: prompt)
        XCTAssertFalse(answer.contains("private fixture")); XCTAssertFalse(answer.contains("\n")); XCTAssertNotNil(Data(base64Encoded: answer))
        XCTAssertThrowsError(try GitSVNAuthenticationResponse(username: "name\n", password: "x").encoded(for: prompt))
        XCTAssertThrowsError(try GitSVNAuthenticationPrompt.decode(GitSVNAuthenticationPrompt.prefix + "not-base64", enabled: true))
    }
    func testTrustFlagsAndPermanentDecisionRespectMaySave() throws {
        let prompt = GitSVNAuthenticationPrompt(kind: .trust, realm: "realm", maySave: false, failures: 0x4000000f, hostname: "example.invalid", validFrom: "from", validUntil: "until", issuer: "issuer", fingerprint: "AA:BB")
        XCTAssertEqual(prompt.failureDescriptions.count, 5); XCTAssertEqual(try GitSVNAuthenticationPrompt.decode(prompt.encoded(), enabled: true), prompt)
        XCTAssertThrowsError(try GitSVNAuthenticationResponse(decision: .permanent).encoded(for: prompt))
        _ = try GitSVNAuthenticationResponse(decision: .reject).encoded(for: prompt); _ = try GitSVNAuthenticationResponse(decision: .temporary).encoded(for: prompt)
        XCTAssertThrowsError(try GitSVNAuthenticationPrompt.decode(GitSVNAuthenticationPrompt(kind: .trust, realm: "bad", failures: 8).encoded(), enabled: true))
    }
    func testCertificateCopyUsesOwnedFolderAndPreservesSourceBytes() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString), folder = root.appendingPathComponent("owned")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]); defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("certificate.p12"), bytes = Data([0,255,1,2]); try bytes.write(to: source)
        let copy = try GitSVNClientCertificate.copy(source, directory: folder)
        XCTAssertEqual(try Data(contentsOf: copy), bytes); XCTAssertEqual(try Data(contentsOf: source), bytes); XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: copy.path)[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: folder.path)
        XCTAssertThrowsError(try GitSVNClientCertificate.copy(source, directory: folder))
    }
    func testCommandOwnsCertificateDirectoryAndPreservesCustomAskpass() async throws {
        let (root, original, _) = try await GitPatchTests().fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let wrapper = root.appendingPathComponent("git-wrapper"), helper = root.appendingPathComponent("askpass")
        let script = #"""
        #!/usr/bin/python3
        import json,os,sys
        if sys.argv[4] != 'svn': os.execv('/usr/bin/git',['/usr/bin/git']+sys.argv[1:])
        directory=os.environ.get('TURTLEGIT_SVN_CERT_DIRECTORY')
        if directory:
          with open(directory+'/fixture.p12','wb') as stream: stream.write(b'private fixture')
        print(json.dumps({'enabled':os.environ.get('TURTLEGIT_SVN_NATIVE_PROMPTS')=='1','directory':directory,'mode':os.stat(directory).st_mode&0o777 if directory else None}))
        """#
        try Data(script.utf8).write(to: wrapper); try Data("#!/bin/sh\nexit 1\n".utf8).write(to: helper)
        for file in [wrapper, helper] { try FileManager.default.setAttributes([.posixPermissions:0o755], ofItemAtPath: file.path) }
        let repo = GitRepository(root: root, executable: wrapper, askpass: helper)
        let own = try await repo.run(["svn", "fetch"])
        let value = try JSONSerialization.jsonObject(with: own.stdout) as! [String:Any]
        XCTAssertEqual(value["enabled"] as? Bool, true); XCTAssertEqual(value["mode"] as? Int, 0o700)
        XCTAssertFalse(FileManager.default.fileExists(atPath: value["directory"] as! String))
        let custom = try await repo.run(["svn", "fetch"], environmentOverrides:["GIT_ASKPASS":"/usr/bin/false", "TURTLEGIT_SVN_NATIVE_PROMPTS":"1"])
        let other = try JSONSerialization.jsonObject(with: custom.stdout) as! [String:Any]; XCTAssertEqual(other["enabled"] as? Bool, false)
        XCTAssertTrue(other["directory"] is NSNull)
        XCTAssertFalse(GitAskpassPrompt("Username: ", svn: true).secret); XCTAssertTrue(GitAskpassPrompt("Username: ").secret)
        _ = original
    }
}
