// SPDX-License-Identifier: GPL-2.0-or-later
import AppKit
import TurtleGitCore

@MainActor @main struct BackendMetadataVerification {
    struct Failure:Error,LocalizedError {let message:String;var errorDescription:String?{message}}
    static func require(_ condition:Bool,_ message:String)throws{if !condition{throw Failure(message:message)}}
    static func wait(_ condition:()->Bool)async throws{for _ in 0..<3000{if condition(){return};try await Task.sleep(nanoseconds:10_000_000)};throw Failure(message:"Metadata native timeout")}
    static func quote(_ s:String)->String{"'"+s.replacingOccurrences(of:"'",with:"'\\''")+"'"}
    static func offscreen(_ w:NSWindow?){w?.isReleasedWhenClosed=false;w?.alphaValue=0;w?.setFrameOrigin(.init(x:-12000,y:-12000));w?.orderFront(nil)}
    static func main()async {
        _ = NSApplication.shared;NSApp.setActivationPolicy(.prohibited)
        let root=URL(fileURLWithPath:CommandLine.arguments[1]),git=URL(fileURLWithPath:CommandLine.arguments[2]),mode=CommandLine.arguments[3]
        let suite="TurtleGit.Metadata."+UUID().uuidString
        let prefs=UserDefaults(suiteName:suite)!
        var push:PushWindowController?,fetch:FetchWindowController?
        let release=root.appendingPathComponent("release"),trace=root.appendingPathComponent("trace"),helper=root.appendingPathComponent("metadata-helper")
        do {
            let cli=GitRepository(root:root,executable:git,libgit2Configuration:.init(enabled:false))
            _ = try await cli.run(["init","-b","main"])
            for(k,v) in [("user.name","Metadata QA"),("user.email","qa@example.invalid"),("core.precomposeunicode","false")] {_ = try await cli.run(["config",k,v])}
            _ = try await cli.run(["commit","--allow-empty","-m","base"])
            _ = try await cli.run(["tag","-a","annotated","-m","tag body"])
            let nfc="caf\u{e9}",nfd="cafe\u{301}"
            for n in [nfc,nfd] {_ = try await cli.run(["-c","core.precomposeunicode=false","remote","add",n,"https://example.invalid/"+n])}
            let runtime=URL(fileURLWithPath:#filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("build/libgit2-runtime/LibGit2/bin/turtlegit-libgit2")
            let script="#!/bin/sh\nprintf '%s\\n' \"$@\" >> "+quote(trace.path)+"\n"+"while [ ! -f "+quote(release.path)+" ]; do /bin/sleep 0.02; done\n"+"exec "+quote(runtime.path)+" \"$@\"\n"
            try Data(script.utf8).write(to:helper);try FileManager.default.setAttributes([.posixPermissions:0o700],ofItemAtPath:helper.path)
            prefs.set(true,forKey:"UseLibgit2");prefs.set(0,forKey:"UseLibgit2_mask");prefs.set(false,forKey:"EnableGravatar");prefs.set(false,forKey:"ConfirmKillProcess")
            let repo=GitRepository(root:root,executable:git,libgit2Configuration:.init(enabled:true,mask:0,helperURL:helper))
            let config=try Data(contentsOf:root.appendingPathComponent(".git/config")),head=try await cli.run(["rev-parse","HEAD"]).stdout
            let owner=PushWindowController(repository:repo,access:nil,preferences:prefs);push=owner;offscreen(owner.window);owner.model.load()
            if mode=="lifetime" {
                try await wait{FileManager.default.fileExists(atPath:trace.path)}
                owner.model.invalidate();owner.window?.close();try Data().write(to:release)
                try await wait{!owner.serviceWorkPending}
                try require(owner.model.references.isEmpty && owner.model.remotes.isEmpty,"Retired catalog reply published")
            } else {
                try await wait{FileManager.default.fileExists(atPath:trace.path)}
                // Mutating the private preference during accepted preparation must
                // not switch the second catalog read to a different backend.
                prefs.set(false,forKey:"UseLibgit2");try Data().write(to:release)
                try await wait{!owner.model.busy && !owner.model.preparing && !owner.serviceWorkPending}
                try require(owner.model.error==nil,"Push catalog failed: "+(owner.model.error ?? ""))
                try require(Set(owner.model.remotes.map{Data($0.utf8)})==Set([nfc,nfd].map{Data($0.utf8)}),"Canonical distinct remote catalog collapsed")
                try require(owner.model.references.contains{$0.name=="refs/heads/main"} && owner.model.references.contains{$0.name=="refs/tags/annotated"},"Native source picker lost branch/tag")
                prefs.set(true,forKey:"UseLibgit2")
                let child=FetchWindowController(repository:repo,access:nil,isPull:false,preferences:prefs);fetch=child;offscreen(child.window);child.model.load()
                try await wait{!child.model.busy && !child.model.preparing && !child.serviceWorkPending}
                try require(child.model.error==nil,"Fetch catalog failed")
                let calls=try String(contentsOf:trace,encoding:.utf8)
                try require(calls.contains("turtlegit-configured-remotes") && calls.contains("turtlegit-checkout-refs"),"Native settings failed to dispatch master catalog helpers")
            }
            let finalHead=try await cli.run(["rev-parse","HEAD"]).stdout
            try require(config==Data(contentsOf:root.appendingPathComponent(".git/config")) && head==finalHead,"Catalog read mutated repository")
            fetch?.model.invalidate();fetch?.window?.close();push?.model.invalidate();push?.window?.close()
            try await wait{!(push?.serviceWorkPending ?? false) && !(fetch?.serviceWorkPending ?? false)}
            prefs.removePersistentDomain(forName:suite);print("PASS: backend metadata "+mode)
        } catch {
            try? Data().write(to:release)
            for w in [push?.window,fetch?.window].compactMap({$0}) {if let sheet=w.attachedSheet{w.endSheet(sheet,returnCode:.abort);sheet.close()};w.close()}
            push?.model.invalidate();fetch?.model.invalidate();try? await wait{!(push?.serviceWorkPending ?? false) && !(fetch?.serviceWorkPending ?? false)}
            prefs.removePersistentDomain(forName:suite);fputs("FAIL: \(error)\n",stderr);exit(1)
        }
    }
}
