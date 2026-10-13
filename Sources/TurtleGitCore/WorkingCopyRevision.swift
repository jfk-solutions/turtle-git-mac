import Foundation
import Darwin

public struct WorkingCopyRevision: Codable, Sendable {
    public var revision = String(repeating: "0", count: 40)
    public var branch = ""
    public var author = ""
    public var email = ""
    public var authorTime: Int64 = 0
    public var commitCount: UInt64 = 0
    public var unborn = false
    public var tagged = false
    public var versioned = false
    public var fileModifications = false
    public var unversioned = false
    public var hasSubmodule = false
    public var submoduleNewCommits = false
    public var submoduleModifications = false
    public var submoduleUnversioned = false
    public init() {}
    /// Keep the pinned utility's distinct conditions, including its unusual
    /// MODSFULL treatment of submodule untracked files rather than new commits.
    public var conditions: [String: Bool] {
        ["WCMODS": fileModifications || submoduleNewCommits, "WCUNVER": unversioned,
         "WCISTAGGED": tagged, "WCINGIT": versioned, "WCFILEMODS": fileModifications,
         "WCSUBMODULE": hasSubmodule, "WCSUBMODULEUP2DATE": !submoduleNewCommits,
         "WCMODSINSUBMODULE": submoduleModifications, "WCUNVERINSUBMODULE": submoduleUnversioned,
         "WCUNVERFULL": unversioned || submoduleUnversioned,
         "WCMODSFULL": fileModifications || submoduleModifications || submoduleUnversioned]
    }
}
public struct WorkingCopyRevisionFailure: LocalizedError {
    public let exitCode: Int32
    public let message: String
    public var errorDescription: String? { message }
    public init(_ exitCode: Int32, _ message: String) { self.exitCode = exitCode; self.message = message }
}

public enum WorkingCopyRevisionReader {
    public static func read(path: URL, executable: URL = URL(fileURLWithPath: "/usr/bin/git"), skipSubmodules: Bool = false, useMailmap: Bool = GitIdentityDisplay().useMailmap, cancellation: OperationCancellation? = nil) async throws -> WorkingCopyRevision {
        var directory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path.path, isDirectory: &directory) else { throw WorkingCopyRevisionFailure(2, "Path does not exist: \(path.path)") }
        let probe = GitRepository(root: directory.boolValue ? path : path.deletingLastPathComponent(), executable: executable, askpass: nil)
        let root: URL
        do {
            root = try await probe.discoverRoot(cancellation: cancellation)
            guard try await !probe.isBare(cancellation: cancellation) else { throw WorkingCopyRevisionFailure(10, "Path is not a working tree") }
        } catch {
            try cancellation?.check()
            throw WorkingCopyRevisionFailure(10, "Path is not a working tree: \(path.path)")
        }
        let repo = GitRepository(root: root, executable: executable, askpass: nil)
        // Resolve only parents, so a versioned leaf symlink keeps its own identity.
        let selected = directory.boolValue ? path.resolvingSymlinksInPath() : path.deletingLastPathComponent().resolvingSymlinksInPath().appendingPathComponent(path.lastPathComponent)
        let canonicalRoot = root.resolvingSymlinksInPath()
        guard selected.path == canonicalRoot.path || selected.path.hasPrefix(canonicalRoot.path + "/") else { throw WorkingCopyRevisionFailure(10, "Path escapes working tree") }
        let relative = selected.path == canonicalRoot.path ? "" : String(selected.path.dropFirst(canonicalRoot.path.count + 1))
        var value = WorkingCopyRevision()
        let head = try await repo.run(["rev-parse", "--verify", "HEAD"], successfulExitCodes: 0...128, cancellation: cancellation)
        let branch = try await repo.run(["symbolic-ref", "--quiet", "--short", "HEAD"], successfulExitCodes: 0...1, cancellation: cancellation)
        if head.exitCode == 0 {
            value.revision = head.text.trimmingCharacters(in: .newlines)
            value.branch = branch.exitCode == 0 ? branch.text.trimmingCharacters(in: .newlines) : value.revision
            let metadata = try await repo.run(["show", "-s", "--format=%at%x00" + GitIdentityDisplay(useMailmap: useMailmap).authorName + "%x00" + GitIdentityDisplay(useMailmap: useMailmap).authorEmail, "HEAD"], cancellation: cancellation).stdout.split(separator: 0, omittingEmptySubsequences: false)
            guard metadata.count == 3, let time = Int64(String(decoding: metadata[0], as: UTF8.self)) else { throw WorkingCopyRevisionFailure(6, "Invalid commit metadata") }
            value.authorTime = time; value.author = String(decoding: metadata[1], as: UTF8.self)
            var mail = Data(metadata[2]); if mail.last == 10 { mail.removeLast() }; value.email = String(decoding: mail, as: UTF8.self)
            value.commitCount = UInt64(try await repo.run(["rev-list", "--first-parent", "--count", "HEAD"], cancellation: cancellation).text.trimmingCharacters(in: .newlines)) ?? 0
            value.tagged = !(try await repo.run(["tag", "--points-at", "HEAD"], cancellation: cancellation).stdout.isEmpty)
        } else {
            guard branch.exitCode == 0 else { throw WorkingCopyRevisionFailure(6, "Cannot read HEAD") }
            value.unborn = true; value.branch = branch.text.trimmingCharacters(in: .newlines)
        }
        var specs = [relative.isEmpty ? ":(glob)**" : ":(literal)" + relative]
        let ignore = root.appendingPathComponent(".GitWCRevignore")
        if FileManager.default.fileExists(atPath: ignore.path) {
            let patterns = String(decoding: try Data(contentsOf: ignore), as: UTF8.self).components(separatedBy: .newlines).filter { !$0.isEmpty }
            specs += patterns.map { ":(exclude)" + $0 }
        }
        let result = try await repo.run(["status", "--porcelain=v2", "-z", "--untracked-files=all", "--ignore-submodules=" + (skipSubmodules ? "all" : "none"), "--"] + specs, environmentOverrides: ["GIT_OPTIONAL_LOCKS": "0"], literalPathspecs: false, cancellation: cancellation)
        let records = result.stdout.split(separator: 0).map { String(decoding: $0, as: UTF8.self) }
        var i = 0, selectedAdded = false
        while i < records.count {
            let record = records[i]; i += 1
            if record.hasPrefix("? ") { value.unversioned = true; continue }
            guard let type = record.first, ["1", "2", "u"].contains(String(type)) else { continue }
            let fields = record.split(separator: " ", maxSplits: type == "2" ? 9 : type == "u" ? 10 : 8)
            guard fields.count >= 4 else { throw WorkingCopyRevisionFailure(6, "Invalid working tree status") }
            if type == "2" { i += 1 } // original path occupies its own NUL record
            let xy = String(fields[1]), sub = Array(fields[2])
            if sub.first == "S" && sub.count == 4 {
                value.hasSubmodule = true
                // Source status.cpp gives changed HEAD priority over dirty files,
                // and dirty files priority over untracked submodule files.
                if sub[1] == "C" { value.submoduleNewCommits = true }
                else if sub[2] == "M" { value.submoduleModifications = true }
                else if sub[3] == "U" { value.submoduleUnversioned = true }
                continue
            }
            if xy == "A." || xy == ".A" { value.unversioned = true; if String(fields.last!) == relative { selectedAdded = true } }
            else if xy != ".." { value.fileModifications = true }
        }
        if relative.isEmpty { value.versioned = true }
        else if !directory.boolValue {
            let tracked = try await repo.run(["ls-files", "--error-unmatch", "--", relative], successfulExitCodes: 0...1, cancellation: cancellation)
            let additions = try await repo.run(["diff", "--cached", "--name-only", "-z", "--diff-filter=A", "--", relative], cancellation: cancellation)
            value.versioned = tracked.exitCode == 0 && !selectedAdded && additions.stdout.isEmpty
        }
        return value
    }
}

