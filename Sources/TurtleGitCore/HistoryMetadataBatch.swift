// SPDX-License-Identifier: GPL-2.0-or-later
import Foundation

public enum HistoryMetadataFailure: LocalizedError {
    case input, framing
    public var errorDescription:String? {
        switch self {
        case .input:return "History metadata requires full commit/object IDs. Refresh the log."
        case .framing:return "Git returned incomplete history metadata. Refresh the log."
        }
    }
}
/// Length/count framing keeps notes, annotations and literal filenames out of protocol delimiters.
enum HistoryMetadataProtocol {
    static func objectID(_ value:String)->Bool {
        (value.utf8.count==40 || value.utf8.count==64) && value.utf8.allSatisfy { (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0) }
    }
    static func sizedLog(_ data:Data) throws -> [String:String] {
        let bytes=Array(data);var cursor=0,result:[String:String]=[:]
        while cursor < bytes.count {
            while cursor < bytes.count, bytes[cursor]==10 { cursor += 1 }
            if cursor==bytes.count { break }
            guard let newline=bytes[cursor...].firstIndex(of:10) else { throw HistoryMetadataFailure.framing }
            let header=String(decoding:bytes[cursor..<newline],as:UTF8.self)
            guard header.hasPrefix("log size "),let size=Int(header.dropFirst(9)),size>=0 else { throw HistoryMetadataFailure.framing }
            cursor=newline+1
            guard size <= bytes.count-cursor,let zero=bytes[cursor..<(cursor+size)].firstIndex(of:0) else { throw HistoryMetadataFailure.framing }
            let hash=String(decoding:bytes[cursor..<zero],as:UTF8.self)
            guard objectID(hash), result[hash]==nil else { throw HistoryMetadataFailure.framing }
            result[hash]=String(decoding:bytes[(zero+1)..<(cursor+size)],as:UTF8.self).trimmingCharacters(in:.newlines)
            cursor += size
        }
        return result
    }
    static func objects(_ data:Data,expected:[String],type:String) throws -> [String:Data] {
        let bytes=Array(data);var cursor=0,result:[String:Data]=[:]
        for hash in expected {
            guard let newline=bytes[cursor...].firstIndex(of:10) else { throw HistoryMetadataFailure.framing }
            let header=String(decoding:bytes[cursor..<newline],as:UTF8.self).split(separator:" ")
            guard header.count==3,header[0].lowercased()==hash.lowercased(),header[1]==type,let size=Int(header[2]),size>=0 else { throw HistoryMetadataFailure.framing }
            cursor=newline+1
            guard size < bytes.count-cursor,bytes[cursor+size]==10 else { throw HistoryMetadataFailure.framing }
            result[hash]=Data(bytes[cursor..<(cursor+size)]);cursor += size+1
        }
        guard cursor==bytes.count else { throw HistoryMetadataFailure.framing };return result
    }
    static func changes(_ data:Data,expected:Set<String>) throws -> [String:[CommitFile]] {
        let tokens=data.split(separator:0,omittingEmptySubsequences:false)
        var result=Dictionary(uniqueKeysWithValues:expected.map { ($0,[CommitFile]()) }),seen=Set<String>(),current:String?,index=0
        while index < tokens.count {
            let token=tokens[index];index += 1
            if token.isEmpty { continue }
            let text=String(decoding:token,as:UTF8.self).trimmingCharacters(in:.newlines)
            if objectID(text) {
                let hash=text.lowercased();guard expected.contains(hash) else { throw HistoryMetadataFailure.framing }
                current=hash;seen.insert(hash);continue
            }
            guard let hash=current,let first=text.utf8.first,"ACDMRTUXB".utf8.contains(first),text.utf8.dropFirst().allSatisfy({ (48...57).contains($0) }) else { throw HistoryMetadataFailure.framing }
            let count=first==82 || first==67 ? 2 : 1
            guard index+count<=tokens.count, tokens[index..<(index+count)].allSatisfy({ !$0.isEmpty }) else { throw HistoryMetadataFailure.framing }
            var record=Data(token);record.append(0)
            for path in tokens[index..<(index+count)] { record.append(contentsOf:path);record.append(0) }
            result[hash,default:[]] += CommitFile.parse(names:record,statistics:Data());index += count
        }
        guard seen==expected else { throw HistoryMetadataFailure.framing };return result
    }
}
extension GitRepository {
    /// A bounded stdin walk preserves every captured parent, including root and octopus commits.
    public func revisionChanges(in entries:[LogEntry],cancellation:OperationCancellation?=nil) throws -> [String:[CommitFile]] {
        try cancellation?.check();var result:[String:[CommitFile]]=[:]
        for start in stride(from:0,to:entries.count,by:128) {
            let batch=Array(entries[start..<min(start+128,entries.count)])
            guard batch.allSatisfy({ HistoryMetadataProtocol.objectID($0.hash) && $0.parents.allSatisfy(HistoryMetadataProtocol.objectID) }) else { throw HistoryMetadataFailure.input }
            let text=batch.map { ([$0.hash]+$0.parents).joined(separator:" ") }.joined(separator:"\n")+"\n"
            let data=try run(["diff-tree","--stdin","--root","--always","-m","--name-status","-z","-r","-M","--no-ext-diff","--no-color","--"],environmentOverrides:["GIT_OPTIONAL_LOCKS":"0"],cancellation:cancellation,input:Data(text.utf8)).stdout
            let values=try HistoryMetadataProtocol.changes(data,expected:Set(batch.map { $0.hash.lowercased() }))
            for entry in batch { result[entry.hash]=values[entry.hash.lowercased()] }
        }
        try cancellation?.check();return result
    }
    public func revisionActions(in entries:[LogEntry],cancellation:OperationCancellation?=nil) throws -> [String:LogRevisionActions] {
        try revisionChanges(in:entries,cancellation:cancellation).mapValues(LogRevisionActions.classify)
    }
    func historyNotes(_ hashes:[String],cancellation:OperationCancellation?) throws -> [String:String] {
        guard hashes.allSatisfy(HistoryMetadataProtocol.objectID) else { throw HistoryMetadataFailure.input }
        var result:[String:String]=[:]
        for start in stride(from:0,to:hashes.count,by:128) {
            let batch=Array(hashes[start..<min(start+128,hashes.count)])
            let data=try run(["show","--encoding=UTF-8","--no-patch","--log-size","--notes","--format=%H%x00%N"]+batch+["--"],environmentOverrides:["GIT_OPTIONAL_LOCKS":"0"],cancellation:cancellation).stdout
            let values=try HistoryMetadataProtocol.sizedLog(data)
            guard batch.allSatisfy({ values[$0.lowercased()] != nil }) else { throw HistoryMetadataFailure.framing }
            for hash in batch { result[hash]=values[hash.lowercased()] }
        }
        return result
    }
    func historyTagObjects(_ hashes:[String],cancellation:OperationCancellation?) throws -> [String:String] {
        guard hashes.allSatisfy(HistoryMetadataProtocol.objectID) else { throw HistoryMetadataFailure.input }
        var result:[String:String]=[:]
        for start in stride(from:0,to:hashes.count,by:128) {
            let batch=Array(hashes[start..<min(start+128,hashes.count)])
            let data=try run(["cat-file","--batch"],environmentOverrides:["GIT_OPTIONAL_LOCKS":"0"],cancellation:cancellation,input:Data((batch.joined(separator:"\n")+"\n").utf8)).stdout
            for (hash,payload) in try HistoryMetadataProtocol.objects(data,expected:batch,type:"tag") {
                var value=String(decoding:payload,as:UTF8.self)
                if value.hasPrefix("object "),let newline=value.firstIndex(of:"\n") {
                    value=String(value[value.index(after:newline)...]);if value.hasPrefix("type commit\n") { value.removeFirst("type commit\n".count) }
                }
                result[hash]=value.trimmingCharacters(in:.newlines)
            }
        }
        return result
    }
}

