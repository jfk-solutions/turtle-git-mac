import Foundation
import CryptoKit
import TurtleGitCore
@main struct Profile {
 static func measure<T>(_ name:String,_ body:() async throws->T) async throws->T {
  let began=ProcessInfo.processInfo.systemUptime,value=try await body()
  print("stage=\(name) seconds=\(ProcessInfo.processInfo.systemUptime-began)");fflush(stdout);return value
 }
 static func main() async {
  do {
   let root=URL(fileURLWithPath:CommandLine.arguments[1]),repo=GitRepository(root:root,executable:URL(fileURLWithPath:CommandLine.arguments[2]),diffDetection:.init(),libgit2Configuration:.init(enabled:false))
   let index=root.appendingPathComponent(".git/index"),before=SHA256.hash(data:try Data(contentsOf:index))
   _=try await measure("identity"){try await repo.replayUserIdentity()}
   _=try await measure("preferences"){try await repo.commitPreferences()}
   let snapshot=try await measure("commitDialogRead"){try await repo.commitDialogRead(amend:false,amendDiffToLastCommit:true)}
   print("entries=\(snapshot.entries.count) working=\(snapshot.working.count) staged=\(snapshot.staged.count) unstaged=\(snapshot.unstaged.count) submodules=\(snapshot.submodules.count)")
   _=try await measure("fileListSupplementary"){try await repo.commitFileListSupplementary(paths:snapshot.entries.map(\.path),columns:[.fileExtension,.lastModified,.fileSize])}
   _=try await measure("issueProperties"){try await repo.issueTrackerProperties()}
   _=try await measure("projectSettings"){try await repo.projectDialogSettings(source:.effective)}
   _=try await measure("messageHistoryIdentity"){try await repo.commitMessageHistoryIdentity()}
   _=try await measure("messageSeed"){try await repo.commitMessageSeed()}
   let association=try await measure("nativeIssueAssociation"){try await repo.nativeIssueAssociation(rows:[])}
   print("project_provider_configured=\(association != nil)")
   let hooks=try await measure("projectClientHooks"){try await repo.projectClientHooks()}
   print("project_start_hook_configured=\(hooks.contains{$0.type == .startCommit})")
   print("index_unchanged=\(before==SHA256.hash(data:try Data(contentsOf:index)))")
  }catch{fputs("Read-only profile failed: \(error)\n",stderr);exit(1)}
 }
}
