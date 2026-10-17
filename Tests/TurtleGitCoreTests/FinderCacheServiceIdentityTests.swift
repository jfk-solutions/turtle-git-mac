import XCTest
import Security
@testable import TurtleGitCore
final class FinderCacheServiceIdentityTests:XCTestCase {
    func testMacGroupNamespaceRequiresAnActualTeamIdentifier() {
        XCTAssertEqual(FinderIntegration.groupIdentifier(team:"ABCDE12345"),"ABCDE12345.org.turtlegit.macos")
        for team in ["", "adhoc", "abcde12345", "ABCDE1234\"", "ABCDE123456", "ABCDE/2345"] { XCTAssertNil(FinderIntegration.groupIdentifier(team:team)) }
        XCTAssertEqual(FinderCacheServiceIdentity.machService,FinderIntegration.group+".cache")
        if FinderIntegration.group == FinderIntegration.groupSuffix { XCTAssertNil(FinderIntegration.container) }
    }
    func testRequirementsPinTeamAndEachPeerIdentifier() throws {
        for identifier in [FinderCacheServiceIdentity.bundleIdentifier,FinderCacheServiceIdentity.appIdentifier] {
            let text=try FinderCacheServiceIdentity.requirement(identifier:identifier,team:"ABCDE12345")
            var requirement:SecRequirement?
            XCTAssertEqual(SecRequirementCreateWithString(text as CFString,[],&requirement),errSecSuccess)
            XCTAssertNotNil(requirement);XCTAssertTrue(text.contains("anchor apple generic"));XCTAssertTrue(text.contains(identifier));XCTAssertTrue(text.contains("ABCDE12345"))
        }
    }
    func testUntrustedRequirementComponentsRejected() {
        for team in ["","adhoc","abcde12345","ABCDE1234\"","ABCDE123456"] {
            XCTAssertThrowsError(try FinderCacheServiceIdentity.requirement(identifier:FinderCacheServiceIdentity.appIdentifier,team:team))
        }
        XCTAssertThrowsError(try FinderCacheServiceIdentity.requirement(identifier:"other.app",team:"ABCDE12345"))
    }
}
