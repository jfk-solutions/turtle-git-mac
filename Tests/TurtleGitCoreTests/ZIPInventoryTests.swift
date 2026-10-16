import XCTest
@testable import TurtleGitCore

final class ZIPInventoryTests: XCTestCase {
    private func little(_ value: UInt64, _ count: Int) -> Data { Data((0..<count).map { UInt8(truncatingIfNeeded: value >> ($0 * 8)) }) }
    private func record(_ name: [UInt8], size: UInt64 = 3, flags: UInt64 = 0x800, extra: Data = Data(), zip64: Bool = false) -> Data {
        var data = Data()
        for (value, count) in [(UInt64(0x02014b50),4),(20,2),(20,2),(flags,2),(0,2),(0x1883,2),(0x5822,2),(0,4),(zip64 ? 0xffffffff : size,4),(zip64 ? 0xffffffff : size,4),(UInt64(name.count),2),(UInt64(extra.count),2),(0,2),(0,2),(0,2),(0,4),(0,4)] { data += little(value,count) }
        data += Data(name); data += extra; return data
    }
    private func archive(_ rows: [Data], comment: Data = Data(), zip64: Bool = false) -> Data {
        var data = rows.reduce(Data(),+)
        let directorySize = UInt64(data.count)
        if zip64 {
            for (value,count) in [(UInt64(0x06064b50),4),(44,8),(45,2),(45,2),(0,4),(0,4),(UInt64(rows.count),8),(UInt64(rows.count),8),(directorySize,8),(0,8),(0x07064b50,4),(0,4),(directorySize,8),(1,4)] { data += little(value,count) }
        }
        for (value,count) in [(UInt64(0x06054b50),4),(0,2),(0,2),(zip64 ? 0xffff : UInt64(rows.count),2),(zip64 ? 0xffff : UInt64(rows.count),2),(zip64 ? 0xffffffff : directorySize,4),(zip64 ? 0xffffffff : 0,4),(UInt64(comment.count),2)] { data += little(value,count) }
        data += comment; return data
    }
    func testTopLevelNamesSizesDatesAndImplicitExplicitFolders() throws {
        let data = archive([record(Array("a.txt".utf8)),record(Array("folder/nested.txt".utf8)),record(Array("folder/".utf8)),record(Array("雪.zip".utf8),size:17)])
        let value = try ZIPInventory(data)
        XCTAssertEqual(value.items.map(\.name),["a.txt","folder","雪.zip"])
        XCTAssertEqual(value.items.map(\.size),[3,0,17]); XCTAssertEqual(value.items.map(\.directory),[false,true,false])
        XCTAssertEqual(value.items[0].modified,"2024-01-02 03:04:06")
        XCTAssertTrue(try value.text(title:"archive.zip").hasPrefix("archive.zip\n\na.txt")); XCTAssertTrue(try value.text(title:"archive.zip").hasSuffix("\n\n3 items\n"))
    }
    func testLegacyCP437UnicodeAndLiteralUnsafeNames() throws {
        let value = try ZIPInventory(archive([record([99,97,102,130,46,116,120,116],flags:0),record(Array("../outside".utf8)),record(Array("line\nname.txt".utf8))]))
        XCTAssertEqual(value.items.map(\.name),["café.txt","..","line\nname.txt"])
        XCTAssertTrue(try value.text(title:"a").contains("line\\nname.txt"))
        XCTAssertThrowsError(try ZIPInventory(archive([record([0xff],flags:0x800)])))
        XCTAssertThrowsError(try ZIPInventory(archive([record([0],flags:0)])))
    }
    func testZIP64DirectoryAndMemberSizes() throws {
        var extra = little(1,2) + little(16,2); extra += little(5_000_000_000,8); extra += little(4,8)
        let value = try ZIPInventory(archive([record(Array("large.bin".utf8),extra:extra,zip64:true)],zip64:true))
        XCTAssertEqual(value.items.first?.size,5_000_000_000)
        XCTAssertThrowsError(try ZIPInventory(archive([record(Array("missing-extra".utf8),zip64:true)])))
    }
    func testEmptyArchiveCommentAndTruncatedDirectory() throws {
        XCTAssertTrue(try ZIPInventory(archive([])).items.isEmpty)
        let comment = Data([0x50,0x4b,0x05,0x06] + Array(repeating:0,count:25))
        XCTAssertEqual(try ZIPInventory(archive([record(Array("a".utf8))],comment:comment)).items.count,1)
        let data = archive([record(Array("a".utf8))])
        for length in [0,1,10,data.count-1] { XCTAssertThrowsError(try ZIPInventory(data.prefix(length))) }
        var corrupt = data; corrupt[0] = 0; XCTAssertThrowsError(try ZIPInventory(corrupt))
    }
    func testMultipartBoundsAndCancellation() throws {
        var multipart = archive([]); multipart[4] = 1; XCTAssertThrowsError(try ZIPInventory(multipart))
        var overflow = archive([]); overflow.replaceSubrange(16..<20,with:little(0xfffffffe,4)); XCTAssertThrowsError(try ZIPInventory(overflow))
        let token = OperationCancellation(); token.cancel(); XCTAssertThrowsError(try ZIPInventory(archive([]),cancellation:token))
        let data = archive([record(Array("a".utf8))],zip64:true)
        var huge = data; let at = record(Array("a".utf8)).count
        huge.replaceSubrange(at+24..<at+32,with:little(100_001,8)); huge.replaceSubrange(at+32..<at+40,with:little(100_001,8))
        XCTAssertThrowsError(try ZIPInventory(huge))
    }
    func testReadOnlyDocumentsNeverRetargetArchiveWrites() throws {
        let bytes = archive([record(Array("a".utf8))])
        let content = ComparisonFileContent(path:"file.zip",revision:.workingTree,bytes:bytes,mode:"100644")
        let original = FileComparisonDocument(base:content,destination:content), inventory = try original.zipInventories()
        XCTAssertEqual(original.destination.bytes,bytes); XCTAssertEqual(inventory.destination.path,"file.zip.inventory.txt")
        XCTAssertNil(inventory.destination.mode); XCTAssertTrue(inventory.destination.text?.contains("1 items") == true)
        let drafts = FileComparisonDrafts(inventory); XCTAssertFalse(drafts.canEdit(base:true)); XCTAssertFalse(drafts.canEdit(base:false))
    }
    func testBundledDefaultsLegacyPreferencesShiftAndMergeRefusal() throws {
        let suite = "TurtleGit.ZIPTests."+UUID().uuidString, defaults=UserDefaults(suiteName:suite)!
        defer { defaults.removePersistentDomain(forName:suite) }
        var prefs=DiffToolPreferences.load(from:defaults)
        XCTAssertEqual(try prefs.selected(base:"a.zip",destination:"b.ZIP")?.builtIn,.zipInventory)
        XCTAssertNil(try prefs.selected(base:"a.zip",destination:"b.zip",alternate:true))
        let identity=prefs.associations[0].id
        prefs.associations[0].program.enabled=false
        XCTAssertNil(try prefs.selected(base:"a.zip",destination:"b.zip"))
        XCTAssertEqual(try prefs.selected(base:"a.zip",destination:"b.zip",alternate:true)?.builtIn,.zipInventory)
        var other=DiffToolAssociation(); other.pattern=".other"; other.program.enabled=false; prefs.associations.append(other)
        prefs.restoreBundledAssociations(); XCTAssertEqual(prefs.associations.first { $0.pattern == ".zip" }?.id,identity)
        XCTAssertTrue(prefs.associations.contains(other)); try prefs.save(to:defaults); XCTAssertEqual(DiffToolPreferences.load(from:defaults),prefs)
        let legacy=Data(#"{"program":{"enabled":false,"applicationPath":"","arguments":"%base %mine"},"associations":[]}"#.utf8)
        defaults.set(legacy,forKey:"TurtleGit.DiffTools"); XCTAssertTrue(DiffToolPreferences.load(from:defaults).associations.isEmpty)
        var merge=MergeToolPreferences(); merge.program=prefs.associations.last { $0.pattern == ".zip" }!.program
        XCTAssertFalse(merge.valid); XCTAssertThrowsError(try merge.selected(path:"a.zip")); XCTAssertThrowsError(try merge.save(to:defaults))
    }
}
