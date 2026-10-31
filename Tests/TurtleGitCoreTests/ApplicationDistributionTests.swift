import XCTest
@testable import TurtleGitCore

final class ApplicationDistributionTests:XCTestCase {
    func testBuildPolicyDoesNotImplyPublishedStoreListing() throws {
        let local=ApplicationDistribution(appStoreBuild:true)
        XCTAssertTrue(local.appStoreBuild);XCTAssertNil(local.appStoreListing);XCTAssertFalse(local.canOpenStoreListing)
        XCTAssertEqual(local.buildConfiguration,"App Store")
        let listing=try XCTUnwrap(URL(string:"https://apps.apple.com/app/id123456789"))
        XCTAssertTrue(ApplicationDistribution(appStoreBuild:true,appStoreListing:listing).canOpenStoreListing)
        XCTAssertFalse(ApplicationDistribution(appStoreBuild:false,appStoreListing:listing).canOpenStoreListing)
        for value in ["https://apps.apple.com/app/id123456789","https://apps.apple.com/us/app/turtlegit/id123456789"] {
            let url=try XCTUnwrap(URL(string:value));XCTAssertEqual(ApplicationDistribution.validatedListing(url),url)
        }
        for value in ["http://apps.apple.com/app/id123","macappstore://apps.apple.com/app/id123","https://example.invalid/app/id123","https://apps.apple.com.evil.invalid/app/id123","https://user:secret@apps.apple.com/app/id123","https://apps.apple.com:443/app/id123","https://apps.apple.com/app/id123?token=secret","https://apps.apple.com/app/id123#fragment","https://apps.apple.com/app/id0","https://apps.apple.com/app/id","https://apps.apple.com/app/123","https://apps.apple.com/app//id123","https://apps.apple.com/app/%2e%2e/id123","https://apps.apple.com/usa/app/id123","https://apps.apple.com/app/id123/extra"] {
            XCTAssertNil(ApplicationDistribution.validatedListing(URL(string:value)),value)
        }
    }
    func testOptionalPublisherBundleMetadataHasNoDefaultAndRejectsInvalidListing() throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("TurtleGitDistribution-"+UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true);defer{try? FileManager.default.removeItem(at:root)}
        func bundle(_ suffix:String,_ listing:String?) throws -> Bundle {
            let path=root.appendingPathComponent(suffix+".bundle");try FileManager.default.createDirectory(at:path,withIntermediateDirectories:true)
            var info:[String:Any] = ["CFBundleIdentifier":"org.turtlegit.distributiontest."+suffix,"CFBundlePackageType":"BNDL"]
            if let listing {info["TurtleGitAppStoreListingURL"]=listing}
            try PropertyListSerialization.data(fromPropertyList:info,format:.xml,options:0).write(to:path.appendingPathComponent("Info.plist"))
            return try XCTUnwrap(Bundle(url:path))
        }
        XCTAssertNil(GitRuntime.appStoreListingURL(bundle:try bundle("absent",nil)))
        XCTAssertNil(GitRuntime.appStoreListingURL(bundle:try bundle("invalid","https://example.invalid/")))
        let value="https://apps.apple.com/app/id123456789"
        XCTAssertEqual(GitRuntime.appStoreListingURL(bundle:try bundle("valid",value))?.absoluteString,value)
    }
}
