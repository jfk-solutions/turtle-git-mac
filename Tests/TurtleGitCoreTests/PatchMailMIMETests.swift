import XCTest
@testable import TurtleGitCore

final class PatchMailMIMETests: XCTestCase {
    func testMailboxComponentsPreserveUnicodeAndQuotedDisplayNames() throws {
        let values = [("Bare <bare@example.invalid>", "Bare", "bare@example.invalid"),
                      (#""Quoted \"Name\" 雪" <quoted@example.invalid>"#, "Quoted \"Name\" 雪", "quoted@example.invalid"),
                      ("  plain@example.invalid  ", "", "plain@example.invalid")]
        for (value, name, address) in values {
            let parsed = try PatchMailMIME.mailboxComponents(value)
            XCTAssertEqual(parsed.name, name); XCTAssertEqual(parsed.address, address)
            XCTAssertEqual(try PatchMailMIME.envelopeAddress(value), address)
        }
        XCTAssertThrowsError(try PatchMailMIME.mailboxComponents("Bad\nName <bare@example.invalid>"))
    }
    func testMailClientAttachmentMapUsesLastDuplicateAndUTF16PathOrder() {
        let a = PatchMailAttachment(file: URL(fileURLWithPath: "/a/same.patch"), bytes: Data([1]))
        let b = PatchMailAttachment(file: URL(fileURLWithPath: "/b/same.patch"), bytes: Data([2]))
        let last = PatchMailAttachment(file: a.file, bytes: Data([3]))
        let emoji = PatchMailAttachment(file: URL(fileURLWithPath: "/🐢.patch"), bytes: Data([4]))
        let bmp = PatchMailAttachment(file: URL(fileURLWithPath: "/\u{e000}.patch"), bytes: Data([5]))
        let result = PatchMailPreparation.mailClientAttachments([bmp, b, a, emoji, last])
        XCTAssertEqual(result.map(\.file), [a.file, b.file, emoji.file, bmp.file])
        XCTAssertEqual(result.map(\.bytes), [Data([3]), Data([2]), Data([4]), Data([5])])
    }
    private let sender = PatchMailSender(name: "Sender 雪", email: "sender@example.invalid")
    private func patch(_ name: String, subject: String, body: Data) throws -> SerialPatch {
        try SerialPatch(file: URL(fileURLWithPath: "/fixture/" + name), bytes: Data(("Subject: " + subject + "\n\n").utf8) + body)
    }

    func testFourModesRoundTripWithIndependentMIMEParser() throws {
        let patches = try [patch("' quote; 雪\n.patch", subject: "First 雪", body: Data("one\n.two\r\n".utf8)),
                           patch(String(repeating: "雪", count: 60) + ".patch", subject: "Second", body: Data("two\n".utf8))]
        var fixtures: [(Data, [String: Any])] = []
        for combine in [false, true] {
            for attachment in [false, true] {
                var options = PatchMailOptions()
                options.combine = combine; options.attachment = attachment
                options.subject = String(repeating: "Series 雪 🐢 ", count: 40)
                options.to = #"Alice, Example <alice@example.invalid>; "Quoted \"Name\"" <quoted@example.invalid>"#
                options.cc = "Review 雪 <review@example.invalid>"
                for message in try PatchMailPreparation.messages(patches: patches, options: options) {
                    let bytes = try PatchMailMIME.data(message: message, sender: sender, date: Date(timeIntervalSince1970: 0))
                    fixtures.append((bytes, ["subject": message.subject, "body": message.body.base64EncodedString(),
                        "names": message.attachments.map { $0.file.lastPathComponent },
                        "attachments": message.attachments.map { $0.bytes.base64EncodedString() }]))
                    let lines = String(decoding: bytes, as: UTF8.self).components(separatedBy: "\r\n")
                    XCTAssertTrue(lines.allSatisfy { $0.utf8.count <= 998 })
                    XCTAssertTrue(lines.filter { $0.contains("=?UTF-8?B?") }.allSatisfy { $0.utf8.count <= 76 })
                    XCTAssertFalse(String(decoding: bytes, as: UTF8.self).replacingOccurrences(of: "\r\n", with: "").contains("\n"))
                }
            }
        }
        try parse(fixtures, script: #"""
for entry in entries:
    msg = BytesParser(policy=policy.default).parsebytes(base64.b64decode(entry['mail']))
    assert not msg.defects, msg.defects
    assert str(msg['Subject']) == entry['subject'], str(msg['Subject'])
    assert msg['From'].addresses[0].display_name == 'Sender 雪'
    assert msg['From'].addresses[0].addr_spec == 'sender@example.invalid'
    assert [a.addr_spec for a in msg['To'].addresses] == ['alice@example.invalid', 'quoted@example.invalid']
    assert msg['To'].addresses[0].display_name == 'Alice, Example'
    assert msg['To'].addresses[1].display_name == 'Quoted "Name"'
    assert [a.addr_spec for a in msg['Cc'].addresses] == ['review@example.invalid']
    assert msg['Cc'].addresses[0].display_name == 'Review 雪'
    assert str(msg['Date']) == 'Thu, 01 Jan 1970 00:00:00 +0000'
    body = msg.get_body(preferencelist=('plain',))
    assert body.get_payload(decode=True) == base64.b64decode(entry['body'])
    attachments = list(msg.iter_attachments())
    assert [a.get_filename() for a in attachments] == entry['names']
    assert [a.get_payload(decode=True) for a in attachments] == [base64.b64decode(a) for a in entry['attachments']]
    assert all(not p.defects for p in msg.walk())
"""#)
    }

    func testOpaqueEncodedSubjectEmptyRecipientsAndUniqueIdentifiers() throws {
        let message = try PatchMailPreparation.messages(patches: [patch("p", subject: "=?UTF-8?q?Snow_=E9=9B=AA?=", body: Data())], options: PatchMailOptions())[0]
        let first = try PatchMailMIME.data(message: message, sender: sender)
        let second = try PatchMailMIME.data(message: message, sender: sender)
        XCTAssertNotEqual(first, second)
        try parse([(first, [:])], script: #"""
msg = BytesParser(policy=policy.default).parsebytes(base64.b64decode(entries[0]['mail']))
assert str(msg['Subject']) == 'Snow 雪'
assert msg['To'] is None and msg['Cc'] is None
assert msg.get_payload(decode=True) == b''
assert not msg.defects
"""#)
    }

    func testLongOpaqueEncodedSubjectIsFoldedWithoutDoubleEncoding() throws {
        let word = "=?UTF-8?q?Snow_=E9=9B=AA?="
        let subject = Array(repeating: word, count: 10).joined(separator: " ")
        let message = try PatchMailPreparation.messages(patches: [patch("p", subject: subject, body: Data())], options: PatchMailOptions())[0]
        let mail = try PatchMailMIME.data(message: message, sender: sender)
        try parse([(mail, [:])], script: #"""
msg = BytesParser(policy=policy.default).parsebytes(base64.b64decode(entries[0]['mail']))
assert str(msg['Subject']) == 'Snow 雪' * 10
assert not msg.defects
"""#)
    }

    func testCharsetChoicePreservesNonUTF8Bytes() throws {
        let bytes = Data([0xff, 0x00, 0x0a, 0x0d, 0x80])
        let message = try PatchMailPreparation.messages(patches: [patch("p", subject: "Latin1", body: bytes)], options: PatchMailOptions())[0]
        XCTAssertThrowsError(try PatchMailMIME.data(message: message, sender: sender))
        let mail = try PatchMailMIME.data(message: message, sender: sender, bodyCharset: .latin1)
        try parse([(mail, ["body": bytes.base64EncodedString()])], script: #"""
msg = BytesParser(policy=policy.default).parsebytes(base64.b64decode(entries[0]['mail']))
assert msg.get_content_charset() == 'iso-8859-1'
assert msg.get_payload(decode=True) == base64.b64decode(entries[0]['body'])
"""#)
    }

    func testBinaryAttachmentSnapshotRoundTrip() throws {
        let bytes = Data((0...255).map { UInt8($0) })
        let input = try SerialPatch(file: URL(fileURLWithPath: "/nonexistent/snapshot.patch"), bytes: bytes)
        var options = PatchMailOptions(); options.attachment = true
        let message = try PatchMailPreparation.messages(patches: [input], options: options)[0]
        let mail = try PatchMailMIME.data(message: message, sender: sender)
        try parse([(mail, ["bytes": bytes.base64EncodedString()])], script: #"""
msg = BytesParser(policy=policy.default).parsebytes(base64.b64decode(entries[0]['mail']))
assert list(msg.iter_attachments())[0].get_payload(decode=True) == base64.b64decode(entries[0]['bytes'])
assert msg.get_body(preferencelist=('plain',)).get_payload(decode=True) == b''
"""#)
    }

    func testInvalidMailboxesAndHeaderInjectionFailBeforeSerialization() throws {
        let valid = try PatchMailPreparation.messages(patches: [patch("p", subject: "OK", body: Data("body".utf8))], options: PatchMailOptions())[0]
        XCTAssertThrowsError(try PatchMailMIME.data(message: valid, sender: sender, date: Date(timeIntervalSince1970: .nan)))
        let overlong = try patch("p", subject: "=?" + String(repeating: "a", count: 1000), body: Data())
        let longMessage = try PatchMailPreparation.messages(patches: [overlong], options: PatchMailOptions())[0]
        XCTAssertThrowsError(try PatchMailMIME.data(message: longMessage, sender: sender))
        for value in ["sender\r\nBcc: x", "sender\0", "sender\u{7}"] {
            XCTAssertThrowsError(try PatchMailMIME.data(message: valid, sender: PatchMailSender(name: value, email: "sender@example.invalid")))
        }
        for email in ["a..b@example.invalid", ".a@example.invalid", "a@-domain.invalid", "a@example.invalid,other@example.invalid", "雪@example.invalid", "a@example.invalid\r\nBcc: x"] {
            XCTAssertThrowsError(try PatchMailMIME.data(message: valid, sender: PatchMailSender(name: "", email: email)))
        }
        for recipient in ["undisclosed: a@example.invalid", "Name <a@example.invalid> trailing", "a@example.invalid, b@example.invalid", "a@example.invalid (comment)"] {
            var options = PatchMailOptions(); options.to = recipient
            let message = try PatchMailPreparation.messages(patches: [patch("p", subject: "OK", body: Data())], options: options)[0]
            XCTAssertThrowsError(try PatchMailMIME.data(message: message, sender: sender))
        }
    }

    /// Python's standard-library parser is independent of the Swift serializer.
    /// All files live in a private fixture; no mail client or network is used.
    private func parse(_ fixtures: [(Data, [String: Any])], script: String) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("TurtleGitMIME-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let manifest = root.appendingPathComponent("messages.json"), python = root.appendingPathComponent("parse.py")
        let entries = fixtures.map { mail, expected -> [String: Any] in
            var result = expected; result["mail"] = mail.base64EncodedString(); return result
        }
        try JSONSerialization.data(withJSONObject: entries).write(to: manifest)
        let preamble = "import base64, json, sys\nfrom email import policy\nfrom email.parser import BytesParser\nwith open(sys.argv[1]) as f: entries = json.load(f)\n"
        try (preamble + script + "\n").write(to: python, atomically: true, encoding: .utf8)
        let process = Process(), output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = [python.path, manifest.path]
        process.standardOutput = output; process.standardError = output
        try process.run()
        let diagnostics = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0, String(decoding: diagnostics, as: UTF8.self))
    }
}

final class PatchMailSenderTests: XCTestCase {
    private func fixture() throws -> (URL, GitRepository, [String: String]) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("TurtleGitSender-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let repo = GitRepository(root: root, executable: URL(fileURLWithPath:
            ProcessInfo.processInfo.environment["TURTLEGIT_SEND_PATCH_TEST_GIT"] ?? "/usr/bin/git"))
        // Isolate Git configuration without changing the process/user environment.
        let environment = ["GIT_CONFIG_NOSYSTEM": "1", "GIT_CONFIG_SYSTEM": "/dev/null",
            "GIT_CONFIG_GLOBAL": root.appendingPathComponent("global.config").path,
            "GIT_CONFIG_COUNT": "0", "GIT_AUTHOR_NAME": "", "GIT_AUTHOR_EMAIL": ""]
        return (root, repo, environment)
    }
    func testSourceSenderPrecedenceIsIndependentForNameAndEmail() async throws {
        let (root, repo, environment) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try await repo.run(["init", "-b", "main"], environmentOverrides: environment)
        for (key, value) in [("user.name", "User 雪"), ("user.email", "user@example.invalid"),
                             ("author.name", "Author 雪"), ("author.email", "author@example.invalid")] {
            _ = try await repo.run(["config", "--local", key, value], environmentOverrides: environment)
        }
        let config = try Data(contentsOf: root.appendingPathComponent(".git/config"))
        var actual = try await repo.patchMailSender(environmentOverrides: environment)
        XCTAssertEqual(actual, PatchMailSender(name: "Author 雪", email: "author@example.invalid"))
        var overrides = environment
        overrides["GIT_AUTHOR_NAME"] = "Environment 雪"
        overrides["GIT_COMMITTER_EMAIL"] = "ignored@example.invalid"
        overrides["EMAIL"] = "also-ignored@example.invalid"
        actual = try await repo.patchMailSender(environmentOverrides: overrides)
        XCTAssertEqual(actual, PatchMailSender(name: "Environment 雪", email: "author@example.invalid"))
        overrides["GIT_AUTHOR_EMAIL"] = "environment@example.invalid"
        actual = try await repo.patchMailSender(environmentOverrides: overrides)
        XCTAssertEqual(actual, PatchMailSender(name: "Environment 雪", email: "environment@example.invalid"))
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(".git/config")), config)
        _ = try await repo.run(["config", "--local", "author.name", ""], environmentOverrides: environment)
        _ = try await repo.run(["config", "--local", "--unset", "author.email"], environmentOverrides: environment)
        actual = try await repo.patchMailSender(environmentOverrides: environment)
        XCTAssertEqual(actual, PatchMailSender(name: "User 雪", email: "user@example.invalid"))
    }
    func testSenderIncludesMissingValuesAndConfigurationErrors() async throws {
        let (root, repo, environment) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try await repo.run(["init", "-b", "main"], environmentOverrides: environment)
        var actual = try await repo.patchMailSender(environmentOverrides: environment)
        XCTAssertEqual(actual, PatchMailSender(name: "", email: ""), "No host/login identity fallback")
        let included = root.appendingPathComponent("included 雪.config")
        try Data("[author]\nname = Included 雪\nemail = included@example.invalid\n".utf8).write(to: included)
        _ = try await repo.run(["config", "--file", environment["GIT_CONFIG_GLOBAL"]!, "include.path", included.path], environmentOverrides: environment)
        actual = try await repo.patchMailSender(environmentOverrides: environment)
        XCTAssertEqual(actual, PatchMailSender(name: "Included 雪", email: "included@example.invalid"))
        _ = try await repo.run(["config", "--local", "author.email", "local@example.invalid"], environmentOverrides: environment)
        actual = try await repo.patchMailSender(environmentOverrides: environment)
        XCTAssertEqual(actual, PatchMailSender(name: "Included 雪", email: "local@example.invalid"))
        try Data("[malformed\n".utf8).write(to: included)
        do { _ = try await repo.patchMailSender(environmentOverrides: environment); XCTFail("Malformed config must fail") }
        catch is GitFailure { }
        // With both environment fields supplied upstream does not read config.
        var supplied = environment
        supplied["GIT_AUTHOR_NAME"] = "Captured"; supplied["GIT_AUTHOR_EMAIL"] = "captured@example.invalid"
        actual = try await repo.patchMailSender(environmentOverrides: supplied)
        XCTAssertEqual(actual, PatchMailSender(name: "Captured", email: "captured@example.invalid"))
    }
    func testSenderCancellationAndMIMEValidationWithoutCoercingConfiguration() async throws {
        let (root, repo, environment) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try await repo.run(["init", "-b", "main"], environmentOverrides: environment)
        let token = OperationCancellation(); token.cancel()
        do { _ = try await repo.patchMailSender(environmentOverrides: environment, cancellation: token); XCTFail("Cancelled read must fail") }
        catch is OperationCancellationFailure { }
        _ = try await repo.run(["config", "--local", "user.name", "Name\nInjected"], environmentOverrides: environment)
        _ = try await repo.run(["config", "--local", "user.email", "sender@example.invalid"], environmentOverrides: environment)
        let sender = try await repo.patchMailSender(environmentOverrides: environment)
        XCTAssertEqual(sender.name, "Name\nInjected", "NUL framing preserves config; MIME validates headers")
        let patch = try SerialPatch(file: root.appendingPathComponent("patch"), bytes: Data("Subject: example\n\nbody".utf8))
        let message = try XCTUnwrap(PatchMailPreparation.messages(patches: [patch], options: PatchMailOptions()).first)
        XCTAssertThrowsError(try PatchMailMIME.data(message: message, sender: sender))
    }
}
