import XCTest
@testable import TurtleGitCore

final class BundledComparisonToolsTests: XCTestCase {
    func document(_ a: Data, _ b: Data, absent: Bool = false) -> FileComparisonDocument {
        FileComparisonDocument(base:.init(path:"old.dll",revision:.workingTree,bytes:a,mode:"100644",isDeleted:absent),destination:.init(path:"new.dll",revision:.workingTree,bytes:b,mode:"100644"))
    }
    func put(_ value: UInt64, in data: inout Data, at: Int, count: Int = 4, big: Bool = false) {
        for index in 0..<count { data[at + index] = UInt8(truncatingIfNeeded:value >> ((big ? count - index - 1 : index) * 8)) }
    }
    func library(version: UInt64 = 0x010203, big: Bool = false, wide: Bool = true) -> Data {
        let header = wide ? 32 : 28
        var data = Data(repeating:0,count:header + 24)
        put(wide ? 0xfeedfacf : 0xfeedface,in:&data,at:0,big:big)
        put(0x100000c,in:&data,at:4,big:big); put(6,in:&data,at:12,big:big)
        put(1,in:&data,at:16,big:big); put(24,in:&data,at:20,big:big)
        put(0xd,in:&data,at:header,big:big); put(24,in:&data,at:header+4,big:big); put(version,in:&data,at:header+16,big:big)
        return data
    }
    func executable(wide: Bool = false) -> Data {
        var data = Data(repeating:0,count:0x600)
        put(0x5a4d,in:&data,at:0,count:2); put(0x80,in:&data,at:0x3c); put(0x4550,in:&data,at:0x80)
        put(1,in:&data,at:0x86,count:2); let optionalSize = wide ? 240 : 224
        put(UInt64(optionalSize),in:&data,at:0x94,count:2); put(wide ? 0x20b : 0x10b,in:&data,at:0x98,count:2)
        let directory=0x98+(wide ? 112 : 96), section=0x98+optionalSize
        put(16,in:&data,at:directory-4); put(0x1000,in:&data,at:directory+16); put(0x300,in:&data,at:directory+20)
        put(0x1000,in:&data,at:section+12); put(0x400,in:&data,at:section+16); put(0x200,in:&data,at:section+20)
        // RT_VERSION -> name -> language -> data entry, relative to .rsrc.
        for (at,key,target) in [(0x200,16,0x80000020),(0x220,1,0x80000040),(0x240,1033,0x60)] {
            put(1,in:&data,at:at+14,count:2); put(UInt64(key),in:&data,at:at+16); put(UInt64(target),in:&data,at:at+20)
        }
        put(0x1100,in:&data,at:0x260); put(92,in:&data,at:0x264)
        put(92,in:&data,at:0x300,count:2); put(52,in:&data,at:0x302,count:2)
        for (index,character) in Array("VS_VERSION_INFO".utf16).enumerated() { put(UInt64(character),in:&data,at:0x306+index*2,count:2) }
        put(0xfeef04bd,in:&data,at:0x328); put(0x00010002,in:&data,at:0x330); put(0x00030004,in:&data,at:0x334)
        return data
    }
    func testSourceBinaryEqualSizeContentAndAbsentReports() throws {
        let a=Data("abc".utf8)
        let equal=try BinaryComparisonReport(document(a,a)); XCTAssertTrue(equal.identical); XCTAssertTrue(equal.text.contains("Files are identical")); XCTAssertTrue(equal.text.contains("File sizes: 3 bytes"))
        let content=try BinaryComparisonReport(document(a,Data("abd".utf8))); XCTAssertFalse(content.identical); XCTAssertTrue(content.text.contains("File content differs!"))
        let size=try BinaryComparisonReport(document(a,Data())); XCTAssertFalse(size.identical); XCTAssertTrue(size.text.contains("Size: 0 bytes"))
        XCTAssertFalse(try BinaryComparisonReport(document(Data(),Data(),absent:true)).identical)
        let token=OperationCancellation(); token.cancel(); XCTAssertThrowsError(try BinaryComparisonReport(document(a,a),cancellation:token))
        let large=Data(repeating:0x80,count:2_100_000); var changed=large; changed[2_000_000]=0
        XCTAssertFalse(try BinaryComparisonReport(document(large,changed)).identical)
    }
    func testPE32AndPE64VersionDirectoryAndMalformedInputs() throws {
        for wide in [false,true] {
            let data=executable(wide:wide); XCTAssertEqual(BinaryFileVersion.read(data),"1.2.3.4")
            for size in [0,2,64,0x100,0x220,0x350] { XCTAssertNil(BinaryFileVersion.read(data.prefix(size))) }
            var invalid=data; put(0x7fffffff,in:&invalid,at:0x214); XCTAssertNil(BinaryFileVersion.read(invalid))
            invalid=data; put(0x7fffffff,in:&invalid,at:0x260); XCTAssertNil(BinaryFileVersion.read(invalid))
            invalid=data; put(0,in:&invalid,at:0x328); XCTAssertNil(BinaryFileVersion.read(invalid))
        }
        let old=executable(); var new=old; put(0x00050006,in:&new,at:0x334)
        let report=try BinaryComparisonReport(document(old,new)); XCTAssertFalse(report.identical); XCTAssertTrue(report.text.contains("Version: 1.2.5.6"))
    }
    func testMachOEndianWidthsUniversalSlicesAndMalformedBounds() {
        for big in [false,true] { for wide in [false,true] { XCTAssertEqual(BinaryFileVersion.read(library(big:big,wide:wide)),"1.2.3") } }
        let thin=library(); var fat=Data(repeating:0,count:64)
        put(0xcafebabe,in:&fat,at:0,big:true); put(1,in:&fat,at:4,big:true); put(0x100000c,in:&fat,at:8,big:true); put(64,in:&fat,at:16,big:true); put(UInt64(thin.count),in:&fat,at:20,big:true); fat += thin
        XCTAssertEqual(BinaryFileVersion.read(fat),"arm64: 1.2.3")
        var invalid=thin; put(0xffffffff,in:&invalid,at:20); XCTAssertNil(BinaryFileVersion.read(invalid))
        invalid=fat; put(0xffffffff,in:&invalid,at:16,big:true); XCTAssertNil(BinaryFileVersion.read(invalid))
        XCTAssertNil(BinaryFileVersion.read(Data("ordinary binary".utf8)))
    }
    func testNotebookLiteralEscapingSourceButtonAndPrivateExactFiles() throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("Notebook QA 雪 "+UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true); defer { try? FileManager.default.removeItem(at:root) }
        let source=try NotebookComparisonPreview.source(base:"/a/quote\";Run[\"bad\"]/雪🙂\\\n.nb",destination:"/b.nb")
        XCTAssertTrue(source.contains("ButtonFunction:>(Needs[\"AuthorTools`\"]")); XCTAssertTrue(source.contains("Saveable->False, Editable->False"))
        XCTAssertTrue(source.contains("quote\\\";Run[\\\"bad\\\"]")); XCTAssertTrue(source.contains("\\:96ea\\|01f642\\\\\\:000a")); XCTAssertTrue(source.unicodeScalars.allSatisfy { $0.value < 128 })
        XCTAssertThrowsError(try NotebookComparisonPreview.source(base:"\0",destination:"b"))
        let a=Data([0,0xff,10,32]),b=Data("Notebook[{}]".utf8), preview=try NotebookComparisonPreview.prepare(document(a,b),in:root)
        XCTAssertEqual(try Data(contentsOf:preview.base),a); XCTAssertEqual(try Data(contentsOf:preview.destination),b)
        let permissions=try FileManager.default.attributesOfItem(atPath:preview.notebook.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(permissions?.intValue,0o444)
        XCTAssertTrue(try String(contentsOf:preview.notebook).contains("NotebookDiff")); preview.discard(); XCTAssertFalse(FileManager.default.fileExists(atPath:preview.directory.path))
        let token=OperationCancellation(); token.cancel(); XCTAssertThrowsError(try NotebookComparisonPreview.prepare(document(a,b),in:root,cancellation:token))
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath:root.path).isEmpty)
    }
    func testAllBundledDefaultsMatchingRestorationAndPersistence() throws {
        let suite="TurtleGit.BundledTests."+UUID().uuidString, prefs=UserDefaults(suiteName:suite)!; defer { prefs.removePersistentDomain(forName:suite) }
        var value=DiffToolPreferences.load(from:prefs)
        for tool in BuiltInDiffTool.allCases { for ext in tool.extensions { XCTAssertEqual(try value.selected(base:"a"+ext,destination:"b"+ext)?.builtIn,tool); XCTAssertNil(try value.selected(base:"a"+ext,destination:"b"+ext,alternate:true)) } }
        let ids=Dictionary(uniqueKeysWithValues:value.associations.map { ($0.normalizedPattern,$0.id) })
        value.restoreBundledAssociations(); XCTAssertEqual(Dictionary(uniqueKeysWithValues:value.associations.map { ($0.normalizedPattern,$0.id) }),ids)
        try value.save(to:prefs); XCTAssertEqual(DiffToolPreferences.load(from:prefs),value)
    }
}
