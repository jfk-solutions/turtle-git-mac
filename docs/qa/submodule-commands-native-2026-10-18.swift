import AppKit
import TurtleGitCore

extension PrimaryCommandsVerification {
    @MainActor static func verifySubmoduleCommands() async throws {
        let container=URL(fileURLWithPath:CommandLine.arguments[1]),git=URL(fileURLWithPath:CommandLine.arguments[2])
        let root=container.appendingPathComponent("super"),sourceRoot=container.appendingPathComponent("source")
        let wrapper=container.appendingPathComponent("private-git")
        func quote(_ value:String)->String {"'"+value.replacingOccurrences(of:"'",with:"'\\''")+"'"}
        try ("#!/bin/sh\nexec "+quote(git.path)+" -c protocol.file.allow=always \"$@\"\n").write(to:wrapper,atomically:true,encoding:.utf8)
        try FileManager.default.setAttributes([.posixPermissions:0o755],ofItemAtPath:wrapper.path)
        for folder in [root,sourceRoot] {try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)}
        let repo=GitRepository(root:root,executable:wrapper),source=GitRepository(root:sourceRoot,executable:wrapper)
        for candidate in [repo,source] {
            _ = try await candidate.run(["init","-b","main"])
            for (key,value) in [("user.name","Submodule command QA"),("user.email","submodule@example.invalid"),("commit.gpgsign","false"),("core.hooksPath","/dev/null"),("core.precomposeunicode","false")] {_ = try await candidate.run(["config",key,value])}
        }
        let sourceFile=sourceRoot.appendingPathComponent("file.txt")
        try Data("first\n".utf8).write(to:sourceFile);try await source.stage(["file.txt"]);_ = try await source.commit(message:"first")
        let base=try await source.rebaseCommit("HEAD")
        try Data("second\n".utf8).write(to:sourceFile);try await source.stage(["file.txt"]);_ = try await source.commit(message:"second")
        let tip=try await source.rebaseCommit("HEAD")
        let first="libs/雪[*]",second="other"
        for (name,path) in [("first",first),("second",second)] {
            _ = try await repo.run(["submodule","add","--name",name,"--",sourceRoot.path,path])
            _ = try await GitRepository(root:root.appendingPathComponent(path),executable:wrapper).run(["checkout",base.hash])
        }
        let readme=root.appendingPathComponent("README.txt");try Data("super\n".utf8).write(to:readme)
        try await repo.stage([".gitmodules",first,second,"README.txt"]);_ = try await repo.commit(message:"modules")
        let firstRepo=GitRepository(root:root.appendingPathComponent(first),executable:wrapper),secondRepo=GitRepository(root:root.appendingPathComponent(second),executable:wrapper)
        _ = try await firstRepo.run(["checkout",tip.hash]);_ = try await secondRepo.run(["checkout",tip.hash])
        let suite="TurtleGit.SubmoduleCommands."+UUID().uuidString,prefs=UserDefaults(suiteName:suite)!
        defer {prefs.removePersistentDomain(forName:suite)}
        prefs.set(false,forKey:"DownloadAnimation");prefs.set(0,forKey:"AutoCloseGitProgress")
        prefs.set(["https://example.invalid/private-draft.git"],forKey:"SubmoduleAdd.URLHistory")
        var savedOptions=SubmoduleUpdateOptions();savedOptions.recursive=true
        prefs.set(try JSONEncoder().encode(savedOptions),forKey:"SubmoduleUpdate."+root.path+".options")
        let workspace=RepositoryModel(startMonitoring:false,initializePreferences:false,repositoryFactory:{GitRepository(root:$0,executable:wrapper)},snapshotWriter:{_ in true},comparisonMarks:WorkingComparisonMarkStore(storageURL:container.appendingPathComponent("mark.json")))
        workspace.requiresRepositoryScope=false;workspace.fileComparisonPreferences=prefs;workspace.transportClipboardText={nil}
        var permissionTargets=[[URL]]();workspace.commandLineRepositoryPermission={paths in permissionTargets.append(paths);return RepositoryAccessLease(url:root)}
        func windows<T>(_ type:T.Type)->[T] {NSApp.windows.filter(\.isVisible).compactMap {$0.delegate as? T}}
        func invoke(_ arguments:[String]) {workspace.error=nil;workspace.handleCommandLine(arguments:arguments,currentDirectory:root.path)}
        @MainActor func cleanup() async {
            workspace.stopMonitoringForTermination()
            let adds=windows(SubmoduleAddProgressWindowController.self).map(\.model),updates=windows(SubmoduleUpdateProgressWindowController.self).map(\.model),syncs=windows(SubmoduleSyncWindowController.self).map(\.model)
            for window in NSApp.windows {window.close()}
            for _ in 0..<1000 {
                if !workspace.busy && SubmoduleUpdateWindowModel.activeReads==0 && SubmoduleUpdateProgressWindowModel.activeOperations==0 && adds.allSatisfy({!$0.busy}) && updates.allSatisfy({!$0.busy}) && syncs.allSatisfy({!$0.busy}) {return}
                try? await Task.sleep(nanoseconds:10_000_000)
            }
        }
        do {
            let head=try await repo.rebaseCommit("HEAD")
            invoke(["--command=subadd","--path",readme.path])
            try await wait {!workspace.busy && windows(SubmoduleAddWindowController.self).count==1}
            let add=try requireOne(windows(SubmoduleAddWindowController.self))
            try require(add.model.path.isEmpty && add.model.source=="https://example.invalid/private-draft.git","Add did not use the selected file's directory and owning source history")
            add.model.source=sourceRoot.path;add.model.path="new-entry";add.model.useKey=false
            invoke(["/command:subadd","/path:"+root.appendingPathComponent("libs").path])
            try await wait {!workspace.busy}
            try require(windows(SubmoduleAddWindowController.self).count==1 && add.model.path=="new-entry" && add.model.source==sourceRoot.path && workspace.error?.contains("already open")==true,"Repeated command replaced the Add draft")
            try require(!(try await repo.submoduleUpdatePaths()).contains("new-entry"),"Submodule Add ran before acceptance")
            workspace.error=nil;add.model.apply()
            try await wait {windows(SubmoduleAddProgressWindowController.self).first?.model.busy==false}
            let addProgress=try requireOne(windows(SubmoduleAddProgressWindowController.self))
            try require(addProgress.model.success && !addProgress.model.progressPresentation.animateActivity,"Accepted Add failed or lost progress preferences: "+addProgress.model.output)
            try require((try await repo.submoduleUpdatePaths()).contains("new-entry"),"Accepted Add did not stage its gitlink")
            addProgress.close();try await wait {!workspace.busy}
            let index=try Data(contentsOf:root.appendingPathComponent(".git/index"))
            // Default base is the selected directory's parent, not its child Git root.
            invoke(["--command=subupdate","--path",root.appendingPathComponent(first).path,"--selectedpath",first])
            try await wait {!workspace.busy && windows(SubmoduleUpdateWindowController.self).first?.model.busy==false && windows(SubmoduleUpdateWindowController.self).first?.model.paths.contains(first)==true}
            let update=try requireOne(windows(SubmoduleUpdateWindowController.self))
            try require(update.model.repository.root.path==root.path && update.model.paths==[first] && update.model.selection==[GitReferenceName(first)] && update.model.options.recursive,"Update lost superproject, filter, requested selection or private persisted options: root=\(update.model.repository.root.path), paths=\(update.model.paths), selected=\(update.model.selection), recursive=\(update.model.options.recursive)")
            update.model.options.noFetch=true;update.model.options.force=true
            invoke(["--command=subupdate","--path",root.path,"--bkpath",root.path,"--selectedpath",second])
            try await wait {!workspace.busy}
            try require(windows(SubmoduleUpdateWindowController.self).count==1 && update.model.paths==[first] && update.model.options.force && workspace.error?.contains("already open")==true,"Repeated Update replaced the checked draft/scope")
            try require(try await firstRepo.rebaseCommit("HEAD").hash==tip.hash,"Update ran without acceptance")
            workspace.error=nil;update.model.apply()
            try await wait {windows(SubmoduleUpdateProgressWindowController.self).first?.model.busy==false}
            let progress=try requireOne(windows(SubmoduleUpdateProgressWindowController.self))
            try require(progress.model.success && !progress.model.progressPresentation.animateActivity,"Scoped Update failed or lost progress preferences: "+progress.model.output)
            try require(try await firstRepo.rebaseCommit("HEAD").hash==base.hash,"Update did not restore checked module")
            try require(try await secondRepo.rebaseCommit("HEAD").hash==tip.hash,"Scoped Update changed the unchecked module")
            let parentAfterUpdate=try await repo.rebaseCommit("HEAD")
            try require(try Data(contentsOf:root.appendingPathComponent(".git/index"))==index && parentAfterUpdate.hash==head.hash,"Submodule operations committed parent history or changed its index during Update")
            progress.close();try await wait {!workspace.busy}
            let desired="https://example.invalid/new-first.git"
            _ = try await repo.run(["config","--file",".gitmodules","submodule.first.url",desired])
            let config=try Data(contentsOf:root.appendingPathComponent(".git/config"))
            invoke(["/command:subsync","/path:"+readme.path,"/bkpath:"+root.path])
            try await wait {!workspace.busy && windows(SubmoduleSyncWindowController.self).first?.model.busy==false}
            let skipped=try requireOne(windows(SubmoduleSyncWindowController.self))
            try require(skipped.model.output.contains("No directories") && (try Data(contentsOf:root.appendingPathComponent(".git/config")))==config,"File-only Sync broadened to the whole repository")
            skipped.close();try await wait {!workspace.busy}
            invoke(["--command=subsync","--path",root.appendingPathComponent(first).path])
            try await wait {!workspace.busy && windows(SubmoduleSyncWindowController.self).first?.model.busy==false}
            let sync=try requireOne(windows(SubmoduleSyncWindowController.self))
            try require(sync.model.success && !sync.model.progressPresentation.animateActivity,"Sync failed or lost owning progress settings: "+sync.model.output)
            try require(try await repo.run(["config","submodule.first.url"]).text.trimmingCharacters(in:.whitespacesAndNewlines)==desired,"Sync did not update selected module URL")
            try require(try await secondRepo.run(["config","remote.origin.url"]).text.trimmingCharacters(in:.whitespacesAndNewlines)==sourceRoot.path,"Sync changed an unselected module")
            sync.model.confirmingQuit=true
            invoke(["--command=subsync","--path",root.path,"--bkpath",root.path]);try await wait {!workspace.busy}
            try require(windows(SubmoduleSyncWindowController.self).count==1 && workspace.error?.contains("already running")==true,"Sync replaced an owned operation")
            sync.model.confirmingQuit=false;sync.close();workspace.error=nil
            // A fresh workspace must authorize both selected submodule and discovery base.
            let refused=RepositoryModel(startMonitoring:false,initializePreferences:false,repositoryFactory:{GitRepository(root:$0,executable:wrapper)},snapshotWriter:{_ in true},comparisonMarks:WorkingComparisonMarkStore(storageURL:container.appendingPathComponent("refused-mark.json")))
            refused.requiresRepositoryScope=false;refused.fileComparisonPreferences=prefs
            defer {refused.stopMonitoringForTermination()}
            var requested=[URL]();refused.commandLineRepositoryPermission={paths in requested=paths;return RepositoryAccessLease(url:root.appendingPathComponent(first))}
            refused.handleCommandLine(arguments:["--command=subupdate","--path",root.appendingPathComponent(first).path],currentDirectory:root.path)
            try require(requested.contains(root.appendingPathComponent("libs")) && refused.error != nil && !refused.busy && windows(SubmoduleUpdateWindowController.self).isEmpty,"Submodule-only grant authorized the superproject")
            refused.error=nil;refused.commandLineRepositoryPermission={_ in RepositoryAccessLease(url:root.appendingPathComponent("libs"))}
            refused.handleCommandLine(arguments:["--command=subupdate","--path",root.appendingPathComponent(first).path],currentDirectory:root.path)
            try await wait {!refused.busy}
            try require(refused.error != nil && windows(SubmoduleUpdateWindowController.self).isEmpty,"Discovery-folder grant authorized its ungranted superproject")
            refused.error=nil;refused.commandLineRepositoryPermission={_ in nil}
            refused.handleCommandLine(arguments:["--command=subsync","--path",root.path,"--bkpath",root.path],currentDirectory:root.path)
            try require(!refused.busy && windows(SubmoduleSyncWindowController.self).isEmpty,"Cancelled grant started Sync")
            refused.commandLineRepositoryPermission={_ in RepositoryAccessLease(url:container)}
            refused.handleCommandLine(arguments:["--command=subupdate","--path",sourceRoot.path,"--bkpath",sourceRoot.path],currentDirectory:root.path)
            try await wait {!refused.busy}
            try require(refused.error?.contains("superproject")==true && windows(SubmoduleUpdateWindowController.self).isEmpty,"Missing .gitmodules did not stop superproject discovery")
            try require(permissionTargets.count==1,"Existing authorized workspace grant was not reused")
            await cleanup()
            try require(SubmoduleUpdateWindowModel.activeReads==0 && SubmoduleUpdateProgressWindowModel.activeOperations==0 && !NSApp.windows.contains(where:{$0.isVisible}),"Submodule command windows/operations remained open")
            print("PASS: submodule command family: Add directory/history/draft and actual gitlink; Update parent discovery/filter/preselection/draft and actual selected checkout; file-only Sync skips all, selected Sync updates URL, active operation refusal; private preferences, unchanged parent HEAD/index during Update; cancelled/insufficient grants and missing superproject refuse; owned windows and operations closed")
        } catch {fputs("Submodule command state: busy=\(workspace.busy) error=\(workspace.error ?? "nil") root=\(workspace.root?.path ?? "nil")\n",stderr);await cleanup();throw error}
    }
}
