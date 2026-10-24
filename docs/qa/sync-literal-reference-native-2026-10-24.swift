// SPDX-License-Identifier: GPL-2.0-or-later
import AppKit
import TurtleGitCore

@main struct SyncLiteralReferenceVerification {
    struct Failure:Error,CustomStringConvertible {let description:String}
    static func require(_ value:Bool,_ message:String)throws {if !value{throw Failure(description:message)}}
    static func exact(_ a:String,_ b:String)->Bool {a.utf8.elementsEqual(b.utf8)}
    @MainActor static func views(_ root:NSView?)->[NSView] {guard let root else{return []};return [root]+root.subviews.flatMap{views($0)}}
    @MainActor static var phase="setup"
    @MainActor static var inspect:()->String={"no native owner"}
    @MainActor static func wait(_ ready:()->Bool)async throws {
        for _ in 0..<2000 {if ready(){return};try await Task.sleep(nanoseconds:10_000_000)}
        throw Failure(description:"Exact Sync workflow timed out at "+phase+"\n"+inspect())
    }
    @MainActor static func main()async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let root=URL(fileURLWithPath:CommandLine.arguments[1]),git=URL(fileURLWithPath:CommandLine.arguments[2]),mode=CommandLine.arguments[3]
        let suite="TurtleGit.SyncLiteralReference."+UUID().uuidString,prefs=UserDefaults(suiteName:suite)!
        prefs.set(false,forKey:"UseLibgit2");prefs.set(false,forKey:"EnableGravatar");prefs.set(false,forKey:"ConfirmKillProcess");prefs.set(0,forKey:"AutoCloseGitProgress")
        defer{prefs.removePersistentDomain(forName:suite)}
        let pasteboard=NSPasteboard(name:NSPasteboard.Name("TurtleGit.SyncLiteralReference."+UUID().uuidString));defer{pasteboard.releaseGlobally()}
        let repo=GitRepository(root:root,executable:git,askpass:nil,libgit2Configuration:.init(enabled:false))
        func run(_ args:[String])async throws->GitResult {try await repo.run(["-c","core.precomposeunicode=false"]+args)}
        _=try await run(["init","--template=","-b","main"])
        for (key,value) in [("user.name","Sync exact QA"),("user.email","sync-exact@example.invalid"),("commit.gpgsign","false"),("core.hooksPath","/dev/null"),("core.precomposeunicode","false")] {_=try await run(["config",key,value])}
        try Data("base\n".utf8).write(to:root.appendingPathComponent("file"));try await repo.stage(["file"]);_=try await repo.commit(message:"base")
        let base=try await run(["rev-parse","HEAD"]).text.trimmingCharacters(in:.newlines)
        try Data("local outgoing\n".utf8).write(to:root.appendingPathComponent("file"));try await repo.stage(["file"]);_=try await repo.commit(message:"outgoing")
        let head=try await run(["rev-parse","HEAD"]).text.trimmingCharacters(in:.newlines),composed="café",decomposed="cafe\u{301}"
        _=try await run(["branch","-m","main",composed]);_=try await run(["pack-refs","--all"])
        _=try await run(["update-ref","--create-reflog","refs/heads/"+decomposed,base]);_=try await run(["pack-refs","--all"])
        let server=root.appendingPathComponent("server.git");_=try await run(["init","--bare","--template=",server.path]);_=try await run(["remote","add","origin",server.path])
        for branch in [composed,decomposed] {
            _=try await run(["push","origin",base+":refs/heads/"+branch])
            _=try await run(["--git-dir="+server.path,"pack-refs","--all"])
            _=try await run(["update-ref","refs/remotes/origin/"+branch,base]);_=try await run(["pack-refs","--all"])
        }
        if mode == "pull" {
            _=try await run(["push","origin",head+":refs/heads/"+decomposed]);_=try await run(["--git-dir="+server.path,"pack-refs","--all"])
            // A tracked-pair Pull may omit its explicit field. Limit that real
            // fetch to this selected ref; APFS cannot create two canonically
            // equivalent loose tracking files in one wildcard transaction.
            _=try await run(["config","--local","--replace-all","remote.origin.fetch","+refs/heads/"+decomposed+":refs/remotes/origin/"+decomposed])
        }
        // The port must override path precomposition per invocation, preserving
        // this saved setting and the two packed reference byte spellings.
        _=try await run(["config","core.precomposeunicode","true"])
        let initialIndex=try Data(contentsOf:root.appendingPathComponent(".git/index")),initialWorking=try Data(contentsOf:root.appendingPathComponent("file"))
        var owners:[SynchronizationWindowController]=[]
        defer{for owner in owners{owner.model.invalidate();owner.window?.orderOut(nil);owner.close()}}
        func open()async throws->SynchronizationWindowController {
            let owner=SynchronizationWindowController(repository:repo,access:nil,preferences:prefs);owners.append(owner)
            owner.window?.isReleasedWhenClosed=false;owner.window?.alphaValue=0;owner.window?.setFrameOrigin(NSPoint(x:-30000,y:-30000));owner.window?.orderFront(nil)
            owner.model.notifications.publishClipboard={value in pasteboard.clearContents();pasteboard.setString(value,forType:.string)}
            inspect={ [weak owner] in
                guard let owner else{return "native owner released"}
                let model=owner.model
                func bytes(_ text:String)->String {text+" ["+text.utf8.map{String(format:"%02x",$0)}.joined(separator:" ")+"]"}
                let popups=views(owner.window?.contentView).compactMap{$0 as? NSPopUpButton}.map{popup in
                    "popup "+String(describing:type(of:popup))+" enabled="+String(popup.isEnabled)+" title="+(popup.titleOfSelectedItem ?? "nil")+" items="+popup.itemTitles.map(bytes).joined(separator:" | ")
                }.joined(separator:"\n")
                let controls=views(owner.window?.contentView).compactMap{$0 as? NSControl}.map{String(describing:type(of:$0))+":"+($0.accessibilityLabel() ?? "")}.joined(separator:", ")
                let state="busy=\(model.busy) pending=\(model.hasPendingInlineWork) waiting=\(model.waitingForInput) transport=\(model.transportRunning) closed=\(model.closed) blocked=\(model.hasBlockingChild) sheet=\(owner.window?.attachedSheet?.title ?? "nil")"
                let selection="local="+bytes(model.localBranch)+" remote="+bytes(model.remote)+" branch="+bytes(model.remoteBranch)
                let catalog="catalog="+model.localBranches.map(bytes).joined(separator:" | ")
                let issue="error="+(model.error ?? "nil")+" output="+String(model.commandOutput.suffix(1200))
                return [state,selection,catalog,issue,popups,"controls="+controls].joined(separator:"\n")
            }
            phase="open.initial catalog"
            owner.model.sshSettings.enabled=false;owner.model.reload(initial:true)
            try await wait{!owner.model.busy && !owner.model.hasPendingInlineWork && owner.model.localBranches.count==2}
            owner.window?.contentView?.layoutSubtreeIfNeeded();return owner
        }
        func settled(_ owner:SynchronizationWindowController,_ label:String="settle")async throws {phase=label;try await wait{!owner.model.busy && !owner.model.waitingForInput && !owner.model.hasPendingInlineWork}}
        func reference(_ name:String,remote:Bool=false)async throws->String? {
            let prefix=remote ? ["--git-dir="+server.path]:[]
            if name.hasPrefix("refs/") {
                // Enumerate logical raw refs instead of resolving a pathname:
                // an APFS loose alias can shadow a different packed spelling.
                let raw=try await run(prefix+["for-each-ref","--format=%(refname)%00%(objectname)"]).stdout
                for line in raw.split(separator:10) {
                    let fields=line.split(separator:0,omittingEmptySubsequences:false)
                    try require(fields.count==2,"Malformed exact-reference receipt")
                    if fields[0].elementsEqual(name.utf8) {return String(decoding:fields[1],as:UTF8.self)}
                }
                print("Missing raw reference "+name+" in "+String(decoding:raw,as:UTF8.self).replacingOccurrences(of:"\0",with:" -> "))
                return nil
            }
            let args=prefix+["rev-parse","--verify","--quiet","--end-of-options",name]
            let result=try await repo.run(["-c","core.precomposeunicode=false"]+args,successfulExitCodes:0...1)
            return result.exitCode==0 ? result.text.trimmingCharacters(in:.newlines):nil
        }
        func config(_ key:String)async throws->Data {try await repo.run(["-c","core.precomposeunicode=false","config","--local","--null","--get",key],successfulExitCodes:0...1).stdout}
        func pick(_ owner:SynchronizationWindowController,_ branch:String)async throws {
            try await settled(owner,"pick.before "+branch);owner.window?.contentView?.layoutSubtreeIfNeeded()
            // SwiftUI's shipping Picker is not an NSPopUpButton. Exercise its
            // actual receipt-bound setter in the real window; physical popup
            // dispatch is a separate acceptance scope, not an assumed AppKit class.
            let names=owner.model.localBranches
            try require(names.count==2 && names.filter{exact($0,composed)}.count==1 && names.filter{exact($0,decomposed)}.count==1,"Shipping local Picker catalog merged equivalent-looking refs")
            let binding=owner.model.formString(\.localBranch,context:owner.model.formContext,tracking:true)
            binding.wrappedValue=branch
            try await settled(owner,"pick.accepted "+branch)
            try require(exact(owner.model.localBranch,branch) && exact(binding.wrappedValue,branch),"Shipping Picker binding selected another raw branch")
        }
        func fields(_ owner:SynchronizationWindowController,branch:String)async throws {
            // Local picker owns the real local choice; editable remote fields use
            // the shipping receipt-bound model entry points for this fixture.
            owner.model.formString(\.remote,context:owner.model.formContext).wrappedValue="origin"
            owner.model.formString(\.remoteBranch,context:owner.model.formContext).wrappedValue=branch
            try await settled(owner,"fields.deferred "+branch);owner.model.reload();try await settled(owner,"fields.projection "+branch)
        }
        let owner=try await open(),model=owner.model
        if mode == "push" {
            try await pick(owner,decomposed);try await fields(owner,branch:decomposed)
            try require(model.outgoing?.localHash==base && model.outgoing?.remoteHash==base,"NFD selected outgoing comparison read the NFC branch")
            try await pick(owner,composed);try await fields(owner,branch:decomposed)
            try require(model.outgoing?.localHash==head && model.outgoing?.remoteHash==base && model.outgoing?.commits.count==1,"NFC outgoing projection lost the selected source")
            _=try await run(["config","branch."+decomposed+".remote","untouched"]);_=try await run(["config","branch."+decomposed+".merge","refs/heads/untouched"])
            let siblingRemote=try await config("branch."+decomposed+".remote"),siblingMerge=try await config("branch."+decomposed+".merge")
            var asked:[String]=[]
            model.askTracking={local,remote,destination in asked=[local,remote,destination];return SynchronizationTrackingAnswer(choice:.yes)}
            model.push(.push,shift:false);try await settled(owner,"push transport/tracking")
            try require(model.commandCompleted && model.commandSucceeded,"Exact native Push failed: "+(model.error ?? model.commandOutput))
            try require(asked.count==3 && exact(asked[0],composed) && exact(asked[1],"origin") && exact(asked[2],decomposed),"Tracking prompt changed captured source/destination spelling")
            // APFS may let a loose NFD filename shadow a packed NFC name in
            // direct path lookup. Assert the logical raw enumeration without
            // repacking or otherwise mutating the tested remote repository.
            let raw=try await run(["--git-dir="+server.path,"for-each-ref","--format=%(refname)%00%(objectname)","refs/heads/"]).stdout
            try raw.write(to:root.appendingPathComponent("server-after-push.refs"))
            var exactHeads:[GitReferenceName:String]=[:]
            for line in raw.split(separator:10) {
                let fields=line.split(separator:0,omittingEmptySubsequences:false)
                try require(fields.count==2,"Malformed private server reference receipt")
                exactHeads[GitReferenceName(String(decoding:fields[0],as:UTF8.self))]=String(decoding:fields[1],as:UTF8.self)
            }
            try require(exactHeads.count==2 && exactHeads[GitReferenceName("refs/heads/"+decomposed)]==head && exactHeads[GitReferenceName("refs/heads/"+composed)]==base,"Raw server receipt shows Push updated the wrong exact remote name")
            print("Exact server Push receipt: "+String(decoding:raw,as:UTF8.self).replacingOccurrences(of:"\0",with:" -> "))
            let selected=try await reference("refs/heads/"+decomposed,remote:true),other=try await reference("refs/heads/"+composed,remote:true)
            try require(selected==head && other==base,"Native Push updated the wrong equivalent-looking remote ref")
            let savedRemote=try await config("branch."+composed+".remote"),savedMerge=try await config("branch."+composed+".merge")
            try require(savedRemote==Data("origin\0".utf8) && savedMerge==Data(("refs/heads/"+decomposed+"\0").utf8),"Tracking write did not preserve exact local key/remote ref bytes")
            let unchangedRemote=try await config("branch."+decomposed+".remote"),unchangedMerge=try await config("branch."+decomposed+".merge")
            try require(unchangedRemote==siblingRemote && unchangedMerge==siblingMerge,"Tracking write changed sibling branch settings")
        } else if mode == "pull" {
            try await pick(owner,decomposed);try await fields(owner,branch:decomposed)
            var checkout:[String]=[]
            model.confirmCheckout={branch in checkout.append(branch);return true}
            // Keep the real controller checkout-progress callback: the child
            // must return the same actor-owned receipt to this transport.
            model.askTracking={_,_,_ in SynchronizationTrackingAnswer(choice:.yes)}
            model.fetch(.pull,shift:false);try await settled(owner,"pull checkout/tracking/transport")
            try require(model.commandCompleted && model.commandSucceeded,"Exact native Pull failed: "+(model.error ?? model.commandOutput))
            let attached=try await run(["symbolic-ref","HEAD"]).text.trimmingCharacters(in:.newlines)
            try require(checkout.count==1 && exact(checkout[0],decomposed) && exact(attached,"refs/heads/"+decomposed),"Pull skipped exact sibling checkout or attached another branch")
            let selected=try await reference("refs/heads/"+decomposed),other=try await reference("refs/heads/"+composed)
            try require(selected==head && other==head,"Pull failed to merge selected branch or rewrote original branch")
            let merge=try await config("branch."+decomposed+".merge")
            try require(merge==Data(("refs/heads/"+decomposed+"\0").utf8),"Pull tracking selected a normalized remote destination")
        } else if mode == "lifetime" {
            try await fields(owner,branch:decomposed)
            let receipt=model.formContext,oldRemote=model.remote
            model.localBranch=decomposed
            model.formString(\.remote,context:receipt).wrappedValue="stale-owner"
            try require(exact(model.remote,oldRemote),"Old form receipt accepted equivalent-looking different local branch")
            model.localBranch=composed;model.reload();try await settled(owner)
            let before=try Data(contentsOf:root.appendingPathComponent(".git/config"))
            var held:CheckedContinuation<SynchronizationTrackingAnswer,Never>?,prompts=0
            model.askTracking={_,_,_ in prompts += 1;return await withCheckedContinuation{held=$0}}
            model.push(.push,shift:false);phase="lifetime.first tracking prompt";try await wait{held != nil}
            model.cancelTransport();held!.resume(returning:SynchronizationTrackingAnswer(choice:.yes));held=nil;try await settled(owner)
            let afterCancelConfig=try Data(contentsOf:root.appendingPathComponent(".git/config"))
            try require(prompts==1 && !model.commandSucceeded && afterCancelConfig==before,"Cancelled tracking response wrote config or dispatched Push")
            let next=try await open();try await fields(next,branch:decomposed)
            next.model.askTracking={_,_,_ in prompts += 1;return await withCheckedContinuation{held=$0}}
            next.model.push(.push,shift:false);phase="lifetime.first tracking prompt";try await wait{held != nil}
            next.close();try require(next.model.closed && next.model.hasPendingInlineWork,"Closing held tracking lost owned work")
            held!.resume(returning:SynchronizationTrackingAnswer(choice:.yes));held=nil;phase="lifetime.retired tracking drain";try await wait{!next.model.hasPendingInlineWork}
            let afterCloseConfig=try Data(contentsOf:root.appendingPathComponent(".git/config"))
            try require(prompts==2 && afterCloseConfig==before,"Retired tracking response changed exact config")
            let remote=try await reference("refs/heads/"+decomposed,remote:true);try require(remote==base,"Late tracking response dispatched transport")
        } else {throw Failure(description:"Unknown Sync identity mode")}
        let savedPrecompose=try await config("core.precomposeunicode")
        try require(savedPrecompose==Data("true\0".utf8),"Source invocation changed saved precomposition setting")
        if mode != "pull" {
            try require(try Data(contentsOf:root.appendingPathComponent(".git/index"))==initialIndex && Data(contentsOf:root.appendingPathComponent("file"))==initialWorking,"Sync selected-ref action changed index/working file")
            let current=try await reference("HEAD");try require(current==head,"Sync Push/cancellation changed HEAD")
        }
        for owner in owners{owner.close();owner.window?.orderOut(nil)}
        phase="final owned releases"
        try await wait{SynchronizationWindowModel.activeInlineOperations==0 && SynchronizationWindowController.activeInlineReleases==0}
        print("PASS: Sync literal reference "+mode+"; real window/binding exact selection/tracking/transport and owned windows closed")
    }
}
