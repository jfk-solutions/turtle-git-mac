// SPDX-License-Identifier: GPL-2.0-or-later
import Foundation
import CoreFoundation

public struct NativeIssueProviderDescriptor:Sendable,Identifiable {
    public let identifier:String
    public let name:String
    public let exampleParameters:String
    public let optionsDescription:String
    public var id:String {identifier}
}
public enum NativeIssueProviderRegistry {
    public static let descriptors:[NativeIssueProviderDescriptor]=[
        .init(identifier:NativeIssueCatalogProvider.identifier,name:NativeIssueCatalogProvider.name,exampleParameters:NativeIssueCatalogProvider.exampleParameters,optionsDescription:"A local JSON catalog with issue IDs, summaries and an optional commit-message template."),
        .init(identifier:"org.turtlegit.issue-http",name:"HTTP issue provider",exampleParameters:#"{"endpoint":"https://issues.example.invalid/turtlegit","linkText":"Choose issues…"}"#,optionsDescription:"A version 1 JSON endpoint for listing issues, preparing messages, checking commits and reporting completed commits. Use HTTPS or a loopback HTTP endpoint. Configure its bearer token separately in Settings.")
    ]
    public static func descriptor(identifier:String)->NativeIssueProviderDescriptor? {descriptors.first{$0.identifier==identifier}}
}

/// Immutable provider/configuration/credential capture. Construction performs no
/// network access; hosts establish local consent before invoking remote methods.
public struct NativeIssueProviderSession:Sendable,CustomStringConvertible,CustomDebugStringConvertible {
    public static let httpIdentifier="org.turtlegit.issue-http"
    public static let maximumRequestBytes=1_048_576
    public static let maximumResponseBytes=1_048_576
    public let identifier:String
    public let linkText:String
    public var isRemote:Bool {endpoint != nil}
    public let endpoint:URL?
    private let catalog:NativeIssueCatalogProvider?
    private let bearerToken:String?
    public var description:String {"NativeIssueProviderSession("+identifier+", "+(endpoint?.absoluteString ?? "local")+")"}
    public var debugDescription:String {description}
    public init(catalog:NativeIssueCatalogProvider) {
        self.catalog=catalog;identifier=NativeIssueCatalogProvider.identifier;linkText=catalog.linkText;endpoint=nil;bearerToken=nil
    }
    public init(identifier:String,parameters:String,bearerToken:String?=nil)throws {
        if identifier==NativeIssueCatalogProvider.identifier {self=NativeIssueProviderSession(catalog:try NativeIssueCatalogProvider(parameters:parameters));return}
        guard identifier==Self.httpIdentifier else{throw NativeIssueProviderFailure.unavailable(identifier)}
        guard parameters.utf8.count<=Self.maximumRequestBytes,
              let data=parameters.data(using:.utf8),let values=(try? JSONSerialization.jsonObject(with:data)) as? [String:Any],
              Set(values.keys).isSubset(of:["endpoint","linkText"]),let raw=values["endpoint"] as? String,
              let parts=URLComponents(string:raw),let url=parts.url,
              let host=parts.host,!host.isEmpty,let scheme=parts.scheme?.lowercased(),parts.user==nil,parts.password==nil,parts.fragment==nil,parts.query==nil,
              parts.port.map({(1...65535).contains($0)}) ?? true,
              scheme=="https" || scheme=="http" && ["localhost","127.0.0.1","::1","[::1]"].contains(host.lowercased()),
              !raw.contains(where:{$0.isWhitespace || $0=="\0"}) else {
            throw NativeIssueProviderFailure.configuration("Enter an absolute HTTPS endpoint, or HTTP on localhost/127.0.0.1/::1, without credentials, query or fragment. Supported JSON fields are endpoint and linkText.")
        }
        let caption:String
        if let value=values["linkText"] {guard let text=value as? String,!text.contains("\0"),text.utf8.count<=4096 else{throw NativeIssueProviderFailure.configuration("The provider link text is invalid or too large.")};caption=text.isEmpty ? "Choose issues…":text}
        else{caption="Choose issues…"}
        if let bearerToken {
            let allowed=CharacterSet(charactersIn:"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~+/=")
            guard !bearerToken.isEmpty,bearerToken.utf8.count<=8192,bearerToken.unicodeScalars.allSatisfy({allowed.contains($0)}) else{throw NativeIssueProviderFailure.configuration("The bearer token must be a single HTTP bearer credential without spaces or control characters.")}
        }
        self.identifier=identifier;linkText=caption;endpoint=url;catalog=nil;self.bearerToken=bearerToken
    }
    public func selectedIDs(in text:String)->Set<String> {
        if let catalog {return catalog.selectedIDs(in:text)}
        return Set(text.split(separator:",").map{$0.trimmingCharacters(in:.whitespacesAndNewlines)}.filter{!$0.isEmpty})
    }
    public func issues(context:NativeIssueProviderContext,cancellation:OperationCancellation?=nil) async throws->[NativeIssueCatalogItem] {
        try check(cancellation)
        if let catalog {return catalog.issues}
        let response=try await call("listIssues",context:context,cancellation:cancellation)
        guard let data=try? JSONSerialization.data(withJSONObject:response["issues"] as Any),
              let issues=try? JSONDecoder().decode([NativeIssueCatalogItem].self,from:data),issues.count<=10_000,
              Set(issues.map(\.id)).count==issues.count,
              issues.allSatisfy({Self.validID($0.id) && !$0.summary.contains("\0")}) else{throw failure("The issue list must contain at most 10,000 unique, unambiguous nonempty IDs and summaries.")}
        return issues
    }
    public func commitMessage(context:NativeIssueProviderContext,selected:Set<String>,cancellation:OperationCancellation?=nil) async throws->NativeIssueProviderResult {
        try check(cancellation)
        if let catalog {return try catalog.commitMessage(context:context,selected:selected)}
        guard !selected.isEmpty,selected.count<=10_000,selected.allSatisfy(Self.validID) else{throw NativeIssueProviderFailure.selection}
        let response=try await call("commitMessage",context:context,selected:selected.sorted{Array($0.utf16).lexicographicallyPrecedes(Array($1.utf16))},cancellation:cancellation)
        guard let message=response["message"] as? String,!message.contains("\0") else{throw failure("The message response must include a text message without NUL.")}
        let issueID:String
        if let value=response["issueID"] {guard let text=value as? String,!text.contains("\0") else{throw failure("The returned issue ID must be text without NUL.")};issueID=text}
        else{issueID=context.issueID}
        return .init(message:message,issueID:issueID)
    }
    public func checkCommit(context:NativeIssueProviderContext,cancellation:OperationCancellation?=nil) async throws {
        try check(cancellation)
        if let catalog {try catalog.checkCommit(context:context);return}
        _ = try await call("checkCommit",context:context,cancellation:cancellation)
    }
    public func commitFinished(context:NativeIssueProviderContext,revision:String,cancellation:OperationCancellation?=nil) async throws->String? {
        try check(cancellation)
        if let catalog {try catalog.commitFinished(context:context,revision:revision);return nil}
        guard (revision.utf8.count==40 || revision.utf8.count==64),revision.utf8.allSatisfy({(48...57).contains($0)||(97...102).contains($0)}) else{throw failure("Report a complete Git commit ID to the provider.")}
        let response=try await call("commitFinished",context:context,revision:revision,cancellation:cancellation)
        if let value=response["warning"] {guard let warning=value as? String else{throw failure("The completion warning must be text.")};return warning.isEmpty ? nil:safe(warning)}
        return nil
    }
    private static func validID(_ value:String)->Bool {!value.isEmpty && value==value.trimmingCharacters(in:.whitespacesAndNewlines) && !value.contains(where:{$0=="," || $0=="\r" || $0=="\n" || $0=="\0"})}
    private func check(_ cancellation:OperationCancellation?)throws {try cancellation?.check();try Task.checkCancellation()}
    private func safe(_ text:String)->String {String(text.replacingOccurrences(of:bearerToken ?? "\0",with:"[redacted]").replacingOccurrences(of:"\0",with:"").prefix(4096))}
    private func failure(_ message:String)->NativeIssueProviderFailure {.configuration("HTTP provider: "+safe(message))}
    private func call(_ action:String,context:NativeIssueProviderContext,selected:[String]?=nil,revision:String?=nil,cancellation:OperationCancellation?) async throws->[String:Any] {
        guard let endpoint else{throw NativeIssueProviderFailure.unavailable(identifier)}
        try check(cancellation)
        guard context.repositoryRoot.isFileURL,context.commonRoot.isFileURL,
              context.paths.count<=10_000,!context.message.contains("\0"),!context.issueID.contains("\0"),context.paths.allSatisfy({!$0.contains("\0")}) else{throw failure("The captured commit context is invalid or too large.")}
        var body:[String:Any]=["version":1,"action":action,"context":["repositoryRoot":context.repositoryRoot.path,"commonRoot":context.commonRoot.path,"paths":context.paths,"message":context.message,"issueID":context.issueID]]
        if let selected {body["selectedIDs"]=selected};if let revision {body["revision"]=revision}
        let data=try JSONSerialization.data(withJSONObject:body,options:[.sortedKeys])
        guard data.count<=Self.maximumRequestBytes else{throw failure("The captured commit request exceeds 1 MiB.")}
        var request=URLRequest(url:endpoint,cachePolicy:.reloadIgnoringLocalCacheData,timeoutInterval:30)
        request.httpMethod="POST";request.httpBody=data
        request.setValue("application/json",forHTTPHeaderField:"Content-Type");request.setValue("application/json",forHTTPHeaderField:"Accept")
        if let bearerToken {request.setValue("Bearer "+bearerToken,forHTTPHeaderField:"Authorization")}
        let bytes:Data
        do {bytes=try await NativeIssueHTTPExchange(request:request,maximumBytes:Self.maximumResponseBytes).run(cancellation:cancellation)}
        catch {if cancellation?.isCancelled==true || Task.isCancelled || error is OperationCancellationFailure {throw OperationCancellationFailure.cancelled};throw failure(error.localizedDescription)}
        try check(cancellation)
        guard let response=(try? JSONSerialization.jsonObject(with:bytes)) as? [String:Any],
              let version=response["version"] as? NSNumber,CFGetTypeID(version)==CFNumberGetTypeID(),version.doubleValue==1 else{throw failure("Expected a version 1 JSON object response.")}
        if let value=response["error"] {guard let message=value as? String else{throw failure("The provider error must be text.")};if !message.isEmpty {throw failure(message)}}
        return response
    }
}
