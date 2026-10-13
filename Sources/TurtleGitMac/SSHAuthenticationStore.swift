// SPDX-License-Identifier: GPL-2.0-or-later
import Foundation
import CryptoKit
import Security
import LocalAuthentication
import TurtleGitCore

struct SSHAuthenticationEntry: Identifiable, Sendable {
    let id: String
    let name: String
}
protocol SSHAuthenticationStore: Sendable {
    func read(identity: String) async throws -> String?
    func save(identity: String, name: String, passphrase: String) async throws
    func entries() async throws -> [SSHAuthenticationEntry]
    func remove(identity: String) async throws
}
struct SSHAuthenticationFailure: LocalizedError {
    let status: OSStatus
    var errorDescription: String? { "SSH authentication could not be accessed in Keychain (\(status))." }
}
struct SSHAuthenticationAPI: Sendable {
    var copy: @Sendable ([String: Any]) -> (OSStatus, Any?)
    var update: @Sendable ([String: Any], [String: Any]) -> OSStatus
    var add: @Sendable ([String: Any]) -> OSStatus
    var delete: @Sendable ([String: Any]) -> OSStatus
    static let live = Self(copy: { query in
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        return (status, result)
    }, update: { SecItemUpdate($0 as CFDictionary, $1 as CFDictionary) },
       add: { SecItemAdd($0 as CFDictionary, nil) }, delete: { SecItemDelete($0 as CFDictionary) })
}
actor SSHKeychainAuthenticationStore: SSHAuthenticationStore {
    static let shared = SSHKeychainAuthenticationStore()
    private let api: SSHAuthenticationAPI
    init(api: SSHAuthenticationAPI = .live) { self.api = api }
    private var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: "org.turtlegit.macos.ssh-authentication",
         kSecUseDataProtectionKeychain as String: true,
         kSecAttrSynchronizable as String: false]
    }
    private func item(_ identity: String) -> [String: Any] {
        var value = query; value[kSecAttrAccount as String] = identity; return value
    }
    func read(identity: String) throws -> String? {
        var request = item(identity)
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        let context = LAContext(); context.interactionNotAllowed = true
        request[kSecUseAuthenticationContext as String] = context
        let (status, result) = api.copy(request)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw SSHAuthenticationFailure(status: status) }
        guard let data = result as? Data, let text = String(data: data, encoding: .utf8), Self.valid(text) else { throw SSHAuthenticationFailure(status: errSecDecode) }
        return text
    }
    static func valid(_ value: String) -> Bool {
        !value.utf8.contains(0) && !value.contains("\n") && !value.contains("\r") && value.utf8.count + "TurtleGitSSHAskpass\0".utf8.count <= 65_536
    }
    func save(identity: String, name: String, passphrase: String) throws {
        guard Self.valid(passphrase) else { throw SSHAgentFailure.passphrase }
        let values: [String: Any] = [kSecAttrLabel as String: name, kSecValueData as String: Data(passphrase.utf8)]
        var status = api.update(item(identity), values)
        if status == errSecItemNotFound {
            var request = item(identity); request.merge(values) { _, new in new }
            request[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            status = api.add(request)
        }
        guard status == errSecSuccess else { throw SSHAuthenticationFailure(status: status) }
    }
    func entries() throws -> [SSHAuthenticationEntry] {
        var request = query
        request[kSecReturnAttributes as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitAll
        let context = LAContext(); context.interactionNotAllowed = true
        request[kSecUseAuthenticationContext as String] = context
        let (status, result) = api.copy(request)
        if status == errSecItemNotFound { return [] }
        guard status == errSecSuccess else { throw SSHAuthenticationFailure(status: status) }
        guard let rows = result as? [[String: Any]] else { throw SSHAuthenticationFailure(status: errSecDecode) }
        return try rows.map { row in
            guard let identity = row[kSecAttrAccount as String] as? String else { throw SSHAuthenticationFailure(status: errSecDecode) }
            return SSHAuthenticationEntry(id: identity, name: row[kSecAttrLabel as String] as? String ?? "SSH key")
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
    func remove(identity: String) throws {
        let status = api.delete(item(identity))
        guard status == errSecSuccess || status == errSecItemNotFound else { throw SSHAuthenticationFailure(status: status) }
    }
}

enum SSHAuthenticationIdentity {
    /// Content identity prevents a replaced key at the same path inheriting a
    /// previous key's passphrase. Neither encoded key bytes nor paths are stored.
    static func read(_ file: URL, cancellation: OperationCancellation) throws -> String {
        let handle = try FileHandle(forReadingFrom: file); defer { try? handle.close() }
        var hash = SHA256(), count = 0
        while true {
            if cancellation.isCancelled { throw OperationCancellationFailure.cancelled }
            guard let bytes = try handle.read(upToCount: 64 * 1024), !bytes.isEmpty else { break }
            count += bytes.count
            guard count <= 16 * 1024 * 1024 else { throw SSHIdentityAccessFailure.file }
            hash.update(data: bytes)
        }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
