import Foundation

/// Encode menu order and captions from pinned TortoiseGitBlameENG.rc.
/// A code page is a codec identity, independent of its translated display name.
public struct GitBlameEncodingChoice: Identifiable, Sendable {
    public let title: String
    public let codePage: UInt32
    public var id: UInt32 { codePage }
    public var encoding: GitBlameEncoding? { GitBlameEncoding.available.first { $0.windowsCodePage == codePage } }
}
public struct GitBlameEncodingGroup: Identifiable, Sendable {
    public let title: String
    public let choices: [GitBlameEncodingChoice]
    public var id: String { title }
}
public enum GitBlameEncodingMenu {
    public static let unicode: [GitBlameEncodingChoice] = [
        .init(title: "UTF-8", codePage: 65001),
        .init(title: "UTF-16 LE", codePage: 1200),
        .init(title: "UTF-16 BE", codePage: 1201),
    ]
    public static let groups: [GitBlameEncodingGroup] = [
        .init(title: "Arabic", choices: [
            .init(title: "ISO 8859-6", codePage: 28596),
            .init(title: "OEM 720", codePage: 720),
            .init(title: "Windows-1256", codePage: 1256),
        ]),
        .init(title: "Baltic", choices: [
            .init(title: "ISO 8859-4", codePage: 28594),
            .init(title: "ISO 8859-13", codePage: 28603),
            .init(title: "OEM 775", codePage: 775),
            .init(title: "Windows-1257", codePage: 1257),
        ]),
        .init(title: "Celtic", choices: [
            .init(title: "ISO 8859-14", codePage: 28604),
        ]),
        .init(title: "Cyrillic", choices: [
            .init(title: "ISO 8859-5", codePage: 28595),
            .init(title: "KOI8-R", codePage: 20866),
            .init(title: "KOI8-U", codePage: 21866),
            .init(title: "Macintosh", codePage: 10007),
            .init(title: "OEM 855", codePage: 855),
            .init(title: "OEM 866", codePage: 866),
            .init(title: "Windows-1251", codePage: 1251),
        ]),
        .init(title: "Central European", choices: [
            .init(title: "ISO 8859-16", codePage: 28606),
            .init(title: "OEM 852", codePage: 852),
            .init(title: "Windows-1250", codePage: 1250),
        ]),
        .init(title: "Chinese", choices: [
            .init(title: "Big5 (Traditional)", codePage: 950),
            .init(title: "GB2312 (Simplified)", codePage: 936),
        ]),
        .init(title: "Eastern European", choices: [
            .init(title: "ISO 8859-2", codePage: 28592),
        ]),
        .init(title: "Greek", choices: [
            .init(title: "ISO 8859-7", codePage: 28597),
            .init(title: "OEM 737", codePage: 737),
            .init(title: "OEM 869", codePage: 869),
            .init(title: "Windows-1253", codePage: 1253),
        ]),
        .init(title: "Hebrew", choices: [
            .init(title: "ISO 8859-8", codePage: 28598),
            .init(title: "OEM 862", codePage: 862),
            .init(title: "Windows-1255", codePage: 1255),
        ]),
        .init(title: "Japanese", choices: [
            .init(title: "Shift-JIS", codePage: 932),
        ]),
        .init(title: "Korean", choices: [
            .init(title: "EUC-KR", codePage: 51949),
        ]),
        .init(title: "North European", choices: [
            .init(title: "OEM 861: Icelandic", codePage: 861),
            .init(title: "OEM 865: Nordic", codePage: 865),
        ]),
        .init(title: "Thai", choices: [
            .init(title: "ISO 8859-11", codePage: 28601),
            .init(title: "TIS-620", codePage: 874),
        ]),
        .init(title: "Turkish", choices: [
            .init(title: "ISO 8859-3", codePage: 28593),
            .init(title: "ISO 8859-9", codePage: 28599),
            .init(title: "OEM 857", codePage: 857),
            .init(title: "Windows-1254", codePage: 1254),
        ]),
        .init(title: "Western European", choices: [
            .init(title: "ISO 8859-1", codePage: 28591),
            .init(title: "ISO 8859-10", codePage: 28600),
            .init(title: "ISO 8859-15", codePage: 28605),
            .init(title: "OEM 850", codePage: 850),
            .init(title: "OEM 858", codePage: 858),
            .init(title: "OEM 860: Portuguese", codePage: 860),
            .init(title: "OEM 863: French", codePage: 863),
            .init(title: "OEM-US", codePage: 437),
            .init(title: "Windows-1252", codePage: 1252),
        ]),
        .init(title: "Vietnamese", choices: [
            .init(title: "Windows-1258", codePage: 1258),
        ]),
    ]
    public static var additional: [GitBlameEncoding] {
        let pages = Set((unicode + groups.flatMap(\.choices)).map(\.codePage))
        return GitBlameEncoding.available.filter { !pages.contains($0.windowsCodePage) }
    }
}

