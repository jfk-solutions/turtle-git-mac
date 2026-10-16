// SPDX-License-Identifier: GPL-2.0-or-later
import AppKit
import TurtleGitCore

@MainActor enum LibreOfficeComparisonAutomation {
    struct Runtime {
        let application: URL, office: URL
        init(bundle: URL) throws {
            let manager = FileManager.default
            office = bundle.appendingPathComponent("Contents/MacOS/soffice")
            let framework = bundle.appendingPathComponent("Contents/Frameworks/LibreOfficePython.framework")
            let versions = framework.appendingPathComponent("Versions")
            var candidates = [framework.appendingPathComponent("Resources/Python.app"), versions.appendingPathComponent("Current/Resources/Python.app")]
            for version in (try? manager.contentsOfDirectory(atPath: versions.path)) ?? [] {
                candidates.append(versions.appendingPathComponent(version).appendingPathComponent("Resources/Python.app"))
            }
            guard manager.isExecutableFile(atPath: office.path),
                  let candidate = candidates.first(where: { url in
                      guard let executable = Bundle(url: url)?.executableURL else { return false }
                      return manager.isExecutableFile(atPath: executable.path) &&
                          executable.resolvingSymlinksInPath().path.hasPrefix(bundle.resolvingSymlinksInPath().path + "/")
                  }) else { throw LibreOfficeComparisonFailure.application }
            application = candidate
        }
    }
    static var launch: (URL, NSWorkspace.OpenConfiguration) async throws -> NSRunningApplication = { application, configuration in
        try await withCheckedThrowingContinuation { reply in
            NSWorkspace.shared.openApplication(at: application, configuration: configuration) { app, error in
                if let app { reply.resume(returning: app) }
                else { reply.resume(throwing: error ?? LibreOfficeComparisonFailure.application) }
            }
        }
    }
    static func readReceipt(_ preview: LibreOfficeComparisonPreview) throws -> LibreOfficeComparisonPreview.Receipt {
        let file = try FileHandle(forReadingFrom: preview.reply); defer { try? file.close() }
        let bytes = try file.read(upToCount: 65_537) ?? Data()
        guard bytes.count <= 65_536 else { throw LibreOfficeComparisonFailure.worker("Invalid completion receipt.", possiblyOpened: true) }
        return try JSONDecoder().decode(LibreOfficeComparisonPreview.Receipt.self, from: bytes)
    }
    static func compare(_ preview: LibreOfficeComparisonPreview, cancellation: OperationCancellation) async throws {
        try cancellation.check()
        guard let bundle = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "org.libreoffice.script") else {
            throw LibreOfficeComparisonFailure.application
        }
        let runtime = try Runtime(bundle: bundle)
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        configuration.activates = false
        configuration.environment = ["PYTHONNOUSERSITE": "1", "PYTHONDONTWRITEBYTECODE": "1"]
        configuration.arguments = [preview.script.path, preview.request.path, runtime.office.path]
        try cancellation.check()
        let app: NSRunningApplication
        do { app = try await launch(runtime.application, configuration) }
        catch { throw LibreOfficeComparisonFailure.worker(error.localizedDescription, possiblyOpened: true) }
        let start = ProcessInfo.processInfo.systemUptime
        var cancelSent = false, terminateSent = false, forceSent = false
        while !app.isTerminated {
            if (cancellation.isCancelled || Task.isCancelled), !cancelSent {
                try? Data().write(to: preview.cancellationFile); cancelSent = true
            }
            let elapsed = ProcessInfo.processInfo.systemUptime - start
            if elapsed >= 180, !terminateSent { app.terminate(); terminateSent = true }
            if elapsed >= 185, !forceSent { app.forceTerminate(); forceSent = true }
            // A cancelled Task must still drain its owned runtime. Unlike a
            // throwing Task.sleep, this wait cannot become a cancellation spin.
            await withCheckedContinuation { reply in
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { reply.resume() }
            }
        }
        let receipt: LibreOfficeComparisonPreview.Receipt
        do { receipt = try readReceipt(preview) }
        catch { throw LibreOfficeComparisonFailure.worker("The runtime exited without confirming document preparation. Captured files were retained.", possiblyOpened: true) }
        guard receipt.success else { throw LibreOfficeComparisonFailure.worker(receipt.message, possiblyOpened: receipt.possiblyOpened) }
        try cancellation.check(); try Task.checkCancellation()
    }
}
