import AppKit
import TurtleGitCore
@main struct FinderPublicationWorker {
    @MainActor static func main() async {
        do {
            let folder=URL(fileURLWithPath:CommandLine.arguments[1])
            let input=try JSONDecoder().decode([String:String].self,from:Data(contentsOf:folder.appendingPathComponent("input.json")))
            let root=URL(fileURLWithPath:input["root"]!,isDirectory:true),store=FinderSnapshotStore(url:URL(fileURLWithPath:input["store"]!))
            let ticket=try store.begin(root:root);try Data().write(to:folder.appendingPathComponent("ready"))
            for _ in 0..<2000 { if FileManager.default.fileExists(atPath:folder.appendingPathComponent("go").path) { break };try await Task.sleep(nanoseconds:10_000_000) }
            guard FileManager.default.fileExists(atPath:folder.appendingPathComponent("go").path) else { throw FinderPublicationFailure.lockTimeout }
            let snapshot=FinderSnapshot(roots:[root.path],states:[root.appendingPathComponent("file").path:.added],repositories:[root.path:FinderRepositoryMetadata()])
            guard try store.publish(ticket,snapshots:[snapshot]).published else { throw FinderPublicationFailure.invalidUpdate }
            try Data().write(to:folder.appendingPathComponent("published"))
            for _ in 0..<2000 { if FileManager.default.fileExists(atPath:folder.appendingPathComponent("release").path) { break };try await Task.sleep(nanoseconds:10_000_000) }
            guard FileManager.default.fileExists(atPath:folder.appendingPathComponent("release").path) else { throw FinderPublicationFailure.lockTimeout }
            withExtendedLifetime(store) {}
        } catch { fputs("Owned publication worker failed: \(error)\n",stderr);exit(1) }
    }
}
