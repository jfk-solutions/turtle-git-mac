// SPDX-License-Identifier: GPL-2.0-or-later
import Foundation
import Darwin
import Security
import CryptoKit

public enum GitSVNAuthenticationFailure: LocalizedError {
    case malformed, response, certificateDirectory
    public var errorDescription: String? {
        switch self { case .malformed: return "The SVN authentication request is invalid."
        case .response: return "The SVN authentication response is invalid."
        case .certificateDirectory: return "The owned SVN certificate directory is unavailable." }
    }
}
public struct GitSVNAuthenticationPrompt: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable { case credentials, username, secret, trust, clientCertificate }
    public static let prefix = "TurtleGit SVN prompt v1:"
    public let version: Int
    public let kind: Kind
    public let realm: String
    public let username: String?
    public let maySave: Bool
    public let failures: UInt32?
    public let hostname: String?
    public let validFrom: String?
    public let validUntil: String?
    public let issuer: String?
    public let fingerprint: String?
    public let certificate: String?
    public init(kind: Kind, realm: String, username: String? = nil, maySave: Bool = false, failures: UInt32? = nil, hostname: String? = nil, validFrom: String? = nil, validUntil: String? = nil, issuer: String? = nil, fingerprint: String? = nil, certificate: String? = nil) {
        version = 1; self.kind = kind; self.realm = realm; self.username = username; self.maySave = maySave; self.failures = failures; self.hostname = hostname; self.validFrom = validFrom; self.validUntil = validUntil; self.issuer = issuer; self.fingerprint = fingerprint; self.certificate = certificate
    }
    public static func decode(_ text: String, enabled: Bool) throws -> Self? {
        guard enabled, text.hasPrefix(prefix) else { return nil }
        guard text.utf8.count <= 65_535, let bytes = Data(base64Encoded: String(text.dropFirst(prefix.count))) else { throw GitSVNAuthenticationFailure.malformed }
        let value: Self
        do { value = try JSONDecoder().decode(Self.self, from: bytes) } catch { throw GitSVNAuthenticationFailure.malformed }
        guard value.version == 1, [value.realm, value.username ?? "", value.hostname ?? "", value.validFrom ?? "", value.validUntil ?? "", value.issuer ?? "", value.fingerprint ?? ""].allSatisfy({ !$0.contains("\0") }) else { throw GitSVNAuthenticationFailure.malformed }
        if value.kind == .trust { guard let failures = value.failures, failures > 0, value.hostname != nil, value.issuer != nil, value.fingerprint?.isEmpty == false else { throw GitSVNAuthenticationFailure.malformed } }
        if value.certificate != nil { _ = try value.certificateDetails() }
        return value
    }
    public func encoded() throws -> String { Self.prefix + (try JSONEncoder().encode(self)).base64EncodedString() }
    public func certificateDetails() throws -> GitCertificateDetails? {
        guard let certificate else { return nil }
        return try GitCertificateDetails(base64DER: certificate)
    }
    public var failureDescriptions: [String] {
        guard let failures else { return [] }; var result: [String] = []
        for (bit, text) in [(UInt32(1), "The certificate is not yet valid."), (2, "The certificate has expired."), (4, "The hostname does not match."), (8, "The issuer is not trusted."), (0x40000000, "An additional certificate error occurred.")] where failures & bit != 0 { result.append(text) }
        if failures & ~UInt32(0x4000000f) != 0 { result.append("An unrecognized certificate error occurred.") }; return result
    }
}
public struct GitSVNAuthenticationResponse: Codable, Equatable, Sendable {
    public enum Decision: String, Codable, Sendable { case reject, temporary, permanent }
    public let version: Int
    public var username: String?
    public var password: String?
    public var save: Bool
    public var decision: Decision?
    public var file: String?
    public init(username: String? = nil, password: String? = nil, save: Bool = false, decision: Decision? = nil, file: String? = nil) { version = 1; self.username = username; self.password = password; self.save = save; self.decision = decision; self.file = file }
    public func encoded(for prompt: GitSVNAuthenticationPrompt) throws -> String {
        guard version == 1, !save || prompt.maySave else { throw GitSVNAuthenticationFailure.response }
        switch prompt.kind {
        case .credentials: guard username?.isEmpty == false, password != nil else { throw GitSVNAuthenticationFailure.response }
        case .username: guard username?.isEmpty == false else { throw GitSVNAuthenticationFailure.response }
        case .secret: guard password != nil else { throw GitSVNAuthenticationFailure.response }
        case .trust: guard let decision, decision != .permanent || prompt.maySave else { throw GitSVNAuthenticationFailure.response }
        case .clientCertificate: guard let file, file.hasPrefix("/"), !save else { throw GitSVNAuthenticationFailure.response }
        }
        guard [username ?? "", password ?? "", file ?? ""].allSatisfy(GitAskpassPrompt.validResponse) else { throw GitSVNAuthenticationFailure.response }
        let value = try JSONEncoder().encode(self).base64EncodedString(); guard value.utf8.count <= 65_535 else { throw GitSVNAuthenticationFailure.response }; return value
    }
}
public enum GitSVNClientCertificate {
    /// Copy a picker-authorized certificate into the command-owned private folder.
    /// The running Git child can read it without inheriting the picker's grant.
    public static func copy(_ source: URL, directory: URL) throws -> URL {
        let accessed = source.startAccessingSecurityScopedResource(); defer { if accessed { source.stopAccessingSecurityScopedResource() } }
        let manager = FileManager.default, attributes = try manager.attributesOfItem(atPath: directory.path)
        guard directory.isFileURL, attributes[.type] as? FileAttributeType == .typeDirectory,
              (attributes[.ownerAccountID] as? NSNumber)?.uint32Value == getuid(),
              (attributes[.posixPermissions] as? NSNumber)?.intValue == 0o700,
              source.isFileURL, try source.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else { throw GitSVNAuthenticationFailure.certificateDirectory }
        let target = directory.appendingPathComponent(UUID().uuidString + ".p12")
        do { try manager.copyItem(at: source, to: target); try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: target.path); return target }
        catch { try? manager.removeItem(at: target); throw error }
    }
}

