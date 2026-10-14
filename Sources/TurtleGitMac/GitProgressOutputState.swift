import Foundation
import SwiftUI
import TurtleGitCore

/// Native presentation of ProgressDlg::UpdateCmdOutput / UpdateProgressFromLine.
/// The parser owns producer bytes; this value owns the bounded visible log.
struct GitProgressOutputState {
    let limit: Int
    private var bytes = Data(), truncated = false
    private(set) var output = "", currentWork = ""
    private(set) var percentage: Int?
    var hasOutput: Bool { !bytes.isEmpty }
    init(preferences: UserDefaults) {
        limit = max(16, min(preferences.object(forKey: "GitOutputLimitinKiB") as? Int ?? 2048, 100 * 1024)) * 1024
    }
    mutating func reset() { bytes.removeAll(); truncated = false; output = ""; currentWork = ""; percentage = nil }
    mutating func consume(_ emission: GitCliOutputParser.Emission, parser: GitCliOutputParser) {
        guard !truncated else { return }
        if emission.erasePreviousLineBytes > 0 { bytes.removeLast(min(bytes.count, emission.erasePreviousLineBytes)) }
        let available = max(0, limit - bytes.count), clipped = emission.data.count > available
        bytes.append(emission.data.prefix(available))
        if clipped {
            // Do not leave the beginning of a UTF-8 scalar at the cut boundary.
            let tail = Array(bytes.suffix(4)); var cursor = tail.count - 1
            while cursor > 0 && tail[cursor] & 0xC0 == 0x80 { cursor -= 1 }
            if cursor >= 0 {
                let lead = tail[cursor]
                let expected = lead >= 0xF0 && lead <= 0xF4 ? 4 : lead >= 0xE0 && lead <= 0xEF ? 3 : lead >= 0xC2 && lead <= 0xDF ? 2 : 1
                if expected > tail.count - cursor { bytes.removeLast(tail.count - cursor) }
            }
        }
        output = String(decoding: bytes, as: UTF8.self).replacingOccurrences(of: "\u{1b}\\[[0-9;]*m|\u{1b}\\[K", with: "", options: .regularExpression)
        for line in String(decoding: emission.data, as: UTF8.self).split(separator: "\n") {
            guard let colon = line.lastIndex(of: ":"), let percent = line.firstIndex(of: "%") else { continue }
            currentWork = String(line[..<colon])
            let digits = line[..<percent].reversed().prefix { $0.isASCII && $0.isNumber }.reversed()
            if let value = Int(String(digits)), value > 0 { percentage = min(value, 100) }
        }
        if emission.limited || clipped || bytes.count >= limit {
            truncated = true; parser.activateDropMode()
            currentWork = "[Output truncated at about \(bytes.count / 1024) KiB]"; percentage = nil
            output += "\n\n...\n" + currentWork
        }
    }
}


/// One producer/consumer lifetime for local command dialogs. Result strings stay
/// original for repository callbacks; only presentation is bounded/CR-normalized.
@MainActor enum LocalGitCommandProgress {
    private(set) static var activeOperations = 0
    static func begin() { activeOperations += 1 }
    static func end() { activeOperations -= 1 }
    static func stream<T>(preferences: UserDefaults, update: @escaping (GitProgressOutputState) -> Void,
                          resultText: @escaping (T) -> String,
                          operation: @escaping (@escaping @Sendable (GitOutputChunk) -> Void) async throws -> T) async throws -> T {
        var state = GitProgressOutputState(preferences: preferences)
        let parser = GitCliOutputParser(limit: state.limit)
        let (updates, continuation) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let worker = Task {
            defer { continuation.finish() }
            return try await operation { chunk in parser.appendChunk(chunk.data); continuation.yield(()) }
        }
        for await _ in updates { state.consume(parser.processPending(), parser: parser); update(state) }
        state.consume(parser.processPending(), parser: parser); state.consume(parser.finish(), parser: parser); update(state)
        let result = try await worker.value
        if state.output.isEmpty {
            let fallback = GitCliOutputParser(limit: state.limit)
            fallback.appendChunk(Data(resultText(result).utf8))
            state.consume(fallback.processPending(), parser: fallback); state.consume(fallback.finish(), parser: fallback); update(state)
        }
        return result
    }
    static func bounded(_ text: String, preferences: UserDefaults) -> String {
        var state = GitProgressOutputState(preferences: preferences); let parser = GitCliOutputParser(limit: state.limit)
        parser.appendChunk(Data(text.utf8)); state.consume(parser.processPending(), parser: parser); state.consume(parser.finish(), parser: parser)
        return state.output
    }
    static func failure(_ error: Error, existing: String, preferences: UserDefaults) -> String {
        if !existing.isEmpty, error is GitFailure || error is GitCommandCancellationFailure { return existing }
        return bounded(existing + (existing.isEmpty || existing.hasSuffix("\n") ? "" : "\n") + error.localizedDescription, preferences: preferences)
    }
}


struct LocalGitProgressIndicator: View {
    let percentage: Int?
    var body: some View {
        if let percentage { ProgressView(value: Double(percentage), total: 100).frame(width: 130) }
        else { ProgressView().controlSize(.small) }
    }
}
