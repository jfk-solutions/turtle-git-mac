import Foundation

/// A read-only patch may contain bytes that cannot be represented in the
/// display encoding. Unedited exports retain original data; edits use the captured codec.
public struct UnifiedDiffDocument: Sendable {
    public let bytes: Data
    public let displayLegacyEncoding:ComparisonTextEncoding
    public let sourceEncoding:ComparisonTextEncoding
    private let retainedEncoding:Bool
    var bytePresentation:UnifiedDiffBytePresentation?
    private static let signatures:[([UInt8],ComparisonTextEncoding,String.Encoding)] = [
        ([0xff,0xfe,0,0],.utf32LE,.utf32LittleEndian),([0,0,0xfe,0xff],.utf32BE,.utf32BigEndian),
        ([0xff,0xfe],.utf16LEBOM,.utf16LittleEndian),([0xfe,0xff],.utf16BEBOM,.utf16BigEndian),([0xef,0xbb,0xbf],.utf8BOM,.utf8)
    ]
    public init(bytes:Data,displayLegacyEncoding:ComparisonTextEncoding = .windows1252,sourceEncoding:ComparisonTextEncoding? = nil) {
        self.bytes=bytes;bytePresentation=nil
        self.displayLegacyEncoding=displayLegacyEncoding.legacyCodePage == nil ? .windows1252:displayLegacyEncoding
        retainedEncoding=sourceEncoding != nil
        self.sourceEncoding=sourceEncoding ?? Self.signatures.first(where:{bytes.starts(with:$0.0)})?.1
            ?? (String(data:bytes,encoding:.utf8) == nil ? self.displayLegacyEncoding:.utf8)
    }
    init(bytes:Data,legacy:ComparisonTextEncoding,encoding:ComparisonTextEncoding,presentation:UnifiedDiffBytePresentation) {
        self.bytes=bytes;displayLegacyEncoding=legacy;sourceEncoding=encoding;retainedEncoding=true;bytePresentation=presentation
    }
    public var displayText:String {
        if let bytePresentation {return bytePresentation.text}
        if retainedEncoding {
            let body=bytes.starts(with:sourceEncoding.patchBOM) ? Data(bytes.dropFirst(sourceEncoding.patchBOM.count)):bytes
            if let text=sourceEncoding.decodePatchPayload(body) {return text}
        }
        // BOMs precede line-local UTF8/legacy display. Prefixing a sentinel keeps
        // a real leading FEFF character after the one file BOM is removed.
        for (signature,_,encoding) in Self.signatures where bytes.starts(with:signature) {
            let body=Data(bytes.dropFirst(signature.count)),width=encoding == .utf32LittleEndian || encoding == .utf32BigEndian ? 4:encoding == .utf8 ? 1:2
            if body.count % width == 0,let prefix="x".data(using:encoding),var text=String(data:prefix+body,encoding:encoding),text.first == "x" {text.removeFirst();return text}
            return String(decoding:bytes,as:UTF8.self)
        }
        return GitPatch.displayText(bytes,displayLegacyEncoding:displayLegacyEncoding)
    }
    public func encodedEdits(_ text:String) throws ->Data {
        var buffer=UnifiedDiffEditBuffer(document:self);buffer.replaceText(text);return try buffer.snapshot().bytes
    }
    public func recording(_ bytes:Data)->Self {
        if bytes == self.bytes {return self}
        return Self(bytes:bytes,displayLegacyEncoding:displayLegacyEncoding,sourceEncoding:sourceEncoding)
    }
    public func write(to url:URL) throws {try bytes.write(to:url,options:.atomic)}
}

public enum UnifiedDiffViewerChoice: Equatable, Sendable {
    case builtin, external(URL)
}
public enum UnifiedDiffViewerFailure: LocalizedError {
    case application
    public var errorDescription: String? { "Choose an application bundle or executable in Settings → Unified Diff Viewer." }
}

