import XCTest
@testable import TurtleGitCore

final class PatchMailPreparationTests: XCTestCase {
    private func location(_ name: String = "patch") -> URL { URL(fileURLWithPath: "/fixture/" + name) }
    func testHeadersFoldingAndLFCRLFBodyBoundaries() throws {
        for ending in ["\n", "\r\n"] {
            let header = ["From abc Mon Sep 17 00:00:00 2001", "From: Author 雪 <author@example.invalid>", "Date: Thu, 2 Jan 2020 03:04:05 +0000", "Subject: [PATCH] first", " continuation", "\tlast", "MIME-Version: 1.0"].joined(separator: ending)
            let body = Data(("commit body" + ending + "Subject: this is body text" + ending + "diff --git a/file b/file" + ending).utf8)
            var bytes = Data((header + ending + ending).utf8); bytes.append(body)
            let patch = try SerialPatch(file: location(), bytes: bytes)
            XCTAssertEqual(patch.author, "Author 雪 <author@example.invalid>")
            XCTAssertEqual(patch.date, "Thu, 2 Jan 2020 03:04:05 +0000")
            XCTAssertEqual(patch.subject, "[PATCH] first continuation\tlast")
            XCTAssertEqual(patch.inlineBody, body); XCTAssertEqual(patch.bytes, bytes)
        }
        let emptyBody = try SerialPatch(file: location(), bytes: Data("Subject: empty\n\n".utf8))
        XCTAssertEqual(emptyBody.inlineBody, Data())
        let encoded = try SerialPatch(file: location(), bytes: Data("Subject: =?UTF-8?q?Snow_=E9=9B=AA?=\n\nbody".utf8))
        XCTAssertEqual(encoded.subject, "=?UTF-8?q?Snow_=E9=9B=AA?=", "Upstream does not decode encoded words")
    }

    func testAllFourSourceModesKeepOrderingSubjectsRecipientsAndExactBytes() throws {
        let first = try SerialPatch(file: location("a 雪.patch"), bytes: Data("From: A <a@example.invalid>\nSubject: [PATCH 1/2] one\n\nfirst\n".utf8))
        let second = try SerialPatch(file: location("b.patch"), bytes: Data("Subject: [PATCH 2/2] two\r\n\r\nsecond\r\n".utf8))
        for combine in [false, true] {
            for attachment in [false, true] {
                var options = PatchMailOptions(); options.combine = combine; options.attachment = attachment; options.subject = "Series 雪"
                options.to = " Alice, Example <alice@example.invalid> ; bob@example.invalid;; "
                options.cc = "review@example.invalid; Other <other@example.invalid>"
                let messages = try PatchMailPreparation.messages(patches: [second, first], options: options)
                XCTAssertEqual(messages.count, combine ? 1 : 2)
                for message in messages {
                    XCTAssertEqual(message.to, ["Alice, Example <alice@example.invalid>", "bob@example.invalid"])
                    XCTAssertEqual(message.cc, ["review@example.invalid", "Other <other@example.invalid>"])
                }
                if combine {
                    XCTAssertEqual(messages[0].subject, "Series 雪")
                    XCTAssertEqual(messages[0].body, attachment ? Data((second.subject + "\r\n" + first.subject + "\r\n").utf8) : second.bytes + first.bytes)
                    XCTAssertEqual(messages[0].attachments.map(\.file), attachment ? [second.file, first.file] : [])
                    XCTAssertEqual(messages[0].attachments.map(\.bytes), attachment ? [second.bytes, first.bytes] : [])
                } else {
                    XCTAssertEqual(messages.map(\.subject), [second.subject, first.subject])
                    XCTAssertEqual(messages.map(\.body), attachment ? [Data(), Data()] : [second.inlineBody!, first.inlineBody!])
                    XCTAssertEqual(messages.flatMap(\.attachments).map(\.file), attachment ? [second.file, first.file] : [])
                }
            }
        }
        XCTAssertFalse(PatchMailOptions().attachment); XCTAssertFalse(PatchMailOptions().combine)
    }

