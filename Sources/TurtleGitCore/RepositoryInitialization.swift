import Foundation

public enum InitializationWarning: Hashable, Sendable {
    case specialFolder, nonemptyBare
}
public enum InitializationFailure: LocalizedError {
    case destination, confirmationRequired(Set<InitializationWarning>)
    public var errorDescription: String? {
        switch self {
        case .destination: return "Choose a local repository folder."
        case .confirmationRequired: return "Review the destination warnings before creating this repository. The folder may have changed since it was selected."
        }
    }
}
public struct RepositoryCreationIdentity:Equatable,Sendable {
    public let root:URL,isBare:Bool,gitDirectory:URL
    public let directoryDevice:UInt64,directoryInode:UInt64
}
public struct InitializationOutcome:Sendable {
    public let output:String,destination:URL
    public let repositoryRoot:URL?,isBare:Bool?
    public let cancelledAfterCreation:Bool
    public let verificationError:String?
    public let identity:RepositoryCreationIdentity?
    public var verified:Bool {repositoryRoot != nil && isBare != nil && verificationError == nil}
    public init(output:String,destination:URL,repositoryRoot:URL?=nil,isBare:Bool?=nil,cancelledAfterCreation:Bool=false,verificationError:String?=nil,identity:RepositoryCreationIdentity?=nil) {
        self.output=output;self.destination=destination;self.repositoryRoot=repositoryRoot;self.isBare=isBare
        self.cancelledAfterCreation=cancelledAfterCreation;self.verificationError=verificationError;self.identity=identity
    }
}
public enum RepositoryInitialization {
    public static func defaultsToBare(_ folder: URL) -> Bool { folder.lastPathComponent.hasSuffix(".git") }
    public static func warnings(for folder: URL, bare: Bool, specialFolders: [URL]? = nil) throws -> Set<InitializationWarning> {
        guard folder.isFileURL, !folder.path.contains("\0") else { throw InitializationFailure.destination }
        var result: Set<InitializationWarning> = []
        let canonical = folder.standardizedFileURL.resolvingSymlinksInPath()
        let manager = FileManager.default
        let special = specialFolders ?? ([manager.homeDirectoryForCurrentUser]
            + manager.urls(for: .desktopDirectory, in: .userDomainMask)
            + manager.urls(for: .documentDirectory, in: .userDomainMask)
            + ["/", "/System", "/Library", "/Applications", "/Volumes", "/usr", "/bin", "/sbin"].map { URL(fileURLWithPath: $0, isDirectory: true) })
        if special.contains(where: { $0.standardizedFileURL.resolvingSymlinksInPath().path == canonical.path }) {
            result.insert(.specialFolder)
        }
        if specialFolders == nil, let volume = try? canonical.resourceValues(forKeys: [.volumeURLKey]).volume,
           volume.standardizedFileURL.resolvingSymlinksInPath().path == canonical.path { result.insert(.specialFolder) }
        var directory: ObjCBool = false
        if manager.fileExists(atPath: folder.path, isDirectory: &directory) {
            guard directory.boolValue else { throw InitializationFailure.destination }
            if bare {
                if !(try manager.contentsOfDirectory(atPath: folder.path)).isEmpty { result.insert(.nonemptyBare) }
            }
        }
        return result
    }
}
extension GitRepository {
    public func initialize(at destination: URL, bare: Bool, confirmedWarnings: Set<InitializationWarning> = [], cancellation: OperationCancellation? = nil) throws -> String {
        try initializeOutcome(at:destination,bare:bare,confirmedWarnings:confirmedWarnings,cancellation:cancellation).output
    }
    public func initializeOutcome(at destination:URL,bare:Bool,confirmedWarnings:Set<InitializationWarning> = [],cancellation:OperationCancellation?=nil)throws->InitializationOutcome {
        try cancellation?.check()
        let warnings = try RepositoryInitialization.warnings(for: destination, bare: bare)
        guard warnings.isSubset(of: confirmedWarnings) else { throw InitializationFailure.confirmationRequired(warnings.subtracting(confirmedWarnings)) }
        // Let Git honor init.defaultBranch and GIT_TEMPLATE_DIR. Do not impose main
        // or delete existing contents when creating/reinitializing a repository.
        let result=try acceptedCreationResult {try run(["init"] + (bare ? ["--bare"] : []) + ["--", destination.standardizedFileURL.path], cancellation: cancellation)}
        var identity:RepositoryCreationIdentity?,issue:String?
        do {identity=try boundedCreationVerification {try createdRepositoryIdentity(at:destination,cancellation:$0)}}
        catch {issue="Initialization completed, but the repository could not be verified: "+error.localizedDescription}
        return .init(output:result.text,destination:destination,repositoryRoot:identity?.root,isBare:identity?.isBare,cancelledAfterCreation:cancellation?.isCancelled == true,verificationError:issue,identity:identity)
    }
    /// Read-only recovery: never re-runs init, even if the destination currently
    /// exists. Its caller retains the accepted outcome and original grants.
    public func inspectInitializationOutcome(_ outcome:InitializationOutcome,cancellation:OperationCancellation?=nil)throws->InitializationOutcome {
        try cancellation?.check()
        let identity=try boundedCreationVerification {try createdRepositoryIdentity(at:outcome.destination,cancellation:$0)}
        if let prior=outcome.identity,prior != identity {throw InitializationFailure.destination}
        return .init(output:outcome.output,destination:outcome.destination,repositoryRoot:identity.root,isBare:identity.isBare,cancelledAfterCreation:outcome.cancelledAfterCreation || cancellation?.isCancelled == true,identity:identity)
    }
    /// All commands use this actor's captured executable and the exact selected
    /// destination; successful stderr warnings are never repository identity.
    func createdRepositoryIdentity(at destination:URL,cancellation:OperationCancellation)throws->RepositoryCreationIdentity {
        try cancellation.check()
        let bare=try run(["-C",destination.path,"rev-parse","--is-bare-repository"],cancellation:cancellation).stdout
        let flag=String(decoding:bare,as:UTF8.self).trimmingCharacters(in:.newlines)
        guard flag=="true" || flag=="false" else {throw InitializationFailure.destination}
        var bytes=try run(["-C",destination.path,"rev-parse",flag=="true" ? "--absolute-git-dir":"--show-toplevel"],cancellation:cancellation).stdout
        if bytes.last==10 {bytes.removeLast()}
        guard let path=String(data:bytes,encoding:.utf8),path.hasPrefix("/"),!path.contains("\0") else {throw InitializationFailure.destination}
        let actual=URL(fileURLWithPath:path,isDirectory:true).standardizedFileURL
        guard GitReferenceName.equal(actual.resolvingSymlinksInPath().path,destination.standardizedFileURL.resolvingSymlinksInPath().path) else {throw InitializationFailure.destination}
        var gitBytes=try run(["-C",destination.path,"rev-parse","--absolute-git-dir"],cancellation:cancellation).stdout
        if gitBytes.last==10 {gitBytes.removeLast()}
        guard let gitPath=String(data:gitBytes,encoding:.utf8),gitPath.hasPrefix("/") else {throw InitializationFailure.destination}
        let gitDirectory=URL(fileURLWithPath:gitPath,isDirectory:true).resolvingSymlinksInPath().standardizedFileURL
        let attributes=try FileManager.default.attributesOfItem(atPath:gitDirectory.path)
        guard attributes[.type] as? FileAttributeType == .typeDirectory,
              let device=attributes[.systemNumber] as? NSNumber,let inode=attributes[.systemFileNumber] as? NSNumber else {throw InitializationFailure.destination}
        return .init(root:actual,isBare:flag=="true",gitDirectory:gitDirectory,directoryDevice:device.uint64Value,directoryInode:inode.uint64Value)
    }
}