/// AppUtils::StartUnifiedDiffViewer inverts enabled/disabled external selection
/// for Shift. A saved disabled viewer remains available for that alternate use.
public struct UnifiedDiffViewerPreferences: Equatable, Sendable {
    public var enabled: Bool
    public var applicationPath: String
    public var bookmark: Data?
    public var arguments: String
    public init(enabled: Bool = false, applicationPath: String = "", bookmark: Data? = nil, arguments: String = "") {
        self.enabled = enabled; self.applicationPath = applicationPath; self.bookmark = bookmark; self.arguments = arguments
    }
    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.enabled == rhs.enabled && lhs.applicationPath.utf8.elementsEqual(rhs.applicationPath.utf8) &&
        lhs.arguments.utf8.elementsEqual(rhs.arguments.utf8) && lhs.bookmark == rhs.bookmark
    }
    public var program: DiffToolProgram {
        var value = DiffToolProgram(); value.enabled = true; value.applicationPath = applicationPath; value.bookmark = bookmark; value.arguments = arguments; return value
    }
    public var argumentsValid: Bool { (try? DiffToolProgram.argumentTokens(arguments)) != nil }
    private var applicationValid: Bool { var value = program; value.arguments = ""; return value.valid }
    public var valid: Bool { !enabled || applicationValid && argumentsValid }
    public func expandedArguments(file: URL, title: String) throws -> [String] {
        guard file.isFileURL, !file.path.contains("\0"), !title.contains("\0") else { throw DiffToolFailure.arguments }
        return try program.expandedArguments(values: ["1": file.path, "title": title], files: ["1"])
    }
    public func choice(alternate: Bool = false) throws -> UnifiedDiffViewerChoice {
        guard !applicationPath.isEmpty, enabled != alternate else { return .builtin }
        guard applicationValid else { throw UnifiedDiffViewerFailure.application }
        guard argumentsValid else { throw DiffToolFailure.arguments }
        return .external(URL(fileURLWithPath: applicationPath, isDirectory: program.isApplicationBundle))
    }
    public static func load(from defaults: UserDefaults = .standard) -> Self {
        Self(enabled: defaults.bool(forKey: "TurtleGit.UnifiedDiffViewer.Enabled"),
             applicationPath: defaults.string(forKey: "TurtleGit.UnifiedDiffViewer.Application") ?? "",
             bookmark: defaults.data(forKey: "TurtleGit.UnifiedDiffViewer.Bookmark"),
             arguments: defaults.string(forKey: "TurtleGit.UnifiedDiffViewer.Arguments") ?? "")
    }
    public func save(to defaults: UserDefaults = .standard) {
        defaults.set(enabled, forKey: "TurtleGit.UnifiedDiffViewer.Enabled")
        defaults.set(applicationPath, forKey: "TurtleGit.UnifiedDiffViewer.Application")
        defaults.set(bookmark, forKey: "TurtleGit.UnifiedDiffViewer.Bookmark")
        defaults.set(arguments, forKey: "TurtleGit.UnifiedDiffViewer.Arguments")
    }
}

/// An exact byte copy for external viewers, kept until application termination.
/// It never overwrites a repository file or an earlier preview.
public struct UnifiedDiffPreview: Sendable {
    public let directory: URL
    public let file: URL
    public static func create(_ bytes: Data) throws -> Self {
        let manager = FileManager.default
        let directory = try TurtleGitTemporaryStorage.root.appendingPathComponent("TurtleGitUnifiedDiffPreview-" + UUID().uuidString, isDirectory: true)
        try manager.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        do {
            let file = directory.appendingPathComponent("diff.patch")
            try bytes.write(to: file, options: .withoutOverwriting)
            try manager.setAttributes([.posixPermissions: 0o444], ofItemAtPath: file.path)
            return Self(directory: directory, file: file)
        } catch { try? manager.removeItem(at: directory); throw error }
    }
    public func discard() { try? FileManager.default.removeItem(at: directory) }
}

