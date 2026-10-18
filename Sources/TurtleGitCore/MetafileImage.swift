// SPDX-License-Identifier: GPL-2.0-or-later
import Foundation
import Darwin

public enum MetafileImageFormat: String, Sendable {
    case wmf, emf
    public static func identify(_ bytes: Data) -> Self? {
        let prefix = Array(bytes.prefix(44))
        if prefix.count >= 44, prefix[0..<4].elementsEqual([1, 0, 0, 0]),
           prefix[40..<44].elementsEqual([0x20, 0x45, 0x4d, 0x46]) { return .emf }
        if prefix.starts(with: [0xd7, 0xcd, 0xc6, 0x9a]) { return .wmf }
        if prefix.count >= 18, [1, 2].contains(prefix[0]), prefix[1] == 0,
           prefix[2] == 9, prefix[3] == 0, prefix[4] == 0,
           [1, 3].contains(prefix[5]) { return .wmf }
        return nil
    }

    static func resolution(_ bytes: Data) -> (Double, Double)? {
        guard let format = identify(bytes) else { return nil }
        if format == .wmf {
            let header = Array(bytes.prefix(16))
            if header.count == 16, header.starts(with: [0xd7, 0xcd, 0xc6, 0x9a]) {
                let inch = Double(UInt16(header[14]) | UInt16(header[15]) << 8)
                return inch > 0 ? (inch, inch) : nil
            }
            return (96, 96)
        }
        let header = Array(bytes.prefix(88))
        guard header.count >= 88 else { return nil }
        func signed(_ offset: Int) -> Double {
            let value = (0..<4).reduce(UInt32(0)) { $0 | UInt32(header[offset + $1]) << ($1 * 8) }
            return Double(Int32(bitPattern: value))
        }
        func dpi(_ size: Double, _ physical: Double, unit: Double) -> Double? {
            let value = size * unit / physical
            return size > 0 && physical > 0 && value.isFinite && value > 0 ? value : nil
        }
        let x = dpi(signed(72), signed(80), unit: 25.4)
            ?? dpi(signed(16) - signed(8), signed(32) - signed(24), unit: 2540)
        let y = dpi(signed(76), signed(84), unit: 25.4)
            ?? dpi(signed(20) - signed(12), signed(36) - signed(28), unit: 2540)
        guard let x, let y else { return nil }
        return (x, y)
    }
}

public enum MetafileImageFailure: LocalizedError {
    case runtimeMissing, inputTooLarge, timedOut, outputTooLarge, invalidOutput, failed(String)
    public var errorDescription: String? {
        switch self {
        case .runtimeMissing: return "The bundled Windows metafile renderer is missing."
        case .inputTooLarge: return "The Windows metafile exceeds the decoder input limit."
        case .timedOut: return "The Windows metafile renderer did not finish in time."
        case .outputTooLarge: return "The Windows metafile exceeds the rendered image limit."
        case .invalidOutput: return "The Windows metafile renderer returned an invalid image."
        case .failed(let details): return details.isEmpty ? "Could not render the Windows metafile." : details
        }
    }
}

/// Runs the bundled decoder off the UI thread. The helper has no file paths from
/// the document: it receives captured bytes on stdin and returns inline SVG.
/// Each request owns its process group, private streams and cancellation lifetime.
public enum MetafileImageDecoder {
    public static let maximumInputBytes = 64 * 1024 * 1024
    public static let maximumOutputBytes = 128 * 1024 * 1024

    public static func executable(bundle: Bundle = .main) throws -> URL {
        let packaged = bundle.bundleURL.appendingPathComponent("Contents/Helpers/Metafile/metafile-convert")
        if FileManager.default.isExecutableFile(atPath: packaged.path) { return packaged }
        #if DEBUG
        if !GitRuntime.isAppStoreBuild {
            let sourceRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            let development = sourceRoot.appendingPathComponent("build/metafile-runtime/Metafile/metafile-convert")
            if FileManager.default.isExecutableFile(atPath: development.path) { return development }
        }
        #endif
        throw MetafileImageFailure.runtimeMissing
    }