    func testMalformedBodyAttachmentRulesAndHeaderGuards() throws {
        let headerless = try SerialPatch(file: location(), bytes: Data("nonempty attachment bytes".utf8))
        XCTAssertEqual(headerless.subject, ""); XCTAssertNil(headerless.inlineBody)
        let manyLines = try SerialPatch(file: location(), bytes: Data(String(repeating: "unrecognized line\n", count: 10_000).utf8))
        XCTAssertEqual(manyLines.subject, ""); XCTAssertNil(manyLines.inlineBody)
        var options = PatchMailOptions(); options.attachment = true
        XCTAssertEqual(try PatchMailPreparation.messages(patches: [headerless], options: options)[0].attachments[0].bytes, headerless.bytes)
        for combine in [false, true] {
            options.combine = combine; options.attachment = false
            XCTAssertThrowsError(try PatchMailPreparation.messages(patches: [headerless], options: options))
        }
        XCTAssertThrowsError(try SerialPatch(file: location(), bytes: Data()))
        XCTAssertThrowsError(try SerialPatch(file: URL(string: "https://example.invalid/patch")!, bytes: Data([1])))
        XCTAssertThrowsError(try PatchMailPreparation.messages(patches: [], options: options))
        let patch = try SerialPatch(file: location(), bytes: Data("Subject: valid\n\nbody".utf8))
        for value in ["one\r\nBcc: somebody", "one\nother", "bad\0header"] {
            var invalid = PatchMailOptions(); invalid.to = value
            XCTAssertThrowsError(try PatchMailPreparation.messages(patches: [patch], options: invalid))
            invalid.to = ""; invalid.cc = value
            XCTAssertThrowsError(try PatchMailPreparation.messages(patches: [patch], options: invalid))
            invalid.cc = ""; invalid.combine = true; invalid.subject = value
            XCTAssertThrowsError(try PatchMailPreparation.messages(patches: [patch], options: invalid))
        }
        XCTAssertEqual(try PatchMailPreparation.messages(patches: [patch], options: PatchMailOptions())[0].to, [], "Mail-client review can fill recipients, matching MAPI")
        var ignored = PatchMailOptions(); ignored.subject = "ignored\nsubject"
        XCTAssertEqual(try PatchMailPreparation.messages(patches: [patch], options: ignored)[0].subject, "valid")
    }

