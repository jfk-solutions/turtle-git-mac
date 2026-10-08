import Foundation

/// Byte-oriented port of upstream CGitCliOutputParser. Append may run on the Git
/// actor while one UI consumer processes pending input; the lock owns all state.
public final class GitCliOutputParser: @unchecked Sendable {
    public struct Emission: Sendable {
        public var data = Data()
        public var erasePreviousLineBytes = 0
        public var limited = false
    }
    private let lock = NSLock()
    private let limit: Int
    private var input = [UInt8](), currentLine = [UInt8](), pendingCR = [UInt8]()
    private var lineLength = 0
    private var skippingTruncatedLine = false, dropMode = false, pendingVisible = false, skipEmptyRemoteLF = false
    private let remotePrefix = Array("remote: ".utf8)
    public init(limit: Int = Int.max) { self.limit = limit }
    public func appendChunk(_ bytes: Data) {
        lock.lock(); defer { lock.unlock() }; guard !dropMode else { return }
        for original in bytes {
            let ch: UInt8 = original == 0 ? 10 : original
            if ch == 10 || ch == 13 { input.append(ch); lineLength = 0; skippingTruncatedLine = false; continue }
            if skippingTruncatedLine { continue }
            if lineLength >= 8 * 1024 { skippingTruncatedLine = true; input += Array("... [line truncated at 8 KiB]".utf8); continue }
            lineLength += 1; input.append(ch)
        }
        if input.count > 150 * 1024 * 1024 { input += Array("\n\n[Buffer truncated at about 150 MiB to prevent resource exhaustion]\n".utf8); dropMode = true }
    }
    public func processPending() -> Emission {
        lock.lock(); defer { lock.unlock() }
        let bytes = input; input.removeAll(keepingCapacity: true)
        return process(bytes)
    }
    /// Preserve a final unterminated diagnostic on macOS. Ordinary streaming
    /// retains upstream delimiter-based emission, including split UTF-8 bytes.
    public func finish() -> Emission {
        lock.lock(); defer { lock.unlock() }
        var bytes = input; input.removeAll(keepingCapacity: true)
        if !currentLine.isEmpty || !bytes.isEmpty { bytes.append(10) }
        return process(bytes)
    }
    public func activateDropMode() { lock.lock(); defer { lock.unlock() }; dropMode = true; input.removeAll() }
    public func reset() {
        lock.lock(); defer { lock.unlock() }; input.removeAll(); currentLine.removeAll(); pendingCR.removeAll(); lineLength = 0; skippingTruncatedLine = false; dropMode = false; pendingVisible = false; skipEmptyRemoteLF = false
    }
    private func process(_ bytes: [UInt8]) -> Emission {
        var out = Emission(), foundCR = false
        for ch in bytes {
            if ch == 10 || ch == 13 {
                handle(currentLine, cr: ch == 13, out: &out); if ch == 13 { foundCR = true }; currentLine.removeAll(keepingCapacity: true)
                if out.limited { break }
            } else { currentLine.append(ch) }
        }
        if !pendingCR.isEmpty && foundCR && !(skipEmptyRemoteLF && pendingCR == remotePrefix) { out.data.append(contentsOf: pendingCR); pendingVisible = true }
        return out
    }
    private func erase(_ out: inout Emission) { if pendingVisible { out.erasePreviousLineBytes = pendingCR.count; pendingVisible = false } }
    private func discard(_ out: inout Emission) { erase(&out); pendingCR.removeAll() }
    private func appendLine(_ line: [UInt8], out: inout Emission) {
        if out.data.count > limit { out.limited = true; return }; out.data.append(contentsOf: line); out.data.append(10)
    }
    private func permanent(_ out: inout Emission) { guard !pendingCR.isEmpty else { return }; erase(&out); appendLine(pendingCR, out: &out); pendingCR.removeAll() }
    private func overlay(_ old: [UInt8], _ new: [UInt8]) -> [UInt8] { if new.count >= old.count { return new }; var bytes = old; bytes.replaceSubrange(0..<new.count, with: new); return bytes }
    private func handle(_ line: [UInt8], cr: Bool, out: inout Emission) {
        let remote = line.starts(with: remotePrefix), pendingRemote = pendingCR.starts(with: remotePrefix), emptyRemote = line == remotePrefix
        if cr {
            if pendingCR.isEmpty { pendingCR = line; return }
            if pendingRemote && remote {
                if !(skipEmptyRemoteLF && emptyRemote) { skipEmptyRemoteLF = false }
                if !emptyRemote { discard(&out) } else if !skipEmptyRemoteLF { permanent(&out) }
                pendingCR = line; return
            }
            erase(&out); pendingCR = overlay(pendingCR, line); return
        }
        if pendingCR.isEmpty {
            if !skipEmptyRemoteLF || !emptyRemote { appendLine(line, out: &out) }; skipEmptyRemoteLF = false; return
        }
        if pendingRemote && remote {
            skipEmptyRemoteLF = emptyRemote
            if emptyRemote && pendingCR != remotePrefix { permanent(&out); return }
            discard(&out); appendLine(line, out: &out); return
        }
        erase(&out)
        if out.data.count > limit { out.limited = true; pendingCR.removeAll(); skipEmptyRemoteLF = false; return }
        out.data.append(contentsOf: line.isEmpty ? pendingCR : overlay(pendingCR, line)); out.data.append(10)
        pendingCR.removeAll(); skipEmptyRemoteLF = false
    }
}

public struct GitOutputChunk: Sendable {
    public enum Stream: Sendable { case stdout, stderr }
    public let stream: Stream
    public let data: Data
    public init(stream: Stream, data: Data) { self.stream = stream; self.data = data }
}
