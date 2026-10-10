import XCTest
@testable import TurtleGitCore

final class PatchMailMIMETests: XCTestCase {
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
