// SPDX-License-Identifier: GPL-2.0-or-later
import Foundation
import Darwin
import Security

struct HTTPConfiguration {
    let headers: [String]
    let proxy: String?
    let caCertificates: [Data]

    static func load(url: String, directory: String, configs: [String], environment: [String: String]) throws -> HTTPConfiguration {
        let reader = try HTTPConfigurationReader(directory: directory, configs: configs, environment: environment)
        let proxy = try reader.scalar("proxy", url: url)
        let caInfo = try environment["GIT_SSL_CAINFO"].map { try reader.expandedPath($0) } ?? reader.scalar("sslCAInfo", url: url, path: true)
        let caPath = try environment["GIT_SSL_CAPATH"].map { try reader.expandedPath($0) } ?? reader.scalar("sslCAPath", url: url, path: true)
        var certificates: [Data] = [], total = 0
        func add(_ file: URL, required: Bool) throws {
            let file = file.resolvingSymlinksInPath()
            let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
            guard attributes[.type] as? FileAttributeType == .typeRegular,
                  let size = (attributes[.size] as? NSNumber)?.intValue, size <= 1_048_576,
                  total <= 16_777_216 - size else { throw HelperFailure(message: "The configured certificate collection exceeds its limit.") }
            let handle = try FileHandle(forReadingFrom: file); defer { try? handle.close() }
            let data = try handle.read(upToCount: 1_048_577) ?? Data()
            guard data.count <= 1_048_576, total <= 16_777_216 - data.count else { throw HelperFailure(message: "The configured certificate collection exceeds its limit.") }
            total += data.count
            let decoded = try certificateData(data)
            guard !required || !decoded.isEmpty else { throw HelperFailure(message: "The configured certificate file is invalid.") }
            for certificate in decoded where !certificates.contains(certificate) {
                guard certificates.count < 256 else { throw HelperFailure(message: "Too many configured certificates.") }
                certificates.append(certificate)
            }
        }
        do {
            if let caInfo, !caInfo.isEmpty { try add(reader.file(caInfo), required: true) }
            if let caPath, !caPath.isEmpty {
                let directory = reader.file(caPath)
                let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isRegularFileKey])
                guard files.count <= 1024 else { throw HelperFailure(message: "The configured certificate directory exceeds its limit.") }
                let before = certificates.count
                for file in files.sorted(by: { $0.path.utf8.lexicographicallyPrecedes($1.path.utf8) }) {
                    let target = file.resolvingSymlinksInPath()
                    if try target.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true { try add(target, required: false) }
                }
                guard certificates.count > before || !certificates.isEmpty else { throw HelperFailure(message: "The configured certificate directory contains no certificates.") }
            }
        } catch { throw HelperFailure(message: "The configured HTTP certificates could not be loaded.") }
        return HTTPConfiguration(headers: try reader.headers(url: url), proxy: proxy, caCertificates: certificates)
    }

    private static func certificateData(_ bytes: Data) throws -> [Data] {
        if SecCertificateCreateWithData(nil, bytes as CFData) != nil { return [bytes] }
        guard let text = String(data: bytes, encoding: .utf8) else { return [] }
        var result: [Data] = []
        for block in text.components(separatedBy: "-----BEGIN CERTIFICATE-----").dropFirst() {
            guard result.count < 256, let end = block.range(of: "-----END CERTIFICATE-----"),
                  let data = Data(base64Encoded: block[..<end.lowerBound].filter { !$0.isWhitespace }),
                  SecCertificateCreateWithData(nil, data as CFData) != nil else { throw HelperFailure(message: "Invalid configured certificate.") }
            result.append(data)
        }
        return result
    }
}

