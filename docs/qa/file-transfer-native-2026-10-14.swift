import AppKit
import TurtleGitCore
@main struct FileTransferVerification {
    struct Failure: Error, CustomStringConvertible {let description: String}
    static func require(_ condition: Bool,_ message: String) throws {if !condition {throw Failure(description:message)}}
    @MainActor static func wait(_ condition: ()->Bool) async throws {for _ in 0..<2500 {if condition(){return};try await Task.sleep(nanoseconds:10_000_000)};throw Failure(description:"File transfer timeout")}
    @MainActor static func main() async {do {try await verify()}catch{fputs("File transfer failed: \(error)\n",stderr);exit(1)}}
    @MainActor static func verify() async throws {
        let root=URL(fileURLWithPath:CommandLine.arguments[1]),git=URL(fileURLWithPath:CommandLine.arguments[2]),repo=GitRepository(root:root,executable:git)
        _ = try await repo.run(["init","-b","main"])
        for (key,value) in [("user.name","Copy QA"),("user.email","qa@example.invalid"),("commit.gpgsign","false"),("core.hooksPath","/dev/null")] {_ = try await repo.run(["config",key,value])}
        let source=root.deletingLastPathComponent().appendingPathComponent("CopyNative-"+UUID().uuidString);try FileManager.default.createDirectory(at:source,withIntermediateDirectories:true);defer{try? FileManager.default.removeItem(at:source)}
        let suite="TurtleGit.CopyQA."+UUID().uuidString,prefs=UserDefaults(suiteName:suite)!;prefs.set(false,forKey:"ConfirmKillProcess");defer{prefs.removePersistentDomain(forName:suite)}
        ProgressActionLog.install(store:ActionLogStore(storageURL:source.appendingPathComponent("actions.log")),preferences:prefs)
        let filename="-雪\n[*].txt",file=source.appendingPathComponent(filename);try Data("copied\n".utf8).write(to:file)
        let pasteboard=NSPasteboard.withUniqueName();defer{pasteboard.releaseGlobally()};FileTransferClipboard.copy([file],pasteboard:pasteboard)
        try require(FileTransferClipboard.urls(pasteboard).map(\.path)==[file.path],"File URL clipboard lost literal name")
        let first=FileCopyWindowController(repository:repo,access:nil,sources:[file],preferences:prefs);defer{first.close()};first.window?.alphaValue = 0;first.model.run();try await wait{!first.model.busy}
        let staged=try await repo.run(["show",":"+filename]).text
        try require(first.model.copied==1 && !first.model.failed && staged=="copied\n" && String(contentsOf:file)=="copied\n","Copy/Add lost source or staged bytes");first.close()
        // Self-copy opens the actual reusable name sheet; invalid input stays.
        let selfCopy=FileCopyWindowController(repository:repo,access:nil,sources:[root.appendingPathComponent(filename)],preferences:prefs);defer{selfCopy.close()};selfCopy.window?.alphaValue = 0;selfCopy.model.run();try await wait{selfCopy.name != nil}
        let name=selfCopy.name!;name.accept();try await wait{!name.busy && !name.error.stringValue.isEmpty};try require(selfCopy.name === name,"Invalid name closed sheet")
        name.field.stringValue="second 雪.txt";name.accept();try await wait{!selfCopy.model.busy};try require(selfCopy.model.copied==1 && FileManager.default.fileExists(atPath:root.appendingPathComponent("second 雪.txt").path),"Self-copy rename failed");selfCopy.close()
        // Keep stages retained target; overwrite copies and stages actual new data.
        try Data("retained\n".utf8).write(to:root.appendingPathComponent(filename))
        let keep=FileCopyWindowController(repository:repo,access:nil,sources:[file],preferences:prefs);defer{keep.close()};keep.window?.alphaValue = 0;keep.model.collision={_ in .keep};keep.model.run();try await wait{!keep.model.busy}
        let kept=try await repo.run(["show",":"+filename]).text;try require(keep.model.kept==1 && kept=="retained\n","Keep did not add retained contents");keep.close()
        let overwrite=FileCopyWindowController(repository:repo,access:nil,sources:[file],preferences:prefs);defer{overwrite.close()};overwrite.window?.alphaValue = 0;overwrite.model.collision={_ in .overwrite};overwrite.model.run();try await wait{!overwrite.model.busy};try require(overwrite.model.copied==1 && String(contentsOf:root.appendingPathComponent(filename))=="copied\n","Overwrite failed");overwrite.close()
        // Nested repository choices delete only copied metadata or omit its tree.
        let tree=source.appendingPathComponent("tree");for path in ["delete","ignore"] {let sub=tree.appendingPathComponent(path);try FileManager.default.createDirectory(at:sub,withIntermediateDirectories:true);_ = try await GitRepository(root:sub,executable:git).run(["init"]);try Data(path.utf8).write(to:sub.appendingPathComponent("file"))}
        let nested=FileCopyWindowController(repository:repo,access:nil,sources:[tree],preferences:prefs);defer{nested.close()};nested.window?.alphaValue = 0;nested.model.repositoryChoice={$0.path.hasSuffix("/delete") ? .deleteMetadata : .ignore};nested.model.run();try await wait{!nested.model.busy}
        let indexed=try await repo.run(["ls-files","-z"]).stdout
        try require(!nested.model.failed && indexed.range(of:Data("tree/delete/file".utf8)) != nil && indexed.range(of:Data("tree/ignore/file".utf8)) == nil && FileManager.default.fileExists(atPath:tree.appendingPathComponent("delete/.git").path),"Copied metadata choices changed source/staged ignored repo");nested.close()
        let abortSource=source.appendingPathComponent("abort");try FileManager.default.createDirectory(at:abortSource,withIntermediateDirectories:true);_ = try await GitRepository(root:abortSource,executable:git).run(["init"])
        let beforeAbort=try await repo.run(["ls-files","--stage","-z"]).stdout,abort=FileCopyWindowController(repository:repo,access:nil,sources:[abortSource],preferences:prefs);defer{abort.close()};abort.window?.alphaValue = 0;abort.model.repositoryChoice={_ in .abort};abort.model.run();try await wait{!abort.model.busy}
        let afterAbort=try await repo.run(["ls-files","--stage","-z"]).stdout;try require(abort.model.cancelled && beforeAbort==afterAbort && FileManager.default.fileExists(atPath:root.appendingPathComponent("abort/.git").path),"Abort lost recoverable copy or staged it");abort.close()
        // Actual Git add stream cancellation leaves copied working file, no stage.
        let helper=source.appendingPathComponent("stream-git"),marker=root.appendingPathComponent("ready")
        let script = #"""
        #!/bin/sh
        if [ "$4" = -c ] && [ "$5" = core.precomposeunicode=false ] && [ "$6" = add ];then
          printf 'Add: 10%%\rAdd: 35%%\r\n'
          : > "$3/ready"
          while :;do /bin/sleep 0.05;done
        fi
        exec "$TG_COPY_GIT" "$@"
        """#
        try Data(script.utf8).write(to:helper);try FileManager.default.setAttributes([.posixPermissions:0o755],ofItemAtPath:helper.path);setenv("TG_COPY_GIT",git.path,1);defer{unsetenv("TG_COPY_GIT")}
        let extra=source.appendingPathComponent("cancelled.txt");try Data("recover\n".utf8).write(to:extra)
        let slow=FileCopyWindowController(repository:GitRepository(root:root,executable:helper),access:nil,sources:[extra],preferences:prefs);defer{slow.close()};slow.window?.alphaValue = 0;let indexBefore=try await repo.run(["ls-files","--stage","-z"]).stdout;slow.model.run()
        try await wait{FileManager.default.fileExists(atPath:marker.path) && slow.model.output.contains("Add: 35%")};try require(TurtleGitApplicationDelegate().applicationShouldTerminate(NSApp) == .terminateCancel,"Quit lost copy operation")
        slow.model.cancel();try await wait{!slow.model.busy && FileCopyWindowModel.activeOperations==0};let indexAfter=try await repo.run(["ls-files","--stage","-z"]).stdout
        try require(slow.model.cancelled && indexAfter==indexBefore && String(contentsOf:root.appendingPathComponent("cancelled.txt"))=="recover\n","Cancellation lost copy recovery or changed index");slow.close()
        let move=FileMoveWindowController(repository:repo,access:nil,paths:[],preferences:prefs);defer{move.close()};move.window?.alphaValue = 0;move.model.loadClipboard([root.appendingPathComponent(filename)]);try await wait{!move.model.busy};try require(move.model.paths==[filename],"Paste Move failed captured file URL read");move.close()
        try require(FileCopyWindowModel.activeOperations==0 && FileMoveWindowModel.activeOperations==0,"Operation owners leaked")
        print("File transfers: private URL clipboard; actual Copy/Add and self-name sheet validation; Keep stages retained bytes; Overwrite; copied repository Delete/Ignore/Abort; real streamed Add cancellation and recoverable working copy; captured Paste Move paths; owned windows closed.")
    }
}