public enum WorkingCopyRevisionTemplate {
    /// Operate on bytes (or UTF-16 units) so unrelated binary/legacy template
    /// bytes are preserved. Replacements in byte templates use UTF-8 on macOS.
    public static func expand(_ input: Data, revision: WorkingCopyRevision, now: Date = Date()) -> Data {
        let bytes = Array(input)
        let little = bytes.starts(with: [255, 254])
        let big = bytes.starts(with: [254, 255])
        let sample = Array(bytes.prefix(64))
        let unmarkedLE = sample.count >= 4 && stride(from: 1, to: sample.count, by: 2).allSatisfy { sample[$0] == 0 } && sample.contains { $0 != 0 }
        let wide = little || big || unmarkedLE
        let bom = little || big ? Array(bytes.prefix(2)) : []
        let content = Array(bytes.dropFirst(bom.count))
        let units: [UInt16] = wide ? stride(from: 0, to: content.count - content.count % 2, by: 2).map { big ? UInt16(content[$0]) << 8 | UInt16(content[$0+1]) : UInt16(content[$0]) | UInt16(content[$0+1]) << 8 } : content.map(UInt16.init)
        var output: [UInt16] = [], i = 0
        while i < units.count {
            guard units[i] == 36, i + 2 < units.count, units[i+1] == 87, units[i+2] == 67,
                  let end = units[(i+1)...].firstIndex(of: 36) else { output.append(units[i]); i += 1; continue }
            let tokenUnits = units[(i+1)..<end]
            if let question = tokenUnits.firstIndex(of: 63),
               tokenUnits[..<question].allSatisfy({ $0 < 128 }),
               let condition = revision.conditions[String(decoding: tokenUnits[..<question], as: UTF16.self)],
               let split = tokenUnits[tokenUnits.index(after: question)...].firstIndex(of: 58) {
                output.append(contentsOf: condition ? tokenUnits[tokenUnits.index(after: question)..<split] : tokenUnits[tokenUnits.index(after: split)...])
                i = end + 1; continue
            }
            guard tokenUnits.allSatisfy({ $0 < 128 }), let replacement = replacement(String(decoding: tokenUnits, as: UTF16.self), revision: revision, now: now) else {
                output.append(contentsOf: units[i...end]); i = end + 1; continue
            }
            output.append(contentsOf: wide ? Array(replacement.utf16) : replacement.utf8.map(UInt16.init)); i = end + 1
        }
        if !wide { return Data(output.map(UInt8.init)) }
        var result = bom
        for unit in output { result += big ? [UInt8(unit >> 8), UInt8(unit & 255)] : [UInt8(unit & 255), UInt8(unit >> 8)] }
        if content.count % 2 == 1 { result.append(content.last!) }
        return Data(result)
    }
    private static func number(_ text: String) -> UInt64 {
        // Windows strtoul uses base 0 and a 32-bit unsigned long, stopping at
        // the first invalid digit. Invalid/empty values resolve to zero.
        var text = text.trimmingCharacters(in: .whitespaces), negative = false
        if text.hasPrefix("-") { negative = true; text.removeFirst() } else if text.hasPrefix("+") { text.removeFirst() }
        var base: UInt64 = 10
        if text.lowercased().hasPrefix("0x") { base = 16; text.removeFirst(2) }
        else if text.hasPrefix("0") { base = 8 }
        var value: UInt64 = 0
        for c in text.lowercased().utf8 {
            let digit = c >= 48 && c <= 57 ? UInt64(c-48) : c >= 97 && c <= 102 ? UInt64(c-87) : 100
            guard digit < base else { break }
            value = min(UInt64(UInt32.max), value * base + digit)
        }
        return negative ? UInt64(0 &- UInt32(value)) : value
    }
    private static func replacement(_ token: String, revision: WorkingCopyRevision, now: Date) -> String? {
        if token == "WCREV" { return revision.revision }
        if token.hasPrefix("WCREV=") { let spec = String(token.dropFirst(6)); guard spec.utf8.count <= 1024 else { return nil }; return String(revision.revision.prefix(Int(min(UInt64(revision.revision.count), number(spec))))) }
        if token == "WCBRANCH" { return revision.branch }
        if token == "WCLOGCOUNT" { return String(Int64(bitPattern: revision.commitCount)) }
        for (prefix, operation) in [("WCLOGCOUNT&", 0), ("WCLOGCOUNT-", 1), ("WCLOGCOUNT+", 2)] where token.hasPrefix(prefix) {
            let spec = String(token.dropFirst(prefix.count)); guard spec.utf8.count <= 1024 else { return nil }
            let n = number(spec), value = operation == 0 ? revision.commitCount & n : operation == 1 ? revision.commitCount &- n : revision.commitCount &+ n
            return String(Int64(bitPattern: value))
        }
        if let question = token.firstIndex(of: "?"), let condition = revision.conditions[String(token[..<question])], let split = token[token.index(after: question)...].firstIndex(of: ":") {
            return condition ? String(token[token.index(after: question)..<split]) : String(token[token.index(after: split)...])
        }
        for prefix in ["WCDATEUTC", "WCNOWUTC", "WCDATE", "WCNOW"] {
            if token == prefix || token.hasPrefix(prefix + "=") {
                let spec = token == prefix ? "%Y/%m/%d %H:%M:%S" : String(token.dropFirst(prefix.count + 1))
                guard spec.utf8.count <= 1024 else { return nil }
                var format = spec, cursor = format.startIndex
                let conversions = Set("aAbBcCdDeFgGhHIjmMnprRStTuUVwWxXyYzZ%")
                while cursor < format.endIndex {
                    if format[cursor] != "%" { cursor = format.index(after: cursor); continue }
                    cursor = format.index(after: cursor)
                    if cursor < format.endIndex && format[cursor] == "#" { cursor = format.index(after: cursor) }
                    guard cursor < format.endIndex, conversions.contains(format[cursor]) else { return "Invalid Time Format Specified" }
                    cursor = format.index(after: cursor)
                }
                format = format.replacingOccurrences(of: "%#", with: "%-")
                var timestamp = time_t(prefix.hasPrefix("WCNOW") ? now.timeIntervalSince1970 : Double(revision.authorTime)), parts = tm()
                if prefix.hasSuffix("UTC") { guard gmtime_r(&timestamp, &parts) != nil else { return nil } }
                else { guard localtime_r(&timestamp, &parts) != nil else { return nil } }
                var buffer = [CChar](repeating: 0, count: 1024)
                let count = strftime(&buffer, buffer.count, format, &parts)
                return count == 0 ? "" : String(cString: buffer)
            }
        }
        return nil
    }
}
