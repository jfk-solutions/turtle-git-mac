import XCTest
@testable import TurtleGitCore

final class LibreOfficeComparisonTests: XCTestCase {
    private func root() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
    private func document(absent: Bool = false) -> FileComparisonDocument {
        .init(base: .init(path: "old.odt", revision: .revision("captured"), bytes: Data([0,255,13]), mode: "100644", isDeleted: absent),
              destination: .init(path: "folder/new \" # % 雪.ods", revision: .workingTree, bytes: Data([1,254,10]), mode: "100644"))
    }
    func testExactInputsLiteralJSONAndModes() throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let doc = document(), preview = try LibreOfficeComparisonPreview.prepare(doc, in: root, cancellation: .init())
        let request = try JSONDecoder().decode(LibreOfficeComparisonPreview.Request.self, from: Data(contentsOf: preview.request))
        XCTAssertEqual(try Data(contentsOf: preview.base), doc.base.bytes)
        XCTAssertEqual(try Data(contentsOf: preview.destination), doc.destination.bytes)
        XCTAssertEqual(request.base, preview.base.path); XCTAssertEqual(request.destination, preview.destination.path)
        XCTAssertNil(request.result); XCTAssertEqual(request.pipe.count, 41)
        for (file, mode) in [(preview.directory,0o700),(preview.base,0o600),(preview.destination,0o600),(preview.script,0o400)] {
            XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber)?.intValue, mode)
        }
        preview.discard(); XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
    }
    func testMergeUsesTheirsAgainstMineWithoutChangingWorkingResult() throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let result = root.appendingPathComponent("real.odt"), working = Data("working".utf8)
        try working.write(to: result)
        let input = ExternalMergeInputs(entry: .init(path: "real.odt", stages: []), base: Data([1]), mine: Data([2]), theirs: Data([3]), result: result)
        let preview = try LibreOfficeComparisonPreview.prepare(input, in: root, cancellation: .init())
        let request = try JSONDecoder().decode(LibreOfficeComparisonPreview.Request.self, from: Data(contentsOf: preview.request))
        XCTAssertEqual(try Data(contentsOf: preview.base), input.theirs)
        XCTAssertEqual(try Data(contentsOf: preview.destination), input.mine)
        XCTAssertEqual(request.result, result.path)
        try Data("edited".utf8).write(to: preview.destination)
        XCTAssertEqual(try Data(contentsOf: result), working)
    }
    func testAbsentAndCancellationDoNotLeaveInputs() throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let token = OperationCancellation(); token.cancel()
        XCTAssertThrowsError(try LibreOfficeComparisonPreview.prepare(document(), in: root, cancellation: token))
        XCTAssertThrowsError(try LibreOfficeComparisonPreview.prepare(document(absent: true), in: root, cancellation: .init()))
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
    }
    func testDefaultsRestoreSavedChoicesAndMergeRouting() throws {
        let suite = "TurtleGit.LibreOffice." + UUID().uuidString, prefs = UserDefaults(suiteName: suite)!
        defer { prefs.removePersistentDomain(forName: suite) }
        var diff = DiffToolPreferences.load(from: prefs), merge = MergeToolPreferences.load(from: prefs)
        for ext in ["odt","ods","sxw"] {
            XCTAssertEqual(try diff.selected(base: "a."+ext, destination: "b."+ext.uppercased())?.builtIn, .libreOfficeDocument)
            XCTAssertEqual(try merge.selected(path: "a."+ext)?.builtIn, .libreOfficeDocument)
            XCTAssertNil(try diff.selected(base: "a."+ext, destination: "b."+ext, alternate: true))
            XCTAssertNil(try merge.selected(path: "a."+ext, alternate: true))
        }
        let id = diff.associations.first { $0.pattern == ".odt" }!.id
        diff.associations[diff.associations.firstIndex { $0.pattern == ".odt" }!].program.builtIn = .wordDocument
        try diff.save(to: prefs)
        XCTAssertEqual(try DiffToolPreferences.load(from: prefs).selected(base: "a.odt", destination: "b.odt")?.builtIn, .wordDocument)
        diff.restoreBundledAssociations(); XCTAssertEqual(diff.associations.first { $0.pattern == ".odt" }?.id, id)
        merge.program.enabled = true; merge.program.builtIn = .excelWorkbook
        XCTAssertFalse(merge.valid)
    }
    func testRealWorkerWithInjectedUNOAndProcessInterfaces() throws {
        // Execute shipping Python code with protocol doubles. This verifies
        // frame ownership, literal URL conversion, properties and failure receipts,
        // without launching installed office software or altering user profiles.
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        for mode in ["success", "dispatch-error", "open-error", "pre-cancel", "connect-error"] {
            let preview = try LibreOfficeComparisonPreview.prepare(document(), in: root, cancellation: .init())
            if mode == "pre-cancel" { try Data().write(to: preview.cancellationFile) }
            let harness = preview.directory.appendingPathComponent("harness.py")
            let code = #"""
            import sys, types, subprocess, pathlib, json
            request, worker, mode = sys.argv[1:]
            events = []
            def module(name):
                value = types.ModuleType(name); sys.modules[name] = value; return value
            for name in ['com','com.sun','com.sun.star','com.sun.star.beans','com.sun.star.document']:
                module(name)
            module('com.sun.star.document.MacroExecMode').NEVER_EXECUTE = 0
            module('com.sun.star.document.UpdateDocMode').NO_UPDATE = 0
            sys.modules['com.sun.star.beans'].PropertyValue = type('PropertyValue', (), {})
            class Office:
                def __init__(self, args, **kwargs): events.append(['spawn', args])
                def poll(self): return 1 if mode == 'connect-error' else None
                def terminate(self): events.append(['terminate'])
                def wait(self, **kwargs): events.append(['wait'])
            subprocess.Popen = Office
            class Document:
                def getCurrentController(self): return self
                def getFrame(self): return 'OWNED_FRAME'
            class Service:
                def createInstanceWithContext(self, name, context): return self
                def resolve(self, url):
                    events.append(['resolve', url])
                    if mode == 'connect-error': raise RuntimeError('no server')
                    return self
                @property
                def ServiceManager(self): return self
                def loadComponentFromURL(self, url, target, flags, props):
                    events.append(['load', url, {p.Name:p.Value for p in props}])
                    return None if mode == 'open-error' else Document()
                def executeDispatch(self, frame, command, target, flags, props):
                    events.append(['dispatch', frame, command, {p.Name:p.Value for p in props}])
                    if mode == 'dispatch-error': raise RuntimeError('dispatch refused')
            uno = module('uno')
            uno.Any = lambda kind, value: value
            uno.getComponentContext = lambda: Service()
            uno.systemPathToFileUrl = lambda path: pathlib.Path(path).as_uri()
            scope = {'__name__':'shipping_worker'}
            exec(pathlib.Path(worker).read_text(), scope)
            scope['run'](request, '/fixed/LibreOffice.app/Contents/MacOS/soffice')
            pathlib.Path(request).with_name('events.json').write_text(json.dumps(events))
            """#
            try Data(code.utf8).write(to: harness)
            let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
            process.arguments = [harness.path, preview.request.path, preview.script.path, mode]
            try process.run(); process.waitUntilExit(); XCTAssertEqual(process.terminationStatus, 0)
            let receipt = try JSONDecoder().decode(LibreOfficeComparisonPreview.Receipt.self, from: Data(contentsOf: preview.reply))
            XCTAssertEqual(receipt.success, mode == "success")
            XCTAssertEqual(receipt.possiblyOpened, ["success","dispatch-error","open-error"].contains(mode))
            let events = try JSONSerialization.jsonObject(with: Data(contentsOf: preview.directory.appendingPathComponent("events.json"))) as! [[Any]]
            if mode == "success" {
                let load = events.first { $0[0] as? String == "load" }!, properties = load[2] as! [String: Any]
                XCTAssertEqual(load[1] as? String, preview.destination.absoluteString)
                XCTAssertEqual(properties["MacroExecutionMode"] as? Int, 0)
                XCTAssertEqual(properties["UpdateDocMode"] as? Int, 0)
                let dispatches = events.filter { $0[0] as? String == "dispatch" }
                XCTAssertEqual(dispatches.count, 2)
                XCTAssertEqual(dispatches.map { $0[1] as! String }, ["OWNED_FRAME","OWNED_FRAME"])
                XCTAssertEqual((dispatches.last![3] as! [String: String])["URL"], preview.base.absoluteString)
            }
            if mode == "connect-error" { XCTAssertEqual(events.suffix(2).map { $0[0] as! String }, ["terminate","wait"]) }
            if mode == "pre-cancel" { XCTAssertTrue(events.isEmpty) }
        }
    }
}
