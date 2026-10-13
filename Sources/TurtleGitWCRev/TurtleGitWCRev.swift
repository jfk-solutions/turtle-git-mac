import Foundation
import TurtleGitCore
import Darwin

@main struct TurtleGitWCRev {
    static let usage = """
    TurtleGitWCRev — working-copy version templates for TurtleGit for Mac
    Usage: TurtleGitWCRev Path [SrcVersionFile DstVersionFile] [-mMuUdqse]
           TurtleGitWCRev --json Path
    -m/-M  fail on modifications (M includes submodule modifications)
    -u/-U  fail on unversioned files (U includes submodule unversioned files)
    -d     fail if the destination already exists
    -q     quiet output
    -s     omit submodules
    -e     UTF-16 LE console output; default output is UTF-8
    Supply switches together, for example -mUq.
    Templates accept the upstream $WC...$ revision/date/status/count/branch keywords.
    --json provides the native automation replacement for Windows COM status reads.
    """
    static func printOutput(_ text: String, wide: Bool) {
        let data = wide ? text.data(using: .utf16LittleEndian)! : Data(text.utf8)
        FileHandle.standardOutput.write(data)
    }
    static func main() async {
        do { try await execute(Array(CommandLine.arguments.dropFirst())) }
        catch let error as WorkingCopyRevisionFailure { fputs("TurtleGitWCRev: \(error.message)\n", stderr); exit(error.exitCode) }
        catch { fputs("TurtleGitWCRev: \(error.localizedDescription)\n", stderr); exit(6) }
    }
    static func execute(_ arguments: [String]) async throws {
        if arguments == ["--help"] || arguments == ["-h"] { print(usage); return }
        let json = arguments.first == "--json"
        let args = json ? Array(arguments.dropFirst()) : arguments
        guard (json && args.count == 1) || (!json && (1...4).contains(args.count)) else { throw WorkingCopyRevisionFailure(1, usage) }
        let hasSwitches = args.count == 2 || args.count == 4
        let flags = hasSwitches ? args.last! : ""
        guard !hasSwitches || flags.hasPrefix("-") else { throw WorkingCopyRevisionFailure(1, usage) }
        let path = URL(fileURLWithPath: args[0]).standardizedFileURL
        let template = args.count >= 3 ? URL(fileURLWithPath: args[1]) : nil
        let destination = args.count >= 3 ? URL(fileURLWithPath: args[2]) : nil
        var contents: Data?
        if let template {
            guard FileManager.default.fileExists(atPath: template.path) else { throw WorkingCopyRevisionFailure(2, "Template does not exist: \(template.path)") }
            do { contents = try Data(contentsOf: template) } catch { throw WorkingCopyRevisionFailure(3, "Cannot read template: \(error.localizedDescription)") }
        }
        if let destination, flags.contains("d"), FileManager.default.fileExists(atPath: destination.path) { throw WorkingCopyRevisionFailure(9, "Destination already exists") }
        // The packaged tool finds the app explicitly; Bundle.main for a CLI
        // is not guaranteed to identify the containing application bundle.
        let executable: URL
        let toolURL = (Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0])).standardizedFileURL.resolvingSymlinksInPath()
        let appURL = toolURL.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        if !GitRuntime.isAppStoreBuild, let custom = ProcessInfo.processInfo.environment["TURTLEGIT_WCREV_GIT"] {
            guard custom.hasPrefix("/"), FileManager.default.isExecutableFile(atPath: custom) else { throw WorkingCopyRevisionFailure(6, "TURTLEGIT_WCREV_GIT must identify an executable by its absolute path") }
            executable = URL(fileURLWithPath: custom)
        } else if appURL.pathExtension == "app", let bundle = Bundle(url: appURL) {
            executable = try GitRuntime.executable(bundle: bundle)
        } else { executable = try GitRuntime.executable(appStore: false) }
        let value = try await WorkingCopyRevisionReader.read(path: path, executable: executable, skipSubmodules: flags.contains("s"))
        let recursive = flags.contains("M") || flags.contains("U")
        if (flags.contains("m") || flags.contains("M")) && (value.fileModifications || value.submoduleNewCommits || (recursive && value.submoduleModifications)) { throw WorkingCopyRevisionFailure(7, "Working tree has uncommitted modifications") }
        if (flags.contains("u") || flags.contains("U")) && (value.unversioned || (recursive && value.submoduleUnversioned)) { throw WorkingCopyRevisionFailure(11, "Working tree has unversioned items") }
        if json { FileHandle.standardOutput.write(try JSONEncoder().encode(value)); print(); return }
        if !flags.contains("q") {
            var text = "TurtleGitWCRev: '\(path.path)'\nHEAD is \(value.revision)\n"
            if value.fileModifications { text += "Uncommitted modifications found\n" }
            if value.unversioned { text += "Unversioned items found\n" }
            printOutput(text, wide: flags.contains("e"))
        }
        if let contents, let destination {
            let result = WorkingCopyRevisionTemplate.expand(contents, revision: value)
            if flags.contains("d") {
                let descriptor = open(destination.path, O_WRONLY | O_CREAT | O_EXCL, 0o666)
                guard descriptor >= 0 else { throw WorkingCopyRevisionFailure(errno == EEXIST ? 9 : 3, "Cannot create destination") }
                let file = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
                do { try file.write(contentsOf: result); try file.close() } catch { try? file.close(); throw WorkingCopyRevisionFailure(5, "Cannot write destination") }
            } else {
                if (try? Data(contentsOf: destination)) == result { return } // preserve timestamps
                do {
                    let permissions = try? FileManager.default.attributesOfItem(atPath: destination.path)[.posixPermissions]
                    try result.write(to: destination, options: .atomic)
                    if let permissions { try FileManager.default.setAttributes([.posixPermissions: permissions], ofItemAtPath: destination.path) }
                } catch { throw WorkingCopyRevisionFailure(5, "Cannot write destination: \(error.localizedDescription)") }
            }
        }
    }
}
