// Adapted from TortoiseGitMerge FileTextLines.cpp::CheckUnicodeType and decode filters.
// Copyright (C) 2016, 2019, 2021, 2023, 2025 - TortoiseGit
// Copyright (C) 2007-2016, 2019 - TortoiseSVN. GPL-2.0-or-later.
import Foundation

public enum MessageCodeText {
    public enum Encoding: Sendable { case binary, ascii, utf8, utf8BOM, utf16LE, utf16BE, utf16LEBOM, utf16BEBOM, utf32LE, utf32BE }
    public struct Decoded: Sendable {
        public let encoding: Encoding
        /// Preserve raw units, including unpaired surrogates and source length quirks.
        public let units: [UInt16]
    }
    public static func detect(_ data: Data, useUTF8: Bool = false) -> Encoding {
        let bytes = Array(data), count = bytes.count
        guard count >= 2 else { return .ascii }
        for start in stride(from: 0, to: count - count % 4, by: 4) {
            if bytes[start..<(start + 4)].allSatisfy({ $0 == 0 }) { return .binary }
        }
        if count >= 4 {
            if bytes.starts(with: [0xff, 0xfe, 0, 0]) { return .utf32LE }
            if bytes.starts(with: [0, 0, 0xfe, 0xff]) { return .utf32BE }
        }
        if bytes.starts(with: [0xff, 0xfe]) { return .utf16LEBOM }
        if bytes.starts(with: [0xfe, 0xff]) { return .utf16BEBOM }
        guard count >= 3 else { return .ascii }
        if bytes.starts(with: [0xef, 0xbb, 0xbf]) { return .utf8BOM }
        var nonANSI = false, needed = 0, index = 0, zeros = 0
        while index < count {
            if bytes[index] == 0 {
                zeros += 1
                if zeros > count / 50 { return index % 2 == 1 ? .utf16LE : .utf16BE }
            }
            if bytes[index] & 0x80 != 0 { nonANSI = true; break }
            index += 1
        }
        while index < count {
            let byte = bytes[index]; defer { index += 1 }
            if byte & 0x80 == 0 {
                if byte == 0 {
                    zeros += 1
                    if zeros > count / 50 { return index % 2 == 1 ? .utf16LE : .utf16BE }
                    needed = 0
                } else if needed != 0 { return .ascii }
                continue
            }
            if byte & 0x40 == 0 {
                if needed == 0 { return .ascii }; needed -= 1
            } else if needed != 0 { return .ascii }
            else if byte & 0x20 == 0 {
                if byte <= 0xc1 { return .ascii }; needed = 1
            } else if byte & 0x10 == 0 { needed = 2 }
            else if byte & 0x08 == 0 {
                if byte >= 0xf5 { return .ascii }; needed = 3
            } else { return .ascii }
        }
        if nonANSI && needed == 0 { return .utf8 }
        if !nonANSI && useUTF8 { return .utf8 }
        return .ascii
    }
    /// CP_ACP has no macOS equivalent. Caller supplies the desired legacy code page;
    /// Windows-1252 is the initial native default, not a claim of exact Windows ACP.
    public static func decode(_ data: Data, useUTF8: Bool = false, legacyEncoding: String.Encoding = .windowsCP1252) -> Decoded? {
        guard !data.isEmpty else { return nil }
        let encoding = detect(data, useUTF8: useUTF8), bytes = Array(data)
        let units: [UInt16]
        switch encoding {
        case .binary: return nil
        case .ascii:
            guard let text = String(data: data, encoding: legacyEncoding) else { return nil }
            units = Array(text.utf16)
        case .utf8, .utf8BOM:
            // Native replacement decoding; exact malformed Windows UTF-8 behavior
            // remains under audit. BOM is intentionally part of scanner input.
            units = Array(String(decoding: data, as: UTF8.self).utf16)
        case .utf16LE, .utf16LEBOM, .utf16BE, .utf16BEBOM:
            let little = encoding == .utf16LE || encoding == .utf16LEBOM
            units = stride(from: 0, to: bytes.count - bytes.count % 2, by: 2).map {
                little ? UInt16(bytes[$0]) | UInt16(bytes[$0 + 1]) << 8 : UInt16(bytes[$0]) << 8 | UInt16(bytes[$0 + 1])
            }
        case .utf32LE, .utf32BE:
            let count = bytes.count / 4
            var decoded: [UInt16] = []
            for start in stride(from: 0, to: count * 4, by: 4) {
                var value: UInt32 = 0
                let positions = encoding == .utf32LE ? [3, 2, 1, 0] : [0, 1, 2, 3]
                for offset in positions { value = value << 8 | UInt32(bytes[start + offset]) }
                if value >= 0x110000 { decoded.append(0xfffd) }
                else if value >= 0x10000 {
                    value -= 0x10000
                    decoded.append(UInt16((value >> 10) & 0x3ff) | 0xd800)
                    decoded.append(UInt16(value & 0x7ff) | 0xdc00)
                } else { decoded.append(UInt16(value)) }
            }
            // CUtf32leFilter sets m_iBufferLength to input scalar count after
            // expanding pairs, so GetStringView exposes only this prefix.
            units = Array(decoded.prefix(count))
        }
        return Decoded(encoding: encoding, units: units)
    }
}
