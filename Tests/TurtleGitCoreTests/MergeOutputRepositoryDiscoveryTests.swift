// SPDX-License-Identifier: GPL-2.0-or-later
import XCTest
import Darwin
@testable import TurtleGitCore

final class MergeOutputRepositoryDiscoveryTests:XCTestCase {
    private func fixture()throws->URL {
        let url=FileManager.default.temporaryDirectory.appendingPathComponent("turtlegit-merge-discovery-"+UUID().uuidString,isDirectory:true)
        try FileManager.default.createDirectory(at:url,withIntermediateDirectories:true)
        return url.resolvingSymlinksInPath().standardizedFileURL
    }
    private func physicalLocation(_ url:URL)throws->URL {
        let pointer=try XCTUnwrap(realpath(url.path,nil))
        defer {free(pointer)}
        return URL(fileURLWithPath:String(cString:pointer),isDirectory:true)
    }
    private func repositoryPath(_ result:MergeOutputRepositoryDiscovery,file:StaticString=#filePath,line:UInt=#line)->String {
        guard case let .repository(root)=result else {XCTFail("Expected repository, got \(result)",file:file,line:line);return ""}
        return root.standardizedFileURL.resolvingSymlinksInPath().path
    }
    func testFullUnrestrictedPlainFolderWalkProvesNoRepository()throws {
        let folder=try fixture();defer{try? FileManager.default.removeItem(at:folder)}
        let nested=folder.appendingPathComponent("one/two",isDirectory:true)
        try FileManager.default.createDirectory(at:nested,withIntermediateDirectories:true)
        XCTAssertEqual(try RepositoryMetadataAccess.discoverMergeOutputRepository(at:nested,permissions:[],requireSecurityScope:false),.noRepository)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath:nested.path),[],"Discovery must not create repository metadata")
    }
    func testNearestWorkingLinkedAndBareMarkersAreCandidatesForLaterValidation()throws {
        let folder=try fixture();defer{try? FileManager.default.removeItem(at:folder)}
        let nested=folder.appendingPathComponent("nested/inside",isDirectory:true)
        try FileManager.default.createDirectory(at:nested,withIntermediateDirectories:true)
        try FileManager.default.createDirectory(at:folder.appendingPathComponent(".git"),withIntermediateDirectories:true)
        let near=nested.deletingLastPathComponent()
        try Data("gitdir: /external-metadata\n".utf8).write(to:near.appendingPathComponent(".git"))
        XCTAssertEqual(repositoryPath(try RepositoryMetadataAccess.discoverMergeOutputRepository(at:nested,permissions:[],requireSecurityScope:false)),near.path)
        try FileManager.default.removeItem(at:near.appendingPathComponent(".git"))
        XCTAssertEqual(repositoryPath(try RepositoryMetadataAccess.discoverMergeOutputRepository(at:nested,permissions:[],requireSecurityScope:false)),folder.path)
        try FileManager.default.removeItem(at:folder.appendingPathComponent(".git"))
        try Data("ref: refs/heads/main\n".utf8).write(to:folder.appendingPathComponent("HEAD"))
        try FileManager.default.createDirectory(at:folder.appendingPathComponent("objects"),withIntermediateDirectories:false)
        XCTAssertEqual(repositoryPath(try RepositoryMetadataAccess.discoverMergeOutputRepository(at:nested,permissions:[],requireSecurityScope:false)),folder.path)
    }
    func testAuthorityBoundaryIsUnknownAndNoOutsideAncestorIsInspected()throws {
        let folder=try fixture();defer{try? FileManager.default.removeItem(at:folder)}
        let nested=folder.appendingPathComponent("nested",isDirectory:true)
        try FileManager.default.createDirectory(at:nested,withIntermediateDirectories:true)
        var visited:[URL]=[]
        let outcome=try RepositoryMetadataAccess.discoverMergeOutputRepository(at:nested,authorizedFolders:[folder],requireSecurityScope:true,inspect:{url in
            visited.append(url)
            return [".git","HEAD","objects"].contains(url.lastPathComponent) ? nil:.typeDirectory
        })
        XCTAssertEqual(outcome,.needsAuthority(folder.deletingLastPathComponent()))
        XCTAssertFalse(visited.contains(folder.deletingLastPathComponent()))
        XCTAssertTrue(visited.allSatisfy{RepositoryAccessLease.pathIsContained($0,by:folder)})
        XCTAssertEqual(try RepositoryMetadataAccess.discoverMergeOutputRepository(at:nested,permissions:[],requireSecurityScope:true),.needsAuthority(nested))
    }
    func testDeniedAndMalformedAncestorsNeverBecomeNoRepository()throws {
        let folder=try fixture();defer{try? FileManager.default.removeItem(at:folder)}
        for code in [EACCES,EPERM,EIO,ENOTDIR] {
            XCTAssertThrowsError(try RepositoryMetadataAccess.discoverMergeOutputRepository(at:folder,authorizedFolders:[],requireSecurityScope:false,inspect:{url in
                if url.lastPathComponent == ".git" {throw NSError(domain:NSPOSIXErrorDomain,code:Int(code))}
                return .typeDirectory
            })) {error in XCTAssertEqual((error as NSError).domain,NSPOSIXErrorDomain);XCTAssertEqual((error as NSError).code,Int(code))}
        }
        XCTAssertThrowsError(try RepositoryMetadataAccess.discoverMergeOutputRepository(at:folder.appendingPathComponent("missing"),permissions:[],requireSecurityScope:false))
        let file=folder.appendingPathComponent("file");try Data().write(to:file)
        XCTAssertThrowsError(try RepositoryMetadataAccess.discoverMergeOutputRepository(at:file,permissions:[],requireSecurityScope:false))
    }
    func testSymlinkedOutputParentDiscoversItsActualRepository()throws {
        let folder=try fixture();defer{try? FileManager.default.removeItem(at:folder)}
        let repo=folder.appendingPathComponent("repo",isDirectory:true),child=repo.appendingPathComponent("child",isDirectory:true)
        try FileManager.default.createDirectory(at:child,withIntermediateDirectories:true)
        try FileManager.default.createDirectory(at:repo.appendingPathComponent(".git"),withIntermediateDirectories:false)
        let link=folder.appendingPathComponent("alias")
        try FileManager.default.createSymbolicLink(at:link,withDestinationURL:child)
        XCTAssertEqual(repositoryPath(try RepositoryMetadataAccess.discoverMergeOutputRepository(at:link,permissions:[],requireSecurityScope:false)),repo.path)
        // The injected walker begins at exactly the physical child supplied by
        // the public realpath entry; the public assertion above tests the alias.
        let physicalChild=try physicalLocation(child)
        XCTAssertEqual(try RepositoryMetadataAccess.discoverMergeOutputRepository(at:physicalChild,authorizedFolders:[child],requireSecurityScope:true,inspect:{url in
            if url.lastPathComponent == ".git" || url.lastPathComponent == "HEAD" || url.lastPathComponent == "objects" {return nil}
            return .typeDirectory
        }),.needsAuthority(physicalChild.deletingLastPathComponent()),"An alias must not bypass the real authorization boundary")
    }
    func testCancellationBeforeOrDuringMarkerReadCannotReturnAResult()throws {
        let folder=try fixture();defer{try? FileManager.default.removeItem(at:folder)}
        let canceled=OperationCancellation();canceled.cancel()
        var probes=0
        XCTAssertThrowsError(try RepositoryMetadataAccess.discoverMergeOutputRepository(at:folder,authorizedFolders:[],requireSecurityScope:false,cancellation:canceled,inspect:{_ in probes+=1;return .typeDirectory}))
        XCTAssertEqual(probes,0)
        let during=OperationCancellation()
        XCTAssertThrowsError(try RepositoryMetadataAccess.discoverMergeOutputRepository(at:folder,authorizedFolders:[],requireSecurityScope:false,cancellation:during,inspect:{url in
            if url.lastPathComponent == ".git" {during.cancel();return .typeDirectory}
            return .typeDirectory
        }))
    }
    func testBoundedAncestorWalkDoesNotMisclassifyAnUnfinishedSearch()throws {
        let location=URL(fileURLWithPath:"/"+Array(repeating:"folder",count:258).joined(separator:"/"),isDirectory:true)
        XCTAssertThrowsError(try RepositoryMetadataAccess.discoverMergeOutputRepository(at:location,authorizedFolders:[],requireSecurityScope:false,inspect:{url in
            [".git","HEAD","objects"].contains(url.lastPathComponent) ? nil:.typeDirectory
        })) {error in
            guard case RepositoryMetadataAccessFailure.tooManyDependencies=error else{return XCTFail("Unexpected error: \(error)")}
        }
    }
}
