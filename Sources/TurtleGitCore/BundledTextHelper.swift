import Foundation
import Darwin

enum BundledTextHelperFailure: Error { case failed(String), timedOut }
enum BundledTextHelper {
    /// Runs off the main thread. File-backed output avoids pipe deadlocks;
    /// termination is bounded and cancellation is checked before/after execution.
    static func capture(executable: URL, arguments: [String]) throws -> Data {
        try Task.checkCancellation()
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("TurtleGitTextHelper-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let outputURL = temporary.appendingPathComponent("stdout"), errorURL = temporary.appendingPathComponent("stderr")
        try Data().write(to: outputURL); try Data().write(to: errorURL)
        let output = try FileHandle(forWritingTo: outputURL), error = try FileHandle(forWritingTo: errorURL)
        defer { try? output.close(); try? error.close() }
        let process = Process(), finished = DispatchSemaphore(value: 0)
        process.executableURL = executable; process.arguments = arguments
        process.standardInput = FileHandle.nullDevice; process.standardOutput = output; process.standardError = error
        process.terminationHandler = { _ in finished.signal() }
        try process.run()
        if finished.wait(timeout: .now() + 5) == .timedOut {
            if process.isRunning { process.terminate() }
            if finished.wait(timeout: .now() + 1) == .timedOut, process.isRunning { Darwin.kill(process.processIdentifier, SIGKILL) }
            process.waitUntilExit()
            throw BundledTextHelperFailure.timedOut
        }
        try Task.checkCancellation()
        guard process.terminationStatus == 0 else {
            let diagnostics = try FileHandle(forReadingFrom: errorURL)
            defer { try? diagnostics.close() }
            throw BundledTextHelperFailure.failed(String(decoding: try diagnostics.read(upToCount: 1024) ?? Data(), as: UTF8.self))
        }
        let size = (try FileManager.default.attributesOfItem(atPath: outputURL.path)[.size] as? NSNumber)?.intValue ?? 0
        guard size <= 32 * 1024 * 1024 else { throw BundledTextHelperFailure.failed("Helper output is too large.") }
        return try Data(contentsOf: outputURL)
    }
}
