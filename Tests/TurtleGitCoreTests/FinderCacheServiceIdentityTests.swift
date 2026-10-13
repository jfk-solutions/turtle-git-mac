import XCTest
import Security
@testable import TurtleGitCore
final class FinderCacheServiceIdentityTests:XCTestCase {
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
