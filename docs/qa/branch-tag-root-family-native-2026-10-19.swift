// SPDX-License-Identifier: GPL-2.0-or-later
import AppKit
import TurtleGitCore

struct BranchTagRootFamilyVerification {
    @MainActor static func verify()async throws {
        typealias F=BranchTagPlanFixture
        let suite="TurtleGit.ReferenceRoot."+UUID().uuidString,prefs=UserDefaults(suiteName:suite)!
        prefs.set(0,forKey:"AutoCloseGitProgress");prefs.set(false,forKey:"ConfirmKillProcess");prefs.set(false,forKey:"PushTag")
        defer{prefs.removePersistentDomain(forName:suite)}
        let(repo,_,_)=try await F.repository("reference Root routes"),base=URL(fileURLWithPath:CommandLine.arguments[1]),grant=RepositoryAccessLease(url:repo.root),workspace=RepositoryModel(startMonitoring:false,initializePreferences:false,snapshotWriter:{_ in false})
        defer{workspace.stopMonitoringForTermination()}
        let marker=repo.root.appendingPathComponent(".git/deny-description"),helper=base.appendingPathComponent("reference-description-git")
        let quoted="'"+repo.executable.path.replacingOccurrences(of:"'",with:"'\\''")+"'",path="'"+marker.path.replacingOccurrences(of:"'",with:"'\\''")+"'"
        let script="""
        #!/bin/sh
        description_write() {
          if [ "${1-}" = --literal-pathspecs ] || [ "${1-}" = --no-literal-pathspecs ]; then shift; fi
          if [ "${1-}" = -C ]; then shift 2; fi
          while [ "${1-}" = -c ]; do shift 2; done
          test "${1-}" = config && test "${2-}" = --local && test "${3-}" = branch.root-topic.description
        }
        if description_write "$@" && [ -f \(path) ]; then /bin/rm \(path);printf 'controlled description write failure\\n' >&2;exit 23;fi
        exec \(quoted) "$@"
        """
        try Data(script.utf8).write(to:helper);try FileManager.default.setAttributes([.posixPermissions:0o700],ofItemAtPath:helper.path);try Data().write(to:marker)
        let wrapped=GitRepository(root:repo.root,executable:helper),owner=BranchTagWindowController(repository:wrapped,access:grant,isTag:false,preferences:prefs),q=BranchTagQuestions()
        owner.window?.alphaValue=0;owner.window?.appearance=NSAppearance(named:.darkAqua);q.install(owner);defer{owner.close()}
        workspace.configureReferenceInteractions(owner,repository:wrapped,access:grant)
        var closed=0,created=0
        owner.onClosed={closed+=1};let notify=owner.model.onCreated;owner.model.onCreated={text in created+=1;notify(text)}
        owner.model.load(revision:"HEAD");try await F.wait("Root branch options did not load"){!owner.model.busy && !owner.model.chooser.busy}
        owner.model.options.name="root-topic";owner.model.options.message="captured root description";owner.model.switchAfterCreation=true
        owner.model.create()
        var progress:SwitchProgressWindowController?
        try await F.wait("Root branch did not host actual Switch"){progress=owner.window?.attachedSheet?.delegate as? SwitchProgressWindowController;return progress?.model.success==true && progress?.model.hasPendingWork==false}
        try F.require(progress!.model.repositoryAccess===grant && progress!.model.outputPreferences===prefs && progress!.window?.appearance?.name==NSAppearance.Name.darkAqua && progress!.window?.alphaValue==0,"Branch→Switch lost captured grant/preferences/appearance")
        let descriptionBefore=try await repo.run(["config","--get","branch.root-topic.description"],successfulExitCodes:0...1)
        try F.require(descriptionBefore.exitCode==1 && owner.model.awaitingSwitch && owner.model.hasPendingWork,"Description was written before actual Switch acknowledgement")
        progress!.model.close();progress!.model.close()
        try await F.wait("Description failure did not show owned error after Switch detach"){owner.model.retryDescription && owner.window?.attachedSheet===owner.questionWindow && q.last != nil && !owner.model.busy}
        try F.require(progress!.window?.sheetParent==nil && closed==0 && created==1,"Switch acknowledgement released parent or repeated creation")
        let reference=try await repo.run(["rev-parse","refs/heads/root-topic"]).stdout
        q.last!.1.buttons[0].performClick(nil);try await F.wait("Description error did not detach"){owner.questionWindow==nil}
        owner.model.options.name="wrong later name";owner.model.options.message="wrong later description";owner.model.create()
        try await F.wait("Retry description did not finish actual parent close"){closed==1 && !owner.model.hasPendingWork && owner.window?.attachedSheet==nil}
        let after=try await repo.run(["rev-parse","refs/heads/root-topic"]).stdout,value=try await repo.run(["config","--get","branch.root-topic.description"]).text,branch=try await repo.branch()
        try F.require(after==reference && value=="captured root description\n" && branch=="root-topic" && created==1,"Retry description recreated reference, changed snapshot, or duplicated creation")
        let tag=BranchTagWindowController(repository:repo,access:grant,isTag:true,preferences:prefs)
        tag.window?.alphaValue=0;tag.window?.appearance=NSAppearance(named:.darkAqua);defer{tag.close()}
        workspace.configureReferenceInteractions(tag,repository:repo,access:grant)
        tag.model.load(revision:"HEAD");try await F.wait("Root tag options did not load"){!tag.model.busy && !tag.model.chooser.busy}
        tag.model.options.name="root-release";tag.model.options.message="release";tag.model.pushAfterCreation=true
        let before=Set(NSApp.windows.map{ObjectIdentifier($0)})
        var tagClosed=0;tag.onClosed={tagClosed+=1};tag.model.create();tag.model.create()
        var push:PushWindowController?
        try await F.wait("Tag Push did not open after actual reference options detach"){push=NSApp.windows.filter{!before.contains(ObjectIdentifier($0))}.compactMap{$0.delegate as? PushWindowController}.first;return push != nil && tagClosed==1 && !tag.model.hasPendingWork && tag.window?.attachedSheet==nil}
        defer{push?.close()}
        try await F.wait("Tag Push preparation did not drain"){!push!.model.busy}
        try F.require(push!.model.repositoryAccess===grant && push!.model.presentationPreferences===prefs && push!.model.options.source=="refs/tags/root-release" && push!.window?.appearance?.name==NSAppearance.Name.darkAqua && push!.window?.alphaValue==0,"Tag Push lost captured source/grant/preferences/appearance: sameGrant=\(push!.model.repositoryAccess===grant), samePrefs=\(push!.model.presentationPreferences===prefs), source=\(push!.model.options.source), appearance=\(String(describing:push!.window?.appearance?.name)), alpha=\(String(describing:push!.window?.alphaValue))")
        try F.require(prefs.bool(forKey:"PushTag") && NSApp.windows.filter{!before.contains(ObjectIdentifier($0)) && $0.delegate is PushWindowController}.count==1,"Tag Push preference/handoff duplicated or not persisted")
        print("Actual Root Branch→Switch acknowledgement before recoverable description retry, captured immutable description/once notification, and Tag→Push scope/preferences/appearance after actual options close passed.")
    }
}
