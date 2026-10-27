// SPDX-License-Identifier: GPL-2.0-or-later
import XCTest
@testable import TurtleGitCore

final class HistoricalFileDeliveryTests: XCTestCase {
    private let oid=String(repeating:"a",count:40)
    private func content(_ path:String,_ bytes:Data=Data("payload\n".utf8),mode:String="100644",oid:String?=nil)->ComparisonFileContent {
        .init(path:path,revision:.revision(String(repeating:"b",count:40)),bytes:bytes,mode:mode,objectID:oid)
    }
    func testSafeDeliveryNamesRetainObjectIdentityAndPreviewBytes()throws {
        let raw=try RepositoryBrowserGitPath(rawData:Data([0xff])+Data("/file.TXT".utf8)).key
        let source=content(raw,Data([0xff,0,10]),mode:"120000",oid:oid)
        XCTAssertEqual(try HistoricalFileDeliveryName.leaf(for:source),"Git-blob-"+oid+".TXT")
        XCTAssertEqual(source.usingMergeEncoding(preferUTF8:true).objectID,oid)
        XCTAssertEqual(try content(raw,oid:oid).reinterpreting(encoding:.utf8).objectID,oid)
        let preview=try HistoricalFilePreview.create(source)
        defer{try? FileManager.default.removeItem(at:preview.directory)}
        XCTAssertFalse(preview.file.lastPathComponent.contains("\0"))
        XCTAssertTrue(preview.file.lastPathComponent.hasPrefix("Git-blob-"+oid))
        XCTAssertEqual(try Data(contentsOf:preview.file),source.bytes)
        let attributes=try FileManager.default.attributesOfItem(atPath:preview.file.path)
        XCTAssertEqual(attributes[.type] as? FileAttributeType,.typeRegular)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue,0o444)
        let ordinary="folder/cafe\u{301}.txt"
        XCTAssertTrue(try HistoricalFileDeliveryName.leaf(for:content(ordinary)).utf8.elementsEqual("cafe\u{301}.txt".utf8))
        XCTAssertThrowsError(try HistoricalFileDeliveryName.leaf(for:content(raw)))
        XCTAssertThrowsError(try HistoricalFileDeliveryName.leaf(for:content(raw,oid:"not-an-object")))
        XCTAssertThrowsError(try HistoricalFileDeliveryName.leaf(for:content("invalid\0key",oid:oid)))
    }
    func testAssociationPolicyNeverSelectsReplacementCharacterSibling()throws {
        let raw=try RepositoryBrowserGitPath(rawData:Data([0xff])+Data(".TXT".utf8)).key
        let rawDirectory=try RepositoryBrowserGitPath(rawData:Data([0xff])+Data("/exact.TXT".utf8)).key
        XCTAssertNil(HistoricalGitPath.filename(raw))
        XCTAssertEqual(HistoricalGitPath.filename(rawDirectory),"exact.TXT")
        XCTAssertEqual(HistoricalGitPath.fileExtension(raw),"TXT")
        var settings=DiffToolPreferences()
        func association(_ pattern:String,_ tool:BuiltInDiffTool)->DiffToolAssociation {
            var value=DiffToolAssociation();value.pattern=pattern;value.program.enabled=true;value.program.builtIn=tool;return value
        }
        settings.associations=[association("\u{fffd}.txt",.zipInventory),association(".txt",.binaryReport),association("exact.txt",.zipInventory)]
        XCTAssertEqual(try settings.selected(base:"base",destination:raw)?.builtIn,.binaryReport)
        XCTAssertEqual(try settings.selected(base:"base",destination:rawDirectory)?.builtIn,.zipInventory)
        let image=try RepositoryBrowserGitPath(rawData:Data([0xfe])+Data(".png".utf8)).key
        XCTAssertEqual(try settings.selection(base:"base",destination:image),.image)
        let invalidExtension=try RepositoryBrowserGitPath(rawData:Data("file.".utf8)+Data([0xfe])).key
        XCTAssertEqual(HistoricalGitPath.fileExtension(invalidExtension),"")
        let profiles=MergeCommentProfiles(text:"txt=//,/*,*/")
        XCTAssertEqual(profiles.tokens(paths:[raw])?.line,"//")
        XCTAssertNil(profiles.tokens(paths:[invalidExtension]))
        let file=CommitFile(path:raw,oldPath:nil,action:"M",added:1,removed:0,hasStatistics:true,isSubmodule:false)
        XCTAssertEqual(file.fileExtension,"TXT")
        XCTAssertFalse(ComparisonFileList.clipboard([file],extended:true).contains("\0"))
        XCTAssertTrue(ComparisonFileList.clipboard([file],extended:false).contains(file.displayPath))
    }
    func testRawPatchHeadersAndSymlinkTargetsApplyToPrivateIndex()async throws {
        let(root,repo,_)=try await GitPatchTests().fixture()
        defer{try? FileManager.default.removeItem(at:root)}
        let name=Data([0xff])+Data(" name\t.txt".utf8),key=try RepositoryBrowserGitPath(rawData:name).key
        let environment=["GIT_INDEX_FILE":root.appendingPathComponent("delivery-index").path]
        for mode in ["100644","120000"] {
            let old=Data([0xfe])+Data(" old-target".utf8),new=Data([0xfd])+Data(" new-target".utf8)
            let oldOID=try await repo.run(["hash-object","-w","--stdin"],input:old).text.trimmingCharacters(in:.newlines)
            _ = try await repo.run(["read-tree","--empty"],environmentOverrides:environment)
            var record=Data((mode+" "+oldOID+"\t").utf8);record.append(name);record.append(0)
            _ = try await repo.run(["update-index","-z","--index-info"],environmentOverrides:environment,input:record)
            let patch=try await MergeUnifiedPatch.create(base:content(key,old,mode:mode,oid:oldOID),destination:content(key,new,mode:mode,oid:oid),baseLabel:key,destinationLabel:key,executable:repo.executable)
            XCTAssertTrue(String(decoding:patch,as:UTF8.self).contains("\\377 name\\t.txt"))
            XCTAssertFalse(patch.contains(0))
            _ = try await repo.run(["apply","--cached","-"],environmentOverrides:environment,input:patch)
            let records=try await repo.run(["ls-files","--stage","-z"],environmentOverrides:environment).stdout
            let fields=String(decoding:records.prefix{ $0 != 9 },as:UTF8.self).split(separator:" ")
            let result=try await repo.run(["cat-file","blob",String(fields[1])]).stdout
            XCTAssertEqual(result,new)
            XCTAssertEqual(String(fields[0]),mode)
        }
    }
}
