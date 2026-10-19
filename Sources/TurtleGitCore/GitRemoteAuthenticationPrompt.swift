// SPDX-License-Identifier: GPL-2.0-or-later
import Foundation

/// A separately gated Git transport protocol sharing the bounded native
/// credential/certificate payload, never SVN's persistence or client-key modes.
public enum GitRemoteAuthenticationPrompt{
    public static let prefix="TurtleGit Git transport prompt v1:"
    public static func decode(_ text:String,enabled:Bool)throws->GitSVNAuthenticationPrompt?{
        guard enabled,text.hasPrefix(prefix) else{return nil}
        guard text.utf8.count<=65_535,let prompt=try GitSVNAuthenticationPrompt.decode(GitSVNAuthenticationPrompt.prefix+String(text.dropFirst(prefix.count)),enabled:true) else{throw GitSVNAuthenticationFailure.malformed}
        try validate(prompt);return prompt
    }
    public static func encoded(_ prompt:GitSVNAuthenticationPrompt)throws->String{
        try validate(prompt)
        let value=prefix+String(try prompt.encoded().dropFirst(GitSVNAuthenticationPrompt.prefix.count));guard value.utf8.count<=65_535 else{throw GitSVNAuthenticationFailure.malformed};return value
    }
    private static func validate(_ prompt:GitSVNAuthenticationPrompt)throws{
        guard !prompt.maySave,prompt.kind == .credentials || prompt.kind == .trust else{throw GitSVNAuthenticationFailure.malformed}
        if prompt.kind == .trust{guard prompt.certificate != nil,try prompt.certificateDetails() != nil else{throw GitSVNAuthenticationFailure.malformed}}
    }
}

/// Temporary source-process acceptance, never a system trust or password store.
/// Authority equality deliberately uses UTF-8 bytes rather than Swift's Unicode
/// canonical string equality. DER is the actual connection's certificate.
public struct GitRemoteCertificateAcceptance: Codable, Sendable {
    public let version: Int
    public let hostname: String
    public let port: UInt16
    public let certificateDER: Data
    public init(hostname: String, port: UInt16, certificateDER: Data) throws {
        version = 1; self.hostname = hostname; self.port = port; self.certificateDER = certificateDER
        try validate()
    }
    public var key: Data {
        var value = Data(hostname.utf8); value.append(0); value.append(contentsOf: String(port).utf8); value.append(0); value.append(certificateDER); return value
    }
    public func validate() throws {
        guard version == 1, !hostname.isEmpty, hostname.utf8.count <= 1024, port > 0,
              !hostname.contains(where: { $0.isWhitespace }), !hostname.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
              !certificateDER.isEmpty, certificateDER.count <= 36_000 else { throw GitSVNAuthenticationFailure.malformed }
        _ = try GitCertificateDetails(base64DER: certificateDER.base64EncodedString())
    }
    public static let maximumRecords = 256 // memory snapshot128 + new operation accepts128
    public static let maximumBytes = 13_000_000
    public static func decode(_ data: Data) throws -> [Self] {
        guard data.count <= maximumBytes, data.isEmpty || data.last == 10 else { throw GitSVNAuthenticationFailure.malformed }
        let lines = data.split(separator: 10, omittingEmptySubsequences: false).dropLast(data.isEmpty ? 0 : 1)
        guard lines.count <= maximumRecords else { throw GitSVNAuthenticationFailure.malformed }
        if data.isEmpty { return [] }
        return try lines.map { line in
            guard !line.isEmpty, line.count <= 51_000 else { throw GitSVNAuthenticationFailure.malformed }
            let value = try JSONDecoder().decode(Self.self, from: Data(line)); try value.validate(); return value
        }
    }
    public func encodedLine() throws -> Data { try validate(); var data = try JSONEncoder().encode(self); data.append(10); return data }
}
