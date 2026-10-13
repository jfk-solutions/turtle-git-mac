// SPDX-License-Identifier: GPL-2.0-or-later
import Foundation
import CryptoKit

/// Edits stored metadata only: no file content is read or staged. Git first
/// materializes split indexes; this codec retains paths, OIDs, stat data, stages,
/// intent-to-add and unknown entry flags in versions 2, 3 and 4.
enum GitPropertyIndexMaterialization: Error { case split }
struct GitPropertyIndex {
    struct Entry {
        var fixed: Data
        var flags: UInt16
        var extended: UInt16
        var name: Data
        var encodedName: Data
        var stage: Int { Int((flags >> 12) & 3) }
        var mode: UInt32 { Self.number(fixed, 24) }
        static func number(_ data: Data, _ offset: Int) -> UInt32 { data[offset..<offset+4].reduce(0) { ($0 << 8) | UInt32($1) } }
    }
    var version: UInt32
    var entries: [Entry]
    var extensions: [(String, Data)]
    let hashLength: Int
    static func number(_ data: Data, _ offset: Int, _ count: Int) -> UInt32 { data[offset..<offset+count].reduce(0) { ($0 << 8) | UInt32($1) } }
    static func encoded(_ value: UInt32, _ count: Int) -> Data { Data((0..<count).reversed().map { UInt8(truncatingIfNeeded: value >> ($0 * 8)) }) }
    static func checksum(_ data: Data, length: Int) -> Data { length == 32 ? Data(SHA256.hash(data: data)) : Data(Insecure.SHA1.hash(data: data)) }
    init(_ bytes: Data, hashLength: Int) throws {
        guard [20,32].contains(hashLength), bytes.count >= 12 + hashLength, bytes.prefix(4) == Data("DIRC".utf8) else { throw GitPropertyFailure.indexFormat }
        let end = bytes.count - hashLength
        guard Self.checksum(Data(bytes.prefix(end)), length: hashLength) == bytes.suffix(hashLength) else { throw GitPropertyFailure.indexFormat }
        version = Self.number(bytes,4,4); guard [2,3,4].contains(version) else { throw GitPropertyFailure.indexFormat }
        self.hashLength = hashLength; entries = []; extensions = []
        let count = Int(Self.number(bytes,8,4)); guard count <= end / (42 + hashLength) else { throw GitPropertyFailure.indexFormat }
        var cursor = 12, previous = Data()
        for _ in 0..<count {
            let start = cursor, size = 40 + hashLength
            guard cursor + size + 2 < end else { throw GitPropertyFailure.indexFormat }
            let fixed = Data(bytes[cursor..<cursor+size]); cursor += size
            let flags = UInt16(Self.number(bytes,cursor,2)); cursor += 2
            var extended: UInt16 = 0
            if flags & 0x4000 != 0 {
                guard version >= 3, cursor + 2 < end else { throw GitPropertyFailure.indexFormat }
                extended = UInt16(Self.number(bytes,cursor,2)); cursor += 2
            }
            let nameStart = cursor
            var remove = 0
            if version == 4 {
                var byte = bytes[cursor]; cursor += 1; remove = Int(byte & 127)
                while byte & 128 != 0 {
                    guard cursor < end, remove <= Int.max >> 8 else { throw GitPropertyFailure.indexFormat }
                    byte = bytes[cursor]; cursor += 1; remove = ((remove + 1) << 7) + Int(byte & 127)
                }
                guard remove <= previous.count else { throw GitPropertyFailure.indexFormat }
            }
            guard cursor < end, let nul = bytes[cursor..<end].firstIndex(of: 0) else { throw GitPropertyFailure.indexFormat }
            let suffix = Data(bytes[cursor..<nul])
            let name = version == 4 ? Data(previous.prefix(previous.count - remove)) + suffix : suffix
            cursor = nul + 1
            let encodedName = Data(bytes[nameStart..<cursor])
            if version != 4 { cursor = start + ((cursor - start + 7) / 8) * 8 }
            guard cursor <= end else { throw GitPropertyFailure.indexFormat }
            entries.append(Entry(fixed:fixed,flags:flags,extended:extended,name:name,encodedName:encodedName)); previous = name
        }
        while cursor < end {
            guard cursor + 8 <= end else { throw GitPropertyFailure.indexFormat }
            let name = String(decoding:bytes[cursor..<cursor+4],as:UTF8.self), size = Int(Self.number(bytes,cursor+4,4)); cursor += 8
            guard size <= end - cursor else { throw GitPropertyFailure.indexFormat }
            if name == "link" { throw GitPropertyIndexMaterialization.split }
            extensions.append((name,Data(bytes[cursor..<cursor+size]))); cursor += size
        }
    }
    func propertyEntries() -> [GitPropertyIndexEntry] {
        entries.compactMap { entry in
            guard let path = String(data:entry.name,encoding:.utf8) else { return nil }
            let object = entry.fixed[40..<40+hashLength].map { String(format:"%02x",$0) }.joined()
            return GitPropertyIndexEntry(path:path,pathBytes:entry.name,mode:String(format:"%06o",entry.mode),object:object,stage:entry.stage,assumeUnchanged:entry.flags & 0x8000 != 0,skipWorktree:entry.extended & 0x4000 != 0)
        }
    }
    mutating func apply(_ draft: GitPropertyDraft, selected: [GitPropertyIndexEntry]) throws {
        let targets = Dictionary(uniqueKeysWithValues:selected.map { ($0.pathBytes,$0.stage) })
        let modeEnabled = !selected.contains { $0.mode == "160000" }
        guard !modeEnabled || draft.executable != .on || draft.symlink != .on else { throw GitPropertyFailure.mode }
        var found = Set<Data>()
        for index in entries.indices where targets[entries[index].name] == entries[index].stage {
            found.insert(entries[index].name)
            if draft.assumeUnchanged != .mixed {
                entries[index].flags = draft.assumeUnchanged == .on ? entries[index].flags | 0x8000 : entries[index].flags & ~0x8000
            }
            if draft.skipWorktree != .mixed {
                entries[index].extended = draft.skipWorktree == .on ? entries[index].extended | 0x4000 : entries[index].extended & ~0x4000
            }
            if entries[index].extended != 0 { entries[index].flags |= 0x4000; if version == 2 { version = 3 } }
            else { entries[index].flags &= ~0x4000 }
            if modeEnabled {
                var mode = entries[index].mode
                if draft.executable == .on { mode = 0o100755 }
                else if draft.executable == .off && mode & 0o111 != 0 { mode = 0o100644 }
                if draft.symlink == .on { mode = 0o120000 }
                else if draft.symlink == .off && mode == 0o120000 { mode = 0o100644 }
                entries[index].fixed.replaceSubrange(24..<28,with:Self.encoded(mode,4))
            }
        }
        guard found == Set(targets.keys) else { throw GitPropertyFailure.stale }
        // Entry offsets and cached trees/clean bits are invalidated by metadata
        // changes. Other extension payloads and unresolved stages are retained.
        extensions.removeAll { ["TREE","EOIE","IEOT","FSMN"].contains($0.0) }
    }
    func encoded() -> Data {
        var result = Data("DIRC".utf8) + Self.encoded(version,4) + Self.encoded(UInt32(entries.count),4)
        for entry in entries {
            let start = result.count
            result.append(entry.fixed); result.append(Self.encoded(UInt32(entry.flags),2))
            if entry.flags & 0x4000 != 0 { result.append(Self.encoded(UInt32(entry.extended),2)) }
            result.append(entry.encodedName)
            if version != 4 { result.append(Data(repeating:0,count:(8 - (result.count - start) % 8) % 8)) }
        }
        for (name,data) in extensions { result.append(Data(name.utf8)); result.append(Self.encoded(UInt32(data.count),4)); result.append(data) }
        result.append(Self.checksum(result,length:hashLength)); return result
    }
}