private final class HTTPConfigurationReader {
    private let executable: URL, directory: URL, configs: [String], environment: [String: String]
    private let deadline = Date().addingTimeInterval(15)
    init(directory: String, configs: [String], environment: [String: String]) throws {
        guard let path = environment["TURTLEGIT_LIBGIT2_GIT_EXECUTABLE"], path.hasPrefix("/"), !path.utf8.contains(0),
              FileManager.default.isExecutableFile(atPath: path), directory.hasPrefix("/"), !directory.utf8.contains(0) else {
            throw HelperFailure(message: "The captured Git configuration reader is unavailable.")
        }
        executable = URL(fileURLWithPath: path); self.directory = URL(fileURLWithPath: directory); self.configs = configs
        var captured = environment
        // Arguments.configs already expanded these values in their original
        // order. Reapplying them duplicates multi-valued HTTP headers.
        for key in Array(captured.keys) where key == "GIT_CONFIG_COUNT" || key == "GIT_CONFIG_PARAMETERS" || key.hasPrefix("GIT_CONFIG_KEY_") || key.hasPrefix("GIT_CONFIG_VALUE_") { captured.removeValue(forKey: key) }
        captured["GIT_TERMINAL_PROMPT"] = "0"; captured["GIT_OPTIONAL_LOCKS"] = "0"
        self.environment = captured
    }
    func file(_ path: String) -> URL { path.hasPrefix("/") ? URL(fileURLWithPath: path) : directory.appendingPathComponent(path) }
    private func query(_ arguments: [String], extra: [String] = []) throws -> [String] {
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("TurtleGit-HTTP-config-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: temporary) }
        let output = temporary.appendingPathComponent("out")
        guard FileManager.default.createFile(atPath: output.path, contents: nil, attributes: [.posixPermissions: 0o600]) else { throw HelperFailure(message: "Could not read HTTP configuration.") }
        let handle = try FileHandle(forWritingTo: output); defer { try? handle.close() }
        let process = Process(); process.executableURL = executable; process.currentDirectoryURL = directory; process.environment = environment
        process.arguments = ["-C", directory.path] + (configs + extra).flatMap { ["-c", $0] } + ["-c", "core.precomposeunicode=false", "config", "--null"] + arguments
        process.standardInput = FileHandle.nullDevice; process.standardOutput = handle; process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { throw HelperFailure(message: "Could not launch the captured Git configuration reader.") }
        var refused = false
        while process.isRunning {
            let size = (try? FileManager.default.attributesOfItem(atPath: output.path)[.size] as? NSNumber)?.intValue ?? 0
            if cancelled() || Date() >= deadline || size > 4_194_304 {
                refused = true; process.terminate()
                for _ in 0..<50 where process.isRunning { usleep(10_000) }
                if process.isRunning { kill(process.processIdentifier, SIGKILL) }
                break
            }
            usleep(5_000)
        }
        process.waitUntilExit()
        guard !refused, !cancelled(), process.terminationStatus == 0 || process.terminationStatus == 1 else { throw HelperFailure(message: "The HTTP configuration could not be read.") }
        if process.terminationStatus == 1 { return [] }
        let bytes = try Data(contentsOf: output)
        guard bytes.count <= 4_194_304, bytes.isEmpty || bytes.last == 0 else { throw HelperFailure(message: "Invalid HTTP configuration output.") }
        var values = bytes.split(separator: 0, omittingEmptySubsequences: false); if !bytes.isEmpty { values.removeLast() }
        if bytes.isEmpty { return [] }
        return try values.map { guard let text = String(data: Data($0), encoding: .utf8) else { throw HelperFailure(message: "Invalid HTTP configuration text.") }; return text }
    }
    func scalar(_ key: String, url: String, path: Bool = false) throws -> String? {
        try query((path ? ["--path"] : []) + ["--get-urlmatch", "http." + key, url]).last
    }
    func expandedPath(_ path: String) throws -> String {
        let marker = "http.turtlegitpath" + UUID().uuidString.replacingOccurrences(of: "-", with: "")
        return try query(["--path", "--get", marker], extra: [marker + "=" + path]).last ?? ""
    }
    func headers(url: String) throws -> [String] {
        let records = try query(["--get-regexp", "^http[.](.*[.])?extraheader$"])
        guard records.count <= 128 else { throw HelperFailure(message: "Too many HTTP header settings.") }
        var headers: [String] = [], winningKey: String?, total = 0
        let marker = "turtlegitmatch" + UUID().uuidString.replacingOccurrences(of: "-", with: "")
        for record in records {
            guard let separator = record.firstIndex(of: "\n") else { throw HelperFailure(message: "Invalid HTTP header setting.") }
            let key = String(record[..<separator]), value = String(record[record.index(after: separator)...])
            guard key.hasSuffix(".extraheader"), !value.contains("\r"), !value.contains("\n"), !value.utf8.contains(0), value.utf8.count <= 65_535 else { throw HelperFailure(message: "Invalid HTTP header setting.") }
            if winningKey.map({ !$0.utf8.elementsEqual(key.utf8) }) ?? true {
                func probe(_ key: String, _ value: String) -> String { String(key.dropLast("extraheader".count)) + marker + "=" + value }
                var probes = ["http." + marker + "=unmatched"]
                if let winningKey { probes.append(probe(winningKey, "previous")) }
                probes.append(probe(key, "candidate"))
                guard try query(["--get-urlmatch", "http." + marker, url], extra: probes).last == "candidate" else { continue }
            }
            winningKey = key
            if value.isEmpty { headers.removeAll(); total = 0 }
            else {
                total += value.utf8.count
                guard total <= 262_144 else { throw HelperFailure(message: "The HTTP headers exceed their limit.") }
                headers.append(value)
            }
        }
        return headers
    }
}
