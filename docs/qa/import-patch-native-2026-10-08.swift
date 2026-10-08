import AppKit
import SwiftUI
import TurtleGitCore

@main struct ImportPatchVerification {
    @MainActor static func settle(_ model: ImportPatchWindowModel) async throws {
        for _ in 0..<1000 {
            if !model.busy && !model.closing && !model.openingViewer && !model.composingMail { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        fatalError("Import did not finish")
    }
    @MainActor static func fixture(_ directory: URL, _ git: URL, conflict: Bool = false) async throws -> (GitRepository, [URL]) {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let repo = GitRepository(root: directory, executable: git)
        _ = try await repo.run(["init", "-b", "main"])
        _ = try await repo.run(["config", "user.name", "Importer"]); _ = try await repo.run(["config", "user.email", "importer@example.invalid"])
        _ = try await repo.run(["config", "commit.gpgsign", "false"]); _ = try await repo.run(["config", "core.hooksPath", "/dev/null"])
        try Data("base\n".utf8).write(to: directory.appendingPathComponent("file")); try await repo.stage(["file"]); _ = try await repo.commit(message: "base")
        _ = try await repo.run(["switch", "-c", "feature"])
        var patches: [URL] = []
        for (index, file) in ["file", "other"].enumerated() {
            try Data("feature\n".utf8).write(to: directory.appendingPathComponent(file)); try await repo.stage([file])
            _ = try await repo.run(["-c", "user.name=Author 雪", "-c", "user.email=author@example.invalid", "commit", "-m", "Feature \(index)"])
            let patch = directory.appendingPathComponent("--mail 雪 \(index).patch")
            try await repo.run(["format-patch", "-1", "--stdout", "HEAD"]).stdout.write(to: patch); patches.append(patch)
        }
        _ = try await repo.run(["switch", "main"])
        if conflict { try Data("ours\n".utf8).write(to: directory.appendingPathComponent("file")); try await repo.stage(["file"]); _ = try await repo.commit(message: "ours") }
        return (repo, patches)
    }
    @MainActor static func nativeTable(_ view: NSView) -> NSTableView? {
        if let table = view as? NSTableView { return table }
        return view.subviews.compactMap { nativeTable($0) }.first
    }
    @MainActor static func main() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let root = URL(fileURLWithPath: CommandLine.arguments[1]), git = URL(fileURLWithPath: CommandLine.arguments[2])
        let (repo, patches) = try await fixture(root.appendingPathComponent("batch"), git)
        let controller = ImportPatchWindowController(repository: repo, access: nil), model = controller.model
        // Prevent production error sheets. The layout host remains hidden and
        // uses its own preferences; no main app or user preference store runs.
        controller.window?.contentViewController = nil
        let suite = "TurtleGit.ImportPatch.QA." + UUID().uuidString, prefs = UserDefaults(suiteName: suite)!
        defer { prefs.removePersistentDomain(forName: suite); prefs.synchronize(); model.invalidate(); controller.close() }
        let host = NSHostingView(rootView: ImportPatchDialog(model: model).defaultAppStorage(prefs))
        let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 800, height: 620), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = host
        defer { window.contentView = nil; window.close() }
        model.add(patches + [patches[0]])
        let ids = model.items.map(\.id)
        model.selection = [ids[1]]; model.move(-1); precondition(model.items.map(\.id) == [ids[1], ids[0], ids[2]])
        model.move(1); precondition(model.items.map(\.id) == ids)
        model.selection = [ids[0], ids[1]]; model.move(-1); precondition(model.items.map(\.id) == ids)
        model.check(ids[2], false); precondition(!model.items[2].checked)
        model.selection = [ids[0]]
        for _ in 0..<30 { host.layoutSubtreeIfNeeded(); try await Task.sleep(nanoseconds: 10_000_000) }
        precondition(nativeTable(host)?.numberOfRows == 3 && model.preview.contains("Feature 0"))
        precondition(model.options.threeWay && model.options.ignoreSpaceChange && model.options.keepCR && !model.options.signOff)
        model.options.signOff = true; var refreshes = 0; model.onChanged = { _ in refreshes += 1 }
        model.apply(); precondition(model.busy)
        model.remove(); model.add(patches); model.check(ids[0], false); model.move(1)
        precondition(model.items.map(\.id) == ids && model.items[0].checked)
        try await settle(model)
        precondition(model.error == nil && model.finished && model.items.map(\.state) == [.success, .success, .skipped] && refreshes >= 2)
        let message = try await repo.run(["show", "-s", "--format=%an%n%B", "HEAD"]).text
        precondition(message.contains("Author 雪") && message.contains("Signed-off-by: Importer <importer@example.invalid>"))
        let count = try await repo.run(["rev-list", "--count", "HEAD"]).text; precondition(count.trimmingCharacters(in: .whitespacesAndNewlines) == "3")
        host.layoutSubtreeIfNeeded(); precondition(model.tab == 1)
        for action in MailPatchRecovery.allCases {
            let (conflicted, files) = try await fixture(root.appendingPathComponent(action.rawValue), git, conflict: true)
            let m = ImportPatchWindowModel(repository: conflicted, access: nil); defer { m.invalidate() }
            m.add(files); m.apply(); try await settle(m)
            precondition(m.items[0].state == .failed && m.items[1].state == .pending)
            let active = try await conflicted.mailPatchSession(); precondition(active == .applying)
            if action == .resolved { try Data("resolved\n".utf8).write(to: conflicted.root.appendingPathComponent("file")); try await conflicted.stage(["file"]) }
            m.chooseRecovery = { action }
            if action == .abort { m.onChanged = { _ in m.requestStop() } }
            m.apply(); try await settle(m)
            let session = try await conflicted.mailPatchSession(); precondition(session == .none)
            if action == .abort { precondition(m.items.map(\.state) == [.pending, .pending] && m.stopRequested) }
            else { precondition(m.finished && m.items[0].state == (action == .skip ? .skipped : .success) && m.items[1].state == .success) }
        }
        let (closingRepo, closeFiles) = try await fixture(root.appendingPathComponent("close"), git, conflict: true)
        let closing = ImportPatchWindowModel(repository: closingRepo, access: nil); defer { closing.invalidate() }
        closing.add(closeFiles); closing.apply(); try await settle(closing)
        var closes = 0; closing.close = { closes += 1 }
        closing.chooseClose = { .cancel }; closing.requestClose(); try await settle(closing); precondition(closes == 0)
        closing.chooseClose = { .keep }; closing.requestClose(); try await settle(closing); precondition(closes == 1)
        let retained = try await closingRepo.mailPatchSession(); precondition(retained == .applying)
        closing.chooseClose = { .abort }; closing.requestClose(); try await settle(closing); precondition(closes == 2)
        let cleared = try await closingRepo.mailPatchSession(); precondition(cleared == .none)

        let (slow, slowFiles) = try await fixture(root.appendingPathComponent("stop"), git)
        let hooks = slow.root.appendingPathComponent("hooks"); try FileManager.default.createDirectory(at: hooks, withIntermediateDirectories: true)
        let hook = hooks.appendingPathComponent("applypatch-msg")
        try Data("#!/bin/sh\ntouch hook-started\nsleep 1\n".utf8).write(to: hook)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: hook.path)
        _ = try await slow.run(["config", "core.hooksPath", hooks.path])
        let stopping = ImportPatchWindowModel(repository: slow, access: nil); defer { stopping.invalidate() }
        stopping.add(slowFiles); var stoppedClose = false; stopping.close = { stoppedClose = true }; stopping.apply()
        for _ in 0..<500 {
            if FileManager.default.fileExists(atPath: slow.root.appendingPathComponent("hook-started").path) { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        precondition(FileManager.default.fileExists(atPath: slow.root.appendingPathComponent("hook-started").path))
        stopping.requestClose(); precondition(stopping.busy && stopping.stopRequested && !stoppedClose)
        stopping.options.signOff = true // The active batch retains its option snapshot.
        try await settle(stopping)
        precondition(stopping.items.map(\.state) == [.success, .pending] && !stoppedClose)
        let stoppedMessage = try await slow.run(["show", "-s", "--format=%B", "HEAD"]).text
        precondition(!stoppedMessage.contains("Signed-off-by"))
        let context = ImportPatchWindowModel(repository: repo, access: nil); defer { context.invalidate() }
        let utf16 = root.appendingPathComponent("UTF16 雪.patch")
        let bytes = Data([0xff, 0xfe]) + "diff --git a/雪 b/雪\n+Unicode\n".data(using: .utf16LittleEndian)!
        try bytes.write(to: utf16)
        context.add(patches + [utf16]); let contextIDs = context.items.map(\.id)
        precondition(context.contextActions([]).isEmpty && context.contextActions([UUID()]).isEmpty)
        precondition(context.contextActions([contextIDs[0]]) == [.viewPatch, .sendMail])
        precondition(context.contextActions([contextIDs[0], contextIDs[1]]) == [.sendMail])
        var viewed: Data?, viewedTitle = "", usedAlternate = false
        context.showPatch = { data, title, alternate in
            viewed = data; viewedTitle = title; usedAlternate = alternate
            let readOnly = PatchWindowModel(repository: repo, access: nil); readOnly.setReadOnlyDiff(data)
            precondition(readOnly.readOnly && readOnly.exportDocument.bytes == bytes && !readOnly.canApplyHunks && !readOnly.canApplyLines)
        }
        context.viewPatch([contextIDs[2]], alternate: true)
        precondition(context.openingViewer && !context.editable && context.contextActions([contextIDs[0]]).isEmpty)
        context.selection = [contextIDs[0]]; context.remove(); context.add(patches)
        precondition(context.items.count == 3)
        try await settle(context); precondition(viewed == bytes && viewedTitle == utf16.lastPathComponent && usedAlternate)
        var attachments: [URL] = [], completeMail: ((String?) -> Void)?
        context.composeMail = { files, completion in attachments = files; completeMail = completion }
        context.sendMail([contextIDs[2], contextIDs[0]])
        precondition(context.composingMail && attachments == [patches[0], utf16] && !context.editable)
        context.requestClose(); context.apply(); context.remove(); precondition(!context.busy && !context.closing && context.items.count == 3)
        completeMail?("Mail fixture failed"); completeMail = nil
        precondition(!context.composingMail && context.error == "Mail fixture failed")
        context.error = nil
        context.showPatch = { _, _, _ in throw MailPatchFailure.file }
        context.viewPatch([contextIDs[0]], alternate: false); try await settle(context)
        precondition(!context.openingViewer && context.error != nil && context.editable)
        context.viewPatch([contextIDs[0], contextIDs[1]], alternate: false); precondition(!context.openingViewer)
        print("PASS: source context selection policy; exact UTF-16 viewer bytes/title/Shift handoff and read-only export; viewer/mail mutation guards; ordered composition attachments; failure recovery. Injected handoffs, no external app or mail service invoked; native menu gestures remain unverified.")
        precondition(RepositoryAction.importPatch.icon == .patch && RepositoryAction.importPatch.requiresWorkingTree)
        print("PASS: hidden native patch table/preview; order, check, fixed batch options and mutation guards; two real mail commits/signoff; retained conflict cursor Abort/Skip/Resolved; close Cancel/Keep/Abort; real hook stop finishes current command without closing; original patch icon; no main app")
    }
}
