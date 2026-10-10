import XCTest
import Darwin
import TurtleGitSMTP
@testable import TurtleGitCore

private let cancelOpenedMX: @convention(c) (UnsafeMutableRawPointer?, UInt64, UInt64) -> Int32 = { opaque, _, _ in
    guard let opaque else { return 1 }
    let calls = opaque.assumingMemoryBound(to: Int32.self); calls.pointee += 1
    return calls.pointee >= 2 ? 1 : 0
}
final class SMTPMXTests: XCTestCase {
    func testWirePreferenceHostnameAndNullMX() throws {
        let bytes = Data([0x12, 0x34, 3] + Array("mx1".utf8) + [7] + Array("example".utf8) + [3] + Array("com".utf8) + [0])
        let record = try SMTPMXRecord.decode(bytes)
        XCTAssertEqual(record.preference, 0x1234); XCTAssertEqual(record.hostname, "mx1.example.com"); XCTAssertFalse(record.isNull)
        let null = try SMTPMXRecord.decode(Data([0, 0, 0]))
        XCTAssertEqual(null.preference, 0); XCTAssertEqual(null.hostname, "."); XCTAssertTrue(null.isNull)
    }
    func testMalformedWireDataNeverEscapesRecordBounds() throws {
        for bytes in [[UInt8](), [0], [0, 0], [0, 0, 3, 65], [0, 0, 0, 0], [0, 0, 0xC0, 12], [0, 0, 1, 0, 0], [0, 0, 1, 46, 0], [0, 0, 64] + Array(repeating: 65, count: 64) + [0]] {
            XCTAssertThrowsError(try SMTPMXRecord.decode(Data(bytes)), "\(bytes)")
        }
        let threeLabels = Array(repeating: [UInt8(63)] + Array(repeating: UInt8(65), count: 63), count: 3).flatMap { $0 }
        let maximum = Data([0, 0] + threeLabels + [61] + Array(repeating: UInt8(65), count: 61) + [0])
        XCTAssertEqual(try SMTPMXRecord.decode(maximum).hostname.count, 253)
        XCTAssertThrowsError(try SMTPMXRecord.decode(Data([0, 0] + threeLabels + [62] + Array(repeating: UInt8(65), count: 62) + [0])))
        let tooLong = [UInt8](repeating: 0, count: 2) + Array(repeating: [UInt8(63)] + Array(repeating: UInt8(65), count: 63), count: 5).flatMap { $0 } + [0]
        XCTAssertThrowsError(try SMTPMXRecord.decode(Data(tooLong)))
    }
    func testInvalidDomainsAndTimeoutsDoNotQueryDNS() async throws {
        for name in ["", "a..invalid", "a.invalid.", "https://example.invalid", "a\0.invalid", "a\n.invalid", "雪.invalid", String(repeating: "a", count: 64) + ".invalid"] {
            do { _ = try await SMTPMXResolver.lookup(domain: name); XCTFail(name) }
            catch SMTPMXFailure.domain { }
        }
        for timeout in [0, -1, Int(Int32.max) + 1] {
            do { _ = try await SMTPMXResolver.lookup(domain: "example.invalid", timeoutMilliseconds: timeout); XCTFail("Timeout") }
            catch SMTPMXFailure.domain { }
        }
    }
    func testPreCancelledLookupDoesNotOpenService() async throws {
        let token = OperationCancellation(); token.cancel()
        do { _ = try await SMTPMXResolver.lookup(domain: "example.invalid", cancellation: token); XCTFail("Cancelled") }
        catch is OperationCancellationFailure { }
    }
    func testSystemMXLookupWhenRequested() async throws {
        guard ProcessInfo.processInfo.environment["TURTLEGIT_MX_DNS_PROBE"] == "1" else { throw XCTSkip("Read-only system DNS probe requires explicit opt-in.") }
        let records = try await SMTPMXResolver.lookup(domain: "gmail.com", timeoutMilliseconds: 10_000)
        XCTAssertFalse(records.isEmpty)
        XCTAssertTrue(records.allSatisfy { !$0.hostname.isEmpty && $0.hostname.utf8.count <= 253 })
        func descriptors() -> Int { (0..<1024).filter { fcntl(Int32($0), F_GETFD) >= 0 }.count }
        let before = descriptors()
        for _ in 0..<32 {
            var calls: Int32 = 0, count = 0
            var buffer = Array(repeating: TGSMTPMXRecord(), count: 128)
            let code = withUnsafeMutablePointer(to: &calls) { context in buffer.withUnsafeMutableBufferPointer {
                tg_smtp_lookup_mx("gmail.com", 1000, cancelOpenedMX, context, $0.baseAddress, $0.count, &count)
            } }
            XCTAssertEqual(code, -70003); XCTAssertGreaterThanOrEqual(calls, 2); XCTAssertEqual(count, 0)
        }
        XCTAssertEqual(descriptors(), before, "Each cancelled owned DNS service must release its descriptor")
        print("32 post-open MX cancellations released their DNS service descriptors.")
        print("Read-only system MX response: " + records.map { "\($0.preference) \($0.hostname)" }.joined(separator: "; "))
    }
}
