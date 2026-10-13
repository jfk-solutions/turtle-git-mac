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
            let restored=try restarted.restore(requireSecurityScope:false)
            guard restored.accesses.count==1,restored.failures.isEmpty,expectedID==restored.accesses[0].id,expectedRoot.path==restored.accesses[0].root.path else { throw FinderServiceAuthorizationFailure.invalidRequest }
            let grant=restored.accesses[0],repo=GitRepository(root:grant.root,executable:URL(fileURLWithPath:CommandLine.arguments[2]))
            let collection=try await repo.collectFinderRepository(authorizedRoot:grant.lease.url)
            guard collection.root.path==grant.root.path else { throw FinderServiceAuthorizationFailure.invalidRequest }
            let bytes=try String(contentsOf:grant.root.appendingPathComponent("file"))
            try JSONEncoder().encode(["root":grant.root.path,"bytes":bytes]).write(to:folder.appendingPathComponent("result.json"),options:.atomic)
            withExtendedLifetime(restored) {}
        } catch { fputs("Owned service grant worker failed: \(error)\n",stderr);exit(1) }
    }
}
