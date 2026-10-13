import AppKit
import TurtleGitCore
@main struct FinderServiceGrantWorker {
    @MainActor static func main() async {
        do {
            let folder=URL(fileURLWithPath:CommandLine.arguments[1])
            let request=try JSONDecoder().decode(FinderServiceAuthorization.self,from:Data(contentsOf:folder.appendingPathComponent("transfer.json")))
            let grants=try request.acquire(requireSecurityScope:false)
            guard grants.count==1 else { throw FinderServiceAuthorizationFailure.invalidRequest }
            let grant=grants[0],repo=GitRepository(root:grant.root,executable:URL(fileURLWithPath:CommandLine.arguments[2]))
            let collection=try await repo.collectFinderRepository(authorizedRoot:grant.scope.url)
            guard collection.root.path==grant.root.path else { throw FinderServiceAuthorizationFailure.invalidRequest }
            let bytes=try String(contentsOf:grant.root.appendingPathComponent("file"))
            try JSONEncoder().encode(["root":grant.root.path,"bytes":bytes]).write(to:folder.appendingPathComponent("result.json"),options:.atomic)
            withExtendedLifetime(grants) {}
        } catch { fputs("Owned service grant worker failed: \(error)\n",stderr);exit(1) }
    }
}
