// SPDX-License-Identifier: GPL-2.0-or-later
// Standalone, directly executed QA process. Never registers an app or service.
import Foundation
import Security
import TurtleGitCore

@main struct SignedFinderRuntimeProbe {
    struct Failure: Error, CustomStringConvertible { let description:String }
    static func require(_ value:Bool,_ message:String)throws { if !value { throw Failure(description:message) } }
    static func main() async throws {
        let args=CommandLine.arguments
        guard args.count>=4, let uuid=UUID(uuidString:args[2]), let expected=FinderIntegration.groupIdentifier(team:args[3]) else { throw Failure(description:"Invalid signed QA request") }
        let mode=args[1]
        try require(GitRuntime.isAppStoreBuild,"Probe did not link the AppStore Core build")
        try require(try FinderCacheServiceIdentity.currentTeam()==args[3],"Signature team mismatch")
        let task=SecTaskCreateFromSelf(nil)!
        try require((SecTaskCopyValueForEntitlement(task,"com.apple.security.app-sandbox" as CFString,nil) as? Bool)==true,"Probe is not sandbox entitled")
        if mode=="denied" {
            try require(FinderIntegration.container==nil,"A process without the group entitlement acquired the container")
            guard args.count==5 else { throw Failure(description:"Missing negative read target") }
            do { _=try Data(contentsOf:URL(fileURLWithPath:args[4]));throw Failure(description:"Sandbox allowed a group file read without group membership") }
            catch let failure as Failure { throw failure }
            catch { print("TURTLEGIT_SIGNED_QA {\"mode\":\"denied\",\"passed\":true}");return }
        }
        try require(FinderIntegration.group==expected,"Runtime group differs from signature team")
        guard let container=FinderIntegration.container else { throw Failure(description:"Signed group container access failed") }
        let folder=container.appendingPathComponent("TurtleGitSignedQA-"+uuid.uuidString,isDirectory:true)
        let snapshotURL=folder.appendingPathComponent("snapshot.json"),root=folder.appendingPathComponent("repository",isDirectory:true)
        let file=root.appendingPathComponent("file.txt")
        if mode=="cleanup" {
            if FileManager.default.fileExists(atPath:folder.path) { try FileManager.default.removeItem(at:folder) }
        } else if mode=="writer" {
            try require(!FileManager.default.fileExists(atPath:folder.path),"QA directory already exists")
            try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
            let git=try GitRuntime.executable(bundle:.main,appStore:true)
            try require(git.path.hasPrefix(Bundle.main.bundleURL.path+"/Contents/"),"Git escaped the signed bundle")
            let lexilla=Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/Lexilla/lexilla")
            let process=Process(),output=Pipe(),errors=Pipe()
            process.executableURL=lexilla;process.arguments=["--version"];process.standardOutput=output;process.standardError=errors
            try process.run()
            let version=try output.fileHandleForReading.readToEnd() ?? Data()
            _=try errors.fileHandleForReading.readToEnd();process.waitUntilExit()
            try require(process.terminationStatus==0 && String(decoding:version,as:UTF8.self).contains("ef08a1a00ce151ccdddf7da700fbe1a4934a9c71"),"Signed inherited Lexilla failed in its sandboxed parent")
            let repository=GitRepository(root:root,executable:git)
            _=try await repository.run(["init","--initial-branch=main"])
            _=try await repository.run(["config","user.name","Signed Sandbox QA"])
            _=try await repository.run(["config","user.email","signed-qa@example.invalid"])
            try Data("base\n".utf8).write(to:file)
            try await repository.stage(["file.txt"])
            _=try await repository.run(["-c","core.hooksPath=/dev/null","-c","commit.gpgsign=false","commit","-m","Signed sandbox fixture"])
            try Data("modified\n".utf8).write(to:file)
            let snapshot=FinderSnapshot.build(root:root,tracked:try await repository.trackedPaths(),changes:try await repository.status())
            let store=FinderSnapshotStore(url:snapshotURL),ticket=try store.begin(root:root)
            try require(try store.publish(ticket,snapshots:[snapshot]).published,"Signed publication was superseded")
        } else if mode=="reader" {
            let value=try JSONDecoder().decode(FinderSnapshot.self,from:Data(contentsOf:snapshotURL))
            try require(value.roots.contains(root.path) && value.states[file.path] == .modified,"Independent signed reader lost published status")
            try require(try Data(contentsOf:file)==Data("modified\n".utf8),"Independent signed reader lost group-file access")
        } else { throw Failure(description:"Unknown signed QA mode") }
        let result:[String:Any] = ["mode":mode,"passed":true,"group":expected,"snapshot":snapshotURL.path]
        print("TURTLEGIT_SIGNED_QA "+String(decoding:try JSONSerialization.data(withJSONObject:result,options:.sortedKeys),as:UTF8.self))
    }
}
