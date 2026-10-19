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

/// Native formatted-text geometry only. The renderer retains original semantic
/// UTF-16 text separately and applies the EMF+ rectangle/graphics clip and paint.
private final class NativeTextLayout {
    private var shapedGlyphs = 0, pathElements = 0, pathBytes = 0, textUnits = 0
    private let maximumGlyphs = 262_144, maximumElements = 2_000_000
    private struct Line {
        var value: CTLine
        let start: Int, end: Int, paragraphEnd: Int
        var ascent: CGFloat, descent: CGFloat, height: CGFloat, top: CGFloat
    }
    private func invalid(_ message: String) -> ConversionError { .invalid("Formatted metafile text: " + message) }
    private func charge(_ line: CTLine) throws -> CTLine {
        let count = CTLineGetGlyphCount(line)
        guard count <= maximumGlyphs - shapedGlyphs else { throw invalid("aggregate shaped-glyph budget exceeded") }
        shapedGlyphs += count; return line
    }
    private func number(_ options: JSValue, _ key: String, _ fallback: Double = 0) throws -> Double {
        guard let value = options.forProperty(key), !value.isUndefined else { return fallback }
        guard value.isNumber else { throw invalid("non-numeric " + key) }
        let result = value.toDouble()
        guard result.isFinite, abs(result) <= (["flags", "language"].contains(key) ? Double(UInt32.max) : 10_000_000) else { throw invalid("invalid " + key) }; return result
    }
    private func append(_ path: CGPath, to target: CGMutablePath, transform: CGAffineTransform = .identity) throws {
        var count = 0
        path.applyWithBlock { _ in count += 1 }
        guard count <= maximumElements - pathElements else { throw invalid("aggregate outline-element budget exceeded") }
        pathElements += count
        let rect = path.boundingBoxOfPath.applying(transform)
        guard rect.isNull || [rect.minX, rect.minY, rect.maxX, rect.maxY].allSatisfy({ $0.isFinite && abs($0) <= 1_000_000_000 }) else { throw invalid("non-finite glyph outline") }
        target.addPath(path, transform: transform)
    }
    private func svg(_ path: CGPath) throws -> String {
        var result = "", bad = false, bytes = 0
        func coordinate(_ value: CGFloat) -> String {
            guard value.isFinite, abs(value) <= 1_000_000_000 else { bad = true; return "0" }
            return String(format: "%.6f", locale: Locale(identifier: "en_US_POSIX"), Double(value))
        }
        path.applyWithBlock { element in
            guard !bad else { return }
            let e = element.pointee, count: Int, prefix: String
            switch e.type {
            case .moveToPoint: count = 1; prefix = "M"
            case .addLineToPoint: count = 1; prefix = "L"
            case .addQuadCurveToPoint: count = 2; prefix = "Q"
            case .addCurveToPoint: count = 3; prefix = "C"
            case .closeSubpath: count = 0; prefix = "Z"
            @unknown default: bad = true; return
            }
            var command = prefix
            for index in 0..<count { command += coordinate(e.points[index].x) + " " + coordinate(e.points[index].y) + " " }
            bytes += command.utf8.count
            guard bytes <= 32 * 1024 * 1024 - pathBytes else { bad = true; return }
            result += command
        }
        guard !bad else { throw invalid("invalid or oversized outline output") }
        pathBytes += bytes; return result
    }
    func layout(_ original: String, face: String, size: Double, bold: Bool, italic: Bool, options: JSValue) throws -> [String: Any] {
        guard size.isFinite, size > 0, size <= 65_536, face.utf8.count <= 4096,
              original.utf16.count <= 32_768, original.utf16.count <= 262_144 - textUnits,
              !options.isNull, !options.isUndefined, options.isObject else { throw invalid("invalid font, text or options") }
        textUnits += original.utf16.count
        let x = try number(options, "x"), y = try number(options, "y"), width = try number(options, "width"), height = try number(options, "height")
        let rawFlags = try number(options, "flags"), rawAlign = try number(options, "align"), rawLine = try number(options, "line"), rawTrimming = try number(options, "trimming"), rawHotkey = try number(options, "hotkey"), rawStyle = try number(options, "fontStyle"), rawLanguage = try number(options, "language")
        guard width >= 0, height >= 0, rawFlags >= 0, rawFlags <= Double(UInt32.max), rawFlags.rounded() == rawFlags,
              [0.0, 1, 2].contains(rawAlign), [0.0, 1, 2].contains(rawLine), (0...5).contains(Int(rawTrimming)), rawTrimming.rounded() == rawTrimming,
              [0.0, 1, 2].contains(rawHotkey), rawStyle >= 0, rawStyle <= 15, rawStyle.rounded() == rawStyle,
              rawLanguage >= 0, rawLanguage.rounded() == rawLanguage else { throw invalid("invalid rectangle, flags, alignment, language or trimming") }
        let flags = UInt32(rawFlags), alignment = Int(rawAlign), lineAlignment = Int(rawLine), trimming = Int(rawTrimming), style = Int(rawStyle)
        guard flags & ~UInt32(0x80007c07) == 0 else { throw invalid("unsupported StringFormat flags (including DisplayFormatControl)") }
        let vertical = flags & 2 != 0, rtl = flags & 1 != 0, noClip = flags & 0x4000 != 0
        let leading = try number(options, "leading") * size, trailing = try number(options, "trailing") * size, tracking = try number(options, "tracking", 1)
        let firstTab = try number(options, "firstTab")
        guard leading >= 0, trailing >= 0, tracking > 0, tracking <= 1000, firstTab >= 0 else { throw invalid("invalid margins, tracking or tab offset") }
        let inlineExtent = vertical ? height : width, crossExtent = vertical ? width : height
        let pointInline = inlineExtent == 0, pointCross = crossExtent == 0
        let available = pointInline ? 10_000_000 : max(0, inlineExtent - leading - trailing)
        let noWrap = flags & 0x1000 != 0 || pointInline, lineLimit = flags & 0x2000 != 0 && !pointCross
        guard leading + trailing <= 10_000_000 else { throw invalid("oversized margins") }
        if original.isEmpty || available == 0 { return ["path": "", "bounds": [x, y, x, y]] }
        var font = CTFontCreateWithName(face as CFString, size, nil), traits: CTFontSymbolicTraits = []
        if bold { traits.insert(.boldTrait) }; if italic { traits.insert(.italicTrait) }
        if !traits.isEmpty, let adjusted = CTFontCreateCopyWithSymbolicTraits(font, size, nil, traits, traits) { font = adjusted }
        // Hotkey processing changes only visual text, never the JS semantic desc.
        var text = original, hotkeyRange: NSRange?
        if rawHotkey != 0 {
            let clusters = original.map(String.init); var output = "", index = 0
            while index < clusters.count {
                if clusters[index] == "&" {
                    if index + 1 < clusters.count {
                        if clusters[index + 1] == "&" { output += "&"; index += 2; continue }
                        if hotkeyRange == nil { hotkeyRange = NSRange(location: output.utf16.count, length: clusters[index + 1].utf16.count) }
                    }
                    index += 1; continue
                }
                output += clusters[index]; index += 1
            }
            text = output
        }
        if text.isEmpty { return ["path": "", "bounds": [x, y, x, y]] }
        var tabLocations: [CGFloat] = [], tabPosition = firstTab, lastTabInterval: Double?
        if let tabs = options.forProperty("tabs"), !tabs.isUndefined {
            guard tabs.isArray, let count = tabs.forProperty("length")?.toDouble(), count >= 0, count <= 256, count.rounded() == count else { throw invalid("invalid tab array") }
            for index in 0..<Int(count) {
                guard let value = tabs.atIndex(index), value.isNumber else { throw invalid("non-numeric tab interval") }
                let interval = value.toDouble()
                guard interval.isFinite, interval > 0, interval <= 10_000_000, tabPosition + interval <= 10_000_000 else { throw invalid("invalid tab interval") }
                tabPosition += interval; tabLocations.append(CGFloat(tabPosition / tracking)); lastTabInterval = interval
            }
        }
        // Explicit stops are cumulative PageUnit distances, not em multiples.
        // The default interval comes from actual shaped spaces in the font.
        let space = CTLineCreateWithAttributedString(NSAttributedString(string: " ", attributes: [NSAttributedString.Key(kCTFontAttributeName as String): font]))
        var defaultTab = CGFloat(CTLineGetTypographicBounds(space, nil, nil, nil) * 8)
        guard defaultTab.isFinite, defaultTab > 0 else { throw invalid("font has invalid tab metrics") }
        defaultTab /= tracking
        if tabLocations.isEmpty, firstTab > 0 { tabLocations = [CGFloat(firstTab / tracking)] }
        if let interval = lastTabInterval, text.contains("\t") {
            // Core Text's default interval is zero-phased. Expand the repeated
            // final GDI+ interval explicitly so a nonzero initial offset survives
            // second/third tabs beyond the list of recorded stops.
            let withoutTabs = text.replacingOccurrences(of: "\t", with: "").replacingOccurrences(of: "\r", with: "").replacingOccurrences(of: "\n", with: "")
            let probe = try charge(CTLineCreateWithAttributedString(NSAttributedString(string: withoutTabs, attributes: [NSAttributedString.Key(kCTFontAttributeName as String): font])))
            let textAdvance = CTLineGetTypographicBounds(probe, nil, nil, nil) * tracking
            let tabCount = text.utf16.filter { $0 == 9 }.count
            let target = min(10_000_000, max(pointInline ? 0 : available, textAdvance + Double(tabCount + 1) * interval + tabPosition))
            while tabPosition <= target {
                guard tabLocations.count < 8192 else { throw invalid("expanded tab-stop budget exceeded") }
                tabPosition += interval; tabLocations.append(CGFloat(tabPosition / tracking))
            }
            defaultTab = CGFloat(interval / tracking)
        }
        let nativeTabs = tabLocations.map { CTTextTabCreate(.left, Double($0), nil) } as CFArray
        var direction: CTWritingDirection = rtl && !vertical ? .rightToLeft : .leftToRight
        let paragraph = withUnsafePointer(to: &direction) { directionPointer in
            withUnsafePointer(to: &defaultTab) { intervalPointer in
                var tabs = nativeTabs
                return withUnsafePointer(to: &tabs) { tabsPointer in
                    let settings = [CTParagraphStyleSetting(spec: .baseWritingDirection, valueSize: MemoryLayout<CTWritingDirection>.size, value: directionPointer),
                        CTParagraphStyleSetting(spec: .tabStops, valueSize: MemoryLayout<CFArray>.size, value: tabsPointer),
                        CTParagraphStyleSetting(spec: .defaultTabInterval, valueSize: MemoryLayout<CGFloat>.size, value: intervalPointer)]
                    return CTParagraphStyleCreate(settings, settings.count)
                }
            }
        }
        // GDI+ DirectionVertical turns a shaped text line into a column. Core
        // Text's VerticalForms is a different layout mode: its runs already have
        // quarter-turn matrices and vertical cell positions. Combining that mode
        // with the column transform below rotates glyphs/positions twice and
        // replaces proportional Latin advances by vertical font cell advances.
        var attributes: [NSAttributedString.Key: Any] = [NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTParagraphStyleAttributeName as String): paragraph]
        if rawLanguage != 0 {
            guard let locale = NSLocale.localeIdentifier(fromWindowsLocaleCode: UInt32(rawLanguage)), !locale.isEmpty else { throw invalid("unsupported Windows language identifier") }
            attributes[NSAttributedString.Key(kCTLanguageAttributeName as String)] = NSLocale.canonicalLanguageIdentifier(from: locale)
        }
        if style & 4 != 0 { attributes[NSAttributedString.Key(kCTUnderlineStyleAttributeName as String)] = 1 }
        let attributed = NSMutableAttributedString(string: text, attributes: attributes), string = text as NSString
        if rawHotkey == 1, let range = hotkeyRange { attributed.addAttribute(NSAttributedString.Key(kCTUnderlineStyleAttributeName as String), value: 1, range: range) }
        // .NET/GDI+ NoFontFallback means missing glyphs in the requested font;
        // MS-EMFPLUS's prose for this bit is contradictory. Bind unsupported
        // clusters to that font's actual .notdef outline instead of substitution.
        if flags & 0x400 != 0 {
            var index = 0
            while index < string.length {
                let range = string.rangeOfComposedCharacterSequence(at: index), part = string.substring(with: range)
                let units = Array(part.utf16); var glyphs = [CGGlyph](repeating: 0, count: units.count)
                let controlsOnly = part.unicodeScalars.allSatisfy { CharacterSet.whitespacesAndNewlines.contains($0) || $0.properties.generalCategory == .format || CharacterSet.controlCharacters.contains($0) }
                if !controlsOnly, !CTFontGetGlyphsForCharacters(font, units, &glyphs, units.count) {
                    guard let info = CTGlyphInfoCreateWithGlyph(0, font, part as CFString) else { throw invalid("font cannot represent a missing-character glyph") }
                    attributed.addAttribute(NSAttributedString.Key(kCTGlyphInfoAttributeName as String), value: info, range: range)
                }
                index = NSMaxRange(range)
            }
        }
        let typesetter = CTTypesetterCreateWithAttributedString(attributed)
        let baseAscent = CTFontGetAscent(font), baseDescent = CTFontGetDescent(font), baseLeading = CTFontGetLeading(font)
        guard [baseAscent, baseDescent, baseLeading].allSatisfy({ $0.isFinite }), baseAscent + baseDescent + baseLeading > 0 else { throw invalid("invalid font line metrics") }
        var lines: [Line] = [], cursor = 0, top: CGFloat = 0
        while cursor < string.length {
            guard lines.count < 8192 else { throw invalid("line-count budget exceeded") }
            var paragraphStart = 0, paragraphEnd = 0, contentEnd = 0
            string.getLineStart(&paragraphStart, end: &paragraphEnd, contentsEnd: &contentEnd, for: NSRange(location: cursor, length: 0))
            var count = noWrap ? contentEnd - cursor : min(contentEnd - cursor, CTTypesetterSuggestLineBreak(typesetter, cursor, available / tracking))
            if count == 0, cursor < contentEnd { count = string.rangeOfComposedCharacterSequence(at: cursor).length }
            let end = cursor + count
            // Core Text interprets a zero-length range as "to the end", not an
            // empty paragraph. Blank lines still advance actual base-font metrics.
            let line = try charge(count == 0 ? CTLineCreateWithAttributedString(NSAttributedString(string: "", attributes: attributes)) : CTTypesetterCreateLine(typesetter, CFRange(location: cursor, length: count)))
            var ascent: CGFloat = 0, descent: CGFloat = 0, nativeLeading: CGFloat = 0
            _ = CTLineGetTypographicBounds(line, &ascent, &descent, &nativeLeading)
            if count == 0 { ascent = baseAscent; descent = baseDescent; nativeLeading = baseLeading }
            let lineHeight = ascent + descent + nativeLeading
            guard [ascent, descent, lineHeight].allSatisfy({ $0.isFinite }), lineHeight > 0 else { throw invalid("invalid shaped line metrics") }
            if !pointCross, lineLimit ? top + ascent + descent > crossExtent : (!noClip && top >= crossExtent) { break }
            lines.append(Line(value: line, start: cursor, end: end, paragraphEnd: contentEnd, ascent: ascent, descent: descent, height: lineHeight, top: top))
            top += lineHeight
            cursor = end == contentEnd ? paragraphEnd : end
        }
        // Trimming belongs to the last visible/partly-visible line only.
        if trimming != 0, !lines.isEmpty {
            let index = lines.count - 1, last = lines[index]
            let overflow = CTLineGetTypographicBounds(last.value, nil, nil, nil) * tracking > available || cursor < string.length
            if overflow {
                let range = NSRange(location: last.start, length: last.paragraphEnd - last.start)
                let source = attributed.attributedSubstring(from: range), value = source.string as NSString
                let ellipsis = trimming >= 3 ? NSAttributedString(string: "…", attributes: attributes) : NSAttributedString(string: "", attributes: attributes)
                let tokenWidth = CTLineGetTypographicBounds(try charge(CTLineCreateWithAttributedString(ellipsis)), nil, nil, nil) * tracking
                var boundaries = [0], position = 0
                while position < value.length { position = NSMaxRange(value.rangeOfComposedCharacterSequence(at: position)); boundaries.append(position) }
                if trimming == 2 || trimming == 4 {
                    var words = [0]
                    source.string.enumerateSubstrings(in: source.string.startIndex..<source.string.endIndex, options: [.byWords, .substringNotRequired]) { _, _, end, _ in words.append(NSRange(source.string.startIndex..<end.upperBound, in: source.string).length) }
                    boundaries = Array(Set(words)).sorted()
                }
                func candidate(_ count: Int, suffix: Int = 0) -> NSAttributedString {
                    let result = NSMutableAttributedString(attributedString: source.attributedSubstring(from: NSRange(location: 0, length: count)))
                    result.append(ellipsis)
                    if suffix > 0 { result.append(source.attributedSubstring(from: NSRange(location: value.length - suffix, length: suffix))) }
                    return result
                }
                var chosen = try charge(CTLineCreateWithAttributedString(NSAttributedString(string: "", attributes: attributes)))
                if tokenWidth <= available {
                    if trimming == 5 {
                        // Prefer the tail of a path, preserving its final component
                        // whenever it fits; binary search uses composed clusters.
                        var low = 0, high = boundaries.count - 1, suffixIndex = value.length
                        while low <= high {
                            let mid = (low + high) / 2, start = boundaries[mid]
                            let line = try charge(CTLineCreateWithAttributedString(candidate(0, suffix: value.length - start)))
                            if CTLineGetTypographicBounds(line, nil, nil, nil) * tracking <= available { suffixIndex = start; high = mid - 1 } else { low = mid + 1 }
                        }
                        let suffix = value.length - suffixIndex
                        low = 0; high = boundaries.firstIndex(of: suffixIndex) ?? 0
                        while low <= high {
                            let mid = (low + high) / 2, count = boundaries[mid], candidateText = candidate(count, suffix: suffix), line = try charge(CTLineCreateWithAttributedString(candidateText))
                            if CTLineGetTypographicBounds(line, nil, nil, nil) * tracking <= available { chosen = line; low = mid + 1 } else { high = mid - 1 }
                        }
                    } else {
                        var low = 0, high = boundaries.count - 1
                        while low <= high {
                            let mid = (low + high) / 2, candidateText = candidate(boundaries[mid]), line = try charge(CTLineCreateWithAttributedString(candidateText))
                            if CTLineGetTypographicBounds(line, nil, nil, nil) * tracking <= available { chosen = line; low = mid + 1 } else { high = mid - 1 }
                        }
                    }
                }
                lines[index].value = chosen
                var ascent: CGFloat = 0, descent: CGFloat = 0, leading: CGFloat = 0
                _ = CTLineGetTypographicBounds(chosen, &ascent, &descent, &leading)
                if ascent + descent + leading > 0 {
                    guard [ascent, descent, leading].allSatisfy({ $0.isFinite }) else { throw invalid("invalid trimmed line metrics") }
                    lines[index].ascent = ascent; lines[index].descent = descent; lines[index].height = ascent + descent + leading
                }
            }
        }
        let block = lines.last.map { $0.top + $0.ascent + $0.descent } ?? 0
        // A zero extent is unbounded for fitting, but remains zero for alignment.
        // Center/Far can deliberately position ink before the anchor or above a
        // rectangle shorter than the shaped line; the graphics clip decides what
        // remains visible. Clamping would silently turn those alignments to Near.
        let crossOffset = (CGFloat(crossExtent) - block) * CGFloat(lineAlignment) / 2
        let output = CGMutablePath(); var measurement = CGRect.null
        for item in lines {
            let line = item.value, local = CGMutablePath()
            let width = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil) * tracking)
            let trailingSpace = CGFloat(CTLineGetTrailingWhitespaceWidth(line) * tracking)
            let measuredWidth = flags & 0x800 != 0 ? width : max(0, width - trailingSpace)
            let effectiveAlignment = rtl && !vertical ? 2 - alignment : alignment
            var inlineOffset = CGFloat(leading) + ((pointInline ? 0 : CGFloat(available)) - measuredWidth) * CGFloat(effectiveAlignment) / 2
            for run in CTLineGetGlyphRuns(line) as! [CTRun] {
                let count = CTRunGetGlyphCount(run), runAttributes = CTRunGetAttributes(run) as NSDictionary
                guard let fontValue = runAttributes[kCTFontAttributeName] else { throw invalid("shaped run has no font") }
                let runFont = fontValue as! CTFont
                if flags & 0x400 != 0, CTFontCopyPostScriptName(runFont) as String != CTFontCopyPostScriptName(font) as String { throw invalid("requested no-fallback font could not supply its missing-glyph outline") }
                var glyphs = [CGGlyph](repeating: 0, count: count), positions = [CGPoint](repeating: .zero, count: count), advances = [CGSize](repeating: .zero, count: count)
                CTRunGetGlyphs(run, CFRange(), &glyphs); CTRunGetPositions(run, CFRange(), &positions); CTRunGetAdvances(run, CFRange(), &advances)
                let matrix = CTRunGetTextMatrix(run)
                guard [matrix.a, matrix.b, matrix.c, matrix.d, matrix.tx, matrix.ty].allSatisfy({ $0.isFinite }) else { throw invalid("invalid run text matrix") }
                var minimum = CGFloat.infinity, maximum = -CGFloat.infinity
                for index in 0..<count {
                    let position = positions[index]
                    guard position.x.isFinite, position.y.isFinite, advances[index].width.isFinite else { throw invalid("invalid glyph position") }
                    minimum = min(minimum, position.x * tracking); maximum = max(maximum, (position.x + advances[index].width) * tracking)
                    if let outline = CTFontCreatePathForGlyph(runFont, glyphs[index], nil), !outline.isEmpty {
                        var transform = matrix; transform.tx += position.x * tracking; transform.ty += position.y
                        try append(outline, to: local, transform: transform)
                    } else {
                        // Real font bounds distinguish non-ink spaces/controls
                        // from visible bitmap/color glyphs, even after truncation
                        // changes string indices (middle ellipsis and path tail).
                        var glyph = glyphs[index]
                        let ink = CTFontGetBoundingRectsForGlyphs(runFont, .horizontal, &glyph, nil, 1)
                        guard ink.isNull || ink.isEmpty else { throw invalid("visible glyph has no vector outline (color/bitmap fonts are unsupported)") }
                    }
                }
                if minimum.isFinite, maximum > minimum {
                    if ((runAttributes[kCTUnderlineStyleAttributeName] as? NSNumber)?.intValue ?? 0) != 0 {
                        let thickness = CTFontGetUnderlineThickness(runFont), position = CTFontGetUnderlinePosition(runFont)
                        guard thickness.isFinite, thickness > 0, position.isFinite else { throw invalid("invalid underline font metrics") }
                        try append(CGPath(rect: CGRect(x: minimum, y: position, width: maximum - minimum, height: thickness), transform: nil), to: local)
                    }
                    if style & 8 != 0 {
                        guard let table = CTFontCopyTable(runFont, CTFontTableTag(0x4f532f32), []) as Data?, table.count >= 30 else { throw invalid("strikeout requires OS/2 font metrics") }
                        func signed(_ offset: Int) -> CGFloat { CGFloat(Int16(bitPattern: UInt16(table[offset]) << 8 | UInt16(table[offset + 1]))) * CTFontGetSize(runFont) / CGFloat(CTFontGetUnitsPerEm(runFont)) }
                        let thickness = signed(26), position = signed(28)
                        guard thickness > 0, thickness.isFinite, position.isFinite else { throw invalid("invalid strikeout font metrics") }
                        try append(CGPath(rect: CGRect(x: minimum, y: position - thickness, width: maximum - minimum, height: thickness), transform: nil), to: local)
                    }
                }
            }
            if flags & 4 == 0, !pointInline, !local.isEmpty {
                let bounds = local.boundingBoxOfPath
                if inlineOffset + bounds.minX < leading { inlineOffset = CGFloat(leading) - bounds.minX }
                if inlineOffset + bounds.maxX > inlineExtent - trailing { inlineOffset -= min(inlineOffset + bounds.maxX - CGFloat(inlineExtent - trailing), max(0, inlineOffset + bounds.minX - CGFloat(leading))) }
            }
            let transform: CGAffineTransform
            if vertical {
                let column = rtl ? CGFloat(crossExtent) - crossOffset - item.top - item.ascent : crossOffset + item.top + item.descent
                transform = CGAffineTransform(a: 0, b: 1, c: 1, d: 0, tx: CGFloat(x) + column, ty: CGFloat(y) + inlineOffset)
            } else { transform = CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: CGFloat(x) + inlineOffset, ty: CGFloat(y) + crossOffset + item.top + item.ascent) }
            // Elements were charged on their original glyphs, not a second time
            // when moving the completed line into absolute rectangle coordinates.
            output.addPath(local, transform: transform)
            if flags & 0x800 != 0 {
                let rect = CGRect(x: 0, y: -item.descent, width: measuredWidth, height: item.ascent + item.descent).applying(transform)
                measurement = measurement.union(rect)
            }
        }
        let bounds = output.isEmpty ? measurement : output.boundingBoxOfPath.union(measurement)
        guard bounds.isNull || [bounds.minX, bounds.minY, bounds.maxX, bounds.maxY].allSatisfy({ $0.isFinite && abs($0) <= 1_000_000_000 }) else { throw invalid("non-finite text bounds") }
        return ["path": try svg(output), "bounds": bounds.isNull ? [x, y, x, y] : [Double(bounds.minX), Double(bounds.minY), Double(bounds.maxX), Double(bounds.maxY)]]
    }
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
    let textLayout = NativeTextLayout()
    let layoutText: @convention(block) (String, String, Double, Bool, Bool, JSValue) -> NSDictionary = { text, face, size, bold, italic, options in
        do { return try textLayout.layout(text, face: face, size: size, bold: bold, italic: italic, options: options) as NSDictionary }
        catch ConversionError.invalid(let message) { nativeError(message); return [:] }
        catch { nativeError("Formatted metafile text layout failed: " + String(describing: error)); return [:] }
    }
    var decodedBitmapPixels=0
    // The optional sixth argument contains EmfPlusPalette ARGB values. Existing
    // gradient/hatch callers have no palette and continue to pass five arguments.
    let bitmap: @convention(block) (JSValue, Int, Int, Int, UInt32, JSValue) -> String = { value, width, height, stride, format, paletteValue in
        guard width > 0, height > 0, width <= 32768, height <= 32768, width <= 16777216 / height,
              stride != Int.min, stride != 0, abs(stride) <= inputLimit / height else { nativeError("Invalid or oversized metafile bitmap"); return "" }
        // GDI+ PixelFormat values encode bits-per-pixel in bits 8...15.
        let bits = Int((format >> 8) & 255)
        guard [UInt32(0x30101),0x30402,0x30803,0x21005,0x21006,0x61007,0x21808,0x22009,0x26200A,0xE200B].contains(format) else { nativeError("Unsupported metafile pixel format"); return "" }
        guard abs(stride) >= (width * bits + 7) / 8, bits > 16 || abs(stride).isMultiple(of:4),
              let raw=data(value),raw.count == abs(stride) * height else {nativeError("Invalid metafile bitmap stride or pixel count");return ""}
        var palette:[UInt32]=[]
        if bits <= 8 {
            guard !paletteValue.isUndefined,!paletteValue.isNull,let countValue=paletteValue.forProperty("length") else {nativeError("Missing metafile bitmap palette");return ""}
            let length=countValue.toDouble()
            guard length.isFinite,length.rounded() == length,length >= 1,length <= Double(1 << bits) else {nativeError("Invalid metafile bitmap palette count");return ""}
            for index in 0..<Int(length) {
                guard let entry=paletteValue.atIndex(index),entry.isNumber else {nativeError("Invalid metafile bitmap palette entry");return ""}
                let color=entry.toDouble()
                guard color.isFinite,color.rounded() == color,color >= 0,color <= Double(UInt32.max) else {nativeError("Invalid metafile bitmap palette color");return ""}
                palette.append(UInt32(color))
            }
        }
        // Bound total native expansion, including generated gradient/hatch cells,
        // before allocating the per-bitmap RGBA representation.
        let pixels=width * height
        guard pixels <= 67108864-decodedBitmapPixels else {nativeError("Metafile bitmap expansion budget exceeded");return ""}
        decodedBitmapPixels += pixels
        var rgba = Data(count: width * height * 4)
        for y in 0..<height {
            let row = (stride < 0 ? height - 1 - y : y) * abs(stride)
            for x in 0..<width {
                let end = (y * width + x) * 4
                if bits <= 8 {
                    let byte=raw[row + x * bits / 8]
                    let index=Int(bits == 1 ? (byte >> (7-x%8)) & 1:bits == 4 ? (byte >> (x%2 == 0 ? 4:0)) & 15:byte)
                    guard index < palette.count else {nativeError("Metafile bitmap palette index exceeds count");return ""}
                    let color=palette[index]
                    rgba[end]=UInt8(truncatingIfNeeded:color>>16);rgba[end+1]=UInt8(truncatingIfNeeded:color>>8);rgba[end+2]=UInt8(truncatingIfNeeded:color);rgba[end+3]=UInt8(truncatingIfNeeded:color>>24)
                }else if bits == 16 {
                    let start=row+x*2,word=UInt16(raw[start]) | UInt16(raw[start+1]) << 8
                    let is565=format == 0x21006
                    let red=(word >> (is565 ? 11:10)) & 31,green=(word >> 5) & (is565 ? 63:31),blue=word & 31
                    rgba[end]=UInt8((red<<3)|(red>>2));rgba[end+1]=UInt8(is565 ? (green<<2)|(green>>4):(green<<3)|(green>>2));rgba[end+2]=UInt8((blue<<3)|(blue>>2))
                    rgba[end+3]=format == 0x61007 && word & 0x8000 == 0 ? 0:255
                }else {
                    let start=row+x*(bits/8)
                    rgba[end] = raw[start + 2]; rgba[end + 1] = raw[start + 1]; rgba[end + 2] = raw[start]
                    rgba[end + 3] = bits == 32 && (format & 0x40000) != 0 ? raw[start + 3] : 255
                }
            }
        }
        let alpha: CGImageAlphaInfo = format & 0x80000 != 0 ? .premultipliedLast : .last
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
            let provider = CGDataProvider(data: rgba as CFData), let image = CGImage(width: width, height: height,
            bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4, space: space,
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
    context.setObject(layoutText, forKeyedSubscript: "__turtleLayoutText" as NSString)
    context.setObject(bitmap, forKeyedSubscript: "__turtleBitmapNative" as NSString)
    context.evaluateScript("""
    globalThis.__turtleBitmap = function(bytes,width,height,stride,format,palette){return __turtleBitmapNative(bytes,width,height,stride,format,palette === undefined ? [] : palette);};
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
