import XCTest
@testable import TurtleGitCore

final class FinderRegistrationRequestTests:XCTestCase {
    func testRegistrationIsAnExplicitFirstUseRequestWithoutSourceEligibilityOrGitArguments()throws {
        let command=FinderServiceCommand.registerRepository
        let folder=FileTransferPaths.fileURL("/ungranted-"+UUID().uuidString+"/Cafe\u{301}")
        let request=try command.request(paths:[folder])
        XCTAssertEqual(request.action,.registerRepository)
        XCTAssertTrue(try XCTUnwrap(request.paths.first).path.utf8.elementsEqual(folder.path.utf8))
        XCTAssertFalse(command.requiresSourceEligibility);XCTAssertTrue(command.requiresSingleSelection)
        XCTAssertTrue(command.isEligible(flags:[]))
        XCTAssertFalse(request.action.requiresWorkingTree);XCTAssertFalse(request.action.allowsEmptySelection)
        XCTAssertNil(request.action.arguments(value:"arbitrary-command"))
        XCTAssertEqual(request.action.title,"Add to TurtleGit…")
        XCTAssertNil(FinderMenuEntry.entry(for:request.action),"Native registration must not reuse a pinned source mask bit")
        let wire=try command.serviceURL(paths:[folder])
        let decoded=try FinderServiceCommand.request(serviceURL:wire)
        XCTAssertEqual(decoded.action,.registerRepository)
        XCTAssertTrue(try XCTUnwrap(decoded.paths.first).path.utf8.elementsEqual(folder.path.utf8))
        XCTAssertEqual(FinderRequest(url:try XCTUnwrap(request.url))?.action,.registerRepository)
        // No existence/type probe here: sandbox authority and actual repository
        // validation belong to the receiving app after the owned folder grant.
    }
    func testRegistrationRejectsAmbiguousOrAdministrativePayloads()throws {
        let folder=FileTransferPaths.fileURL("/repo/selected"),command=FinderServiceCommand.registerRepository
        for paths in [[],[folder,folder],[folder,FileTransferPaths.fileURL("/repo/other")],[FileTransferPaths.fileURL("/")],[FileTransferPaths.fileURL("/repo/.git")]] {
            XCTAssertThrowsError(try command.request(paths:paths))
        }
        XCTAssertThrowsError(try command.request(paths:[folder],alternateTool:false))
        let wire=try XCTUnwrap(FinderRequest(action:.registerRepository,paths:[folder]).url)
        for suffix in ["&path=/repo/other","&alternate=0","&source=/repo/source","&unknown=1"] {
            XCTAssertNil(FinderRequest(url:try XCTUnwrap(URL(string:wire.absoluteString+suffix))))
        }
        XCTAssertNil(FinderRequest(action:.registerRepository,paths:[folder],sources:[folder]).url)
        XCTAssertNil(FinderRequest(action:.registerRepository,paths:[folder],alternateTool:false).url)
    }
    func testRegistrationDiscoveryDoesNotChangePinnedCreationRules() {
        let repository=FinderCreationMenuContext(directory:true,versioned:true)
        XCTAssertEqual(repository.registrationAction,.registerRepository)
        XCTAssertEqual(repository.actions,[])
        XCTAssertEqual(FinderCreationMenuContext(directory:false).registrationAction,nil)
        XCTAssertEqual(FinderCreationMenuContext(directory:true).actions,[.clone,.initialize])
    }
}
