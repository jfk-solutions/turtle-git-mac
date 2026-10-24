// SPDX-License-Identifier: GPL-2.0-or-later
import AppKit
import TurtleGitCore

@MainActor enum HistoricalBisectVerification {
    struct Failure:Error,CustomStringConvertible {let description:String}
    static func require(_ value:Bool,_ message:String)throws {if !value {throw Failure(description:message)}}
    static func wait(_ ready:()->Bool)async throws {
        for _ in 0..<3000 {if ready(){return};try await Task.sleep(nanoseconds:10_000_000)}
        throw Failure(description:"Historical Bisect native request did not settle")
    }
    static func quote(_ value:String)->String {"'"+value.replacingOccurrences(of:"'",with:"'\\''")+"'"}
    static func verify(base:URL,git:URL)async throws {
        let root=base.appendingPathComponent("bisect-repository")
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        let cli=GitRepository(root:root,executable:git,askpass:nil,libgit2Configuration:.init(enabled:false))
        _=try await cli.run(["init","--template=","-b","main"])
        for (key,value) in [("user.name","Historical Bisect QA"),("user.email","historical@example.invalid"),("core.hooksPath","/dev/null"),("commit.gpgsign","false")] {_=try await cli.run(["config",key,value])}
        var commits=[String]()
        for number in 0..<3 {
            try Data("revision \(number)\n".utf8).write(to:root.appendingPathComponent("file.txt"))
            try await cli.stage(["file.txt"]);_=try await cli.commit(message:"revision \(number)")
            commits.append(try await cli.run(["rev-parse","HEAD"]).text.trimmingCharacters(in:.newlines))
        }
        _=try await cli.run(["tag","historical-tag"])
        let helper=base.appendingPathComponent("bisect-helper"),trace=base.appendingPathComponent("bisect-trace")
        let hold=base.appendingPathComponent("bisect-hold"),started=base.appendingPathComponent("bisect-started"),release=base.appendingPathComponent("bisect-release")
        let resource=base.appendingPathComponent("bisect-owned-resource")
        try Data().write(to:resource)
        let runtime=URL(fileURLWithPath:FileManager.default.currentDirectoryPath).appendingPathComponent("build/libgit2-runtime/LibGit2/bin/turtlegit-libgit2")
        let script="""
        #!/bin/sh
        exec 9< \(quote(resource.path))
        printf '%s\\n' "$*" >> \(quote(trace.path))
        if test -f \(quote(hold.path)); then
          : > \(quote(started.path))
          while ! test -f \(quote(release.path)); do /bin/sleep .02; done
        fi
        exec \(quote(runtime.path)) "$@"
        """
        try Data(script.utf8).write(to:helper)
        try FileManager.default.setAttributes([.posixPermissions:0o700],ofItemAtPath:helper.path)
        let suite="TurtleGit.HistoricalBisect."+UUID().uuidString,prefs=UserDefaults(suiteName:suite)!
        prefs.set(true,forKey:"UseLibgit2");prefs.set(0,forKey:"UseLibgit2_mask");prefs.set(0,forKey:"AutoCloseGitProgress");prefs.set(false,forKey:"ConfirmKillProcess")
        let repository=GitRepository(root:root,executable:git,askpass:nil,libgit2Configuration:.init(enabled:false,mask:0,helperURL:helper))
        let model=BisectWindowModel(repository:repository,access:RepositoryAccessLease(url:root),preferences:prefs)
        defer {try? Data().write(to:release);model.retire();prefs.removePersistentDomain(forName:suite)}
        model.load(good:commits[0],bad:commits[2],requireStart:true)
        prefs.set(false,forKey:"UseLibgit2")
        try await wait {!model.busy && !model.hasPendingWork}
        let calls=(try? String(contentsOf:trace,encoding:.utf8)) ?? ""
        try require(model.error==nil && model.choices.contains("historical-tag") && calls.contains("turtlegit-checkout-refs"),"Bisect did not use the engine captured before its asynchronous catalog read")
        try require(model.acceptedOperationRepository?.libgit2Configuration?.enabled==true,"Bisect catalog actor was recaptured after the preference changed")
        try Data("tracked dirty content\n".utf8).write(to:root.appendingPathComponent("file.txt"))
        prefs.set(true,forKey:"UseLibgit2")
        var stashAccepted=false,captured:GitRepository?
        model.confirmStash={ [weak model] in
            guard let model else{return false}
            captured=model.acceptedOperationRepository;stashAccepted=true
            prefs.set(false,forKey:"UseLibgit2")
            return true
        }
        model.start()
        try await wait {!model.busy && !model.hasPendingWork}
        try require(stashAccepted && captured != nil && model.acceptedOperationRepository === captured,"Bisect Stash/retry replaced its accepted repository")
        try require(model.error==nil && model.lastExitCode==0 && model.state?.active==true,"Bisect failed to start after its actual Stash/retry")
        let stash=try await cli.run(["stash","list"])
        try require(!stash.text.isEmpty,"Bisect did not retain its actual stash")
        model.perform(.reset)
        try await wait {!model.busy && !model.hasPendingWork}
        try require(model.error==nil && model.state?.active==false && model.acceptedOperationRepository?.libgit2Configuration?.enabled==false,"Independent Bisect Reset did not use current preferences or settle the real session")
        model.returnToOptions()
        prefs.set(true,forKey:"UseLibgit2");try Data().write(to:hold)
        model.load(good:commits[0],bad:commits[2],requireStart:true)
        try await wait {model.busy && FileManager.default.fileExists(atPath:started.path)}
        model.cancel();try Data().write(to:release)
        try await wait {!model.busy && !model.hasPendingWork && BisectWindowModel.activeOperations==0}
        let state=try await cli.bisectState()
        try require(!state.active,"Cancelled catalog preparation started a Bisect session")
        model.retire()
    }
}
