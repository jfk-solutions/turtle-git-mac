// Native receiver acceptance for the production drag provider; uses only an owned fixture.
import Foundation
import AppKit
import Darwin
import UniformTypeIdentifiers
import TurtleGitCore

@main struct BrowserItemProviderCheck {
    @MainActor static func main() async throws {
        let manager = FileManager.default
        let root = manager.temporaryDirectory.appendingPathComponent("TurtleGitProviderQA-" + UUID().uuidString)
        try manager.createDirectory(at: root.appendingPathComponent("src/nested"), withIntermediateDirectories: true)
        defer { RepositoryBrowserExportFiles.discardAll(); try? manager.removeItem(at: root) }
        let repository = GitRepository(root: root)
        _ = try await repository.run(["init", "-b", "main"])
        _ = try await repository.run(["config", "user.name", "TurtleGit QA"])
        _ = try await repository.run(["config", "user.email", "qa@example.invalid"])
        let path = "src/nested/file.bin", original = Data([0, 255, 13, 10])
        try original.write(to: root.appendingPathComponent(path))
        try await repository.stage([path]); _ = try await repository.commit(message: "Pinned provider bytes")
        let snapshot = try await repository.browseRepository()
        try Data("Current bytes must not export".utf8).write(to: root.appendingPathComponent(path))
        try await repository.stage([path]); _ = try await repository.commit(message: "New provider revision")
        try Data("Uncommitted bytes must remain".utf8).write(to: root.appendingPathComponent(path))
        let index = try Data(contentsOf: root.appendingPathComponent(".git/index"))
        let head = try await repository.run(["rev-parse", "HEAD"]).stdout
        let nested = try await repository.browseRepositoryDirectory(snapshot, directory: "src/nested")
        let file = nested.entries.first!
        var provider: NSItemProvider? = RepositoryBrowserDrag.provider(repository: repository, access: nil, snapshot: nested, entry: file, directory: nil, name: file.name, folder: false)
        let bytes: Data = try await withCheckedThrowingContinuation { continuation in
            provider!.loadFileRepresentation(forTypeIdentifier: UTType.data.identifier) { url, error in
                do { if let error { throw error }; guard let url else { throw RepositoryBrowserFailure.selection }; continuation.resume(returning: try Data(contentsOf: url)) }
                catch { continuation.resume(throwing: error) }
            }
        }
        guard bytes == original, provider?.suggestedName == "file.bin" else { throw RepositoryBrowserFailure.output }
        // The prepared source copy belongs to the provider, not the whole app.
        let temporaryRoot = try TurtleGitTemporaryStorage.root
        let prepared = try manager.contentsOfDirectory(at: temporaryRoot, includingPropertiesForKeys: nil).filter { $0.lastPathComponent.hasPrefix("TurtleGitBrowserExport-") }
        guard !prepared.isEmpty else { throw RepositoryBrowserFailure.output }
        provider = nil
        for _ in 0..<200 { if prepared.allSatisfy({ !manager.fileExists(atPath: $0.path) }) { break }; try await Task.sleep(nanoseconds: 10_000_000) }
        guard prepared.allSatisfy({ !manager.fileExists(atPath: $0.path) }) else { throw RepositoryBrowserFailure.output }
        let folder = snapshot.entries.first { $0.name == "src" }!
        let folderProvider = RepositoryBrowserDrag.provider(repository: repository, access: nil, snapshot: snapshot, entry: folder, directory: nil, name: folder.name, folder: true)
        let folderBytes: Data = try await withCheckedThrowingContinuation { continuation in
            folderProvider.loadFileRepresentation(forTypeIdentifier: UTType.folder.identifier) { url, error in
                do { if let error { throw error }; guard let url else { throw RepositoryBrowserFailure.selection }; continuation.resume(returning: try Data(contentsOf: url.appendingPathComponent("nested/file.bin"))) }
                catch { continuation.resume(throwing: error) }
            }
        }
        guard folderBytes == original, folderProvider.suggestedName == "src",
              try Data(contentsOf: root.appendingPathComponent(".git/index")) == index,
              try Data(contentsOf: root.appendingPathComponent(path)) == Data("Uncommitted bytes must remain".utf8) else { throw RepositoryBrowserFailure.output }
        let receiver = root.appendingPathComponent("receiver")
        try manager.createDirectory(at: receiver, withIntermediateDirectories: true)
        let promise = RepositoryBrowserFilePromise(repository: repository, access: nil, snapshot: nested, entry: file)
        let promised = promise.provider(), destination = receiver.appendingPathComponent(file.name)
        var delivered: Error??
        promise.filePromiseProvider(promised, writePromiseTo: destination) { delivered = .some($0) }
        guard RepositoryBrowserExportFiles.activeLoads > 0 else { throw RepositoryBrowserFailure.output }
        for _ in 0..<500 { if delivered != nil && RepositoryBrowserExportFiles.activeLoads == 0 { break }; try await Task.sleep(nanoseconds: 10_000_000) }
        guard delivered != nil, delivered! == nil, try Data(contentsOf: destination) == original else { throw RepositoryBrowserFailure.output }
        do { try await promise.write(to: destination); throw RepositoryBrowserFailure.output }
        catch let error as NSError where error.domain == NSPOSIXErrorDomain && error.code == Int(EEXIST) {}
        guard try Data(contentsOf: destination) == original else { throw RepositoryBrowserFailure.output }
        let cancelled = OperationCancellation(); cancelled.cancel()
        let refused = receiver.appendingPathComponent("cancelled.bin")
        do { try await promise.write(to: refused, cancellation: cancelled); throw RepositoryBrowserFailure.output }
        catch OperationCancellationFailure.cancelled {}
        guard !manager.fileExists(atPath: refused.path), !(try manager.contentsOfDirectory(atPath: receiver.path)).contains(where: { $0.hasPrefix(".turtlegit-promise-") }) else { throw RepositoryBrowserFailure.output }
        // Cancelling a real item-provider Progress terminates a started Git read.
        let marker = root.appendingPathComponent("read-started"), wrapper = root.appendingPathComponent("slow-git")
        func quote(_ value: String) -> String {
            let slash = String(UnicodeScalar(92)!)
            return "'" + value.replacingOccurrences(of: "'", with: "'" + slash + "''") + "'"
        }
        let script = """
        #!/bin/sh
        if [ "$4" = cat-file ]; then
          /usr/bin/touch \(quote(marker.path))
          while :; do /bin/sleep 1; done
        fi
        exec /usr/bin/git "$@"

        """
        try Data(script.utf8).write(to: wrapper); try manager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: wrapper.path)
        let slow = RepositoryBrowserDrag.provider(repository: GitRepository(root: root, executable: wrapper), access: nil, snapshot: nested, entry: file, directory: nil, name: file.name, folder: false)
        var cancellationReply: Error??
        let progress = slow.loadFileRepresentation(forTypeIdentifier: UTType.data.identifier) { _, error in Task { @MainActor in cancellationReply = .some(error) } }
        for _ in 0..<500 { if manager.fileExists(atPath: marker.path) { break }; try await Task.sleep(nanoseconds: 10_000_000) }
        guard manager.fileExists(atPath: marker.path) else { throw RepositoryBrowserFailure.output }
        progress.cancel()
        for _ in 0..<500 { if cancellationReply != nil && RepositoryBrowserExportFiles.activeLoads == 0 { break }; try await Task.sleep(nanoseconds: 10_000_000) }
        guard cancellationReply != nil, cancellationReply! != nil, RepositoryBrowserExportFiles.activeLoads == 0 else { throw RepositoryBrowserFailure.output }
        let finalHead = try await repository.run(["rev-parse", "HEAD"]).stdout
        guard finalHead == head else { throw RepositoryBrowserFailure.output }
        print("Standalone historical transport: native file/folder item receivers preserve pinned bytes; provider release cleans its prepared copy; queued promise accounting, coordinated exclusive delivery, collision/pre-cancel refusal and real started Progress cancellation passed. HEAD/index/working bytes unchanged; owned exports cleaned up.")
    }
}