/// Certificate inspection only: no Keychain import and no trust evaluation/override.
public struct GitCertificateDetails: Sendable {
    public let der: Data
    public let subject: String
    public let sha1: String
    public let sha256: String
    public let description: String
    public enum ExportFormat: String, CaseIterable, Sendable {
        case der, pem
        public var fileExtension: String { self == .der ? "cer" : "pem" }
    }
    public var fingerprints: String { "SHA-1: " + sha1 + "\nSHA-256: " + sha256 }
    /// Public certificate bytes only. Export never imports an identity or edits
    /// Keychain trust; PEM uses the standard certificate label and 64-character rows.
    public func encoded(as format: ExportFormat) -> Data {
        guard format == .pem else { return der }
        let bytes = Array(der.base64EncodedString().utf8)
        let rows = stride(from: 0, to: bytes.count, by: 64).map { String(decoding: bytes[$0..<min($0 + 64, bytes.count)], as: UTF8.self) }
        return Data(("-----BEGIN CERTIFICATE-----\n" + rows.joined(separator: "\n") + "\n-----END CERTIFICATE-----\n").utf8)
    }
    public init(base64DER: String) throws {
        guard base64DER.utf8.count <= 48_000, let data = Data(base64Encoded: base64DER.filter { !$0.isWhitespace }), !data.isEmpty,
              let certificate = SecCertificateCreateWithData(nil, data as CFData) else { throw GitSVNAuthenticationFailure.malformed }
        der = data; subject = SecCertificateCopySubjectSummary(certificate).map { $0 as String } ?? "Certificate"
        func hexadecimal(_ bytes: some Sequence<UInt8>) -> String { bytes.map { String(format: "%02X", $0) }.joined(separator: ":") }
        sha1 = hexadecimal(Insecure.SHA1.hash(data: data)); sha256 = hexadecimal(SHA256.hash(data: data))
        var error: Unmanaged<CFError>?
        let properties = SecCertificateCopyValues(certificate, nil, &error) as? [String: Any] ?? [:]
        _ = error?.takeRetainedValue()
        func render(_ value: Any, indent: String = "") -> [String] {
            if let dictionary = value as? [String: Any], let body = dictionary[kSecPropertyKeyValue as String] {
                let label = dictionary[kSecPropertyKeyLabel as String] as? String ?? "Value"
                return [indent + label + ":"] + render(body, indent: indent + "  ")
            }
            if let values = value as? [Any] { return values.flatMap { render($0, indent: indent) } }
            if let bytes = value as? Data { return [indent + hexadecimal(bytes)] }
            return [indent + String(describing: value)]
        }
        description = ([subject, "SHA-1: " + sha1, "SHA-256: " + sha256, ""] + properties.keys.sorted().flatMap { render(properties[$0]!) }).joined(separator: "\n")
    }
}
