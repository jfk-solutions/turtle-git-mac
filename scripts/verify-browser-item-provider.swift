// Native receiver acceptance for the production drag provider; uses only an owned fixture.
import Foundation
import AppKit
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
        let provider = RepositoryBrowserDrag.provider(repository: repository, access: nil, snapshot: nested, entry: file, directory: nil, name: file.name, folder: false)
        let bytes: Data = try await withCheckedThrowingContinuation { continuation in
            provider.loadFileRepresentation(forTypeIdentifier: UTType.data.identifier) { url, error in
                do { if let error { throw error }; guard let url else { throw RepositoryBrowserFailure.selection }; continuation.resume(returning: try Data(contentsOf: url)) }
                catch { continuation.resume(throwing: error) }
            }
        }
        guard bytes == original, provider.suggestedName == "file.bin" else { throw RepositoryBrowserFailure.output }
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
        let finalHead = try await repository.run(["rev-parse", "HEAD"]).stdout
        guard finalHead == head else { throw RepositoryBrowserFailure.output }
        print("Native file/folder NSItemProvider receivers read exact pinned binary contents; HEAD/index/working bytes unchanged; owned exports cleaned up.")
    }
}
