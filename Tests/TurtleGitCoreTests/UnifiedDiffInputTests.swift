import XCTest
import Darwin
@testable import TurtleGitCore

final class UnifiedDiffInputTests: XCTestCase {
    func testExplicitEmptyAndTitlesDoNotConsumeOtherApplicationGrammars() throws {
        XCTAssertNil(try UnifiedDiffInvocation.parse(arguments: ["file.patch"], currentDirectory: "/tmp"))
        XCTAssertNil(try UnifiedDiffInvocation.parse(arguments: ["/diff:a", "/base:b"], currentDirectory: "/tmp"))
        XCTAssertNil(try UnifiedDiffInvocation.parse(arguments: ["/command:diff", "/title:other"], currentDirectory: "/tmp"))
        XCTAssertNil(try UnifiedDiffInvocation.parse(arguments: ["--command", "log", "--unified-diff"], currentDirectory: "/tmp"))
        XCTAssertNil(try UnifiedDiffInvocation.parse(arguments: ["--COMMAND=diff", "--unified-diff"], currentDirectory: "/tmp"))
        XCTAssertFalse(UnifiedDiffInvocation.recognizes(arguments: ["--", "/p"]))
        XCTAssertFalse(UnifiedDiffInvocation.recognizes(arguments: ["--title", "/p"]))
        XCTAssertTrue(UnifiedDiffInvocation.recognizes(arguments: ["--unified-diff=oops"]))
        XCTAssertThrowsError(try UnifiedDiffInvocation.parse(arguments: ["--unified-diff=oops"], currentDirectory: "/tmp"))
        XCTAssertThrowsError(try UnifiedDiffInvocation.parse(arguments: ["--unified-diff"], currentDirectory: "relative"))
        let empty = try XCTUnwrap(UnifiedDiffInvocation.parse(arguments: ["--unified-diff"], currentDirectory: "/tmp"))
        XCTAssertEqual(empty.input, .empty); XCTAssertNil(empty.title)
        let titled = try XCTUnwrap(UnifiedDiffInvocation.parse(arguments: ["/title:Δ title"], currentDirectory: "/tmp"))
        XCTAssertEqual(titled.input, .empty); XCTAssertEqual(titled.title, "Δ title")
    }
    func testNativeAndSourceFileFormsPreserveLiteralUTF8() throws {
        let names = ["Café.anything", "Cafe\u{301}.anything", "雪 [*]?\tfile", " leading and trailing "]
        for name in names {
            for args in [["--unified-diff", name], ["--unified-diff", "--patchfile", name], ["--unified-diff", "--patchfile=" + name], ["/patchfile:" + name]] {
                guard case .file(let url) = try XCTUnwrap(UnifiedDiffInvocation.parse(arguments: args, currentDirectory: "/tmp")).input else { return XCTFail("Missing file") }
                XCTAssertEqual(Data(url.lastPathComponent.utf8), Data(name.utf8))
                XCTAssertEqual(url.deletingLastPathComponent().path, "/tmp")
            }
        }
        let directory = "/tmp/Caf\u{00e9}"
        let raw = "./nested/../Caf\u{00e9}.patch"
        guard case .file(let lexical) = try XCTUnwrap(UnifiedDiffInvocation.parse(arguments:["--unified-diff",raw],currentDirectory:directory)).input else {return XCTFail("Missing lexical file")}
        XCTAssertEqual(Data(lexical.path.utf8),Data((directory + "/Caf\u{00e9}.patch").utf8))
    }
    func testPositionalEscapeAndCapturedTitle() throws {
        let value = try XCTUnwrap(UnifiedDiffInvocation.parse(arguments: ["--unified-diff", "--title", " custom\n雪 ", "--", "--stdin"], currentDirectory: "/tmp"))
        XCTAssertEqual(value.title, " custom\n雪 ")
        XCTAssertEqual(value.input, .file(URL(fileURLWithPath: "/tmp/--stdin")))
        let escapedCommand = try XCTUnwrap(UnifiedDiffInvocation.parse(arguments: ["--unified-diff", "--", "/command:diff"], currentDirectory: "/tmp"))
        XCTAssertEqual(escapedCommand.input, .file(URL(fileURLWithPath: "/command:diff")))
        let absolute = try XCTUnwrap(UnifiedDiffInvocation.parse(arguments: ["--unified-diff", "--", "/x"], currentDirectory: "/tmp"))
        XCTAssertEqual(absolute.input, .file(URL(fileURLWithPath: "/x")))
    }
    func testExplicitInputConflictsUnknownOptionsAndNULRefused() throws {
        for args in [["--unified-diff", "--stdin", "file"], ["/p", "/patchfile:file"], ["--unified-diff", "a", "b"], ["--unified-diff", "--title:a"], ["--unified-diff", "--patchfile"], ["--unified-diff", "--patchfile="], ["--unified-diff", "--unified-diff"], ["/title:a", "--title=b"], ["/p", "/p"], ["--unified-diff", "a\0b"], ["/title:\0"]] {
            XCTAssertThrowsError(try UnifiedDiffInvocation.parse(arguments: args, currentDirectory: "/tmp"), "\(args)") { XCTAssertTrue($0 is UnifiedDiffInvocationFailure) }
        }
    }
    func testExplicitStandardInputVariantsAndEmptyTitle() throws {
        for args in [["--unified-diff", "--stdin"], ["/p"], ["/P", "/title:pipe"]] {
            XCTAssertEqual(try UnifiedDiffInvocation.parse(arguments: args, currentDirectory: "/tmp")?.input, .standardInput)
        }
        XCTAssertEqual(try UnifiedDiffInvocation.parse(arguments: ["--unified-diff", "--title="], currentDirectory: "/tmp")?.title, "")
    }
    private func pipePair() throws -> (Int32, Int32) {
        var fds: [Int32] = [-1,-1]
        guard pipe(&fds) == 0 else { throw POSIXError(.EMFILE) }
        return (fds[0],fds[1])
    }
    private func writeAll(_ data: Data, descriptor: Int32) throws {
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let amount = Darwin.write(descriptor, bytes.baseAddress!.advanced(by:offset), bytes.count-offset)
                if amount < 0 { if errno == EINTR { continue }; throw POSIXError(POSIXErrorCode(rawValue:errno) ?? .EIO) }
                guard amount > 0 else { throw POSIXError(.EIO) }; offset += amount
            }
        }
    }
    func testRealPipeRawBytesEOFAndCallerDescriptorFlagsPreserved() async throws {
        let (input,output) = try pipePair(); defer {close(input)}
        let flags = fcntl(input,F_GETFL), descriptorFlags = fcntl(input,F_GETFD)
        let bytes = Data((0..<150_000).map { UInt8($0 % 256) })
        let reader = Task.detached { try UnifiedDiffInputReader.read(descriptor:input) }
        do { try writeAll(bytes,descriptor:output); close(output) } catch { close(output); throw error }
        let received = try await reader.value
        XCTAssertEqual(received, bytes)
        XCTAssertEqual(fcntl(input,F_GETFL),flags); XCTAssertEqual(fcntl(input,F_GETFD),descriptorFlags)
        var byte: UInt8 = 0
        XCTAssertEqual(Darwin.read(input,&byte,1),0,"Caller descriptor was closed")
    }
    func testRedirectedRegularFileReadsFromCapturedStreamOffset() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("udiff-input-" + UUID().uuidString)
        let bytes = Data([0, 0xff, 0xfe, 10, 13, 0x80])
        try bytes.write(to:url); defer {try? FileManager.default.removeItem(at:url)}
        let input = open(url.path,O_RDONLY); defer {if input>=0 {close(input)}}
        XCTAssertGreaterThanOrEqual(input,0)
        XCTAssertEqual(lseek(input,2,SEEK_SET),2)
        XCTAssertEqual(try UnifiedDiffInputReader.read(descriptor:input),Data(bytes.dropFirst(2)))
        XCTAssertGreaterThanOrEqual(fcntl(input,F_GETFD),0)
        XCTAssertEqual(try Data(contentsOf:url),bytes)
    }
    func testEmptyPipeEOFIsAnExplicitEmptyDocument() throws {
        let (input,output) = try pipePair();defer{close(input)};close(output)
        XCTAssertEqual(try UnifiedDiffInputReader.read(descriptor:input,maxBytes:0),Data())
    }
    func testExactLimitAcceptedAndOneExtraByteRefused() throws {
        for count in [8,9] {
            let (input,output) = try pipePair();defer{close(input)}
            try writeAll(Data(repeating:0xff,count:count),descriptor:output);close(output)
            if count == 8 {XCTAssertEqual(try UnifiedDiffInputReader.read(descriptor:input,maxBytes:8),Data(repeating:0xff,count:8))}
            else {XCTAssertThrowsError(try UnifiedDiffInputReader.read(descriptor:input,maxBytes:8)) {error in
                guard case UnifiedDiffInputFailure.limit(8) = error else {return XCTFail("Wrong limit failure: \(error)")}
            }}
            XCTAssertGreaterThanOrEqual(fcntl(input,F_GETFD),0)
        }
    }
    func testIdlePipeCancellationReleasesWorkerWithoutClosingCaller() async throws {
        let (input,output) = try pipePair();defer{close(input);close(output)}
        let token = OperationCancellation()
        let reader = Task.detached { try UnifiedDiffInputReader.read(descriptor:input,cancellation:token) }
        try await Task.sleep(nanoseconds:50_000_000);token.cancel()
        do {_ = try await reader.value;XCTFail("Idle pipe ignored cancellation")} catch {XCTAssertTrue(error is OperationCancellationFailure)}
        XCTAssertGreaterThanOrEqual(fcntl(input,F_GETFD),0)
        try writeAll(Data([0xfe]),descriptor:output)
        var byte: UInt8 = 0;XCTAssertEqual(Darwin.read(input,&byte,1),1);XCTAssertEqual(byte,0xfe)
    }
    func testCancellationAfterPartialPipeInputDoesNotPublishPartialDocument() async throws {
        let (input,output) = try pipePair();defer{close(input);close(output)}
        let token = OperationCancellation()
        let reader = Task.detached { try UnifiedDiffInputReader.read(descriptor:input,cancellation:token) }
        try writeAll(Data("partial".utf8),descriptor:output)
        try await Task.sleep(nanoseconds:50_000_000);token.cancel()
        do {_ = try await reader.value;XCTFail("Published incomplete input")} catch {XCTAssertTrue(error is OperationCancellationFailure)}
    }
    func testInvalidDescriptorAndReadErrorAreDistinctFromEmptyEOF() throws {
        XCTAssertThrowsError(try UnifiedDiffInputReader.read(descriptor:-1)) {error in
            guard case UnifiedDiffInputFailure.descriptor(EBADF) = error else {return XCTFail("Wrong descriptor error: \(error)")}
        }
        let directory = open(NSTemporaryDirectory(),O_RDONLY);defer{if directory>=0{close(directory)}}
        XCTAssertGreaterThanOrEqual(directory,0)
        XCTAssertThrowsError(try UnifiedDiffInputReader.read(descriptor:directory)) {error in
            guard case UnifiedDiffInputFailure.read = error else {return XCTFail("Wrong read error: \(error)")}
        }
    }
    func testPreCancelledAndInvalidBudgetDoNotConsumeCallerBytes() throws {
        let (input,output) = try pipePair();defer{close(input);close(output)}
        try writeAll(Data([23]),descriptor:output)
        let token = OperationCancellation();token.cancel()
        XCTAssertThrowsError(try UnifiedDiffInputReader.read(descriptor:input,cancellation:token)) {XCTAssertTrue($0 is OperationCancellationFailure)}
        for maximum in [-1,UnifiedDiffInputReader.maximumBytes+1] {
            XCTAssertThrowsError(try UnifiedDiffInputReader.read(descriptor:input,maxBytes:maximum)) {error in
                guard case UnifiedDiffInputFailure.input = error else {return XCTFail("Wrong budget error")}
            }
        }
        var byte: UInt8 = 0;XCTAssertEqual(Darwin.read(input,&byte,1),1);XCTAssertEqual(byte,23)
    }
    private func privateDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("udiff-file-" + UUID().uuidString,isDirectory:true)
        try FileManager.default.createDirectory(at:url,withIntermediateDirectories:false)
        return url
    }
    func testFileAdmissionLiteralArbitraryExtensionAndSymlinkPreserveSource() throws {
        let root = try privateDirectory();defer{try? FileManager.default.removeItem(at:root)}
        let bytes = Data([0,0xff,0xfe,10,13,128])
        let file = root.appendingPathComponent("Cafe\u{301} 雪.anything"),link = root.appendingPathComponent("link")
        try bytes.write(to:file)
        try FileManager.default.createSymbolicLink(at:link,withDestinationURL:file)
        for url in [file,link] {XCTAssertEqual(try UnifiedDiffInputReader.readFile(url),bytes)}
        XCTAssertEqual(try Data(contentsOf:file),bytes)
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath:link.path),file.path)
    }
    func testFileAdmissionRefusesUnconnectedFIFOAndDirectoryWithoutWaiting() throws {
        let root = try privateDirectory();defer{try? FileManager.default.removeItem(at:root)}
        let fifo = root.appendingPathComponent("unconnected 雪.pipe")
        XCTAssertEqual(mkfifo(fifo.path,mode_t(0o600)),0)
        let start = Date()
        for url in [fifo,root] {
            XCTAssertThrowsError(try UnifiedDiffInputReader.readFile(url)) { error in
                guard case UnifiedDiffInputFailure.unsupportedFile = error else{return XCTFail("Wrong admission failure: \(error)")}
            }
        }
        XCTAssertLessThan(Date().timeIntervalSince(start),2,"Special-file admission waited for a producer")
        var metadata = stat();XCTAssertEqual(lstat(fifo.path,&metadata),0)
        XCTAssertEqual(metadata.st_mode & mode_t(S_IFMT),mode_t(S_IFIFO))
    }
    func testFileAdmissionEmptyExactLimitAndOverLimit() throws {
        let root = try privateDirectory();defer{try? FileManager.default.removeItem(at:root)}
        let file = root.appendingPathComponent("input")
        try Data().write(to:file)
        XCTAssertEqual(try UnifiedDiffInputReader.readFile(file,maxBytes:0),Data())
        try Data([1,2,3]).write(to:file)
        XCTAssertEqual(try UnifiedDiffInputReader.readFile(file,maxBytes:3),Data([1,2,3]))
        XCTAssertThrowsError(try UnifiedDiffInputReader.readFile(file,maxBytes:2)) {error in
            guard case UnifiedDiffInputFailure.limit(2) = error else{return XCTFail("Wrong file limit error: \(error)")}
        }
        XCTAssertEqual(try Data(contentsOf:file),Data([1,2,3]))
    }
    func testFileAdmissionPreCancelledAndUnavailableInputsRemainDistinct() throws {
        let root = try privateDirectory();defer{try? FileManager.default.removeItem(at:root)}
        let missing = root.appendingPathComponent("missing")
        let token = OperationCancellation();token.cancel()
        XCTAssertThrowsError(try UnifiedDiffInputReader.readFile(missing,cancellation:token)) {XCTAssertTrue($0 is OperationCancellationFailure)}
        XCTAssertThrowsError(try UnifiedDiffInputReader.readFile(missing)) {error in
            guard case UnifiedDiffInputFailure.descriptor(ENOENT) = error else{return XCTFail("Wrong file open failure: \(error)")}
        }
        XCTAssertThrowsError(try UnifiedDiffInputReader.readFile(URL(string:"https://example.invalid/input")!)) {error in
            guard case UnifiedDiffInputFailure.input = error else{return XCTFail("Admitted remote URL")}
        }
    }

}