/// Editable UDiff backing bytes. The edit tape retains removed byte fragments,
/// so native coalesced Undo/Redo can restore opaque data as well as visible text.
public struct UnifiedDiffEditBuffer:Sendable {
    private struct Edit:Sendable {
        let offset:Int,removed:[UnifiedDiffByteSpan],inserted:[UnifiedDiffByteSpan]
    }
    private var source:UnifiedDiffDocument
    private var presentation:UnifiedDiffBytePresentation
    private var edits:[Edit]=[],keys:[Int],cursor=0
    public private(set) var text:String
    public init(document:UnifiedDiffDocument) {
        let shown=document.displayText
        source=document;text=shown
        presentation=document.bytePresentation ?? UnifiedDiffBytePresentation(document:document,text:shown)
        keys=[Data(shown.utf8).hashValue]
    }
    public mutating func replaceText(_ next:String) {
        guard !GitReferenceName.equal(text,next) else{return}
        let key=Data(next.utf8).hashValue
        // A text control can undo an entire typing group in one notification.
        // Replay captured fragments, never infer their original bytes anew.
        for target in keys.indices.filter({keys[$0]==key}).sorted(by:{abs($0-cursor)<abs($1-cursor)}) {
            var pieces=presentation.pieces,position=cursor,valid=true
            while position>target {
                let edit=edits[position-1]
                guard let replaced=Self.replacing(pieces,offset:edit.offset,length:Self.length(edit.inserted),with:edit.removed) else{valid=false;break}
                pieces=replaced.pieces;position-=1
            }
            while valid,position<target {
                let edit=edits[position]
                guard let replaced=Self.replacing(pieces,offset:edit.offset,length:Self.length(edit.removed),with:edit.inserted) else{valid=false;break}
                pieces=replaced.pieces;position+=1
            }
            if valid,GitReferenceName.equal(pieces.map(\.text).joined(),next) {
                presentation.pieces=pieces;cursor=target;text=next;return
            }
        }
        let before=text.unicodeScalars,after=next.unicodeScalars
        var a=before.startIndex,b=after.startIndex
        while a<before.endIndex,b<after.endIndex,before[a].value==after[b].value {before.formIndex(after:&a);after.formIndex(after:&b)}
        var endA=before.endIndex,endB=after.endIndex
        while endA>a,endB>b {
            let pa=before.index(before:endA),pb=after.index(before:endB)
            guard before[pa].value==after[pb].value else{break};endA=pa;endB=pb
        }
        var offset=a.utf16Offset(in:text),length=endA.utf16Offset(in:text)-offset
        var inserted=[UnifiedDiffByteSpan(text:String(after[b..<endB]),bytes:nil,mapping:.codec(insertionEncoding(at:offset)))]
        var replacement=Self.replacing(presentation.pieces,offset:offset,length:length,with:inserted)
        if replacement==nil {
            // Some regional codecs encode a multi-scalar cluster as one unit.
            // Re-encode the touched spans together, retaining all outside bytes.
            let expanded=expandedReplacement(offset:offset,length:length,replacement:String(after[b..<endB]))
            offset=expanded.offset;length=expanded.length;inserted=expanded.inserted
            replacement=Self.replacing(presentation.pieces,offset:offset,length:length,with:inserted)
        }
        guard let replacement else{return} // Expanded boundaries always align.
        if cursor<edits.count {edits.removeSubrange(cursor...);keys.removeSubrange((cursor+1)...)}
        edits.append(Edit(offset:offset,removed:replacement.removed,inserted:inserted));keys.append(key);cursor+=1
        presentation.pieces=replacement.pieces;text=next
    }
    public func snapshot() throws ->UnifiedDiffDocument {
        var bytes=presentation.prefix,pieces:[UnifiedDiffByteSpan]=[]
        for piece in presentation.pieces {
            let encoded=try piece.encoded();bytes.append(encoded)
            pieces.append(UnifiedDiffByteSpan(text:piece.text,bytes:encoded,mapping:piece.mapping))
        }
        return UnifiedDiffDocument(bytes:bytes,legacy:source.displayLegacyEncoding,encoding:source.sourceEncoding,
                                   presentation:UnifiedDiffBytePresentation(prefix:presentation.prefix,pieces:pieces))
    }
    /// Applies a source-bound line transaction without re-encoding moved spans.
    /// Retain value copies before/after this call for native command Undo/Redo,
    /// including transactions whose distinct bytes have identical visible text.
    @discardableResult public mutating func apply(_ plan:PatchLineEditPlan) throws -> Bool {
        guard GitReferenceName.equal(text,plan.originalText) else {throw FileComparisonEditFailure.encoding}
        guard plan.hasReplacement else {return false}
        let total=text.utf16.count
        var boundaries=Set([0,total])
        for segment in plan.segments {
            if case let .source(range)=segment {
                guard range.location>=0,range.length>=0,range.location<=total,range.length<=total-range.location else {throw FileComparisonEditFailure.encoding}
                boundaries.insert(range.location);boundaries.insert(NSMaxRange(range))
            }
        }
        // Partition once in source order. Repeated or reordered source receipts
        // reuse the same retained byte fragments, never re-encode long prefixes.
        let ordered=boundaries.sorted()
        var fragments:[UnifiedDiffByteSpan]=[],boundaryIndex:[Int:Int]=[:],position=0,nextBoundary=0
        for piece in presentation.pieces {
            let end=position+piece.length
            var offsets=[0]
            while nextBoundary<ordered.count,ordered[nextBoundary]<=end {
                let value=ordered[nextBoundary]
                if value>=position {offsets.append(value-position)}
                nextBoundary+=1
            }
            offsets.append(piece.length);offsets=Array(Set(offsets)).sorted()
            guard let parts=piece.partition(at:offsets) else {throw FileComparisonEditFailure.encoding}
            for (partIndex,part) in parts.enumerated() {
                boundaryIndex[position+offsets[partIndex]]=fragments.count
                fragments.append(part)
            }
            position=end;boundaryIndex[position]=fragments.count
        }
        boundaryIndex[total]=fragments.count
        if total==0 {boundaryIndex[0]=0}
        var inserted:[UnifiedDiffByteSpan]=[]
        for segment in plan.segments {
            switch segment {
            case let .source(range):
                guard let start=boundaryIndex[range.location],let end=boundaryIndex[NSMaxRange(range)] else {throw FileComparisonEditFailure.encoding}
                inserted.append(contentsOf:fragments[start..<end])
            case let .inserted(value):
                // Retain the document codec without forcing a draft to be
                // encodable yet. Ordinary typing and column paste share the
                // existing Save-only validation boundary for regional codecs.
                inserted.append(UnifiedDiffByteSpan(text:value,bytes:nil,mapping:.codec(insertionEncoding(at:0))))
            }
        }
        guard GitReferenceName.equal(inserted.map(\.text).joined(),plan.resultText) else {throw FileComparisonEditFailure.encoding}
        func encoded(_ pieces:[UnifiedDiffByteSpan])->Data? {
            var result=Data()
            for piece in pieces {guard let bytes=try? piece.encoded() else {return nil};result.append(bytes)}
            return result
        }
        // A regional-codepage draft can contain newly typed characters which
        // are not yet encodable. Keep editing/Undo available (including deleting
        // those characters); Save remains the encoding-validation boundary.
        if let old=encoded(presentation.pieces),let new=encoded(inserted),old==new {return false}
        if cursor<edits.count {edits.removeSubrange(cursor...);keys.removeSubrange((cursor+1)...)}
        edits.append(Edit(offset:0,removed:presentation.pieces,inserted:inserted))
        keys.append(Data(plan.resultText.utf8).hashValue);cursor+=1
        presentation.pieces=inserted;text=plan.resultText
        return true
    }
    public func isModified() throws -> Bool {try snapshot().bytes != source.bytes}
    public mutating func markSaved(_ document:UnifiedDiffDocument) {
        guard GitReferenceName.equal(document.displayText,text) else{return}
        source=document;presentation=document.bytePresentation ?? UnifiedDiffBytePresentation(document:document,text:text)
    }
    private func insertionEncoding(at offset:Int)->ComparisonTextEncoding {
        var position=0
        for piece in presentation.pieces {
            if offset<position+piece.length {
                if case let .codec(encoding)=piece.mapping {return encoding}
                return presentation.prefix.isEmpty && source.sourceEncoding.hasBOM ? .utf8:source.sourceEncoding
            }
            position+=piece.length
        }
        if let last=presentation.pieces.last,case let .codec(encoding)=last.mapping {return encoding}
        return presentation.prefix.isEmpty && source.sourceEncoding.hasBOM ? .utf8:source.sourceEncoding
    }
    private static func length(_ pieces:[UnifiedDiffByteSpan])->Int {pieces.reduce(0){$0+$1.length}}
    private static func split(_ pieces:[UnifiedDiffByteSpan],at offset:Int)->([UnifiedDiffByteSpan],[UnifiedDiffByteSpan])? {
        guard offset>=0 else{return nil}
        var left:[UnifiedDiffByteSpan]=[],position=0
        for (index,piece) in pieces.enumerated() {
            if offset==position {return (left,Array(pieces[index...]))}
            if offset<position+piece.length {
                guard let parts=piece.split(at:offset-position) else{return nil}
                if !parts.0.text.isEmpty {left.append(parts.0)}
                var right=[parts.1];right.append(contentsOf:pieces.dropFirst(index+1));return (left,right)
            }
            left.append(piece);position+=piece.length
        }
        return offset==position ? (left,[]):nil
    }
    private static func replacing(_ pieces:[UnifiedDiffByteSpan],offset:Int,length:Int,with inserted:[UnifiedDiffByteSpan])->(pieces:[UnifiedDiffByteSpan],removed:[UnifiedDiffByteSpan])? {
        guard let (left,rest)=split(pieces,at:offset),let (removed,right)=split(rest,at:length) else{return nil}
        return (left+inserted.filter{!$0.text.isEmpty}+right,removed)
    }
    private func expandedReplacement(offset:Int,length:Int,replacement:String)->(offset:Int,length:Int,inserted:[UnifiedDiffByteSpan]) {
        var start=0,end=Self.length(presentation.pieces),position=0,first=0,last=presentation.pieces.count-1
        for (index,piece) in presentation.pieces.enumerated() {
            if position<=offset,offset<position+piece.length {start=position;first=index}
            if position<offset+length,offset+length<=position+piece.length {end=position+piece.length;last=index;break}
            position+=piece.length
        }
        let touched=Array(presentation.pieces[first...last]),shown=touched.map(\.text).joined()
        let prefix=UnifiedDiffByteSpan.substring(shown,from:0,to:offset-start) ?? ""
        let suffix=UnifiedDiffByteSpan.substring(shown,from:offset+length-start,to:shown.utf16.count) ?? ""
        let mapping:UnifiedDiffByteSpan.Mapping
        if let one=touched.first?.mapping,case .codec=one,touched.allSatisfy({$0.mapping==one}) {mapping=one}
        else {mapping = .unmapped}
        return (start,end-start,[UnifiedDiffByteSpan(text:prefix+replacement+suffix,bytes:nil,mapping:mapping)])
    }
}