    func testFileGuardsAndAttachmentSnapshotSurvivesFileReplacement() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("TurtleGitSendPatch-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("' --雪\n.patch"), bytes = Data("Subject: snapshot\n\nbody\n".utf8)
        try bytes.write(to: file)
        let alias = root.appendingPathComponent("alias.patch")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: file)
        let linked = try SerialPatch(file: alias)
        XCTAssertEqual(linked.bytes, bytes); XCTAssertEqual(linked.file, alias)
        var options = PatchMailOptions(); options.attachment = true
        let captured = try PatchMailPreparation.messages(files: [file, file], options: options)
        try Data("replacement".utf8).write(to: file)
        XCTAssertEqual(captured.count, 2, "Duplicate checked paths retain source list order")
        XCTAssertEqual(captured.map { $0.attachments[0].bytes }, [bytes, bytes])
        try FileManager.default.removeItem(at: file)
        XCTAssertEqual(captured[0].attachments[0].bytes, bytes)
        XCTAssertThrowsError(try PatchMailPreparation.messages(files: [file], options: options))
        XCTAssertThrowsError(try SerialPatch(file: alias), "Dangling symlink is unreadable")
        XCTAssertThrowsError(try SerialPatch(file: root))
        try Data().write(to: file); XCTAssertThrowsError(try SerialPatch(file: file))
        let sparse = root.appendingPathComponent("too-large.patch")
        XCTAssertTrue(FileManager.default.createFile(atPath: sparse.path, contents: nil))
        let handle = try FileHandle(forWritingTo: sparse); defer { try? handle.close() }
        try handle.truncate(atOffset: UInt64(Int32.max))
        XCTAssertThrowsError(try SerialPatch(file: sparse), "Source INT_MAX limit is checked before reading")
    }

    func testBinaryAndNonUTF8BodyBytesAreNotReencoded() throws {
        var bytes = Data("Subject: binary\n\n".utf8); let raw = Data([0, 255, 128, 13, 10, 195, 169]); bytes.append(raw)
        let patch = try SerialPatch(file: location(), bytes: bytes)
        let single = try PatchMailPreparation.messages(patches: [patch], options: PatchMailOptions())
        XCTAssertEqual(single[0].body, raw)
        var combined = PatchMailOptions(); combined.combine = true
        XCTAssertEqual(try PatchMailPreparation.messages(patches: [patch], options: combined)[0].body, bytes)
    }

    func testRealGitCombinedInlineMailboxAppliesBinarySeriesWithoutMutatingSource() async throws {
        let (root, _, _) = try await GitPatchTests().fixture()
        let repo = GitRepository(root: root, executable: URL(fileURLWithPath: ProcessInfo.processInfo.environment["TURTLEGIT_SEND_PATCH_TEST_GIT"] ?? "/usr/bin/git"))
        defer { try? FileManager.default.removeItem(at: root) }
        let base = try await repo.run(["rev-parse", "HEAD"]).text.trimmingCharacters(in: .newlines)
        for (number, contents) in [(1, Data([0, 255, 10, 1])), (2, Data([0, 128, 10, 2]))] {
            try contents.write(to: root.appendingPathComponent("binary.dat")); try await repo.stage(["binary.dat"])
            _ = try await repo.commit(message: "Binary \(number) 雪\n\nmessage body")
        }
        let folder = root.appendingPathComponent("mail\n雪")
        _ = try await repo.formatPatch(selection: .range(from: base, to: "HEAD"), to: folder)
        let files = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil).sorted { $0.path < $1.path }
        XCTAssertEqual(files.count, 2)
        let head = try await repo.run(["rev-parse", "HEAD"]).stdout, index = try Data(contentsOf: root.appendingPathComponent(".git/index"))
        var options = PatchMailOptions(); options.combine = true; options.subject = "Series"
        let messages = try PatchMailPreparation.messages(files: files, options: options)
        let mailbox = root.appendingPathComponent("combined.mbox"); try messages[0].body.write(to: mailbox)
        XCTAssertEqual(messages[0].body, try files.reduce(into: Data()) { $0.append(try Data(contentsOf: $1)) })
        let receiverRoot = root.appendingPathComponent("receiver")
        _ = try await repo.run(["clone", "--no-local", "--", root.path, receiverRoot.path])
        let receiver = GitRepository(root: receiverRoot, executable: repo.executable)
        for (key, value) in [("user.name", "Patch QA"), ("user.email", "patch@example.invalid"), ("commit.gpgsign", "false"), ("core.hooksPath", "/dev/null")] { _ = try await receiver.run(["config", key, value]) }
        _ = try await receiver.run(["checkout", "--detach", base]); _ = try await receiver.run(["am", "--", mailbox.path])
        let expected = try await repo.run(["rev-parse", "HEAD^{tree}"]).stdout, actual = try await receiver.run(["rev-parse", "HEAD^{tree}"]).stdout
        XCTAssertEqual(actual, expected)
        // Exercise actual serialized mail with Git's MIME reader, not just our
        // preparation bytes. Apply separate inline messages in checked order.
        _ = try await receiver.run(["checkout", "--detach", base])
        let separate = try PatchMailPreparation.messages(files: files, options: PatchMailOptions())
        var serialized: [String] = []
        for (number, message) in separate.enumerated() {
            let mail = root.appendingPathComponent("serialized-\(number).eml")
            try PatchMailMIME.data(message: message,
                sender: PatchMailSender(name: "Patch QA", email: "patch@example.invalid")).write(to: mail)
            serialized.append(mail.path)
        }
        _ = try await receiver.run(["am", "--"] + serialized)
        let mimeTree = try await receiver.run(["rev-parse", "HEAD^{tree}"]).stdout
        XCTAssertEqual(mimeTree, expected)
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(".git/index")), index)
        let after = try await repo.run(["rev-parse", "HEAD"]).stdout; XCTAssertEqual(after, head)
    }
}
