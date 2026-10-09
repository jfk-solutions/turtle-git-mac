// SPDX-License-Identifier: GPL-2.0-or-later
import Foundation

/// Git/CString reference identity does not normalize Unicode spellings. Keep
/// valid UTF-8 names byte-exact when using Swift dictionaries, sets and equality.
public struct GitReferenceName: Hashable, Sendable, ExpressibleByStringLiteral {
    public let rawValue: String
    public init(_ value: String) { rawValue = value }
    public init(stringLiteral value: String) { rawValue = value }
    public static func equal(_ lhs: String, _ rhs: String) -> Bool { lhs.utf8.elementsEqual(rhs.utf8) }
    public static func removingPrefix(_ prefix: String, from value: String) -> String? {
        guard value.utf8.starts(with: prefix.utf8) else { return nil }
        return String(decoding: value.utf8.dropFirst(prefix.utf8.count), as: UTF8.self)
    }
    public static func removingSuffix(_ suffix: String, from value: String) -> String? {
        guard value.utf8.suffix(suffix.utf8.count).elementsEqual(suffix.utf8) else { return nil }
        return String(decoding: value.utf8.dropLast(suffix.utf8.count), as: UTF8.self)
    }
    public static func == (lhs: Self, rhs: Self) -> Bool { equal(lhs.rawValue, rhs.rawValue) }
    public func hash(into hasher: inout Hasher) { hasher.combine(Data(rawValue.utf8)) }
}