struct UnifiedDiffBytePresentation:Sendable {
    let prefix:Data
    var pieces:[UnifiedDiffByteSpan]
    var text:String {pieces.map(\.text).joined()}
    init(prefix:Data,pieces:[UnifiedDiffByteSpan]) {self.prefix=prefix;self.pieces=pieces}
    init(document:UnifiedDiffDocument,text:String) {
        let bom=document.sourceEncoding.patchBOM
        let hasBOM = !bom.isEmpty && document.bytes.starts(with:bom)
        let body=hasBOM ? Data(document.bytes.dropFirst(bom.count)):document.bytes
        if let decoded=document.sourceEncoding.decodePatchPayload(body),GitReferenceName.equal(decoded,text) {
            prefix=hasBOM ? bom:Data();pieces=[.init(text:text,bytes:body,mapping:.codec(document.sourceEncoding))];return
        }
        prefix=Data()
        if document.sourceEncoding.hasBOM,GitReferenceName.equal(String(decoding:document.bytes,as:UTF8.self),text) {
            pieces=[.init(text:text,bytes:document.bytes,mapping:.lossyUTF8)];return
        }
        pieces=[];var start=document.bytes.startIndex
        func append(_ bytes:Data) {
            let shown=GitPatch.displayText(bytes,displayLegacyEncoding:document.displayLegacyEncoding),mapping:UnifiedDiffByteSpan.Mapping
            if let utf8=String(data:bytes,encoding:.utf8),GitReferenceName.equal(utf8,shown) {
                let encoding=bytes.allSatisfy({$0<128}) ? document.sourceEncoding:ComparisonTextEncoding.utf8
                mapping = .codec(encoding)
            } else if let regional=document.displayLegacyEncoding.decodePatchPayload(bytes),GitReferenceName.equal(regional,shown) {mapping = .codec(document.displayLegacyEncoding)}
            else if GitReferenceName.equal(String(String.UnicodeScalarView(bytes.map{UnicodeScalar($0)})),shown) {mapping = .carrier}
            else {mapping = .unmapped}
            pieces.append(.init(text:shown,bytes:bytes,mapping:mapping))
        }
        for index in document.bytes.indices where document.bytes[index]==10 {append(Data(document.bytes[start...index]));start=document.bytes.index(after:index)}
        if start<document.bytes.endIndex {append(Data(document.bytes[start...]))}
        if !GitReferenceName.equal(pieces.map(\.text).joined(),text) {pieces=[.init(text:text,bytes:document.bytes,mapping:.unmapped)]}
    }
}

