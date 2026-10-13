import AppKit
import TurtleGitCore
@main struct FinderServiceGrantWorker {
    @MainActor static func main() async {
        do {
            let folder=URL(fileURLWithPath:CommandLine.arguments[1])
            let request=try JSONDecoder().decode(FinderServiceAuthorization.self,from:Data(contentsOf:folder.appendingPathComponent("transfer.json")))
            let registryURL=folder.appendingPathComponent("receiver-private/grants.json")
            let registry=try FinderServicePermissionStore(url:registryURL)
            var installed:[FinderServicePersistentAccess]?=try registry.install(request,requireSecurityScope:false)
            guard installed?.count==1 else { throw FinderServiceAuthorizationFailure.invalidRequest }
            let expectedID=installed![0].id,expectedRoot=installed![0].root
            installed=nil
            let restarted=try FinderServicePermissionStore(url:registryURL)
            do {
            let restored=try restarted.restore(requireSecurityScope:false)
            guard restored.accesses.count==1,restored.failures.isEmpty,expectedID==restored.accesses[0].id,expectedRoot.path==restored.accesses[0].root.path else { throw FinderServiceAuthorizationFailure.invalidRequest }
            let grant=restored.accesses[0]
            let bytes=try String(contentsOf:grant.root.appendingPathComponent("file"))
            try JSONEncoder().encode(["root":grant.root.path,"bytes":bytes]).write(to:folder.appendingPathComponent("result.json"),options:.atomic)
            }
            // Release the direct restoration lease: the runtime restores and owns its own.
            let runtime=FinderCacheServiceRuntime(permissions:restarted,cache:FinderSnapshotStore(url:folder.appendingPathComponent("status.json")),repository:{ GitRepository(root:$0,executable:URL(fileURLWithPath:CommandLine.arguments[2])) })
            try runtime.start(requireSecurityScope:false)
            for _ in 0..<3000 {
                if FileManager.default.fileExists(atPath:folder.appendingPathComponent("stop").path) { break }
                try await Task.sleep(nanoseconds:10_000_000)
            }
            await runtime.shutdown()
            guard runtime.failures.isEmpty else { throw FinderServiceAuthorizationFailure.invalidRequest }
            try Data("stopped".utf8).write(to:folder.appendingPathComponent("stopped"),options:.atomic)

        } catch { fputs("Owned service grant worker failed: \(error)\n",stderr);exit(1) }
    }
}
