import AppKit
import TurtleGitCore

@main struct SSHKeyImportVerification {
    static func require(_ condition:Bool) { precondition(condition) }
    @MainActor static func main() async {
        do { try await verify() } catch { fputs("SSH key import failed: \(error)\n",stderr);exit(1) }
    }
    @MainActor static func wait(_ ready:()->Bool) async throws {
        for _ in 0..<1500 { if ready() { return };try await Task.sleep(nanoseconds:10_000_000) }
        throw NSError(domain:"KeyImportFixture",code:1,userInfo:[NSLocalizedDescriptionKey:"Timed out waiting for owned import"])
    }
    @MainActor static func verify() async throws {
        let root=URL(fileURLWithPath:CommandLine.arguments[1])
        let app=URL(fileURLWithPath:FileManager.default.currentDirectoryPath).appendingPathComponent("build/Build/Products/Debug/TurtleGitMac.app")
        let tool=app.appendingPathComponent("Contents/Helpers/PuTTY/bin/puttygen"),keygen=app.appendingPathComponent("Contents/Helpers/OpenSSH/bin/ssh-keygen")
        setenv("TURTLEGIT_QA_PUTTY",tool.path,1)
        let source=root.appendingPathComponent("original.ppk"),phrase=root.appendingPathComponent("fixture-phrase")
        try Data("fixture secret\n".utf8).write(to:phrase)
        let process=Process();process.executableURL=tool
        process.arguments=["-q","-t","ed25519","-C","native original","-o",source.path,"--new-passphrase",phrase.path]
        process.standardInput=FileHandle.nullDevice;process.standardOutput=FileHandle.nullDevice;process.standardError=FileHandle.nullDevice
        try process.run();process.waitUntilExit();require(process.terminationStatus==0);try FileManager.default.removeItem(at:phrase)
        let before=try Data(contentsOf:source),model=SSHKeyImportModel()
        model.converter={ tool };model.keygen={ keygen };model.selectSource(source,access:nil);model.selectFolder(root,access:nil)
        let outputLease=RepositoryAccessLease(url:root)
        model.selectFolder(root,access:outputLease)
        model.oldPassphrase="fixture secret";model.changePassphrase=true;model.newPassphrase="new secret";model.confirmation="mismatch"
        require(!model.valid);model.confirmation="new secret";model.changeComment=true;model.comment="native imported"
        let owner=SSHKeyImportWindowController(model:model);defer { owner.close() }
        owner.window?.alphaValue=0;owner.window?.contentView?.layoutSubtreeIfNeeded();require(model.valid)
        model.convert();require(model.busy && model.oldPassphrase.isEmpty && model.newPassphrase.isEmpty && model.confirmation.isEmpty)
        require(!owner.windowShouldClose(owner.window!) && TurtleGitApplicationDelegate().applicationShouldTerminate(NSApp) == .terminateCancel)
        model.selectFolder(root.appendingPathComponent("late"),access:nil);require(model.folder==root)
        try await wait { !model.busy };require(model.error==nil && model.result?.publicText.contains("native imported")==true)
        require(try Data(contentsOf:source)==before)
        let receiving=SSHKeyGenerationModel()
        receiving.acceptImported(model.result!,access:model.resultAccess)
        require(receiving.folder == root && receiving.hasDestinationAccess(model.result!.privateKey))
        for theme in [NSAppearance.Name.aqua,.darkAqua] { owner.window?.appearance=NSAppearance(named:theme);owner.window?.contentView?.layoutSubtreeIfNeeded() }
        owner.close();require(model.retired);model.convert();require(!model.busy)
        let generator=SSHKeyGenerationWindowController();generator.window?.alphaValue=0;defer { generator.close() }
        generator.model.loadExisting();try await wait { generator.importController != nil }
        require(generator.model.childActive && !generator.windowShouldClose(generator.window!))
        generator.close();try await wait { generator.importController==nil }
        require(!generator.model.active)
        let wrapper=root.appendingPathComponent("delayed-putty")
        try """
        #!/bin/sh
        : > "$0.started"
        /bin/sleep 30
        exec "${TURTLEGIT_QA_PUTTY:?}" "$@"

        """.write(to:wrapper,atomically:true,encoding:.utf8)
        try FileManager.default.setAttributes([.posixPermissions:0o755],ofItemAtPath:wrapper.path)
        let cancelled=SSHKeyImportModel();cancelled.converter={ wrapper };cancelled.keygen={ keygen }
        cancelled.selectSource(source,access:nil);cancelled.selectFolder(root,access:nil);cancelled.filename="cancelled";cancelled.oldPassphrase="fixture secret"
        var callbacks=0;cancelled.imported={ _ in callbacks += 1 }
        let cancelledOwner=SSHKeyImportWindowController(model:cancelled);cancelledOwner.window?.alphaValue=0;cancelled.convert()
        try await wait { FileManager.default.fileExists(atPath:wrapper.path+".started") }
        cancelledOwner.close();require(SSHKeyImportModel.activeOperations==1 && TurtleGitApplicationDelegate().applicationShouldTerminate(NSApp) == .terminateCancel)
        try await wait { !cancelled.busy && SSHKeyImportModel.activeOperations==0 }
        require(cancelled.error==nil && cancelled.result==nil && callbacks==0)
        require(!FileManager.default.fileExists(atPath:root.appendingPathComponent("cancelled").path))
        require(try Data(contentsOf:source)==before)
        require(try FileManager.default.contentsOfDirectory(atPath:root.path).allSatisfy { !$0.hasPrefix("tg-key-import-") })
        print("SSH key import: real encrypted conversion, passphrase/comment drafts, secure-field clearing, captured folder, result, theme layout, parent/child ownership, retired callbacks, live cancellation/Quit and staging cleanup passed. Original key retained; owned windows closed.")
    }
}
