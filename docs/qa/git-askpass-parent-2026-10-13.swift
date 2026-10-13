import Foundation
import TurtleGitCore

@main struct AskpassParent {
    static func main() async throws {
        let root = URL(fileURLWithPath: CommandLine.arguments[1])
        let token = OperationCancellation()
        let repository = GitRepository(root: root, executable: root.appendingPathComponent("git-wrapper"), askpass: nil)
        let task = Task { try await repository.run(["fetch"], environmentOverrides: ["GIT_ASKPASS": CommandLine.arguments[2], "TURTLEGIT_ASKPASS_APPEARANCE": "dark"], cancellation: token) }
        for _ in 0..<5000 {
            if FileManager.default.fileExists(atPath: root.appendingPathComponent("cancel").path) { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        token.cancel()
        do { _ = try await task.value; throw NSError(domain: "AskpassQA", code: 1) }
        catch is OperationCancellationFailure {} catch is GitCommandCancellationFailure {}
        print("PASS displayed helper parent cancellation")
    }
}
