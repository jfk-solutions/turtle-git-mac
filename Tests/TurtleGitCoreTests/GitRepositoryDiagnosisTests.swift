import XCTest
import Darwin
@testable import TurtleGitCore

private extension URL {
    func diagnosisChild(_ component:String)->URL {
        FileTransferPaths.fileURL((path=="/" ? "":path)+"/"+component)
    }
}

final class GitRepositoryDiagnosisTests:XCTestCase {
    struct Fixture {
        let base:URL,root:URL,home:URL,xdg:URL
        var environment:[String:String] {["HOME":home.path,"XDG_CONFIG_HOME":xdg.path,"GIT_CONFIG_NOSYSTEM":"1","GIT_CONFIG_COUNT":"0","GIT_CONFIG_PARAMETERS":""]}
        var configuration:URL {home.diagnosisChild(".gitconfig")}
    }
    private func fixture()throws->Fixture {
        let temporary=FileManager.default.temporaryDirectory.path
        guard let resolved=realpath(temporary,nil) else{throw NSError(domain:NSPOSIXErrorDomain,code:Int(errno))}
        defer{free(resolved)}
        guard let canonical=String(validatingUTF8:resolved) else{throw GitRepositoryDiagnosisFailure.input}
        // Foundation's path append can abbreviate /private/var back to /var.
        // Build every expected URL from the independent POSIX canonical bytes.
        let base=FileTransferPaths.fileURL(canonical).diagnosisChild("diagnosis-"+UUID().uuidString)
        let value=Fixture(base:base,root:base.diagnosisChild("repository"),home:base.diagnosisChild("home"),xdg:base.diagnosisChild("xdg"))
        for directory in [value.root,value.home,value.xdg.diagnosisChild("git")] {try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)}
        return value
    }
    private func quote(_ value:String)->String {"'"+value.replacingOccurrences(of:"'",with:"'\\''")+"'"}
    private func script(_ fixture:Fixture,_ text:String)throws->URL {
        let file=fixture.base.diagnosisChild("command-"+UUID().uuidString)
        try Data(("#!/bin/sh\n"+text+"\n").utf8).write(to:file)
        try FileManager.default.setAttributes([.posixPermissions:0o700],ofItemAtPath:file.path)
        return file
    }
    private func ownerHelper(_ fixture:Fixture)throws->URL {
        let object:[String:Any]=["reason":1,"errorCode":-36,"errorClass":6,"gitFile":false,"detail":"private ownership refusal","workdir":NSNull(),"gitdir":NSNull()]
        let data=try JSONSerialization.data(withJSONObject:object,options:.sortedKeys)
        return try script(fixture,"printf '%s\\n' "+quote("TurtleGit RepositoryDiagnosis v1:"+data.base64EncodedString()))
    }
    private func owner(_ fixture:Fixture,executable:URL=URL(fileURLWithPath:"/usr/bin/git"))throws->GitRepository {
        GitRepository(root:fixture.root,executable:executable,askpass:nil,libgit2Configuration:.init(enabled:false,mask:0,helperURL:try ownerHelper(fixture)))
    }
    private func values(_ file:URL,fixture:Fixture)async throws->[String] {
        let command=GitRepository(root:fixture.base,askpass:nil)
        let result=try await command.run(["config","--file",file.path,"--null","--get-all","safe.directory"],environmentOverrides:fixture.environment,successfulExitCodes:0...1)
        return result.stdout.split(separator:0,omittingEmptySubsequences:false).dropLast().map{String(decoding:$0,as:UTF8.self)}
    }

    func testActualLibgit2DiagnosisDoesNotRequirePriorOpenOrMasterPreference()async throws {
        let f=try fixture();defer{try? FileManager.default.removeItem(at:f.base)}
        let command=GitRepository(root:f.root,askpass:nil,libgit2Configuration:.init(enabled:false,mask:0))
        let missing=try await command.diagnoseRepositoryAccess(environmentOverrides:f.environment)
        XCTAssertEqual(missing.reason,.notRepository);XCTAssertFalse(missing.canTrust);XCTAssertLessThan(missing.errorCode,0)
        _ = try await command.run(["init","-b","main"],environmentOverrides:f.environment)
        let accessible=try await command.diagnoseRepositoryAccess(environmentOverrides:f.environment)
        XCTAssertEqual(accessible.reason,.accessible);XCTAssertEqual(accessible.errorCode,0);XCTAssertFalse(accessible.canTrust)
        XCTAssertFalse(FileManager.default.fileExists(atPath:f.configuration.path))
        let unavailable=GitRepository(root:f.root,libgit2Configuration:.init(enabled:false,mask:0,helperURL:f.base.diagnosisChild("missing-helper")))
        do {_ = try await unavailable.diagnoseRepositoryAccess(environmentOverrides:f.environment);XCTFail("Unconditional diagnostic silently used CLI")}catch GitLibGit2Failure.runtimeMissing{}
    }

    func testActualBareAndLinkedWorktreeDiagnosesKeepAccessibleGitfileUntrusted()async throws {
        let f=try fixture();defer{try? FileManager.default.removeItem(at:f.base)}
        let command=GitRepository(root:f.root,askpass:nil)
        _ = try await command.run(["init","-b","main"],environmentOverrides:f.environment)
        _ = try await command.run(["-c","user.name=Private","-c","user.email=private@example.invalid","-c","commit.gpgsign=false","commit","--allow-empty","-m","base"],environmentOverrides:f.environment)
        let linked=f.base.diagnosisChild("linked")
        _ = try await command.run(["worktree","add","-b","linked","--",linked.path],environmentOverrides:f.environment)
        let diagnosis=try await GitRepository(root:linked,askpass:nil).diagnoseRepositoryAccess(environmentOverrides:f.environment)
        XCTAssertEqual(diagnosis.reason,.accessible);XCTAssertTrue(diagnosis.gitFile);XCTAssertFalse(diagnosis.canTrust)
        do {_ = try await GitRepository(root:linked).prepareSafeDirectoryTrust(diagnosis);XCTFail("Accessible gitfile offered trust")}catch GitRepositoryDiagnosisFailure.notEligible{}
        let bare=f.base.diagnosisChild("bare");try FileManager.default.createDirectory(at:bare,withIntermediateDirectories:true)
        let bareRepository=GitRepository(root:bare,askpass:nil)
        _ = try await bareRepository.run(["init","--bare"],environmentOverrides:f.environment)
        let bareDiagnosis=try await bareRepository.diagnoseRepositoryAccess(environmentOverrides:f.environment)
        XCTAssertEqual(bareDiagnosis.reason,.accessible);XCTAssertFalse(bareDiagnosis.gitFile)
    }

    func testExplicitTrustUsesGlobalXDGAndOverrideTargetsWithoutReplacingEntries()async throws {
        for mode in 0..<5 {
            let f=try fixture();defer{try? FileManager.default.removeItem(at:f.base)}
            let xdg=f.xdg.diagnosisChild("git/config"),custom=f.base.diagnosisChild("custom-config")
            let initial=Data("[safe]\n\tdirectory =\n\tdirectory = /other\n\tdirectory = /other\n[private]\n\tvalue = preserved\n".utf8)
            var environment=f.environment
            if mode==1 || mode==2 {try initial.write(to:xdg)}
            if mode==2 {try initial.write(to:f.configuration)}
            if mode==3 {environment["GIT_CONFIG_GLOBAL"]=custom.path;try initial.write(to:custom)}
            let relative=FileTransferPaths.fileURL(f.root.path+"/relative-e\u{301}.config")
            if mode==4 {environment["GIT_CONFIG_GLOBAL"]="relative-e\u{301}.config";try initial.write(to:relative)}
            let expected=mode==1 ? xdg:mode==3 ? custom:mode==4 ? relative:f.configuration
            let other=mode==2 ? try Data(contentsOf:xdg):nil
            let repository=try owner(f)
            let diagnosis=try await repository.diagnoseRepositoryAccess(environmentOverrides:environment)
            XCTAssertTrue(diagnosis.canTrust)
            let candidates=try await repository.safeDirectoryConfigurationCandidates(diagnosis)
            // Candidate planning is lexical: relative overrides use the
            // accepted actor's invocation directory before canonical selection.
            let relativeCandidate=FileTransferPaths.fileURL(repository.root.path+"/relative-e\u{301}.config")
            let expectedCandidates=mode==3 ? [custom]:mode==4 ? [relativeCandidate]:[f.configuration,xdg]
            XCTAssertEqual(candidates.map{Data($0.path.utf8)},expectedCandidates.map{Data($0.path.utf8)})
            let plan=try await repository.prepareSafeDirectoryTrust(diagnosis)
            XCTAssertEqual(plan.configurationFile,expected);XCTAssertEqual(plan.value,f.root.path)
            let receipt=try await repository.addSafeDirectoryTrust(plan)
            XCTAssertEqual(receipt.configurationFile,expected)
            let actual=try await values(expected,fixture:f)
            XCTAssertEqual(actual,(mode==0 ? []:["","/other","/other"])+[f.root.path])
            if mode != 0 {XCTAssertTrue(try String(contentsOf:expected,encoding:.utf8).contains("[private]\n\tvalue = preserved\n"))}
            if let other {XCTAssertEqual(try Data(contentsOf:xdg),other)}
            XCTAssertFalse(FileManager.default.fileExists(atPath:f.root.diagnosisChild(".git/config").path))
        }
    }

    func testTrustPlanRejectsChangedRepositoryAndChangedGlobalSelection()async throws {
        let f=try fixture();defer{try? FileManager.default.removeItem(at:f.base)}
        let xdg=f.xdg.diagnosisChild("git/config");try Data("[private]\nvalue=old\n".utf8).write(to:xdg)
        let repository=try owner(f),diagnosis=try await repository.diagnoseRepositoryAccess(environmentOverrides:f.environment)
        let plan=try await repository.prepareSafeDirectoryTrust(diagnosis)
        try Data("[private]\nvalue=new\n".utf8).write(to:f.configuration)
        do {_ = try await repository.addSafeDirectoryTrust(plan);XCTFail("New global target adopted after authorization")}catch GitRepositoryDiagnosisFailure.changed{}
        let unchangedXDG=try await values(xdg,fixture:f);XCTAssertEqual(unchangedXDG,[])
        try FileManager.default.removeItem(at:f.configuration)
        let moved=f.base.diagnosisChild("old-root");try FileManager.default.moveItem(at:f.root,to:moved)
        try FileManager.default.createDirectory(at:f.root,withIntermediateDirectories:true)
        do {_ = try await repository.addSafeDirectoryTrust(plan);XCTFail("Replacement repository inherited old trust intent")}catch GitRepositoryDiagnosisFailure.changed{}
        let replacementXDG=try await values(xdg,fixture:f);XCTAssertEqual(replacementXDG,[])
    }

    func testLockFailureAndPrecancelledTrustNeverChangeConfiguration()async throws {
        let f=try fixture();defer{try? FileManager.default.removeItem(at:f.base)}
        let initial=Data("[safe]\ndirectory=/kept\n".utf8);try initial.write(to:f.configuration)
        let repository=try owner(f),diagnosis=try await repository.diagnoseRepositoryAccess(environmentOverrides:f.environment)
        let plan=try await repository.prepareSafeDirectoryTrust(diagnosis)
        let lock=URL(fileURLWithPath:f.configuration.path+".lock");try Data("private lock".utf8).write(to:lock)
        do {_ = try await repository.addSafeDirectoryTrust(plan);XCTFail("Config lock failure was ignored")}catch is GitFailure{}
        XCTAssertEqual(try Data(contentsOf:f.configuration),initial)
        try FileManager.default.removeItem(at:lock)
        let token=OperationCancellation();token.cancel()
        do {_ = try await repository.addSafeDirectoryTrust(plan,cancellation:token);XCTFail("Precancelled trust wrote config")}catch is OperationCancellationFailure{}
        XCTAssertEqual(try Data(contentsOf:f.configuration),initial)
    }

    func testCancelledAfterCommittedAppendReportsActualWriteWithoutDuplicateRetry()async throws {
        let f=try fixture();defer{try? FileManager.default.removeItem(at:f.base)}
        let committed=f.base.diagnosisChild("committed")
        let executable=try script(f,"""
        /usr/bin/git "$@" || exit $?
        for argument in "$@"; do
          if [ "$argument" = '--add' ]; then
            : > \(quote(committed.path))
            while :; do /bin/sleep 1; done
          fi
        done
        """)
        let repository=try owner(f,executable:executable),diagnosis=try await repository.diagnoseRepositoryAccess(environmentOverrides:f.environment)
        let plan=try await repository.prepareSafeDirectoryTrust(diagnosis),token=OperationCancellation()
        let task=Task{try await repository.addSafeDirectoryTrust(plan,cancellation:token)}
        defer{token.cancel()}
        for _ in 0..<1000 {if FileManager.default.fileExists(atPath:committed.path){break};try await Task.sleep(nanoseconds:10_000_000)}
        XCTAssertTrue(FileManager.default.fileExists(atPath:committed.path));token.cancel()
        let receipt=try await task.value
        if case .alreadyRecordedAfterFailure=receipt.outcome {}else{XCTFail("Committed append lost its completion receipt")}
        let actual=try await values(f.configuration,fixture:f);XCTAssertEqual(actual,[f.root.path])
    }

    func testRealMalformedGitfileOffersExplicitTrustWithoutPretendingToRepairItsContents()async throws {
        let f=try fixture();defer{try? FileManager.default.removeItem(at:f.base)}
        let marker=f.root.diagnosisChild(".git"),bytes=Data("not a gitdir\n".utf8)
        try bytes.write(to:marker)
        let repository=GitRepository(root:f.root,askpass:nil,libgit2Configuration:.init(enabled:false,mask:0))
        let diagnosis=try await repository.diagnoseRepositoryAccess(environmentOverrides:f.environment)
        XCTAssertEqual(diagnosis.reason,.inaccessible);XCTAssertTrue(diagnosis.gitFile);XCTAssertTrue(diagnosis.canTrust)
        XCTAssertLessThan(diagnosis.errorCode,0);XCTAssertFalse(diagnosis.detail.isEmpty)
        let plan=try await repository.prepareSafeDirectoryTrust(diagnosis)
        _ = try await repository.addSafeDirectoryTrust(plan)
        let trusted=try await values(f.configuration,fixture:f);XCTAssertEqual(trusted,[f.root.path])
        XCTAssertEqual(try Data(contentsOf:marker),bytes)
        let retry=try await repository.diagnoseRepositoryAccess(environmentOverrides:f.environment)
        XCTAssertEqual(retry.reason,.inaccessible);XCTAssertTrue(retry.gitFile)
        XCTAssertEqual(retry.errorCode,diagnosis.errorCode)
    }

    func testCapturedRootSymlinkCannotBeRetargetedBeforeTrust()async throws {
        let f=try fixture();defer{try? FileManager.default.removeItem(at:f.base)}
        let link=f.base.diagnosisChild("selected-root"),other=f.base.diagnosisChild("replacement")
        try FileManager.default.createDirectory(at:other,withIntermediateDirectories:true)
        try FileManager.default.createSymbolicLink(at:link,withDestinationURL:f.root)
        let repository=GitRepository(root:link,askpass:nil,libgit2Configuration:.init(helperURL:try ownerHelper(f)))
        let diagnosis=try await repository.diagnoseRepositoryAccess(environmentOverrides:f.environment)
        XCTAssertEqual(diagnosis.root.path,f.root.path)
        let plan=try await repository.prepareSafeDirectoryTrust(diagnosis)
        try FileManager.default.removeItem(at:link);try FileManager.default.createSymbolicLink(at:link,withDestinationURL:other)
        do {_ = try await repository.addSafeDirectoryTrust(plan);XCTFail("Retargeted selected symlink inherited old authorization")}catch GitRepositoryDiagnosisFailure.changed{}
        XCTAssertFalse(FileManager.default.fileExists(atPath:f.configuration.path))
    }

    func testMalformedDiagnosticAndWildcardRootNeverAcquireTrust()async throws {
        let f=try fixture();defer{try? FileManager.default.removeItem(at:f.base)}
        let invalid=try script(f,"printf 'invalid-frame\\n'")
        let repository=GitRepository(root:f.root,libgit2Configuration:.init(enabled:false,helperURL:invalid))
        do {_ = try await repository.diagnoseRepositoryAccess(environmentOverrides:f.environment);XCTFail("Malformed helper metadata became eligible diagnosis")}catch GitRepositoryDiagnosisFailure.output{}
        let base:[String:Any]=["reason":1,"errorCode":-36,"errorClass":6,"gitFile":false,"detail":"ownership","workdir":NSNull(),"gitdir":NSNull()]
        let invalidReplies:[[String:Any]]=[
            ["reason":true],["errorCode":-1],["errorClass":false],["workdir":f.root.path],
            ["reason":2],["reason":0,"errorCode":0,"errorClass":0,"detail":""]
        ]
        for overrides in invalidReplies {
            let reply=base.merging(overrides){_,new in new}
            let data=try JSONSerialization.data(withJSONObject:reply,options:.sortedKeys)
            let helper=try script(f,"printf '%s\\n' "+quote("TurtleGit RepositoryDiagnosis v1:"+data.base64EncodedString()))
            let malformed=GitRepository(root:f.root,libgit2Configuration:.init(helperURL:helper))
            do {_ = try await malformed.diagnoseRepositoryAccess(environmentOverrides:f.environment);XCTFail("Inconsistent diagnostic acquired a trust receipt: \(overrides)")}catch GitRepositoryDiagnosisFailure.output{}
        }
        let special=f.root.diagnosisChild("*");try FileManager.default.createDirectory(at:special,withIntermediateDirectories:true)
        let wildcard=GitRepository(root:special,libgit2Configuration:.init(helperURL:try ownerHelper(f)))
        let diagnosis=try await wildcard.diagnoseRepositoryAccess(environmentOverrides:f.environment)
        do {_ = try await wildcard.prepareSafeDirectoryTrust(diagnosis);XCTFail("Literal root became recursive wildcard trust")}catch GitRepositoryDiagnosisFailure.input{}
        // A candidate beneath a regular device cannot be resolved or statted
        // as a directory; lexical permission planning must still return it.
        var inaccessible=f.environment;inaccessible["GIT_CONFIG_GLOBAL"]="/dev/null/private-config"
        let lexical=try owner(f),lexicalDiagnosis=try await lexical.diagnoseRepositoryAccess(environmentOverrides:inaccessible)
        let candidates=try await lexical.safeDirectoryConfigurationCandidates(lexicalDiagnosis)
        XCTAssertEqual(candidates.map(\.path),["/dev/null/private-config"])
        var disabled=f.environment;disabled["GIT_CONFIG_GLOBAL"]=""
        let normal=try owner(f),normalDiagnosis=try await normal.diagnoseRepositoryAccess(environmentOverrides:disabled)
        do {_ = try await normal.prepareSafeDirectoryTrust(normalDiagnosis);XCTFail("Disabled global destination fell back to user config")}catch GitRepositoryDiagnosisFailure.configurationTarget{}
        XCTAssertFalse(FileManager.default.fileExists(atPath:f.configuration.path))
    }
}
