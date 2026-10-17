// SPDX-License-Identifier: GPL-2.0-or-later
import Foundation
import CryptoKit

public struct ReleaseVersion: Comparable, Equatable, Sendable {
    public let numbers: [UInt64]
    public let prerelease: [String]
    public init?(_ value: String) {
        var value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.hasPrefix("v") || value.hasPrefix("V") { value.removeFirst() }
        guard !value.isEmpty else { return nil }
        let buildParts = value.split(separator: "+", omittingEmptySubsequences: false)
        guard buildParts.count <= 2 else { return nil }
        if buildParts.count == 2 {
            guard buildParts[1].split(separator: ".", omittingEmptySubsequences: false).allSatisfy({ !$0.isEmpty && $0.utf8.allSatisfy { (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45 } }) else { return nil }
        }
        let withoutBuild = buildParts[0]
        let pieces = withoutBuild.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
        let components = pieces[0].split(separator: ".", omittingEmptySubsequences: false)
        guard (2...4).contains(components.count), components.allSatisfy({ !$0.isEmpty && $0.utf8.allSatisfy { (48...57).contains($0) } }) else { return nil }
        let numbers = components.compactMap { UInt64($0) }; guard numbers.count == components.count else { return nil }
        let suffix = pieces.count == 2 ? pieces[1].split(separator: ".", omittingEmptySubsequences: false).map(String.init) : []
        guard suffix.allSatisfy({ !$0.isEmpty && $0.utf8.allSatisfy { (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45 } }) else { return nil }
        guard suffix.allSatisfy({ !$0.utf8.allSatisfy { (48...57).contains($0) } || $0.count == 1 || !$0.hasPrefix("0") }) else { return nil }
        self.numbers = numbers + Array(repeating: 0, count: 4 - numbers.count); prerelease = suffix
    }
    public static func < (lhs: Self, rhs: Self) -> Bool {
        if lhs.numbers != rhs.numbers { return lhs.numbers.lexicographicallyPrecedes(rhs.numbers) }
        if lhs.prerelease.isEmpty || rhs.prerelease.isEmpty { return !lhs.prerelease.isEmpty && rhs.prerelease.isEmpty }
        for (a, b) in zip(lhs.prerelease, rhs.prerelease) where a != b {
            let firstNumeric = a.utf8.allSatisfy { (48...57).contains($0) }, secondNumeric = b.utf8.allSatisfy { (48...57).contains($0) }
            if firstNumeric && secondNumeric { return a.count == b.count ? a < b : a.count < b.count }
            if firstNumeric { return true }; if secondNumeric { return false }
            return a < b
        }
        return lhs.prerelease.count < rhs.prerelease.count
    }
}
public struct PublishedRelease: Decodable, Sendable {
    public let tag: String, name: String?, notes: String?
    public let url: URL
    public let draft: Bool, prerelease: Bool
    public let assets: [ReleaseAsset]
    enum CodingKeys: String, CodingKey { case tag = "tag_name", name, notes = "body", url = "html_url", draft, prerelease, assets }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        tag = try values.decode(String.self, forKey: .tag); name = try values.decodeIfPresent(String.self, forKey: .name)
        notes = try values.decodeIfPresent(String.self, forKey: .notes); url = try values.decode(URL.self, forKey: .url)
        draft = try values.decode(Bool.self, forKey: .draft); prerelease = try values.decode(Bool.self, forKey: .prerelease)
        assets = try values.decodeIfPresent([ReleaseAsset].self, forKey: .assets) ?? []
    }
}
public enum ReleaseUpdateFailure: LocalizedError {
    case feed, response(Int), invalidVersion, oversized
    public var errorDescription: String? {
        switch self {
        case .feed: return "The public release feed is unavailable or contains an unexpected release link."
        case .response(let code): return "Could not check for updates (HTTP \(code)). Try again later."
        case .invalidVersion: return "The installed version or release tag cannot be compared. Open the release page to check manually."
        case .oversized: return "The release response exceeded the supported size."
        }
    }
}
public enum ReleaseUpdateFeed {
    public static func repository(bundle: Bundle = .main) -> String {
        let value = bundle.object(forInfoDictionaryKey: "TurtleGitUpdateRepository") as? String ?? "jfk-solutions/turtle-git-mac"
        let parts = value.split(separator: "/", omittingEmptySubsequences: false)
        return parts.count == 2 && parts.allSatisfy({ !$0.isEmpty && $0.utf8.allSatisfy { (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || [45, 46, 95].contains($0) } }) ? value : "jfk-solutions/turtle-git-mac"
    }
    public static func releases(_ data: Data, repository: String, includePreview: Bool) throws -> [PublishedRelease] {
        guard data.count <= 4 * 1024 * 1024 else { throw ReleaseUpdateFailure.oversized }
        let releases = try JSONDecoder().decode([PublishedRelease].self, from: data).filter { !$0.draft && (includePreview || !$0.prerelease) }
        for release in releases {
            guard release.url.scheme == "https", release.url.host?.lowercased() == "github.com", release.url.user == nil,
                  release.url.path.lowercased().hasPrefix("/" + repository.lowercased() + "/releases/tag/") else { throw ReleaseUpdateFailure.feed }
        }
        for release in releases {
            guard Set(release.assets.map(\.id)).count == release.assets.count,
                  Set(release.assets.map { $0.name.lowercased() }).count == release.assets.count else { throw ReleaseDownloadFailure.metadata }
            for asset in release.assets { try asset.validate(repository: repository, tag: release.tag) }
        }
        return releases.sorted {
            guard let a = ReleaseVersion($0.tag), let b = ReleaseVersion($1.tag) else { return ReleaseVersion($0.tag) != nil }
            return a > b
        }
    }
    public static func fetch(repository: String, includePreview: Bool, session: URLSession = .shared) async throws -> [PublishedRelease] {
        let url = URL(string: "https://api.github.com/repos/" + repository + "/releases?per_page=100")!
        var request = URLRequest(url: url, timeoutInterval: 20)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2026-03-10", forHTTPHeaderField: "X-GitHub-Api-Version")
        request.setValue("TurtleGit-for-Mac", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await session.data(for: request)
        try Task.checkCancellation()
        guard let http = response as? HTTPURLResponse else { throw ReleaseUpdateFailure.feed }
        guard http.statusCode == 200 else { throw http.statusCode == 404 ? ReleaseUpdateFailure.feed : ReleaseUpdateFailure.response(http.statusCode) }
        return try releases(data, repository: repository, includePreview: includePreview)
    }
}

/// GitHub's release asset digest is an integrity check on the public metadata,
/// not a replacement for macOS code signing or an independent publisher signature.
public struct ReleaseAsset: Decodable, Equatable, Identifiable, Sendable {
    public let id: Int64
    public let name: String
    public let size: Int64
    public let url: URL
    public let digest: String?
    public let state: String
    enum CodingKeys: String, CodingKey { case id, name, size, digest, state, url = "browser_download_url" }
    public var sha256: String? {
        guard let digest, digest.hasPrefix("sha256:") else { return nil }
        let hex = String(digest.dropFirst(7)).lowercased()
        return hex.utf8.count == 64 && hex.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) } ? hex : nil
    }
    public var downloadable: Bool { state == "uploaded" && sha256 != nil && size > 0 && size <= ReleaseAssetDownload.maximumSize }
    public func validate(repository: String, tag: String) throws {
        let prefix = "/" + repository + "/releases/download/"
        guard id > 0, !name.isEmpty, name != ".", name != "..", !name.contains("/"), !name.contains("\\"),
              !name.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
              size >= 0, url.scheme == "https", url.host?.lowercased() == "github.com", url.user == nil, url.password == nil,
              url.port == nil || url.port == 443, url.query == nil, url.fragment == nil,
              String(url.path.prefix(prefix.count)).caseInsensitiveCompare(prefix) == .orderedSame,
              String(url.path.dropFirst(prefix.count)) == tag + "/" + name else { throw ReleaseDownloadFailure.metadata }
    }
}
public enum ReleaseDownloadFailure: LocalizedError {
    case metadata, integrity, size, destination, response(Int)
    public var errorDescription: String? {
        switch self {
        case .metadata: return "The release contains unexpected download metadata. Open its release page to inspect it."
        case .integrity: return "The downloaded file does not match the release SHA-256 digest. No download was installed."
        case .size: return "The download has an unexpected or unsupported size."
        case .destination: return "A download with this name already exists, or the destination cannot accept it. Choose another folder."
        case .response(let code): return "The release file could not be downloaded (HTTP \(code))."
        }
    }
}
public enum ReleaseAssetDownload {
    public static let maximumSize: Int64 = 1024 * 1024 * 1024
    public static func verify(_ file: URL, asset: ReleaseAsset) throws {
        guard asset.downloadable, let digest = asset.sha256 else { throw ReleaseDownloadFailure.metadata }
        let values = try file.resourceValues(forKeys: [.isRegularFileKey,.isSymbolicLinkKey,.fileSizeKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true, Int64(values.fileSize ?? -1) == asset.size else { throw ReleaseDownloadFailure.size }
        let handle = try FileHandle(forReadingFrom: file); defer { try? handle.close() }
        var hash = SHA256(), count: Int64 = 0
        while let data = try handle.read(upToCount: 1024 * 1024), !data.isEmpty {
            try Task.checkCancellation(); count += Int64(data.count)
            guard count <= asset.size && count <= maximumSize else { throw ReleaseDownloadFailure.size }; hash.update(data: data)
        }
        let actual = hash.finalize().map { String(format: "%02x", $0) }.joined()
        guard count == asset.size, actual == digest else { throw ReleaseDownloadFailure.integrity }
    }
    /// Publish a complete file without replacing a destination created by another
    /// actor. The private sibling and final hard link are on the chosen volume.
    /// Filesystems without hard-link support report an error rather than overwrite.
    public static func install(_ stage: URL, to destination: URL) throws {
        let privateFile = destination.deletingLastPathComponent().appendingPathComponent(".TurtleGit-download-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: privateFile) }
        try FileManager.default.copyItem(at: stage, to: privateFile)
        do { try FileManager.default.linkItem(at: privateFile, to: destination) }
        catch { throw ReleaseDownloadFailure.destination }
    }
    public static func fetch(_ asset: ReleaseAsset, to stage: URL, configuration: URLSessionConfiguration = .ephemeral,
                             progress: @escaping @Sendable (Int64) -> Void = { _ in }) async throws {
        guard asset.downloadable, asset.url.scheme == "https", asset.url.host?.lowercased() == "github.com", asset.url.user == nil, asset.url.password == nil, asset.url.port == nil || asset.url.port == 443 else { throw ReleaseDownloadFailure.metadata }
        let worker = Transfer(asset: asset, stage: stage, configuration: configuration, progress: progress)
        try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { (reply: CheckedContinuation<Void,Error>) in worker.start(reply) }
        }, onCancel: { worker.cancel() })
    }
    private final class Transfer: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
        let asset: ReleaseAsset, stage: URL, configuration: URLSessionConfiguration
        let progress: @Sendable (Int64) -> Void
        let lock = NSLock()
        var cancelled = false
        var session: URLSession?
        var task: URLSessionDownloadTask?
        var reply: CheckedContinuation<Void,Error>?
        var failure: Error?
        var copied = false
        init(asset: ReleaseAsset, stage: URL, configuration: URLSessionConfiguration, progress: @escaping @Sendable (Int64) -> Void) {
            self.asset = asset; self.stage = stage; self.configuration = configuration; self.progress = progress
        }
        func start(_ reply: CheckedContinuation<Void,Error>) {
            lock.lock()
            guard !cancelled else { lock.unlock(); reply.resume(throwing: CancellationError()); return }
            self.reply = reply
            configuration.timeoutIntervalForRequest = 30; configuration.timeoutIntervalForResource = 600
            configuration.httpCookieStorage = nil; configuration.urlCredentialStorage = nil
            let queue = OperationQueue(); queue.maxConcurrentOperationCount = 1
            let session = URLSession(configuration: configuration, delegate: self, delegateQueue: queue)
            self.session = session
            let task = session.downloadTask(with: asset.url); self.task = task
            lock.unlock(); task.resume()
        }
        func cancel() { lock.lock(); cancelled = true; let session = session; lock.unlock(); session?.invalidateAndCancel() }
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
            guard let url = request.url, url.scheme == "https", url.user == nil, url.password == nil,
                  url.port == nil || url.port == 443,
                  url.host?.lowercased() == "github.com" || url.host?.lowercased().hasSuffix(".githubusercontent.com") == true else {
                failure = ReleaseDownloadFailure.metadata; completionHandler(nil); task.cancel(); return
            }
            completionHandler(request)
        }
        func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                        totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
            guard totalBytesWritten <= asset.size && totalBytesWritten <= ReleaseAssetDownload.maximumSize else {
                failure = ReleaseDownloadFailure.size; downloadTask.cancel(); return
            }
            progress(totalBytesWritten)
        }
        func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
            do {
                lock.lock(); let cancelled = cancelled; lock.unlock(); if cancelled { throw CancellationError() }
                guard let response = downloadTask.response as? HTTPURLResponse, response.statusCode == 200 else {
                    throw ReleaseDownloadFailure.response((downloadTask.response as? HTTPURLResponse)?.statusCode ?? 0)
                }
                try ReleaseAssetDownload.verify(location, asset: asset)
                lock.lock(); let stopped = self.cancelled; lock.unlock(); if stopped { throw CancellationError() }
                try FileManager.default.copyItem(at: location, to: stage); copied = true
            } catch { failure = error }
        }
        func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
            lock.lock(); let stopped = cancelled; let reply = reply; self.reply = nil; self.task = nil; self.session = nil; lock.unlock()
            session.finishTasksAndInvalidate()
            let resultError = stopped ? CancellationError() : (failure ?? error)
            if let resultError { if copied { try? FileManager.default.removeItem(at: stage) }; reply?.resume(throwing: resultError) }
            else if !copied { reply?.resume(throwing: ReleaseDownloadFailure.metadata) }
            else { reply?.resume() }
        }
    }
}
