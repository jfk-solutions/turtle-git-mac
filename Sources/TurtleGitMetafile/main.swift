// Copyright (C) TurtleGit contributors. Licensed under GPL-2.0-or-later.
import Foundation
import JavaScriptCore
import CoreText
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

private let inputLimit = 64 * 1024 * 1024
private let outputLimit = 128 * 1024 * 1024
private enum ConversionError: Error { case invalid(String) }
private func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8)); exit(1)
}
private func data(_ value: JSValue) -> Data? {
    let context = value.context.jsGlobalContextRef
    let kind = JSValueGetTypedArrayType(context, value.jsValueRef, nil)
    if kind == kJSTypedArrayTypeUint8Array || kind == kJSTypedArrayTypeUint8ClampedArray,
       let object = JSValueToObject(context, value.jsValueRef, nil) {
        let count = JSObjectGetTypedArrayByteLength(context, object, nil)
        guard count <= inputLimit else { return nil }
        if count == 0 { return Data() }
        let offset = JSObjectGetTypedArrayByteOffset(context, object, nil)
        guard let buffer = JSObjectGetTypedArrayBuffer(context, object, nil),
              let pointer = JSObjectGetArrayBufferBytesPtr(context, buffer, nil) else { return nil }
        return Data(bytes: pointer.advanced(by: offset), count: count)
    }
    guard let length = value.forProperty("length"), !length.isUndefined else { return nil }
    let count = length.toDouble()
    guard count.isFinite, count >= 0, count <= Double(inputLimit), count.rounded() == count else { return nil }
    var result = Data(count: Int(count))
    for index in 0..<Int(count) { result[index] = UInt8(truncatingIfNeeded: value.atIndex(index).toUInt32()) }
    return result
}
private func rendererURL() -> URL? {
    let executable = URL(fileURLWithPath: CommandLine.arguments[0])
    let candidates = [executable.deletingLastPathComponent().appendingPathComponent("renderer.js"),
        executable.resolvingSymlinksInPath().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Resources/TurtleGitRuntimes/Metafile/renderer.js")]
    return candidates.first { FileManager.default.fileExists(atPath: $0.path) }
}
private final class SVGGuard: NSObject, XMLParserDelegate {
    var valid = true
    private let elements: Set<String> = ["svg", "g", "defs", "path", "rect", "circle", "ellipse", "line", "polyline", "polygon", "text", "tspan", "clipPath", "image", "pattern", "linearGradient", "radialGradient", "stop", "mask", "title", "desc"]
    func parser(_ parser: XMLParser, didStartElement element: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String]) {
        if !elements.contains(element) || namespaceURI != "http://www.w3.org/2000/svg" { valid = false }
        for (name, value) in attributes {
            let key = name.lowercased(), lowered = value.lowercased()
            if key.hasPrefix("on") || lowered.contains("@import") { valid = false }
            if key == "href" || key.hasSuffix(":href") {
                if !value.hasPrefix("#") && !value.hasPrefix("data:image/png;base64,") { valid = false }
            }
            if lowered.contains("url(") {
                let pattern = #"url\(\s*["']?#[a-zA-Z0-9_.:-]+["']?\s*\)"#
                let remainder = lowered.replacingOccurrences(of: pattern, with: "", options: .regularExpression)
                if remainder.contains("url(") { valid = false }
            }
        }
        if !valid { parser.abortParsing() }
    }
    func parser(_ parser: XMLParser, foundInternalEntityDeclarationWithName: String, value: String?) { valid = false; parser.abortParsing() }
    func parser(_ parser: XMLParser, foundExternalEntityDeclarationWithName: String, publicID: String?, systemID: String?) { valid = false; parser.abortParsing() }
}
private func run() throws {
    // System JavaScriptCore supports interpreter-only execution. Set this before
    // creating any context/VM so hardened helpers need no executable-memory/JIT
    // entitlement, including when invoked with inherited App Store sandboxing.
    setenv("JSC_useJIT", "false", 1)
    guard CommandLine.arguments.count == 2, ["--wmf", "--emf"].contains(CommandLine.arguments[1]) else {
        throw ConversionError.invalid("Usage: metafile-convert --wmf|--emf (binary stdin, SVG stdout)")
    }
    var input = Data()
    while let chunk = try FileHandle.standardInput.read(upToCount: 65536), !chunk.isEmpty {
        guard chunk.count <= inputLimit - input.count else { throw ConversionError.invalid("Metafile exceeds 64 MiB") }
        input.append(chunk)
    }
    guard !input.isEmpty, let context = JSContext(), let sourceURL = rendererURL() else {
        throw ConversionError.invalid("Missing metafile input or packaged renderer")
    }
    var exception: String?
    context.exceptionHandler = { _, value in exception = value?.toString() ?? "JavaScript rendering failed" }
    func nativeError(_ text: String) { context.exception = JSValue(newErrorFromMessage: text, in: context) }
    let decode: @convention(block) (JSValue, String) -> String = { value, encoding in
        guard let bytes = data(value) else { nativeError("Invalid text bytes"); return "" }
        let names: [String: CFStringEncoding] = ["shift_jis": CFStringEncoding(CFStringEncodings.shiftJIS.rawValue),
            "euc-kr": CFStringEncoding(CFStringEncodings.EUC_KR.rawValue), "gbk": CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue),
            "big5": CFStringEncoding(CFStringEncodings.big5.rawValue)]
        let label = encoding.lowercased()
        let swiftEncoding: String.Encoding
        if label == "utf-8" || label == "utf8" { swiftEncoding = .utf8 }
        else if label == "utf-16le" { swiftEncoding = .utf16LittleEndian }
        else if label == "windows-1252" { swiftEncoding = .windowsCP1252 }
        else if let code = names[label] { swiftEncoding = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(code)) }
        else { nativeError("Unsupported text encoding: " + encoding); return "" }
        guard let text = String(data: bytes, encoding: swiftEncoding) else { nativeError("Invalid encoded text"); return "" }
        return text
    }
    let base64: @convention(block) (JSValue) -> String = { value in
        guard let bytes = data(value) else { nativeError("Invalid base64 bytes"); return "" }; return bytes.base64EncodedString()
    }
    let measure: @convention(block) (String, String, Double, Bool, Bool) -> Double = { text, face, size, bold, italic in
        guard size.isFinite, size > 0, size <= 65536, text.utf8.count <= inputLimit else { nativeError("Invalid font metrics"); return 0 }
        var font = CTFontCreateWithName(face as CFString, size, nil)
        var traits: CTFontSymbolicTraits = []
        if bold { traits.insert(.boldTrait) }; if italic { traits.insert(.italicTrait) }
        if !traits.isEmpty, let adjusted = CTFontCreateCopyWithSymbolicTraits(font, size, nil, traits, traits) { font = adjusted }
        let attributed = NSAttributedString(string: text, attributes: [NSAttributedString.Key(kCTFontAttributeName as String): font])
        return CTLineGetTypographicBounds(CTLineCreateWithAttributedString(attributed), nil, nil, nil)
    }
    let bitmap: @convention(block) (JSValue, Int, Int, Int, UInt32) -> String = { value, width, height, stride, format in
        guard width > 0, height > 0, width <= 32768, height <= 32768, width <= 16777216 / height,
              stride != Int.min, abs(stride) >= width * 3, abs(stride) <= inputLimit / height,
              let raw = data(value), raw.count >= abs(stride) * height else { nativeError("Invalid or oversized metafile bitmap"); return "" }
        // GDI+ PixelFormat values encode bits-per-pixel in bits 8...15.
        let bits = Int((format >> 8) & 255)
        guard [UInt32(0x21808), 0x22009, 0x26200A, 0xE200B].contains(format), abs(stride) >= width * (bits / 8) else { nativeError("Unsupported metafile pixel format"); return "" }
        var rgba = Data(count: width * height * 4)
        for y in 0..<height {
            let row = (stride < 0 ? height - 1 - y : y) * abs(stride)
            for x in 0..<width {
                let start = row + x * (bits / 8), end = (y * width + x) * 4
                rgba[end] = raw[start + 2]; rgba[end + 1] = raw[start + 1]; rgba[end + 2] = raw[start]
                rgba[end + 3] = bits == 32 && (format & 0x40000) != 0 ? raw[start + 3] : 255
            }
        }
        let alpha: CGImageAlphaInfo = format & 0x80000 != 0 ? .premultipliedLast : .last
        guard let provider = CGDataProvider(data: rgba as CFData), let image = CGImage(width: width, height: height,
            bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: alpha.rawValue), provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent) else { nativeError("Cannot decode metafile bitmap"); return "" }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, UTType.png.identifier as CFString, 1, nil) else { nativeError("Cannot encode metafile bitmap"); return "" }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination), output.length <= outputLimit / 2 else { nativeError("Metafile bitmap output exceeds limit"); return "" }
        return "data:image/png;base64," + (output as Data).base64EncodedString()
    }
    let compressed: @convention(block) (JSValue) -> NSDictionary = { value in
        guard let raw = data(value), raw.count >= 8,
              raw.starts(with: [137, 80, 78, 71, 13, 10, 26, 10]) || raw.starts(with: [255, 216, 255]),
              let source = CGImageSourceCreateWithData(raw as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              CGImageSourceGetCount(source) == 1,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0, width <= 32768, height <= 32768, width <= 16777216 / height,
              let image = CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary) else {
            nativeError("Invalid or oversized compressed metafile image"); return [:]
        }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, UTType.png.identifier as CFString, 1, nil) else {
            nativeError("Cannot encode compressed metafile image"); return [:]
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination), output.length <= outputLimit / 2 else {
            nativeError("Compressed metafile image output exceeds limit"); return [:]
        }
        return ["href": "data:image/png;base64," + (output as Data).base64EncodedString(), "width": width, "height": height]
    }
    context.setObject(compressed, forKeyedSubscript: "__turtleCompressedImage" as NSString)
    context.setObject(decode, forKeyedSubscript: "__turtleDecode" as NSString)
    context.setObject(base64, forKeyedSubscript: "__turtleBase64" as NSString)
    context.setObject(measure, forKeyedSubscript: "__turtleMeasureText" as NSString)
    context.setObject(bitmap, forKeyedSubscript: "__turtleBitmap" as NSString)
    context.evaluateScript("""
    globalThis.console = {log(){}, warn(){}, error(){}, debug(){}};
    globalThis.TextDecoder = class { constructor(label='utf-8'){this.label=label;} decode(bytes){return __turtleDecode(bytes || new Uint8Array(0),this.label);} };
    globalThis.btoa = function(text){let bytes=new Uint8Array(text.length);for(let i=0;i<text.length;i++){let n=text.charCodeAt(i);if(n>255)throw Error('Invalid binary string');bytes[i]=n;}return __turtleBase64(bytes);};
    globalThis.Buffer = {from(bytes){return {toString(encoding){if(encoding !== 'base64')throw Error('Unsupported Buffer encoding');return __turtleBase64(bytes);}};}};
    """)
    context.evaluateScript(try String(contentsOf: sourceURL, encoding: .utf8), withSourceURL: sourceURL)
    guard exception == nil else { throw ConversionError.invalid(exception!) }
    // JavaScriptCore owns the typed buffer, including throughout native callbacks.
    guard let typed = JSObjectMakeTypedArray(context.jsGlobalContextRef, kJSTypedArrayTypeUint8Array, input.count, nil),
          let storage = JSObjectGetTypedArrayBytesPtr(context.jsGlobalContextRef, typed, nil) else {
        throw ConversionError.invalid("Cannot allocate metafile input")
    }
    input.copyBytes(to: storage.assumingMemoryBound(to: UInt8.self), count: input.count)
    let value = JSValue(jsValueRef: typed, in: context)!
    let result = context.objectForKeyedSubscript("__turtleRender")?.call(withArguments: [value, String(CommandLine.arguments[1].dropFirst(2))])
    guard exception == nil, let svg = result?.toString(), svg.contains("<svg"), svg.utf8.count <= outputLimit,
          svg.range(of: "<!DOCTYPE", options: .caseInsensitive) == nil,
          svg.range(of: "<!ENTITY", options: .caseInsensitive) == nil else {
        throw ConversionError.invalid(exception ?? "Invalid or oversized SVG output")
    }
    let output = Data(svg.utf8), safety = SVGGuard()
    let parser = XMLParser(data: output)
    parser.shouldProcessNamespaces = true
    parser.shouldResolveExternalEntities = false
    parser.delegate = safety
    guard parser.parse(), safety.valid else { throw ConversionError.invalid("Renderer produced invalid SVG or external resources") }
    try FileHandle.standardOutput.write(contentsOf: output)
}
do { try run() } catch ConversionError.invalid(let text) { fail(text) } catch { fail(String(describing: error)) }
