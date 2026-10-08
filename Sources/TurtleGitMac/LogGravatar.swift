import AppKit
import CryptoKit
import SwiftUI
import TurtleGitCore

struct LogGravatarRequest {
    static let defaultTemplate = "https://gravatar.com/avatar/%HASH%?d=identicon"
    static func url(email: String, template: String, useMD5: Bool) -> URL? {
        let normalized = email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalized.isEmpty else { return nil }
        let bytes = Data(normalized.utf8)
        let hash = useMD5 ? Insecure.MD5.hash(data: bytes).map { String(format: "%02x", $0) }.joined() : SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        guard let url = URL(string: template.replacingOccurrences(of: "%HASH%", with: hash)), ["https", "http"].contains(url.scheme?.lowercased() ?? ""), url.host != nil else { return nil }
        return url
    }
}

/// Owns one selection request. No network work starts while the feature is off.
@MainActor final class LogGravatar: ObservableObject {
    @Published private(set) var image: NSImage?
    private let defaults: UserDefaults
    private let session: URLSession
    private let cache: URL
    private let delay: UInt64
    private var request: Task<Void, Never>?
    private var generation = 0
    init(defaults: UserDefaults = .standard, session: URLSession = .shared, cache: URL = TurtleGitTemporaryStorage.defaultRoot.appendingPathComponent("TurtleGit-Gravatar", isDirectory: true), delay: UInt64 = 500_000_000) {
        self.defaults = defaults; self.session = session; self.cache = cache; self.delay = delay
    }
    func load(email: String?) {
        cancel(); let current = generation
        guard let email, let url = LogGravatarRequest.url(email: email, template: defaults.string(forKey: "GravatarUrl") ?? LogGravatarRequest.defaultTemplate, useMD5: defaults.bool(forKey: "GravatarUseMD5")) else { image = nil; return }
        let key = SHA256.hash(data: Data(url.absoluteString.utf8)).map { String(format: "%02x", $0) }.joined()
        let file = cache.appendingPathComponent(key)
        request = Task {
            do {
                try await Task.sleep(nanoseconds: delay)
                try Task.checkCancellation()
                let attributes = try? FileManager.default.attributesOfItem(atPath: file.path)
                if let date = attributes?[.modificationDate] as? Date, Date().timeIntervalSince(date) < 7 * 24 * 3600, let data = try? Data(contentsOf: file), let cached = NSImage(data: data) {
                    guard current == generation else { return }; image = cached; request = nil; return
                }
                let (data, response) = try await session.data(from: url)
                try Task.checkCancellation()
                guard current == generation else { return }
                guard (response as? HTTPURLResponse)?.statusCode == 200, !data.isEmpty, data.count <= 8 * 1024 * 1024, let loaded = NSImage(data: data) else { image = nil; request = nil; return }
                image = loaded
                // A cache failure does not hide a successfully loaded image.
                try? FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                try? data.write(to: file, options: .atomic)
                request = nil
            } catch {
                guard current == generation else { return }; image = nil; request = nil
            }
        }
    }
    func cancel() { generation += 1; request?.cancel(); request = nil }
    func clear() { cancel(); image = nil }
    deinit { request?.cancel() }
}

struct LogGravatarView: View {
    @ObservedObject var loader: LogGravatar
    var body: some View {
        Group {
            if let image = loader.image { Image(nsImage: image).resizable().scaledToFit().accessibilityLabel("Commit author Gravatar") }
            else { Color.clear.accessibilityLabel("No author Gravatar") }
        }.frame(width: 80, height: 80).overlay(Rectangle().stroke(Color.secondary, lineWidth: 1))
    }
}