    /// nil means an ordinary image, which should continue through ImageIO.
    public static func convert(_ bytes: Data, executable: URL? = nil,
                               cancellation: OperationCancellation? = nil,
                               timeout: TimeInterval = 15) throws -> Data? {
        try Task.checkCancellation(); try cancellation?.check()
        guard let format = MetafileImageFormat.identify(bytes) else { return nil }
        guard bytes.count <= maximumInputBytes else { throw MetafileImageFailure.inputTooLarge }
        guard timeout.isFinite, timeout > 0, timeout <= 120 else { throw MetafileImageFailure.timedOut }
        let helper = try executable ?? Self.executable()
        guard FileManager.default.isExecutableFile(atPath: helper.path) else { throw MetafileImageFailure.runtimeMissing }
        let directory = try TurtleGitTemporaryStorage.root.appendingPathComponent("TurtleGitMetafile-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) }
        let inputURL = directory.appendingPathComponent("input")
        let outputURL = directory.appendingPathComponent("output")
        let errorURL = directory.appendingPathComponent("error")
        for (file, data) in [(inputURL, bytes), (outputURL, Data()), (errorURL, Data())] {
            try data.write(to: file)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        }
        let input = try FileHandle(forReadingFrom: inputURL)
        defer { try? input.close() }
        let output = try FileHandle(forWritingTo: outputURL)
        defer { try? output.close() }
        let errors = try FileHandle(forWritingTo: errorURL)
        defer { try? errors.close() }
        let token = OperationCancellation(), started = DispatchTime.now().uptimeNanoseconds
        var timedOut = false, oversized = false
        func length(_ handle: FileHandle) -> Int64 {
            var state = stat()
            return fstat(handle.fileDescriptor, &state) == 0 ? state.st_size : 0
        }
        let status = try CancellableGitProcess.run(executable: helper, arguments: ["--" + format.rawValue],
            environment: ["PATH": "/usr/bin:/bin", "HOME": NSHomeDirectory(), "TMPDIR": directory.path, "LANG": "en_US.UTF-8", "JSC_useJIT": "false"],
            output: output.fileDescriptor, error: errors.fileDescriptor, input: input.fileDescriptor,
            cancellation: token, pollOutput: {
                if cancellation?.isCancelled == true || Task.isCancelled { token.cancel() }
                if Double(DispatchTime.now().uptimeNanoseconds - started) / 1_000_000_000 > timeout {
                    timedOut = true; token.cancel()
                }
                if length(output) > Int64(maximumOutputBytes) || length(errors) > 1_048_576 {
                    oversized = true; token.cancel()
                }
            }, terminateDescendantsOnExit: true)
        try Task.checkCancellation(); try cancellation?.check()
        if timedOut { throw MetafileImageFailure.timedOut }
        if oversized || length(output) > Int64(maximumOutputBytes) { throw MetafileImageFailure.outputTooLarge }
        if status != 0 {
            let diagnostics = try FileHandle(forReadingFrom: errorURL)
            defer { try? diagnostics.close() }
            let text = String(decoding: try diagnostics.read(upToCount: 4096) ?? Data(), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            throw MetafileImageFailure.failed(text)
        }
        let svg = try Data(contentsOf: outputURL)
        try validateSVG(svg)
        try cancellation?.check()
        return svg
    }

    /// Even locally generated SVG must not make the image decoder resolve file
    /// or network references embedded in captured text or metafile image records.
    static func validateSVG(_ bytes: Data) throws {
        guard !bytes.isEmpty, bytes.count <= maximumOutputBytes,
              let text = String(data: bytes, encoding: .utf8),
              !text.uppercased().contains("<!DOCTYPE"), !text.uppercased().contains("<!ENTITY") else {
            throw MetafileImageFailure.invalidOutput
        }
        let delegate = MetafileSVGValidation()
        let parser = XMLParser(data: bytes)
        parser.shouldResolveExternalEntities = false
        parser.delegate = delegate
        guard parser.parse(), delegate.valid, delegate.foundRoot else { throw MetafileImageFailure.invalidOutput }
    }
}

private final class MetafileSVGValidation: NSObject, XMLParserDelegate {
    var valid = true, foundRoot = false
    private var count = 0
    private let elements: Set<String> = ["svg", "g", "defs", "path", "rect", "circle", "ellipse", "line", "polyline", "polygon", "text", "tspan", "image", "clippath", "pattern", "lineargradient", "radialgradient", "stop", "use", "symbol", "title", "desc", "mask"]
    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes: [String: String]) {
        count += 1
        let name = elementName.split(separator: ":").last.map(String.init)?.lowercased() ?? ""
        if count == 1 { foundRoot = name == "svg" }
        if count > 1_000_000 || !elements.contains(name) { valid = false }
        for (key, raw) in attributes {
            let key = key.lowercased(), value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if key.hasPrefix("on") { valid = false }
            if key == "href" || key.hasSuffix(":href") {
                let lower = value.lowercased()
                if !value.hasPrefix("#") && !["data:image/png;base64,", "data:image/jpeg;base64,", "data:image/bmp;base64,", "data:image/gif;base64,", "data:image/webp;base64,"].contains(where: lower.hasPrefix) { valid = false }
            }
            if value.lowercased().contains("url(") {
                let local = value.replacingOccurrences(of: "url\\(\\s*['\"]?#[A-Za-z0-9_.:-]+['\"]?\\s*\\)", with: "", options: .regularExpression)
                if local.lowercased().contains("url(") { valid = false }
            }
        }
        if !valid { parser.abortParsing() }
    }
}
