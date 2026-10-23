// Native receiver acceptance for the production drag provider; uses only an owned fixture.
import Foundation
import AppKit
import Darwin
import UniformTypeIdentifiers
import TurtleGitCore

@main struct BrowserItemProviderCheck {
    struct Failure: Error, CustomStringConvertible { let description: String }
    @MainActor static var stage = "startup"
    @MainActor static func main() async {
        do { try await run() }
        catch { fputs("Browser provider stage \(stage): \(error)\n", stderr); exit(1) }
    }
    @MainActor static func run() async throws {
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
        stage = "capture historical snapshot"
        let snapshot = try await repository.browseRepository()
        try Data("Current bytes must not export".utf8).write(to: root.appendingPathComponent(path))
        try await repository.stage([path]); _ = try await repository.commit(message: "New provider revision")
        try Data("Uncommitted bytes must remain".utf8).write(to: root.appendingPathComponent(path))
        let index = try Data(contentsOf: root.appendingPathComponent(".git/index"))
        let head = try await repository.run(["rev-parse", "HEAD"]).stdout
        let nested = try await repository.browseRepositoryDirectory(snapshot, directory: "src/nested")
        guard let file = nested.entries.first(where: { $0.name == "file.bin" }) else { throw Failure(description: "Pinned directory inventory omitted file.bin: \(nested.entries.map(\.name))") }
        let temporaryRoot = try TurtleGitTemporaryStorage.root
        let priorExports = Set(try manager.contentsOfDirectory(at: temporaryRoot, includingPropertiesForKeys: nil))
        var provider: NSItemProvider? = RepositoryBrowserDrag.provider(repository: repository, access: nil, snapshot: nested, entry: file, directory: nil, name: file.name, folder: false)
        stage = "pinned file provider"
        let bytes: Data = try await withCheckedThrowingContinuation { continuation in
            provider!.loadFileRepresentation(forTypeIdentifier: UTType.data.identifier) { url, error in
                do { if let error { throw error }; guard let url else { throw RepositoryBrowserFailure.selection }; continuation.resume(returning: try Data(contentsOf: url)) }
                catch { continuation.resume(throwing: error) }
            }
        }
        guard bytes == original, provider?.suggestedName == "file.bin" else { throw Failure(description: "Pinned file bytes/name mismatch: bytes=\(bytes as NSData) name=\(String(describing:provider?.suggestedName))") }
        // The prepared source copy belongs to the provider, not the whole app.
        stage = "prepared inventory"
        let prepared = try manager.contentsOfDirectory(at: temporaryRoot, includingPropertiesForKeys: nil).filter { $0.lastPathComponent.hasPrefix("TurtleGitBrowserExport-") && !priorExports.contains($0) }
        guard !prepared.isEmpty else { throw Failure(description: "No prepared export found in owned temporary inventory after file delivery") }
        stage = "provider release"
        provider = nil
        for _ in 0..<200 { if prepared.allSatisfy({ !manager.fileExists(atPath: $0.path) }) { break }; try await Task.sleep(nanoseconds: 10_000_000) }
        guard prepared.allSatisfy({ !manager.fileExists(atPath: $0.path) }) else { throw Failure(description: "Prepared export survived provider release: \(prepared.filter{manager.fileExists(atPath:$0.path)}) activeLoads=\(RepositoryBrowserExportFiles.activeLoads)") }
        stage = "pinned folder provider"
        guard let folder = snapshot.entries.first(where: { $0.name == "src" }) else { throw Failure(description: "Pinned root inventory omitted src: \(snapshot.entries.map(\.name))") }
        let folderProvider = RepositoryBrowserDrag.provider(repository: repository, access: nil, snapshot: snapshot, entry: folder, directory: nil, name: folder.name, folder: true)
        let folderBytes: Data = try await withCheckedThrowingContinuation { continuation in
            folderProvider.loadFileRepresentation(forTypeIdentifier: UTType.folder.identifier) { url, error in
                do { if let error { throw error }; guard let url else { throw RepositoryBrowserFailure.selection }; continuation.resume(returning: try Data(contentsOf: url.appendingPathComponent("nested/file.bin"))) }
                catch { continuation.resume(throwing: error) }
            }
        }
        guard folderBytes == original, folderProvider.suggestedName == "src",
              try Data(contentsOf: root.appendingPathComponent(".git/index")) == index,
              try Data(contentsOf: root.appendingPathComponent(path)) == Data("Uncommitted bytes must remain".utf8) else { throw Failure(description: "Folder bytes/name or original index/working bytes mismatch") }
        let receiver = root.appendingPathComponent("receiver")
        try manager.createDirectory(at: receiver, withIntermediateDirectories: true)
        stage = "native promise delivery"
        let promise = RepositoryBrowserFilePromise(repository: repository, access: nil, snapshot: nested, entry: file)
        let promised = promise.provider(), destination = receiver.appendingPathComponent(file.name)
        var delivered: Error??
        promise.filePromiseProvider(promised, writePromiseTo: destination) { delivered = .some($0) }
        guard RepositoryBrowserExportFiles.activeLoads > 0 else { throw Failure(description: "Queued native promise was not counted before dispatch") }
        for _ in 0..<500 { if delivered != nil && RepositoryBrowserExportFiles.activeLoads == 0 { break }; try await Task.sleep(nanoseconds: 10_000_000) }
        guard delivered != nil, delivered! == nil, try Data(contentsOf: destination) == original else { throw Failure(description: "Promise delivery failed: reply=\(String(describing:delivered)) activeLoads=\(RepositoryBrowserExportFiles.activeLoads)") }
        do { try await promise.write(to: destination); throw Failure(description: "Promise overwrote an existing receiver file") }
        catch let error as NSError where error.domain == NSPOSIXErrorDomain && error.code == Int(EEXIST) {}
        guard try Data(contentsOf: destination) == original else { throw Failure(description: "Collision refusal changed existing receiver contents") }
        stage = "pre-cancel refusal"
        let cancelled = OperationCancellation(); cancelled.cancel()
        let refused = receiver.appendingPathComponent("cancelled.bin")
        do { try await promise.write(to: refused, cancellation: cancelled); throw Failure(description: "Pre-cancelled promise unexpectedly delivered") }
        catch OperationCancellationFailure.cancelled {}
        guard !manager.fileExists(atPath: refused.path), !(try manager.contentsOfDirectory(atPath: receiver.path)).contains(where: { $0.hasPrefix(".turtlegit-promise-") }) else { throw Failure(description: "Pre-cancelled delivery left output or staging debris") }
        // Cancelling a real item-provider Progress terminates a started Git read.
        stage = "started CLI cancellation"
        let marker = root.appendingPathComponent("read-started"), wrapper = root.appendingPathComponent("slow-git")
        func quote(_ value: String) -> String {
            let slash = String(UnicodeScalar(92)!)
            return "'" + value.replacingOccurrences(of: "'", with: "'" + slash + "''") + "'"
        }
        let script = """
        #!/bin/sh
        is_cat_file() {
          while [ "$#" -gt 0 ]; do
            case "$1" in
              -c|-C|--git-dir|--work-tree|--namespace|--config-env) shift; [ "$#" -gt 0 ] || return 1; shift ;;
              --git-dir=*|--work-tree=*|--namespace=*|--config-env=*|--no-pager|--literal-pathspecs|--no-literal-pathspecs|--no-optional-locks) shift ;;
              cat-file) return 0 ;;
              *) return 1 ;;
            esac
          done
          return 1
        }
        if is_cat_file "$@"; then
          /usr/bin/touch \(quote(marker.path))
          while :; do /bin/sleep 1; done
        fi
        exec /usr/bin/git "$@"

        """
        try Data(script.utf8).write(to: wrapper); try manager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: wrapper.path)
        let slow = RepositoryBrowserDrag.provider(repository: GitRepository(root: root, executable: wrapper), access: nil, snapshot: nested, entry: file, directory: nil, name: file.name, folder: false, backend: .init(enabled: false))
        var cancellationReply: Error??
        let progress = slow.loadFileRepresentation(forTypeIdentifier: UTType.data.identifier) { _, error in Task { @MainActor in cancellationReply = .some(error) } }
        for _ in 0..<500 { if manager.fileExists(atPath: marker.path) { break }; try await Task.sleep(nanoseconds: 10_000_000) }
        guard manager.fileExists(atPath: marker.path) else { throw Failure(description: "Held CLI cat-file never started: reply=\(String(describing:cancellationReply)) activeLoads=\(RepositoryBrowserExportFiles.activeLoads) types=\(slow.registeredTypeIdentifiers)") }
        progress.cancel()
        for _ in 0..<500 { if cancellationReply != nil && RepositoryBrowserExportFiles.activeLoads == 0 { break }; try await Task.sleep(nanoseconds: 10_000_000) }
        guard cancellationReply != nil, cancellationReply! != nil, RepositoryBrowserExportFiles.activeLoads == 0 else { throw Failure(description: "Started Progress cancellation did not fail/drain: reply=\(String(describing:cancellationReply)) activeLoads=\(RepositoryBrowserExportFiles.activeLoads)") }
        stage = "final preservation"
        let finalHead = try await repository.run(["rev-parse", "HEAD"]).stdout
        guard finalHead == head else { throw Failure(description: "Provider workflow changed HEAD") }
        print("Standalone historical transport: native file/folder item receivers preserve pinned bytes; provider release cleans its prepared copy; queued promise accounting, coordinated exclusive delivery, collision/pre-cancel refusal and real started Progress cancellation passed. HEAD/index/working bytes unchanged; owned exports cleaned up.")
    }
}
