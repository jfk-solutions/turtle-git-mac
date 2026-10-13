// SPDX-License-Identifier: GPL-2.0-or-later
import XCTest
@testable import TurtleGitCore

final class SSHKeyConversionTests:XCTestCase {
    let tool=URL(fileURLWithPath:FileManager.default.currentDirectoryPath).appendingPathComponent("build/putty-runtime/PuTTY/bin/puttygen")
    let keygen=URL(fileURLWithPath:"/usr/bin/ssh-keygen")
    func fixture() throws -> URL { try SSHAgentSessionTests().fixture() }
    func command(_ executable:URL,_ args:[String]) throws -> Int32 {
        let process=Process();process.executableURL=executable;process.arguments=args
        process.standardInput=FileHandle.nullDevice;process.standardOutput=FileHandle.nullDevice;process.standardError=FileHandle.nullDevice
        try process.run();process.waitUntilExit();return process.terminationStatus
    }
    func key(_ root:URL,version:Int=3,phrase:String="",algorithm:String="ed25519") throws -> URL {
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath:tool.path),"Build the pinned PuTTY runtime before this group")
        let file=root.appendingPathComponent("input-\(version)-\(algorithm).ppk"),secret=root.appendingPathComponent("phrase-"+UUID().uuidString)
        try Data((phrase+"\n").utf8).write(to:secret);defer { try? FileManager.default.removeItem(at:secret) }
        var args=["-q","-t",algorithm,"-C","original 雪 comment","-o",file.path,"--new-passphrase",secret.path,"--ppk-param","version=\(version)"]
        if algorithm=="rsa" { args += ["-b","2048"] }
        XCTAssertEqual(try command(tool,args),0);return file
    }
    func assertClean(_ root:URL) throws { XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath:root.path).contains { $0.hasPrefix("tg-key-import-") }) }
    func testPlainPPK2And3RSAAndEd25519ImportKeepsOriginalAndPublishesPermissions() throws {
        let root=try fixture();defer { try? FileManager.default.removeItem(at:root) }
        for (version,algorithm) in [(2,"rsa"),(3,"ed25519")] {
            let source=try key(root,version:version,algorithm:algorithm),bytes=try Data(contentsOf:source)
            let destination=root.appendingPathComponent("converted \(version) '")
            let result=try SSHKeyConversion.convert(.init(source:source,destination:destination),converter:tool,keygen:keygen)
            XCTAssertTrue(result.publicText.contains("original 雪 comment"));XCTAssertTrue(result.fingerprint.contains("SHA256:"))
            XCTAssertTrue(try String(contentsOf:destination).hasPrefix("-----BEGIN OPENSSH PRIVATE KEY-----"))
            XCTAssertEqual(try Data(contentsOf:source),bytes)
            XCTAssertEqual(try FileManager.default.attributesOfItem(atPath:destination.path)[.posixPermissions] as? Int,0o600)
            XCTAssertEqual(try FileManager.default.attributesOfItem(atPath:result.publicKey.path)[.posixPermissions] as? Int,0o644)
        }
        try assertClean(root)
    }
    func testEncryptedImportPreservesPassphraseAndLoadsIntoPrivateOpenSSHAgent() throws {
        let root=try fixture();defer { try? FileManager.default.removeItem(at:root) }
        let phrase="fixture '$()' 雪",source=try key(root,phrase:phrase),bytes=try Data(contentsOf:source)
        var request=SSHKeyConversionRequest(source:source,destination:root.appendingPathComponent("encrypted-openssh"));request.oldPassphrase=phrase
        let result=try SSHKeyConversion.convert(request,converter:tool,keygen:keygen)
        let helper=try SSHAskpassTests().helper(in:root)
        let runtime=SSHAgentRuntime(agent:URL(fileURLWithPath:"/usr/bin/ssh-agent"),add:URL(fileURLWithPath:"/usr/bin/ssh-add"),askpass:helper)
        let agent=try SSHAgentSession(runtime:runtime,temporaryRoot:root);defer { agent.close() }
        XCTAssertThrowsError(try agent.add(keys:[result.privateKey]))
        try agent.add(keys:[result.privateKey],passphrase:phrase)
        XCTAssertTrue(try agent.publicIdentities().contains("original 雪 comment"));XCTAssertEqual(try Data(contentsOf:source),bytes);try assertClean(root)
    }
    func testChangeAndRemovePassphraseAndCommentFromExistingOpenSSHKey() throws {
        let root=try fixture();defer { try? FileManager.default.removeItem(at:root) }
        let source=try key(root,phrase:"old phrase"),bytes=try Data(contentsOf:source)
        var request=SSHKeyConversionRequest(source:source,destination:root.appendingPathComponent("first"));request.oldPassphrase="old phrase";request.newPassphrase="new phrase";request.comment="replacement comment"
        let first=try SSHKeyConversion.convert(request,converter:tool,keygen:keygen)
        var second=SSHKeyConversionRequest(source:first.privateKey,destination:root.appendingPathComponent("second"));second.oldPassphrase="new phrase";second.newPassphrase=""
        let result=try SSHKeyConversion.convert(second,converter:tool,keygen:keygen)
        XCTAssertTrue(result.publicText.contains("replacement comment"));XCTAssertEqual(try command(keygen,["-y","-f",result.privateKey.path]),0)
        XCTAssertEqual(first.publicText,result.publicText);XCTAssertEqual(try Data(contentsOf:source),bytes);try assertClean(root)
    }
    func testWrongPassphraseMalformedInputAndDestinationCollisionPublishNothing() throws {
        let root=try fixture();defer { try? FileManager.default.removeItem(at:root) }
        let source=try key(root,phrase:"correct"),bytes=try Data(contentsOf:source),destination=root.appendingPathComponent("refused")
        var request=SSHKeyConversionRequest(source:source,destination:destination);request.oldPassphrase="wrong"
        XCTAssertThrowsError(try SSHKeyConversion.convert(request,converter:tool,keygen:keygen));XCTAssertFalse(FileManager.default.fileExists(atPath:destination.path))
        let malformed=root.appendingPathComponent("malformed");try Data("invalid key".utf8).write(to:malformed)
        XCTAssertThrowsError(try SSHKeyConversion.convert(.init(source:malformed,destination:destination),converter:tool,keygen:keygen))
        request.oldPassphrase="correct";try Data("existing".utf8).write(to:destination)
        XCTAssertThrowsError(try SSHKeyConversion.convert(request,converter:tool,keygen:keygen));XCTAssertEqual(try Data(contentsOf:destination),Data("existing".utf8))
        XCTAssertEqual(try Data(contentsOf:source),bytes);try assertClean(root)
    }
    func testPreCancelledImportAndSymlinkInputOrOutputAreRefused() throws {
        let root=try fixture();defer { try? FileManager.default.removeItem(at:root) }
        let source=try key(root),destination=root.appendingPathComponent("output"),token=OperationCancellation();token.cancel()
        XCTAssertThrowsError(try SSHKeyConversion.convert(.init(source:source,destination:destination),converter:tool,keygen:keygen,cancellation:token))
        let link=root.appendingPathComponent("linked-key");try FileManager.default.createSymbolicLink(at:link,withDestinationURL:source)
        XCTAssertThrowsError(try SSHKeyConversion.convert(.init(source:link,destination:destination),converter:tool,keygen:keygen))
        try FileManager.default.createSymbolicLink(at:destination,withDestinationURL:source)
        XCTAssertThrowsError(try SSHKeyConversion.convert(.init(source:source,destination:destination),converter:tool,keygen:keygen));try assertClean(root)
    }
}
