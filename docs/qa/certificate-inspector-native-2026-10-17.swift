import AppKit
import Security
import SecurityInterface
import ScreenCaptureKit
import TurtleGitCore

private actor CertificateWriteGate {
    var waiting = false
    private var continuation: CheckedContinuation<Void, Never>?
    func pause() async { waiting = true; await withCheckedContinuation { continuation = $0 } }
    func release() { continuation?.resume(); continuation = nil }
}
@main struct CertificateInspectorVerification {
    struct Failure: Error { let message: String }
    static func require(_ value: Bool, _ message: String) throws { if !value { throw Failure(message: message) } }
    @MainActor static func wait(_ message: String, _ ready: () -> Bool) async throws {
        for _ in 0..<2000 { if ready() { return }; try await Task.sleep(nanoseconds: 10_000_000) }
        throw Failure(message: "Timeout: " + message)
    }
    @MainActor static func main() async {
        do { try await SVNAuthenticationVerification.verify(); try await verify() }
        catch { fputs("Certificate inspector failed: \(error)\n", stderr); exit(1) }
    }
    @MainActor static func capture(_ owner: NSWindowController, to directory: URL) async throws {
        guard #available(macOS 14.4, *) else { throw Failure(message: "Native capture requires macOS 14.4") }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        NSApp.setActivationPolicy(.regular); owner.showWindow(nil); NSApp.activate(ignoringOtherApps: true)
        for (appearance, name) in [(NSAppearance.Name.aqua, "light"), (.darkAqua, "dark")] {
            let window = owner.window!; window.appearance = NSAppearance(named: appearance); window.makeKeyAndOrderFront(nil); window.contentView?.layoutSubtreeIfNeeded()
            try await Task.sleep(nanoseconds: 350_000_000)
            let own = try await SCShareableContent.currentProcess
            guard let captured = own.windows.first(where: { $0.windowID == CGWindowID(window.windowNumber) }) else { throw Failure(message: "Owned inspector missing") }
            let configuration = SCStreamConfiguration(); configuration.width = Int(window.frame.width * window.backingScaleFactor); configuration.height = Int(window.frame.height * window.backingScaleFactor); configuration.showsCursor = false; configuration.ignoreShadowsSingleWindow = true
            let image = try await SCScreenshotManager.captureImage(contentFilter: SCContentFilter(desktopIndependentWindow: captured), configuration: configuration)
            try NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])!.write(to: directory.appendingPathComponent("certificate-inspector-" + name + ".png"))
        }
        owner.window?.orderOut(nil)
    }
    @MainActor static func verify() async throws {
        NSApp.setActivationPolicy(.accessory); NSApp.finishLaunching()
        let root = URL(fileURLWithPath: CommandLine.arguments[1]), fm = FileManager.default
        let source = URL(fileURLWithPath: ProcessInfo.processInfo.environment["TURTLEGIT_CERTIFICATE_FIXTURE"]!), original = try Data(contentsOf: source)
        let details = try GitCertificateDetails(base64DER: original.base64EncodedString())
        let clipboard = NSPasteboard(name: .init("TurtleGit.Certificate.QA." + UUID().uuidString))
        defer { clipboard.releaseGlobally() }
        let viewer = GitCertificateDetailsWindowController(details: details, pasteboard: clipboard, images: { MenuIcon.originalImage(resource: $0) })
        defer { viewer.close() }
        viewer.window?.contentView?.layoutSubtreeIfNeeded()
        try require((viewer.certificateView.value(forKey: "editable") as? Bool) == false && (viewer.certificateView.value(forKey: "trustDisplayed") as? Bool) == false, "Inspector permits trust editing/display")
        try require(viewer.tabs.numberOfTabViewItems == 2 && viewer.copyButton.image != nil && viewer.exportButton.image != nil && !viewer.text.isEditable && viewer.text.isSelectable, "Native/text inspection pages missing")
        viewer.copyButton.performClick(nil); try require(clipboard.string(forType: .string) == details.fingerprints, "Copy changed fingerprint bytes")
        var answers: [(NSApplication.ModalResponse) -> Void] = [], panels: [NSSavePanel] = []
        viewer.presentExport = { panel, _, reply in panels.append(panel); answers.append(reply) }
        let der = root.appendingPathComponent("public.der"), pem = root.appendingPathComponent("public.pem")
        viewer.exportDestination = { _ in der }
        viewer.exportButton.performClick(nil); viewer.exportCertificate()
        try require(answers.count == 1 && !viewer.exportButton.isEnabled && panels[0].nameFieldStringValue == "Certificate.cer", "Export panel duplicate/default encoding")
        answers[0](.cancel); answers[0](.OK)
        try await wait("Panel Cancel") { viewer.exportButton.isEnabled }
        try require(!fm.fileExists(atPath: der.path), "Cancelled export wrote a file")
        viewer.exportCertificate(); answers[1](.OK); answers[1](.OK)
        try await wait("DER export") { fm.fileExists(atPath: der.path) && !viewer.exporting && viewer.exportButton.isEnabled }
        try require(try Data(contentsOf: der) == original, "DER export changed certificate")
        viewer.format.selectItem(at: 1); viewer.exportDestination = { _ in pem }; viewer.exportCertificate()
        try require(panels[2].nameFieldStringValue == "Certificate.pem", "PEM export filename")
        viewer.format.selectItem(at: 0) // A delayed callback retains the chosen encoding.
        answers[2](.OK); try await wait("PEM export") { fm.fileExists(atPath: pem.path) && !viewer.exporting && viewer.exportButton.isEnabled }
        try require(try Data(contentsOf: pem) == details.encoded(as: .pem), "Delayed export changed captured format")
        viewer.writeExport = { _, _ in throw Failure(message: "Injected export failure") }
        viewer.exportCertificate(); answers[3](.OK)
        try await wait("Export error") { !viewer.status.stringValue.isEmpty && !viewer.exporting }
        try require(try Data(contentsOf: source) == original, "Inspection/export modified source")
        if let path = ProcessInfo.processInfo.environment["TURTLEGIT_CERTIFICATE_CAPTURES"] {
            viewer.status.stringValue = ""; try await capture(viewer, to: URL(fileURLWithPath: path))
        }
        viewer.close(); let copied = clipboard.string(forType: .string); viewer.copyFingerprints()
        try require(clipboard.string(forType: .string) == copied && viewer.retired, "Retired inspector accepted copy")
        // The helper may exit as soon as its response callback runs. Parent
        // rejection must therefore wait for an accepted export to finish.
        let prompt = GitSVNAuthenticationPrompt(kind: .trust, realm: "private fixture", maySave: true, failures: 8, hostname: "turtlegit.example.invalid", issuer: "fixture", certificate: original.base64EncodedString())
        var responses = 0, result: GitSVNAuthenticationResponse?, pending: GitCertificateDetailsWindowController?, response: ((NSApplication.ModalResponse) -> Void)?
        let gate = CertificateWriteGate()
        let parent = GitSVNPromptWindowController(prompt: prompt) { answer in responses += 1; result = answer }
        defer { parent.close() }
        parent.makeCertificateViewer = { certificate in
            let child = GitCertificateDetailsWindowController(details: certificate, pasteboard: clipboard, images: { MenuIcon.originalImage(resource: $0) }); pending = child
            child.presentExport = { _, _, reply in response = reply }; child.exportDestination = { _ in root.appendingPathComponent("owned-export.cer") }
            child.writeExport = { bytes, destination in await gate.pause(); try bytes.write(to: destination, options: .atomic) }
            return child
        }
        parent.openCertificate(); pending!.exportCertificate(); response?(.OK)
        for _ in 0..<2000 { if await gate.waiting { break }; try await Task.sleep(nanoseconds: 10_000_000) }
        try require(await gate.waiting && pending!.exporting, "Owned writer did not reach gate")
        parent.close(); parent.abort()
        try require(responses == 0 && parent.finished && pending!.retired && pending!.exporting, "Helper response abandoned owned export")
        response?(.OK); await gate.release()
        try await wait("Parent rejection after writer") { responses == 1 }
        try require(result?.decision == .reject && !pending!.exporting && pending!.status.stringValue.isEmpty && (try Data(contentsOf: root.appendingPathComponent("owned-export.cer"))) == original, "Export retirement/response/source bytes changed")
        parent.abort(); try require(responses == 1, "Response duplicated")
        let cancelledParent = GitSVNPromptWindowController(prompt: prompt) { _ in responses += 1 }
        defer { cancelledParent.close() }; var cancelledChild: GitCertificateDetailsWindowController?, oldReply: ((NSApplication.ModalResponse) -> Void)?
        cancelledParent.makeCertificateViewer = { certificate in
            let child = GitCertificateDetailsWindowController(details: certificate, pasteboard: clipboard, images: { MenuIcon.originalImage(resource: $0) }); cancelledChild = child
            child.presentExport = { _, _, reply in oldReply = reply }; child.exportDestination = { _ in root.appendingPathComponent("must-not-write.cer") }; return child
        }
        cancelledParent.openCertificate(); cancelledChild!.exportCertificate(); cancelledParent.close(); oldReply?(.OK)
        try await wait("Retired picker") { responses == 2 }
        try require(cancelledChild!.retired && !fm.fileExists(atPath: root.appendingPathComponent("must-not-write.cer").path), "Late export picker escaped parent")
        print("PASS: native certificate inspector, read-only trust, exact fingerprint clipboard, DER/PEM, owned chooser, errors and deferred parent response")
    }
}
