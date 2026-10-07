import AppKit
import Foundation
import SwiftUI
import TurtleGitCore

final class AvatarTransport: URLProtocol {
    static var count = 0
    static var stops = 0
    static var bytes = Data()
    private static let lock = NSLock()
    private var work: DispatchWorkItem?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lock.lock(); Self.count += 1; let data = Self.bytes; Self.lock.unlock()
        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            let code = self.request.url!.path.contains("failure") ? 404 : 200
            self.client?.urlProtocol(self, didReceive: HTTPURLResponse(url: self.request.url!, statusCode: code, httpVersion: "HTTP/1.1", headerFields: nil)!, cacheStoragePolicy: .notAllowed)
            self.client?.urlProtocol(self, didLoad: self.request.url!.path.contains("invalid") ? Data("invalid image".utf8) : data)
            self.client?.urlProtocolDidFinishLoading(self)
        }
        work = item
        DispatchQueue.global().asyncAfter(deadline: .now() + (request.url!.path.contains("slow") ? 0.3 : 0), execute: item)
    }
    override func stopLoading() { work?.cancel(); Self.lock.lock(); Self.stops += 1; Self.lock.unlock() }
    static func requests() -> Int { lock.lock(); defer { lock.unlock() }; return count }
}

@main struct GravatarVerification {
    @MainActor static func settle() async throws { try await Task.sleep(nanoseconds: 100_000_000) }
    @MainActor static func main() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let root = URL(fileURLWithPath: CommandLine.arguments[1])
        let repo = GitRepository(root: root, executable: URL(fileURLWithPath: CommandLine.arguments[2]))
        _ = try await repo.run(["init", "-b", "main"])
        _ = try await repo.run(["config", "user.name", "Avatar QA"])
        _ = try await repo.run(["config", "user.email", "Test@Example.com"])
        _ = try await repo.run(["config", "commit.gpgsign", "false"])
        _ = try await repo.run(["config", "core.hooksPath", "/dev/null"])
        try Data("one".utf8).write(to: root.appendingPathComponent("file")); try await repo.stage(["file"]); _ = try await repo.commit(message: "one")
        try Data("two".utf8).write(to: root.appendingPathComponent("file")); try await repo.stage(["file"]); _ = try await repo.commit(message: "two")
        let paths = [".git/index", ".git/config", ".git/HEAD", "file"]
        let before = try paths.map { try Data(contentsOf: root.appendingPathComponent($0)) }
        let suite = "TurtleGit.Gravatar.QA." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let normalized = LogGravatarRequest.url(email: "  TEST@example.com\n", template: LogGravatarRequest.defaultTemplate, useMD5: false)!
        precondition(normalized.absoluteString == "https://gravatar.com/avatar/973dfe463ec85785f5f95af5ba3906eedb2d931c24e69824a89ea65dba4e813b?d=identicon")
        precondition(LogGravatarRequest.url(email: "Test@example.com", template: "https://avatar.invalid/%HASH%/%HASH%", useMD5: true)!.path == "/55502f40dc8b7c769880b10874abc9d0/55502f40dc8b7c769880b10874abc9d0")
        precondition(LogGravatarRequest.url(email: " \n", template: LogGravatarRequest.defaultTemplate, useMD5: false) == nil)
        precondition(LogGravatarRequest.url(email: "a", template: "file:///tmp/%HASH%", useMD5: false) == nil)
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 2, pixelsHigh: 2, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        for x in 0..<2 { for y in 0..<2 { bitmap.setColor(NSColor(deviceRed: 1, green: 0, blue: 0, alpha: 1), atX: x, y: y) } }
        AvatarTransport.bytes = bitmap.representation(using: .png, properties: [:])!
        let configuration = URLSessionConfiguration.ephemeral; configuration.protocolClasses = [AvatarTransport.self]
        let session = URLSession(configuration: configuration); defer { session.invalidateAndCancel() }
        let cache = root.appendingPathComponent("avatar-cache")
        defaults.set("https://avatar.invalid/good/%HASH%", forKey: "GravatarUrl")
        let loader = LogGravatar(defaults: defaults, session: session, cache: cache, delay: 0)
        let model = LogWindowModel(repository: repo, access: nil, labelDefaults: defaults, gravatar: loader)
        model.entries = try await repo.history(); model.select([model.entries[0].hash])
        try await settle(); precondition(!model.showGravatar && loader.image == nil && AvatarTransport.requests() == 0)
        model.toggleGravatar(); try await settle(); precondition(model.showGravatar && loader.image?.size == NSSize(width: 2, height: 2) && AvatarTransport.requests() == 1)
        loader.clear(); loader.load(email: "test@example.com"); try await settle(); precondition(loader.image != nil && AvatarTransport.requests() == 1, "Cache caused another network request")
        let file = try FileManager.default.contentsOfDirectory(at: cache, includingPropertiesForKeys: nil)[0]
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -8 * 24 * 3600)], ofItemAtPath: file.path)
        loader.load(email: "test@example.com"); try await settle(); precondition(AvatarTransport.requests() == 2, "Expired cache was reused")
        model.select(Set(model.entries.map(\.hash))); try await settle(); precondition(loader.image == nil && AvatarTransport.requests() == 2)
        model.select([model.entries[0].hash]); try await settle(); precondition(loader.image != nil)
        let unwritable = LogGravatar(defaults: defaults, session: session, cache: root.appendingPathComponent("file"), delay: 0)
        unwritable.load(email: "cache-write@example.com"); try await settle(); precondition(unwritable.image != nil, "Cache failure hid a downloaded image"); unwritable.clear()
        defaults.set("https://avatar.invalid/invalid/%HASH%", forKey: "GravatarUrl")
        loader.load(email: "test@example.com"); try await settle(); precondition(loader.image == nil, "Invalid image was displayed")
        let requestCount = AvatarTransport.requests()
        let delayed = LogGravatar(defaults: defaults, session: session, cache: cache, delay: 100_000_000)
        delayed.load(email: "delayed@example.com"); delayed.clear(); try await Task.sleep(nanoseconds: 150_000_000)
        precondition(AvatarTransport.requests() == requestCount, "Canceled delay still sent a request")
        defaults.set("https://avatar.invalid/failure/%HASH%", forKey: "GravatarUrl")
        loader.load(email: "test@example.com"); try await settle(); precondition(loader.image == nil)
        defaults.set("https://avatar.invalid/slow/%HASH%", forKey: "GravatarUrl")
        loader.load(email: "other@example.com"); try await Task.sleep(nanoseconds: 20_000_000); model.invalidate()
        try await Task.sleep(nanoseconds: 400_000_000); precondition(loader.image == nil, "Late request repopulated a closed Log")
        let reopened = LogWindowModel(repository: repo, access: nil, labelDefaults: defaults, gravatar: loader)
        precondition(reopened.showGravatar); reopened.toggleGravatar(); precondition(!reopened.showGravatar)
        defaults.set(true, forKey: "EnableGravatar")
        precondition(!LogWindowModel(repository: repo, access: nil, labelDefaults: defaults).showGravatar, "Global setting overrode saved repository choice")
        let other = LogWindowModel(repository: GitRepository(root: root.appendingPathComponent("other")), access: nil, labelDefaults: defaults)
        precondition(other.showGravatar); other.invalidate()
        let hidden = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 700), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        hidden.contentViewController = NSHostingController(rootView: LogDialog(model: reopened))
        hidden.contentView?.layoutSubtreeIfNeeded(); hidden.close(); reopened.invalidate()
        let after = try paths.map { try Data(contentsOf: root.appendingPathComponent($0)) }; precondition(before == after)
        print("Native Gravatar: hash normalization, mocked requests, cache hit/expiry, failure, multi-selection clear, cancellation/stale completion, saved/default repository visibility and hidden layout passed; repository unchanged")
    }
}
