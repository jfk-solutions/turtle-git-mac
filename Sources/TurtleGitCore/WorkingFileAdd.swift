import Foundation
import Darwin

public enum WorkingFileAddMode: String, CaseIterable, Sendable {
    case normal = "Add", executable = "Add as Executable (+x)", symlink = "Add as Symlink"
    var indexMode: String? {
        switch self { case .normal: return nil; case .executable: return "100755"; case .symlink: return "120000" }
    }
}

extension GitRepository {
    /// Upstream AddProgressCommand stages with -f, then overrides the selected
    /// non-directory entries' Git mode. This does not chmod or create disk links.
    public func addWorkingFiles(paths: [String], mode: WorkingFileAddMode = .normal) throws {
        let paths = Array(Set(paths)).sorted()
        guard !paths.isEmpty else { throw GitFailure(arguments: ["add"], code: 1, message: "Select files to add.") }
        for path in paths { _ = try restoreLocation(path) }
        var indexBytes = try run(["rev-parse", "--git-path", "index"]).stdout
        if indexBytes.last == 10 { indexBytes.removeLast() }
        let indexPath = String(decoding: indexBytes, as: UTF8.self)
        let index = indexPath.hasPrefix("/") ? URL(fileURLWithPath: indexPath) : root.appendingPathComponent(indexPath)
        let lock = URL(fileURLWithPath: index.path + ".lock")
        let descriptor = open(lock.path, O_WRONLY | O_CREAT | O_EXCL, 0o600)
        guard descriptor >= 0 else { throw GitFailure(arguments: ["add"], code: 1, message: "Could not lock the Git index: " + String(cString: strerror(errno))) }
        var ownsLock = true
        defer { if ownsLock { try? FileManager.default.removeItem(at: lock) } }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("TurtleGitAdd-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) }
        let privateIndex = directory.appendingPathComponent("index")
        let environment = ["GIT_INDEX_FILE": privateIndex.path]
        if FileManager.default.fileExists(atPath: index.path) { try FileManager.default.copyItem(at: index, to: privateIndex) }
        else { _ = try run(["read-tree", "--empty"], environmentOverrides: environment) }
        for offset in stride(from: 0, to: paths.count, by: 64) {
            _ = try run(["add", "-f", "--"] + Array(paths[offset..<min(offset + 64, paths.count)]), environmentOverrides: environment)
        }
        if let indexMode = mode.indexMode {
            for path in paths {
                let location = root.appendingPathComponent(path)
                let type = try FileManager.default.attributesOfItem(atPath: location.path)[.type] as? FileAttributeType
                if type == .typeDirectory { continue }
                let records = try run(["ls-files", "--stage", "-z", "--", path], environmentOverrides: environment).stdout.split(separator: 0)
                guard let record = records.first, records.count == 1, let tab = record.firstIndex(of: 9) else {
                    throw GitFailure(arguments: ["add"], code: 1, message: "Could not read the staged file mode for " + path)
                }
                let header = String(decoding: record[..<tab], as: UTF8.self).split(separator: " ")
                guard header.count == 3, header[2] == "0" else { throw GitFailure(arguments: ["add"], code: 1, message: "The file has unresolved index entries: " + path) }
                _ = try run(["update-index", "--cacheinfo", indexMode, String(header[1]), path], environmentOverrides: environment)
            }
        }
        try handle.write(contentsOf: Data(contentsOf: privateIndex)); try handle.close()
        if let permissions = (try? FileManager.default.attributesOfItem(atPath: index.path))?[.posixPermissions] {
            try FileManager.default.setAttributes([.posixPermissions: permissions], ofItemAtPath: lock.path)
        }
        guard Darwin.rename(lock.path, index.path) == 0 else { throw GitFailure(arguments: ["add"], code: 1, message: "Could not replace the Git index: " + String(cString: strerror(errno))) }
        ownsLock = false
    }
}
