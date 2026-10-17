// SPDX-License-Identifier: GPL-2.0-or-later
import Foundation

/// Git/CString reference identity does not normalize Unicode spellings. Keep
/// valid UTF-8 names byte-exact when using Swift dictionaries, sets and equality.
public struct GitReferenceName: Hashable, Sendable, ExpressibleByStringLiteral {
    public let rawValue: String
    public init(_ value: String) { rawValue = value }
    public init(stringLiteral value: String) { rawValue = value }
    public static func equal(_ lhs: String, _ rhs: String) -> Bool { lhs.utf8.elementsEqual(rhs.utf8) }
    public static func equal(_ lhs:String,_ rhs:String?)->Bool { rhs.map { equal(lhs,$0) } ?? false }
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

/// Git path-keyed metadata must retain canonically equivalent UTF-8 spellings.
/// String-facing lookup keeps callers from accidentally normalizing the payload.
public struct GitPathMap<Value>: Sequence, ExpressibleByDictionaryLiteral {
    private var storage: [GitReferenceName: Value] = [:]
    public init() {}
    public init<S: Sequence>(_ pairs: S, uniquingKeysWith combine: (Value,Value) throws -> Value) rethrows where S.Element == (String,Value) {
        for (path,value) in pairs {
            let key = GitReferenceName(path)
            if let previous = storage[key] { storage[key] = try combine(previous,value) }
            else { storage[key] = value }
        }
    }
    public init<S: Sequence>(uniqueKeysWithValues pairs: S) where S.Element == (String,Value) {
        self.init(pairs,uniquingKeysWith: { _,_ in preconditionFailure("Duplicate Git path bytes") })
    }
    public init(dictionaryLiteral elements: (String,Value)...) { self.init(uniqueKeysWithValues:elements) }
    public subscript(path:String) -> Value? {
        get { storage[GitReferenceName(path)] }
        set { storage[GitReferenceName(path)] = newValue }
    }
    public var count:Int { storage.count }
    public var isEmpty:Bool { storage.isEmpty }
    public var keys:[String] { storage.keys.map(\.rawValue) }
    public var values:[Value] { Array(storage.values) }
    public func makeIterator() -> AnyIterator<(key:String,value:Value)> {
        var iterator = storage.makeIterator()
        return AnyIterator { iterator.next().map { (key:$0.key.rawValue,value:$0.value) } }
    }
    public func filter(_ isIncluded: ((key:String,value:Value)) throws -> Bool) rethrows -> Self {
        var result = Self()
        for entry in self where try isIncluded(entry) { result[entry.key] = entry.value }
        return result
    }
    public func mapValues<T>(_ transform:(Value) throws -> T) rethrows -> GitPathMap<T> {
        var result = GitPathMap<T>()
        for entry in self { result[entry.key] = try transform(entry.value) }
        return result
    }
    public mutating func merge(_ other:Self,uniquingKeysWith combine:(Value,Value) throws -> Value) rethrows {
        for entry in other {
            if let previous = self[entry.key] { self[entry.key] = try combine(previous,entry.value) }
            else { self[entry.key] = entry.value }
        }
    }
    @discardableResult public mutating func removeValue(forKey key:String) -> Value? { storage.removeValue(forKey:GitReferenceName(key)) }
    public mutating func removeAll(keepingCapacity:Bool = false) { storage.removeAll(keepingCapacity:keepingCapacity) }
}
extension GitPathMap: Sendable where Value:Sendable {}
extension GitPathMap: Equatable where Value:Equatable {
    public static func == (lhs:Self,rhs:Self)->Bool { lhs.storage == rhs.storage }
}
extension GitPathMap: Codable where Value:Codable {
    private struct Entry:Codable { let path:String; let value:Value }
    public init(from decoder:Decoder) throws {
        let entries = try decoder.singleValueContainer().decode([Entry].self)
        self.init()
        for entry in entries {
            guard self[entry.path] == nil else { throw DecodingError.dataCorrupted(.init(codingPath:decoder.codingPath,debugDescription:"Duplicate Git path bytes")) }
            self[entry.path] = entry.value
        }
    }
    public func encode(to encoder:Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(keys.sorted { $0.utf8.lexicographicallyPrecedes($1.utf8) }.map { Entry(path:$0,value:self[$0]!) })
    }
}

/// String-facing Git path selection with byte-exact membership and equality.
public struct GitPathSet: SetAlgebra, Sequence, ExpressibleByArrayLiteral, Hashable, Sendable, Codable {
    public typealias Element = String
    private var storage: Set<GitReferenceName> = []
    public init() {}
    public init<S:Sequence>(_ paths:S) where S.Element == String { storage = Set(paths.map { GitReferenceName($0) }) }
    public init(identities:Set<GitReferenceName>) { storage = identities }
    public init(arrayLiteral elements:String...) { self.init(elements) }
    public var identities:Set<GitReferenceName> { storage }
    public var count:Int { storage.count }
    public var isEmpty:Bool { storage.isEmpty }
    public var first:String? { storage.first?.rawValue }
    public func contains(_ path:String)->Bool { storage.contains(GitReferenceName(path)) }
    public func contains(_ path:GitReferenceName)->Bool { storage.contains(path) }
    public func makeIterator()->AnyIterator<String> {
        var iterator = storage.makeIterator(); return AnyIterator { iterator.next()?.rawValue }
    }
    @discardableResult public mutating func insert(_ path:String)->(inserted:Bool,memberAfterInsert:String) {
        let answer = storage.insert(GitReferenceName(path)); return (answer.inserted,answer.memberAfterInsert.rawValue)
    }
    @discardableResult public mutating func remove(_ path:String)->String? { storage.remove(GitReferenceName(path))?.rawValue }
    @discardableResult public mutating func update(with path:String)->String? { storage.update(with:GitReferenceName(path))?.rawValue }
    public func union(_ other:Self)->Self { .init(identities:storage.union(other.storage)) }
    public func intersection(_ other:Self)->Self { .init(identities:storage.intersection(other.storage)) }
    public func symmetricDifference(_ other:Self)->Self { .init(identities:storage.symmetricDifference(other.storage)) }
    public func subtracting(_ other:Self)->Self { .init(identities:storage.subtracting(other.storage)) }
    public mutating func formUnion(_ other:Self) { storage.formUnion(other.storage) }
    public mutating func formIntersection(_ other:Self) { storage.formIntersection(other.storage) }
    public mutating func formSymmetricDifference(_ other:Self) { storage.formSymmetricDifference(other.storage) }
    public mutating func subtract(_ other:Self) { storage.subtract(other.storage) }
    public func isSubset(of other:Self)->Bool { storage.isSubset(of:other.storage) }
    public func isSuperset(of other:Self)->Bool { storage.isSuperset(of:other.storage) }
    public func isDisjoint(with other:Self)->Bool { storage.isDisjoint(with:other.storage) }
    public func union<S:Sequence>(_ paths:S)->Self where S.Element == String { union(Self(paths)) }
    public func intersection<S:Sequence>(_ paths:S)->Self where S.Element == String { intersection(Self(paths)) }
    public func subtracting<S:Sequence>(_ paths:S)->Self where S.Element == String { subtracting(Self(paths)) }
    public mutating func formUnion<S:Sequence>(_ paths:S) where S.Element == String { formUnion(Self(paths)) }
    public mutating func formIntersection<S:Sequence>(_ paths:S) where S.Element == String { formIntersection(Self(paths)) }
    public mutating func subtract<S:Sequence>(_ paths:S) where S.Element == String { subtract(Self(paths)) }
    public mutating func removeAll(keepingCapacity:Bool = false) { storage.removeAll(keepingCapacity:keepingCapacity) }
    public init(from decoder:Decoder) throws { self.init(try decoder.singleValueContainer().decode([String].self)) }
    public func encode(to encoder:Encoder) throws {
        var container = encoder.singleValueContainer(); try container.encode(sorted { $0.utf8.lexicographicallyPrecedes($1.utf8) })
    }
}
public func == (lhs:GitPathSet,rhs:Set<String>)->Bool { lhs == GitPathSet(rhs) }
public func == (lhs:Set<String>,rhs:GitPathSet)->Bool { GitPathSet(lhs) == rhs }
public func != (lhs:GitPathSet,rhs:Set<String>)->Bool { !(lhs == rhs) }
public func != (lhs:Set<String>,rhs:GitPathSet)->Bool { !(lhs == rhs) }

/// An ASCII identity at the SwiftUI/AppKit table boundary. Raw Git path text is
/// kept separately for captions and operations, including synthetic group IDs.
public enum GitPathRowIdentity {
    private static let prefix = "git-path:"
    public static func encode(_ path:String)->String { prefix + Data(path.utf8).base64EncodedString() }
    public static func decode(_ id:String)->String? {
        guard id.hasPrefix(prefix),let bytes = Data(base64Encoded:String(id.dropFirst(prefix.count))),
              let path = String(data:bytes,encoding:.utf8),encode(path) == id else {return nil}
        return path
    }
    public static func paths<S:Sequence>(_ ids:S)->GitPathSet where S.Element == String { GitPathSet(ids.compactMap(decode)) }
}
