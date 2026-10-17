import XCTest
@testable import TurtleGitCore
final class LegacyComparisonEncodingTests:XCTestCase {
    let samples:[(ComparisonTextEncoding,String)] = [(.windows1252,"café €"),(.windows1250,"Příliš žluťoučký"),(.windows1251,"Привет мир"),(.windows1253,"Καλημέρα"),(.windows1254,"İstanbul ışık"),(.windows1255,"שלום"),(.windows1256,"مرحبا"),(.windows1257,"Ąžuolas"),(.windows1258,"Viêt Nam"),(.windows874,"ภาษาไทย"),(.shiftJIS,"日本語"),(.gbk,"中文"),(.korean,"한국어"),(.big5,"繁體中文")]
    func testEveryLegacyCodecRoundTripsAndSourceDetectionRetainsPolicy() throws {
        XCTAssertEqual(Set(samples.map(\.0)),Set(ComparisonTextEncoding.legacyChoices))
        for (encoding,sample) in samples {
            let text = "prefix: "+sample+"\r\nlast\tline",bytes = try encoding.encode(text)
            XCTAssertEqual(encoding.decode(bytes),text,encoding.rawValue)
            XCTAssertEqual(ComparisonTextEncoding.detectMerge(bytes,preferUTF8:false,legacyEncoding:encoding),encoding,encoding.rawValue)
            let raw = ComparisonFileContent(path:"file",revision:.workingTree,bytes:bytes,mode:"100644")
            let adapted = raw.usingMergeEncoding(preferUTF8:false,legacyEncoding:encoding)
            XCTAssertEqual(adapted.text,text);XCTAssertEqual(adapted.bytes,bytes)
        }
        XCTAssertThrowsError(try ComparisonTextEncoding.windows1251.encode("日本語"))
        XCTAssertThrowsError(try ComparisonTextEncoding.shiftJIS.encode("🦎"))
        let utf8 = try ComparisonTextEncoding.utf8BOM.encode("日本語")
        XCTAssertEqual(ComparisonTextEncoding.detectMerge(utf8,preferUTF8:false,legacyEncoding:.windows1251),.utf8BOM)
        XCTAssertNil(ComparisonFileContent(path:"broken",revision:.workingTree,bytes:Data([0xff,0xfe,0,0xd8]),mode:"100644").usingMergeEncoding(preferUTF8:false,legacyEncoding:.windows1251).text)
    }
    func testConfiguredLegacyChoiceReplacesOnlySourceASCIIOption() throws {
        let suite="TurtleGit.LegacyPolicy."+UUID().uuidString,defaults=try XCTUnwrap(UserDefaults(suiteName:suite))
        defer {defaults.removePersistentDomain(forName:suite)}
        XCTAssertEqual(ComparisonTextEncoding.legacyEncoding(from:defaults),.windows1252)
        for value in ComparisonTextEncoding.legacyChoices {
            defaults.set(Int(value.legacyCodePage!),forKey:"TurtleGitMerge.LegacyCodePage")
            XCTAssertEqual(ComparisonTextEncoding.legacyEncoding(from:defaults),value)
            let choices=MergeFormatSelection.encodingChoices(legacy:value)
            XCTAssertEqual(choices.count,9);XCTAssertEqual(choices.first,value)
            XCTAssertEqual(Array(choices.dropFirst()),Array(MergeFormatSelection.encodings.dropFirst()))
        }
        for value in [-1,999,Int.max] {defaults.set(value,forKey:"TurtleGitMerge.LegacyCodePage");XCTAssertEqual(ComparisonTextEncoding.legacyEncoding(from:defaults),.windows1252)}
    }
    func testRepositoryConflictUsesConfiguredLegacyCodecWithoutIndexMutation() async throws {
        let (root,repo,path)=try await ConflictResolutionTests().fixture();defer {try? FileManager.default.removeItem(at:root)}
        let codec=ComparisonTextEncoding.windows1251,texts=["общая строка\r\nоснова","общая строка\r\nмоя версия","общая строка\r\nдругая версия"]
        var packet=Data()
        for (index,text) in texts.enumerated() {
            let hash=try await repo.run(["hash-object","-w","--stdin"],input:codec.encode(text)).text.trimmingCharacters(in:.newlines)
            packet.append(Data("100644 \(hash) \(index+1)\t\(path)\0".utf8))
        }
        _=try await repo.run(["update-index","-z","--index-info"],input:packet)
        let file=root.appendingPathComponent(path);try codec.encode("<<<<<<< mine\r\nмоя версия\r\n=======\r\nдругая версия\r\n>>>>>>> theirs\r\n").write(to:file)
        let index=try Data(contentsOf:root.appendingPathComponent(".git/index")),head=try await repo.run(["rev-parse","HEAD"]).stdout
        let document=try await repo.textConflictDocument(path:path,mergePreferUTF8:false,mergeLegacyEncoding:codec)
        XCTAssertEqual(document.encoding,codec);XCTAssertEqual(document.base,texts[0]);XCTAssertEqual(document.mine,texts[1]);XCTAssertEqual(document.theirs,texts[2])
        _=try await repo.saveTextConflict(document,result:"решено\r\nпоследняя",markResolved:false)
        XCTAssertEqual(try Data(contentsOf:file),try codec.encode("решено\r\nпоследняя"))
        XCTAssertEqual(try Data(contentsOf:root.appendingPathComponent(".git/index")),index)
        let currentHead=try await repo.run(["rev-parse","HEAD"]).stdout
        XCTAssertEqual(currentHead,head)
    }
    func testLegacyWorkingSaveAndSavedPaneReloadPreserveExactBytesAndMode() throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true);defer {try? FileManager.default.removeItem(at:root)}
        let base=root.appendingPathComponent("base"),mine=root.appendingPathComponent("mine")
        for (encoding,text) in samples {
            let original=try encoding.encode(text+"\r\nlast")
            try original.write(to:base);try original.write(to:mine)
            try FileManager.default.setAttributes([.posixPermissions:0o755],ofItemAtPath:mine.path)
            let pair=try WorkingFileComparison(base:base,destination:mine),document=try pair.read().usingMergeEncoding(preferUTF8:false,legacyEncoding:encoding)
            let changed=text+"\r\nchanged",expected=try encoding.encode(changed)
            let saved=try pair.save(document,base:false,text:changed,encoding:encoding)
            XCTAssertEqual(saved.destination.encoding,encoding);XCTAssertEqual(saved.destination.text,changed)
            let target=try SavedMergePane(url:mine,writtenBytes:expected,encoding:encoding),reread=try target.read()
            XCTAssertEqual(reread.encoding,encoding);XCTAssertEqual(reread.text,changed)
            XCTAssertEqual(try Data(contentsOf:mine),expected);XCTAssertEqual(try Data(contentsOf:base),original)
            XCTAssertEqual((try FileManager.default.attributesOfItem(atPath:mine.path)[.posixPermissions] as? NSNumber)?.intValue,0o755)
        }
        let original=try ComparisonTextEncoding.windows1251.encode("исходный текст")
        try original.write(to:mine)
        let target=try SavedMergePane(url:mine,writtenBytes:original,encoding:.windows1251)
        for encoding in [ComparisonTextEncoding.utf8,.utf8BOM,.utf16LEBOM] {
            try encoding.encode("外部からの変更").write(to:mine)
            let reloaded=try target.read()
            XCTAssertEqual(reloaded.encoding,encoding);XCTAssertEqual(reloaded.text,"外部からの変更")
        }
    }
}
