// SPDX-License-Identifier: GPL-2.0-or-later
// Native handoff for the pinned diff-odt.js / merge-odt.js UNO workflows.
import Foundation

public enum LibreOfficeComparisonFailure: LocalizedError, Sendable {
    case application, absent
    case worker(String, possiblyOpened: Bool)
    public var possiblyOpened: Bool { if case .worker(_, let value) = self { return value }; return false }
    public var errorDescription: String? {
        switch self {
        case .application: return "LibreOffice with its bundled Python runtime is required. Install LibreOffice or choose another comparison tool in Settings."
        case .absent: return "LibreOffice comparison requires two existing document files."
        case .worker(let message, _): return "LibreOffice could not prepare the document comparison: " + message
        }
    }
}

public struct LibreOfficeComparisonPreview: Sendable {
    public struct Request: Codable, Sendable {
        public let base: String, destination: String, result: String?
        public let directory: String, pipe: String
    }
    public struct Receipt: Codable, Sendable {
        public let success: Bool, possiblyOpened: Bool, message: String
        public init(success: Bool, possiblyOpened: Bool, message: String) {
            self.success = success; self.possiblyOpened = possiblyOpened; self.message = message
        }
    }
    public let directory: URL, base: URL, destination: URL, request: URL, script: URL
    public var reply: URL { directory.appendingPathComponent("reply.json") }
    public var cancellationFile: URL { directory.appendingPathComponent("cancel") }
    public static func prepare(_ document: FileComparisonDocument, in root: URL, cancellation: OperationCancellation) throws -> Self {
        guard !document.base.isDeleted, !document.destination.isDeleted else { throw LibreOfficeComparisonFailure.absent }
        return try prepare(base: document.base.bytes, destination: document.destination.bytes,
                           path: document.destination.path, basePath: document.base.path, result: nil, in: root, cancellation: cancellation)
    }
    public static func prepare(_ input: ExternalMergeInputs, in root: URL, cancellation: OperationCancellation) throws -> Self {
        // Source merge-odt compares mine with theirs; it does not consume base.
        try prepare(base: input.theirs, destination: input.mine, path: input.entry.path, basePath: input.entry.path,
                    result: input.result.path, in: root, cancellation: cancellation)
    }
    private static func prepare(base: Data, destination: Data, path: String, basePath: String, result: String?, in root: URL, cancellation: OperationCancellation) throws -> Self {
        try cancellation.check()
        guard !path.contains("\0"), !basePath.contains("\0"), result?.contains("\0") != true else { throw DiffToolFailure.arguments }
        let manager = FileManager.default, id = UUID().uuidString.replacingOccurrences(of: "-", with: "")
        let directory = root.appendingPathComponent("TurtleGitLibreOffice-" + id, isDirectory: true)
        try manager.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        do {
            func copy(_ bytes: Data, side: String, sourcePath: String) throws -> URL {
                let name = (sourcePath as NSString).lastPathComponent
                let filename = name.isEmpty || name == "." || name == ".." ? "document.odt" : name
                try cancellation.check()
                let folder = directory.appendingPathComponent(side, isDirectory: true)
                try manager.createDirectory(at: folder, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
                let file = folder.appendingPathComponent(filename)
                try bytes.write(to: file, options: .withoutOverwriting)
                try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
                return file
            }
            let old = try copy(base, side: "base", sourcePath: basePath), new = try copy(destination, side: "new", sourcePath: path)
            let request = directory.appendingPathComponent("request.json"), script = directory.appendingPathComponent("compare.py")
            let value = Request(base: old.path, destination: new.path, result: result, directory: directory.path, pipe: "TurtleGit" + id)
            try JSONEncoder().encode(value).write(to: request, options: .withoutOverwriting)
            try Data(workerSource.utf8).write(to: script, options: .withoutOverwriting)
            for file in [request, script] { try manager.setAttributes([.posixPermissions: 0o400], ofItemAtPath: file.path) }
            try cancellation.check()
            return Self(directory: directory, base: old, destination: new, request: request, script: script)
        } catch { try? manager.removeItem(at: directory); throw error }
    }
    public func discard() { try? FileManager.default.removeItem(at: directory) }

    // Fixed code, literal JSON arguments, isolated office profile and UUID pipe.
    // Never use the user's desktop/current frame or attach to their office server.
    public static let workerSource = #"""
    import json, os, pathlib, subprocess, sys, time

    def run(request_path, office_path):
        request = json.loads(pathlib.Path(request_path).read_text(encoding="utf-8"))
        root = pathlib.Path(request["directory"])
        office = None
        document = None
        opened = False
        outcome = {"success": False, "possiblyOpened": False, "message": "Operation did not finish."}
        def cancelled():
            if (root / "cancel").exists():
                raise RuntimeError("Operation cancelled.")
        try:
            contents = pathlib.Path(office_path).parent.parent
            sys.path[:0] = [str(contents / "Resources"), str(contents / "MacOS")]
            os.environ["URE_BOOTSTRAP"] = "vnd.sun.star.pathname:" + str(contents / "Resources" / "fundamentalrc")
            import uno
            from com.sun.star.beans import PropertyValue
            from com.sun.star.document.MacroExecMode import NEVER_EXECUTE
            from com.sun.star.document.UpdateDocMode import NO_UPDATE
            def prop(name, value):
                item = PropertyValue(); item.Name = name; item.Value = value
                return item
            def file_url(path):
                return uno.systemPathToFileUrl(str(path))
            cancelled()
            # A separate profile forces our own process/server instead of using
            # an unrelated running LibreOffice instance. No shell interprets args.
            profile = file_url(root / "profile")
            pipe = request["pipe"]
            office = subprocess.Popen([office_path, "-env:UserInstallation=" + profile,
                "--norestore", "--nodefault", "--nologo",
                "--accept=pipe,name=" + pipe + ";urp;StarOffice.ServiceManager"],
                stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            context = uno.getComponentContext()
            resolver = context.ServiceManager.createInstanceWithContext("com.sun.star.bridge.UnoUrlResolver", context)
            deadline = time.monotonic() + 45
            while True:
                cancelled()
                try:
                    remote = resolver.resolve("uno:pipe,name=" + pipe + ";urp;StarOffice.ComponentContext")
                    break
                except Exception:
                    if office.poll() is not None or time.monotonic() >= deadline:
                        raise RuntimeError("Could not connect to the private LibreOffice instance.")
                    time.sleep(0.1)
            services = remote.ServiceManager
            desktop = services.createInstanceWithContext("com.sun.star.frame.Desktop", remote)
            cancelled()
            # Explicit UNO constants prevent inherited macro/link update policy.
            # The destination is a private writable copy, as required for tracking.
            properties = (prop("ShowTrackedChanges", True), prop("ReadOnly", False),
                          prop("MacroExecutionMode", uno.Any("short", NEVER_EXECUTE)), prop("UpdateDocMode", uno.Any("short", NO_UPDATE)))
            opened = True  # A load may create a window before reporting an error.
            document = desktop.loadComponentFromURL(file_url(request["destination"]), "_blank", 0, properties)
            if document is None:
                raise RuntimeError("LibreOffice did not open the captured document.")
            cancelled()
            frame = document.getCurrentController().getFrame()
            dispatcher = services.createInstanceWithContext("com.sun.star.frame.DispatchHelper", remote)
            dispatcher.executeDispatch(frame, ".uno:ShowTrackedChanges", "", 0, (prop("ShowTrackedChanges", True),))
            dispatcher.executeDispatch(frame, ".uno:CompareDocuments", "", 0, (prop("URL", file_url(request["base"])),))
            cancelled()
            outcome = {"success": True, "possiblyOpened": True, "message": ""}
            # Leave the result and its private office instance for user review.
            # Source merge requires Save As to the working result, then explicit
            # Mark Resolved in TurtleGit; no automatic stage/save takes place.
        except Exception as error:
            outcome = {"success": False, "possiblyOpened": opened, "message": str(error)[:4096]}
            if not opened and office is not None:
                try:
                    office.terminate(); office.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    office.kill(); office.wait()
                except ProcessLookupError:
                    pass
        finally:
            temporary = root / "reply.tmp"
            temporary.write_text(json.dumps(outcome, ensure_ascii=False), encoding="utf-8")
            temporary.replace(root / "reply.json")

    if __name__ == "__main__":
        run(sys.argv[1], sys.argv[2])
    """#
}