/// Incremental byte framing for the eleven NUL-terminated Git log fields.
/// UTF-8 is decoded only once a field is complete, including split code points.
final class HistoryRecordStream: @unchecked Sendable {
    private let lock = NSLock()
    private var field = Data(), fields: [String] = [], records: [LogEntry] = []
    private var failed = false
    private var recordBytes = 0
    private(set) var maximumBufferedBytes = 0
    @discardableResult func ingest(_ bytes: Data) -> Int? {
        lock.lock(); defer { lock.unlock() }
        guard !failed else { return nil }
        let before = records.count
        var cursor = bytes.startIndex
        while cursor < bytes.endIndex, let end = bytes[cursor...].firstIndex(of: 0) {
            field.append(bytes[cursor..<end]); recordBytes += end - cursor
            maximumBufferedBytes = max(maximumBufferedBytes, recordBytes)
            fields.append(String(decoding: field, as: UTF8.self)); field.removeAll(keepingCapacity: true)
            cursor = bytes.index(after: end)
            if fields.count == 11 {
                let hash = fields[0].trimmingCharacters(in: .whitespacesAndNewlines)
                guard HistoryMetadataProtocol.objectID(hash) else { failed = true; return nil }
                let parents = fields[1].split(separator: " ").map(String.init)
                var entry = LogEntry(hash: hash, author: fields[2], date: fields[4], subject: fields[5], parents: parents, email: fields[3], message: fields[6], committer: fields[7], committerEmail: fields[8], committerDate: fields[9])
                entry.isBoundary = fields[10] == "-"
                records.append(entry); fields.removeAll(keepingCapacity: true); recordBytes = 0
            }
        }
        if cursor < bytes.endIndex { field.append(bytes[cursor...]); recordBytes += bytes.endIndex - cursor; maximumBufferedBytes = max(maximumBufferedBytes, recordBytes) }
        return records.count > before ? records.count : nil
    }
    func finish() throws -> [LogEntry] {
        lock.lock(); defer { lock.unlock() }
        guard !failed, fields.isEmpty, field.allSatisfy({ [9, 10, 13, 32].contains($0) }) else { throw HistoryMetadataFailure.input }
        return records
    }
}