extension GitBlameEncoding {
    // Foundation exposes neither OEM 720 nor OEM 858 on macOS. These Windows
    // single-byte mappings keep the source choices functional without a helper
    // process or an invalid Foundation encoding identifier.
    static let supplemental: [GitBlameEncoding] = [
        .init(id: 0x100000000 + 720, rawValue: "OEM 720"),
        .init(id: 0x100000000 + 858, rawValue: "OEM 858"),
    ]
    static let supplementalMappings: [UInt: [UInt32]] = [
        0x100000000 + 720: [
            0x80, 0x81, 0xe9, 0xe2, 0x84, 0xe0, 0x86, 0xe7, 0xea, 0xeb, 0xe8, 0xef, 0xee, 0x8d, 0x8e, 0x8f,
            0x90, 0x651, 0x652, 0xf4, 0xa4, 0x640, 0xfb, 0xf9, 0x621, 0x622, 0x623, 0x624, 0xa3, 0x625, 0x626, 0x627,
            0x628, 0x629, 0x62a, 0x62b, 0x62c, 0x62d, 0x62e, 0x62f, 0x630, 0x631, 0x632, 0x633, 0x634, 0x635, 0xab, 0xbb,
            0x2591, 0x2592, 0x2593, 0x2502, 0x2524, 0x2561, 0x2562, 0x2556, 0x2555, 0x2563, 0x2551, 0x2557, 0x255d, 0x255c, 0x255b, 0x2510,
            0x2514, 0x2534, 0x252c, 0x251c, 0x2500, 0x253c, 0x255e, 0x255f, 0x255a, 0x2554, 0x2569, 0x2566, 0x2560, 0x2550, 0x256c, 0x2567,
            0x2568, 0x2564, 0x2565, 0x2559, 0x2558, 0x2552, 0x2553, 0x256b, 0x256a, 0x2518, 0x250c, 0x2588, 0x2584, 0x258c, 0x2590, 0x2580,
            0x636, 0x637, 0x638, 0x639, 0x63a, 0x641, 0xb5, 0x642, 0x643, 0x644, 0x645, 0x646, 0x647, 0x648, 0x649, 0x64a,
            0x2261, 0x64b, 0x64c, 0x64d, 0x64e, 0x64f, 0x650, 0x2248, 0xb0, 0x2219, 0xb7, 0x221a, 0x207f, 0xb2, 0x25a0, 0xa0,
        ],
        0x100000000 + 858: [
            0xc7, 0xfc, 0xe9, 0xe2, 0xe4, 0xe0, 0xe5, 0xe7, 0xea, 0xeb, 0xe8, 0xef, 0xee, 0xec, 0xc4, 0xc5,
            0xc9, 0xe6, 0xc6, 0xf4, 0xf6, 0xf2, 0xfb, 0xf9, 0xff, 0xd6, 0xdc, 0xf8, 0xa3, 0xd8, 0xd7, 0x192,
            0xe1, 0xed, 0xf3, 0xfa, 0xf1, 0xd1, 0xaa, 0xba, 0xbf, 0xae, 0xac, 0xbd, 0xbc, 0xa1, 0xab, 0xbb,
            0x2591, 0x2592, 0x2593, 0x2502, 0x2524, 0xc1, 0xc2, 0xc0, 0xa9, 0x2563, 0x2551, 0x2557, 0x255d, 0xa2, 0xa5, 0x2510,
            0x2514, 0x2534, 0x252c, 0x251c, 0x2500, 0x253c, 0xe3, 0xc3, 0x255a, 0x2554, 0x2569, 0x2566, 0x2560, 0x2550, 0x256c, 0xa4,
            0xf0, 0xd0, 0xca, 0xcb, 0xc8, 0x20ac, 0xcd, 0xce, 0xcf, 0x2518, 0x250c, 0x2588, 0x2584, 0xa6, 0xcc, 0x2580,
            0xd3, 0xdf, 0xd4, 0xd2, 0xf5, 0xd5, 0xb5, 0xfe, 0xde, 0xda, 0xdb, 0xd9, 0xfd, 0xdd, 0xaf, 0xb4,
            0xad, 0xb1, 0x2017, 0xbe, 0xb6, 0xa7, 0xf7, 0xb8, 0xb0, 0xa8, 0xb7, 0xb9, 0xb3, 0xb2, 0x25a0, 0xa0,
        ],
    ]
    /// Decode the complete source, preserving state for platform legacy codecs.
    public func decodeText(_ bytes: Data) -> String? {
        guard let mapping = Self.supplementalMappings[id] else {
            return String(data: bytes, encoding: String.Encoding(rawValue: id))
        }
        var scalars = String.UnicodeScalarView()
        for byte in bytes {
            let value = byte < 128 ? UInt32(byte) : mapping[Int(byte) - 128]
            guard let scalar = UnicodeScalar(value) else { return nil }
            scalars.append(scalar)
        }
        return String(scalars)
    }
}
