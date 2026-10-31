// SPDX-License-Identifier: GPL-2.0-or-later
import Foundation

/// Build policy does not establish publication or a purchasable Store listing.
/// Only publisher-owned bundle metadata can configure this optional public page.
public struct ApplicationDistribution:Sendable,Equatable {
    public let appStoreBuild:Bool
    public let appStoreListing:URL?
    public init(appStoreBuild:Bool,appStoreListing:URL? = nil) {
        self.appStoreBuild=appStoreBuild
        self.appStoreListing=Self.validatedListing(appStoreListing)
    }
    public static func validatedListing(_ url:URL?)->URL? {
        guard let url,let parts=URLComponents(url:url,resolvingAgainstBaseURL:false),
              parts.scheme?.lowercased()=="https",parts.host?.lowercased()=="apps.apple.com",
              parts.user==nil,parts.password==nil,parts.port==nil,parts.query==nil,parts.fragment==nil,
              !parts.percentEncodedPath.contains("%"),!url.absoluteString.contains("\0") else{return nil}
        let components=parts.path.split(separator:"/",omittingEmptySubsequences:false)
        guard components.first=="",components.count>=3,components.count<=5,
              let app=components.firstIndex(of:"app"),app==1 || app==2,
              app==1 || components[1].utf8.count==2 && components[1].utf8.allSatisfy({(97...122).contains($0)}),
              components.count==app+2 || components.count==app+3,
              let last=components.last,last.hasPrefix("id"),last.count>2,
              last.dropFirst(2).utf8.allSatisfy({(48...57).contains($0)}),last.dropFirst(2).first != "0",
              components.dropFirst().allSatisfy({!$0.isEmpty && $0 != "." && $0 != ".." && !$0.contains("\\")}) else{return nil}
        return url
    }
    public var canOpenStoreListing:Bool {appStoreBuild && appStoreListing != nil}
    public var buildConfiguration:String {appStoreBuild ? "App Store":"Desktop"}
}
extension GitRuntime {
    /// No default Store ID/page exists. Setting this key belongs to publication.
    public static func appStoreListingURL(bundle:Bundle = .main)->URL? {
        guard let raw=bundle.object(forInfoDictionaryKey:"TurtleGitAppStoreListingURL") as? String,
              raw.utf8.count<=2048,let url=URL(string:raw) else{return nil}
        return ApplicationDistribution.validatedListing(url)
    }
}
