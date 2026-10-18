// Adapted from TortoiseGitMerge DiffData.cpp and FileTextLines.cpp.
// FileTextLines.cpp: Copyright (C) 2016, 2019, 2021, 2023, 2025 - TortoiseGit
// Copyright (C) 2007-2016, 2019 - TortoiseSVN
// DiffData.cpp: Copyright (C) 2023, 2025 - TortoiseGit
// Copyright (C) 2006-2017, 2020 - TortoiseSVN
// SPDX-License-Identifier: GPL-2.0-or-later
import Foundation

/// TortoiseMerge FileTextLines::StripWhiteSpace's /blame projection. The
/// fixed-width metadata belongs to the original displayed row, not its diff key.
/// CString counts UTF-16 code units; counting Swift Characters changes this ABI.
public enum MergeBlameComparison {
    public static let prefixLength = 66

    /// DiffData::Load strips Blame prefixes only from inputs which its converted
    /// Save path rewrites. UTF-8 without BOM can bypass conversion; an ASCII /
    /// legacy side converts when any companion uses a Unicode comparison stream.
    /// Preserve this asymmetric source behavior rather than treating /blame as
    /// an unconditional instruction to remove every prefix.
    public static func conversionMask(texts: [String], encodings: [ComparisonTextEncoding?]? = nil, forceConversion: Bool = false) -> [Bool] {
        let formats = texts.enumerated().map { index, text -> ComparisonTextEncoding in
            if let encodings, encodings.indices.contains(index), let value = encodings[index] { return value }
            return text.utf8.allSatisfy { $0 < 128 } ? .windows1252 : .utf8
        }
        let needs = zip(texts, formats).map { text, format in
            forceConversion || format != .utf8 && format.legacyCodePage == nil ||
            ["\r\n", "\u{000c}", "\u{000b}", "\u{0085}", "\u{2028}", "\u{2029}"].contains { text.contains($0) }
        }
        let unicodeStream = zip(formats, needs).contains { format, converted in format.legacyCodePage == nil || converted }
        return zip(formats, needs).map { format, needsConversion in needsConversion || format.legacyCodePage != nil && unicodeStream }
    }

    /// Input is the line payload, after comment and regex filtering and before
    /// whitespace/case comparison. Exactly-66 and shorter lines remain intact.
    public static func content(_ payload: String) -> String {
        let text = payload as NSString
        return text.length > prefixLength ? text.substring(from: prefixLength) : payload
    }

    /// Immediate native alignment only. The authoritative engine applies the
    /// same projection after its configured comment and regex transforms.
    public static func keys(in text: String) -> [String] {
        let source = text as NSString
        return MergeLineEndings.lineRanges(in: text).map { range in
            let line = source.substring(with: range)
            let payload = MergeLineEndings.droppingFinalEnding(line)
            let ending = (line as NSString).substring(from: (payload as NSString).length)
            return content(payload) + ending
        }
    }
}