struct UnifiedDiffByteSpan:Sendable {
    enum Mapping:Equatable,Sendable {case codec(ComparisonTextEncoding),carrier,lossyUTF8,unmapped}
    let text:String,bytes:Data?,mapping:Mapping
    var length:Int {text.utf16.count}
    func encoded() throws ->Data {
        if let bytes {return bytes}
        if case let .codec(encoding)=mapping {return try encoding.encodePatchPayload(text)}
        throw FileComparisonEditFailure.encoding
    }
    static func substring(_ text:String,from:Int,to:Int)->String? {
        guard from>=0,to>=from,to<=text.utf16.count else{return nil}
        let units=text.utf16
        for offset in [from,to] where offset<units.count {
            let value=units[units.index(units.startIndex,offsetBy:offset)]
            if (0xdc00...0xdfff).contains(value) {return nil}
        }
        return String(text.unicodeScalars[String.Index(utf16Offset:from,in:text)..<String.Index(utf16Offset:to,in:text)])
    }
    /// Cuts requested source boundaries in one forward byte pass. Codec
    /// verification is chunk-local; an indivisible regional cluster fails closed.
    func partition(at offsets:[Int])->[Self]? {
        guard offsets.first==0,offsets.last==length else {return nil}
        if offsets.count==1 {return []}
        if offsets.count==2 {return [self]}
        let units=Array(text.utf16),shown=text as NSString
        guard offsets.allSatisfy({$0>=0 && $0<=units.count && ($0==units.count || !(0xdc00...0xdfff).contains(units[$0]))}) else {return nil}
        if case .unmapped=mapping,offsets.count>2 {return nil}
        let lossy:[Int:Int]?
        if case .lossyUTF8=mapping,let bytes {lossy=Self.lossyUTF8Offsets(bytes)} else {lossy=nil}
        var result:[Self]=[],byteOffset=0
        for i in 0..<(offsets.count-1) {
            let start=offsets[i],end=offsets[i+1]
            let value=shown.substring(with:NSRange(location:start,length:end-start))
            let payload:Data?
            if let bytes {
                let count:Int
                switch mapping {
                case let .codec(encoding):
                    guard let encoded=try? encoding.encodePatchPayload(value),byteOffset+encoded.count<=bytes.count,
                          bytes.subdata(in:byteOffset..<(byteOffset+encoded.count))==encoded else {return nil}
                    count=encoded.count
                case .carrier:count=value.unicodeScalars.count
                case .lossyUTF8:
                    guard let lo=lossy?[start],let hi=lossy?[end],lo==byteOffset else {return nil};count=hi-lo
                case .unmapped:count=bytes.count
                }
                guard count<=bytes.count-byteOffset else {return nil}
                payload=bytes.subdata(in:byteOffset..<(byteOffset+count));byteOffset+=count
            } else {payload=nil}
            result.append(.init(text:value,bytes:payload,mapping:mapping))
        }
        if let bytes,byteOffset != bytes.count {return nil}
        return result
    }
    func split(at offset:Int)->(Self,Self)? {
        guard let a=Self.substring(text,from:0,to:offset),let b=Self.substring(text,from:offset,to:length) else{return nil}
        guard let bytes else{return (.init(text:a,bytes:nil,mapping:mapping),.init(text:b,bytes:nil,mapping:mapping))}
        let position:Int
        switch mapping {
        case let .codec(encoding):guard let prefix=try? encoding.encodePatchPayload(a),bytes.starts(with:prefix) else{return nil};position=prefix.count
        case .carrier:position=a.unicodeScalars.count
        case .lossyUTF8:guard let boundary=Self.lossyUTF8Boundary(bytes,utf16:offset) else{return nil};position=boundary
        case .unmapped:return nil
        }
        return (.init(text:a,bytes:Data(bytes.prefix(position)),mapping:mapping),.init(text:b,bytes:Data(bytes.dropFirst(position)),mapping:mapping))
    }
    // Unicode maximal-subpart boundaries, matching String(decoding:as:UTF8.self).
    // Invalid bytes remain in the fragment they projected, including truncated
    // sequences and malformed BOMs; U+FFFD is never used to regenerate them.
    private static func lossyUTF8Boundary(_ bytes:Data,utf16 target:Int)->Int? {lossyUTF8Offsets(bytes)[target]}
    private static func lossyUTF8Offsets(_ bytes:Data)->[Int:Int] {
        var index=0,units=0,result=[0:0]
        while index<bytes.count {
            result[units]=index
            let lead=bytes[bytes.startIndex+index],expected:Int
            if lead<0x80 {index+=1;units+=1;continue}
            if (0xc2...0xdf).contains(lead) {expected=2}
            else if (0xe0...0xef).contains(lead) {expected=3}
            else if (0xf0...0xf4).contains(lead) {expected=4}
            else {index+=1;units+=1;continue}
            var count=1
            while count<expected,index+count<bytes.count {
                let byte=bytes[bytes.startIndex+index+count]
                guard (0x80...0xbf).contains(byte) else{break}
                if count==1, (lead==0xe0 && byte<0xa0 || lead==0xed && byte>0x9f || lead==0xf0 && byte<0x90 || lead==0xf4 && byte>0x8f) {break}
                count+=1
            }
            units += count==expected && expected==4 ? 2:1;index+=count
        }
        result[units]=index;return result
    }
}
