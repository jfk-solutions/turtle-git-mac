// SPDX-License-Identifier: GPL-2.0-or-later
import Foundation
import Darwin

public enum SSHKeyAlgorithm: String, CaseIterable, Sendable { case ed25519, rsa, ecdsa }
public struct SSHKeyGenerationRequest: Sendable {
    public var algorithm: SSHKeyAlgorithm = .ed25519
    public var bits = 3072
    public var comment = ""
    public var passphrase = ""
    public var destination: URL
    public init(destination: URL) { self.destination = destination }
    public var valid: Bool {
        destination.isFileURL && destination.path.hasPrefix("/") && !destination.path.contains("\0") &&
        !["", ".", ".."].contains(destination.lastPathComponent) &&
        !comment.contains("\0") && !comment.contains("\n") && !comment.contains("\r") &&
        !passphrase.contains("\0") && !passphrase.contains("\n") && !passphrase.contains("\r") && passphrase.utf8.count < 65_000 &&
        (algorithm == .ed25519 || (algorithm == .rsa ? [2048, 3072, 4096] : [256, 384, 521]).contains(bits))
    }
}
public struct SSHKeyGenerationResult: Sendable {
    public let privateKey: URL, publicKey: URL
    public let publicText: String, fingerprint: String
}
public enum SSHKeyGenerationFailure: LocalizedError {
    case invalid, runtime, exists, command(Int32), publish
    public var errorDescription: String? {
        switch self {
        case .invalid: return "Choose a valid key destination, algorithm and single-line comment/passphrase."
        case .runtime: return "The bundled SSH key generator or passphrase helper is unavailable."
        case .exists: return "The private or public key already exists. Choose another filename."
        case .command(let code): return "SSH key generation failed (\(code)). No key was published."
        case .publish: return "Could not publish the key pair. Check the destination folder and choose another filename."
        }
    }
}
public enum SSHKeyGeneration {
    public static func executable(bundle: Bundle = .main, appStore: Bool = GitRuntime.isAppStoreBuild) throws -> URL {
        let bundled = bundle.bundleURL.appendingPathComponent("Contents/Helpers/OpenSSH/bin/ssh-keygen")
        if FileManager.default.isExecutableFile(atPath: bundled.path) { return bundled }
        guard !appStore else { throw SSHKeyGenerationFailure.runtime }
        return URL(fileURLWithPath: "/usr/bin/ssh-keygen")
    }
    public static func generate(_ request: SSHKeyGenerationRequest, executable: URL, askpass: URL?, cancellation: OperationCancellation) throws -> SSHKeyGenerationResult {
        guard request.valid else { throw SSHKeyGenerationFailure.invalid }
        try cancellation.check()
        let destination = request.destination, publicDestination = URL(fileURLWithPath: destination.path + ".pub")
        var info = stat()
        guard lstat(destination.path, &info) != 0, errno == ENOENT, lstat(publicDestination.path, &info) != 0, errno == ENOENT else { throw SSHKeyGenerationFailure.exists }
        let directory = destination.deletingLastPathComponent().appendingPathComponent("tg-keygen-" + UUID().uuidString, isDirectory: true)
        guard mkdir(directory.path, 0o700) == 0 else { throw SSHKeyGenerationFailure.publish }
        defer { try? FileManager.default.removeItem(at: directory) }
        guard chmod(directory.path, 0o700) == 0 else { throw SSHKeyGenerationFailure.publish }
        let key = directory.appendingPathComponent("identity"), publicKey = directory.appendingPathComponent("identity.pub")
        let output = directory.appendingPathComponent("output"), errors = directory.appendingPathComponent("errors")
        FileManager.default.createFile(atPath: output.path, contents: nil); FileManager.default.createFile(atPath: errors.path, contents: nil)
        let out = try FileHandle(forWritingTo: output), err = try FileHandle(forWritingTo: errors)
        defer { try? out.close(); try? err.close() }
        var environment = ProcessInfo.processInfo.environment
        environment.removeValue(forKey: "TURTLEGIT_SSH_CREDENTIAL_FILE")
        environment["LC_ALL"] = "C"; environment["DISPLAY"] = "TurtleGit-keygen"; environment["SSH_ASKPASS_REQUIRE"] = "force"
        var arguments = ["-q", "-t", request.algorithm.rawValue, "-C", request.comment, "-f", key.path]
        if request.algorithm != .ed25519 { arguments += ["-b", String(request.bits)] }
        if request.passphrase.isEmpty {
            arguments += ["-N", ""]; environment["SSH_ASKPASS"] = "/usr/bin/false"
        } else {
            guard let askpass, FileManager.default.isExecutableFile(atPath: askpass.path) else { throw SSHKeyGenerationFailure.runtime }
            let file = directory.appendingPathComponent("credential-" + UUID().uuidString)
            let descriptor = open(file.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
            guard descriptor >= 0 else { throw SSHKeyGenerationFailure.publish }
            guard fchmod(descriptor, 0o600) == 0 else { Darwin.close(descriptor); throw SSHKeyGenerationFailure.publish }
            let writer = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
            do { try writer.write(contentsOf: Data("TurtleGitSSHKeygen\0".utf8) + Data(request.passphrase.utf8)); try writer.close() }
            catch { try? writer.close(); throw error }
            environment["SSH_ASKPASS"] = askpass.path; environment["TURTLEGIT_SSH_CREDENTIAL_FILE"] = file.path
        }
        let code = try CancellableGitProcess.run(executable: executable, arguments: arguments, environment: environment, output: out.fileDescriptor, error: err.fileDescriptor, cancellation: cancellation)
        try cancellation.check()
        guard code == 0 else { throw SSHKeyGenerationFailure.command(code) }
        guard chmod(key.path, 0o600) == 0, chmod(publicKey.path, 0o644) == 0 else { throw SSHKeyGenerationFailure.publish }
        let publicText = try String(contentsOf: publicKey, encoding: .utf8)
        // Fingerprinting reads only the generated public key.
        let fingerprintCode = try CancellableGitProcess.run(executable: executable, arguments: ["-l", "-E", "sha256", "-f", publicKey.path], environment: environment, output: out.fileDescriptor, error: err.fileDescriptor, cancellation: cancellation)
        try cancellation.check()
        guard fingerprintCode == 0 else { throw SSHKeyGenerationFailure.command(fingerprintCode) }
        let fingerprint = try String(contentsOf: output, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        // Same-volume exclusive links publish complete files and never overwrite.
        guard link(key.path, destination.path) == 0 else { throw SSHKeyGenerationFailure.publish }
        if link(publicKey.path, publicDestination.path) != 0 {
            var staged = stat(), published = stat()
            if lstat(key.path, &staged) == 0, lstat(destination.path, &published) == 0,
               staged.st_ino == published.st_ino, staged.st_dev == published.st_dev { _ = unlink(destination.path) }
            throw SSHKeyGenerationFailure.publish
        }
        return .init(privateKey: destination, publicKey: publicDestination, publicText: publicText, fingerprint: fingerprint)
    }
}
