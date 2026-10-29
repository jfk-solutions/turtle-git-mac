// SPDX-License-Identifier: GPL-2.0-or-later
// Adapts TortoiseMerge.cpp command entry; see NOTICE and MERGE-TOOL-ENTRY-PARITY.md.
import Foundation

/// A standalone Merge-tool request. Parsing grants no filesystem permission and
/// never consumes TortoiseProc /command requests or ordinary document launches.
public struct MergeToolInvocation: Sendable {
    public let base:URL?,theirs:URL?,mine:URL?,merged:URL?,diff:URL?,patchPath:URL?
    public let originalFile:URL?,modifiedFile:URL?,outputFile:URL?
    public let baseName:String?,theirsName:String?,mineName:String?,mergedName:String?
    public let baseReflectedName:String?,theirsReflectedName:String?,mineReflectedName:String?,mergedReflectedName:String?
    public let patchOriginal:String?,patchPatched:String?
    public let readOnly:Bool,blame:Bool,oneWay:Bool,reversedPatch:Bool
    public let saveRequired:Bool,saveRequiredOnConflicts:Bool,deleteInputsOnClose:Bool,workingCopy:Bool,createUnifiedDiff:Bool,help:Bool
    /// Source /line is one-based; the native editor converts it to an index.
    public let line:Int?
    public struct Failure:Error,LocalizedError,Equatable,Sendable {
        public let message:String
        public var errorDescription:String? {message}
        public init(_ message:String) {self.message=message}
    }
    private static let flags:Set<String>=["readonly","blame","oneway","reversedpatch","saverequired","saverequiredonconflicts","deletebasetheirsmineonclose","wc","createunifieddiff","help","?"]
    private static let valued:Set<String>=["base","theirs","mine","merged","basename","theirsname","minename","mergedname","basereflectedname","theirsreflectedname","minereflectedname","mergedreflectedname","diff","patchpath","patchoriginal","patchpatched","line","origfile","modifiedfile","outfile"]
    private static let aliases:[String:String]=["read-only":"readonly","one-way":"oneway","reversed-patch":"reversedpatch","save-required":"saverequired","save-required-on-conflicts":"saverequiredonconflicts","onconflicts":"saverequiredonconflicts","delete-inputs-on-close":"deletebasetheirsmineonclose","working-copy":"wc","create-unified-diff":"createunifieddiff","base-name":"basename","theirs-name":"theirsname","mine-name":"minename","merged-name":"mergedname","base-reflected-name":"basereflectedname","theirs-reflected-name":"theirsreflectedname","mine-reflected-name":"minereflectedname","merged-reflected-name":"mergedreflectedname","patch-path":"patchpath","patch-original":"patchoriginal","patch-patched":"patchpatched","original-file":"origfile","modified-file":"modifiedfile","output-file":"outfile"]
    private static func option(_ argument:String)->(key:String,value:String?,legacy:Bool)? {
        let legacy=argument.hasPrefix("/")
        guard legacy || argument.hasPrefix("--") else{return nil}
        let body=argument.dropFirst(legacy ? 1:2),separator:Character=legacy ? ":":"="
        let parts=body.split(separator:separator,maxSplits:1,omittingEmptySubsequences:false)
        guard let first=parts.first else{return nil}
        let raw=String(first).lowercased(),key=aliases[raw] ?? raw
        return (key,parts.count==2 ? String(parts[1]):nil,legacy)
    }
    /// Excludes argv[0]. Native values may follow --key or --key=; legacy values
    /// use /key:value. Literal paths are accepted with --merge-tool only.
    public static func parse(arguments:[String],currentDirectory:String) throws -> Self? {
        if arguments.contains(where:{Self.option($0)?.key=="command"}) {return nil}
        let marked=arguments.contains {guard let option=Self.option($0) else{return false};return !option.legacy && option.key=="merge-tool"}
        guard marked || arguments.contains(where:{value in guard let key=option(value)?.key else{return false};return flags.contains(key) || valued.contains(key) || ["resolvemsghwnd","resolvemsgwparam","resolvemsglparam"].contains(key)}) else{return nil}
        guard !currentDirectory.contains("\0"),currentDirectory.hasPrefix("/") else{throw Failure("The Merge-tool working directory must be an absolute path.")}
        var values:[String:String]=[:],positionals:[String]=[],index=0,markerSeen=false,positionalOnly=false
        while index<arguments.count {
            let argument=arguments[index];index += 1
            guard !argument.contains("\0") else{throw Failure("Merge-tool arguments cannot contain NUL.")}
            if !positionalOnly,let marker=option(argument),!marker.legacy,marker.key=="merge-tool" {
                guard marker.value==nil else{throw Failure("The Merge-tool marker takes no value.")}
                guard !markerSeen else{throw Failure("Duplicate Merge-tool marker.")};markerSeen=true;continue
            }
            if argument=="--",marked {positionalOnly=true;continue}
            let parsed=positionalOnly ? nil:option(argument)
            if let parsed,flags.contains(parsed.key) || valued.contains(parsed.key) {
                guard values[parsed.key]==nil else{throw Failure("Duplicate Merge-tool option: "+parsed.key)}
                if flags.contains(parsed.key) {
                    guard parsed.value==nil else{throw Failure("Merge-tool option takes no value: "+parsed.key)}
                    values[parsed.key]=""
                } else if let value=parsed.value {values[parsed.key]=value}
                else {
                    guard !parsed.legacy,index<arguments.count,!arguments[index].hasPrefix("--") else{throw Failure("Missing value for Merge-tool option: "+parsed.key)}
                    let value=arguments[index];index += 1
                    guard !value.contains("\0") else{throw Failure("Merge-tool arguments cannot contain NUL.")}
                    values[parsed.key]=value
                }
            } else if marked,(positionalOnly || !argument.hasPrefix("--") && (!argument.hasPrefix("/") || argument.dropFirst().contains("/"))) {positionals.append(argument)}
            else {
                let key=parsed?.key ?? argument
                if ["resolvemsghwnd","resolvemsgwparam","resolvemsglparam"].contains(key) {throw Failure("Windows HWND resolve notifications are unavailable on macOS: "+key)}
                throw Failure("Unsupported Merge-tool option: "+key)
            }
        }
        if !positionals.isEmpty {
            guard positionals.count<=3,values["base"]==nil,values["mine"]==nil,values["theirs"]==nil else{throw Failure("Use one to three positional Merge-tool files or named inputs, without mixing them.")}
            if positionals.count==1 {values["mine"]=positionals[0]}
            else {values["base"]=positionals[0];values["mine"]=positionals[1];if positionals.count==3 {values["theirs"]=positionals[2]}}
        }
        func location(_ key:String)throws->URL? {
            guard let raw=values[key] else{return nil}
            guard !raw.isEmpty else{throw Failure("Empty Merge-tool file option: "+key)}
            var expanded=raw
            if raw.hasPrefix("~") {
                let prefix=raw.split(separator:"/",maxSplits:1,omittingEmptySubsequences:false)[0]
                let user=String(prefix.dropFirst())
                if let home=user.isEmpty ? NSHomeDirectory():NSHomeDirectoryForUser(user) {
                    // Expand only the home prefix. NSString path conversion and
                    // fileURLWithPath can decompose the original filename tail.
                    expanded=home+String(raw.dropFirst(prefix.count))
                }
            }
            let absolute=expanded.hasPrefix("/") ? expanded:currentDirectory+"/"+expanded
            return FileTransferPaths.fileURL(FileTransferPaths.lexicalPath(absolute))
        }
        var mine=try location("mine"),mineName=values["minename"],theirs=try location("theirs"),theirsName=values["theirsname"]
        let base=try location("base"),diff=try location("diff")
        // CWorkingFile::TransferDetailsFrom moves filename/descriptive name and
        // retires Theirs. Reflected names are deliberately not transferred.
        if base != nil,mine==nil,theirs != nil {mine=theirs;mineName=theirsName;theirs=nil;theirsName=nil}
        let line:Int?
        if let raw=values["line"] {guard let value=Int(raw),value>0 else{throw Failure("Merge-tool line must be a positive one-based integer.")};line=value} else{line=nil}
        return Self(base:base,theirs:theirs,mine:mine,merged:try location("merged"),diff:diff,
            patchPath:try location("patchpath") ?? (values["wc"] != nil ? diff?.deletingLastPathComponent():nil),
            originalFile:try location("origfile"),modifiedFile:try location("modifiedfile"),outputFile:try location("outfile"),
            baseName:values["basename"],theirsName:theirsName,mineName:mineName,mergedName:values["mergedname"],
            baseReflectedName:values["basereflectedname"],theirsReflectedName:values["theirsreflectedname"],mineReflectedName:values["minereflectedname"],mergedReflectedName:values["mergedreflectedname"],
            patchOriginal:values["patchoriginal"],patchPatched:values["patchpatched"],readOnly:values["readonly"] != nil || values["blame"] != nil,
            blame:values["blame"] != nil,oneWay:values["oneway"] != nil && diff==nil,reversedPatch:values["reversedpatch"] != nil,
            saveRequired:values["saverequired"] != nil,saveRequiredOnConflicts:values["saverequiredonconflicts"] != nil,
            deleteInputsOnClose:values["deletebasetheirsmineonclose"] != nil,workingCopy:values["wc"] != nil,createUnifiedDiff:values["createunifieddiff"] != nil,
            help:values["help"] != nil || values["?"] != nil,line:line)
    }
}

/// A command-line output is captured before the editor opens, including absence.
/// Choosing a filename is not permission to overwrite a subsequently changed file.
public struct MergeToolOutputTarget:Sendable {
    public let url:URL
    public let content:ComparisonFileContent
    private let identity:String?
    private static func fileIdentity(_ url:URL)throws->String? {
        let attributes=try FileManager.default.attributesOfItem(atPath:url.path)
        guard attributes[.type] as? FileAttributeType == .typeRegular else{throw FileComparisonEditFailure.unsupported}
        return (attributes[.systemNumber] as? NSNumber).flatMap {device in (attributes[.systemFileNumber] as? NSNumber).map{device.stringValue+":"+$0.stringValue}}
    }
    public init(capturing url:URL,absentPermissions:Int=0o644)throws {
        let location=url.standardizedFileURL
        guard location.isFileURL,!location.path.contains("\0") else{throw FileComparisonEditFailure.unsupported}
        self.url=location
        do {
            let before=try Self.fileIdentity(location),actual=try WorkingFileComparison.workingContent(at:location)
            guard try Self.fileIdentity(location)==before else{throw FileComparisonEditFailure.changed}
            content=actual;identity=before
        } catch let error as CocoaError where error.code == .fileNoSuchFile || error.code == .fileReadNoSuchFile {
            content=ComparisonFileContent(path:location.path,revision:.workingTree,bytes:Data(),mode:absentPermissions & 0o111 != 0 ? "100755":"100644",permissions:absentPermissions,isDeleted:true);identity=nil
        }
    }
    private init(url:URL,content:ComparisonFileContent,identity:String?) {self.url=url;self.content=content;self.identity=identity}
    public func validate()throws {
        let current=try Self(capturing:url,absentPermissions:content.permissions ?? 0o644)
        guard current.content.bytes==content.bytes,current.content.permissions==content.permissions,current.content.mode==content.mode,current.content.isDeleted==content.isDeleted,current.identity==identity else{throw FileComparisonEditFailure.changed}
    }
    public func save(text:String,encoding:ComparisonTextEncoding?=nil,options:MergeFileSaveOptions = .init(),cancellation:OperationCancellation?=nil)throws->Self {
        try cancellation?.check()
        guard !text.utf8.contains(0) else{throw FileComparisonEditFailure.encoding}
        let selected=encoding ?? content.encoding ?? .utf8
        return try write(bytes:selected.encode(text),encoding:selected,options:options,cancellation:cancellation)
    }
    /// Unified patches may contain arbitrary original bytes. Never decode and
    /// re-encode them merely to write a command-line output.
    public func save(bytes:Data,options:MergeFileSaveOptions = .init(),cancellation:OperationCancellation?=nil,validatingInputs:(()throws->Void)?=nil)throws->Self {
        try write(bytes:bytes,encoding:nil,options:options,cancellation:cancellation,validatingInputs:validatingInputs)
    }
    private func write(bytes:Data,encoding:ComparisonTextEncoding?,options:MergeFileSaveOptions,cancellation:OperationCancellation?,validatingInputs:(()throws->Void)?=nil)throws->Self {
        try cancellation?.check(); try validate();try validatingInputs?()
        guard options.emptyResult != .delete || bytes.isEmpty else{throw MergeFileSaveFailure.nonemptyDeletion}
        guard !MergePaneSaveAs.requiresSaveAs(at:url,permissions:content.permissions,absent:content.isDeleted) else{throw FileComparisonEditFailure.readOnly}
        let deleting=options.emptyResult == .delete
        try MergeWorkingFileSave.write(at:url,original:content.isDeleted ? nil:content.bytes,permissions:content.permissions ?? 0o644,bytes:bytes,delete:deleting,backup:options.backupOriginal,outputDirectories:options.outputDirectories) {
            try cancellation?.check(); try validate();try validatingInputs?()
        }
        // Publication has succeeded. Always return its owned receipt, even if
        // cancellation arrives now; callers must adopt a completed disk write.
        let observed=try Self(capturing:url,absentPermissions:content.permissions ?? 0o644)
        guard observed.content.isDeleted==deleting,deleting || observed.content.bytes==bytes else{throw FileComparisonEditFailure.changed}
        let saved=ComparisonFileContent(path:url.path,revision:.workingTree,bytes:deleting ? Data():bytes,mode:observed.content.mode,permissions:observed.content.permissions,encoding:encoding ?? observed.content.encoding,isDeleted:deleting)
        return Self(url:url,content:saved,identity:observed.identity)
    }
    /// Keep the input's location while using the saved result as a clean draft
    /// baseline; source FileSave does not turn Mine into the merged filename.
    public func savedPaneContent(like original:ComparisonFileContent)->ComparisonFileContent {
        ComparisonFileContent(path:original.path,revision:original.revision,bytes:content.bytes,mode:original.mode,permissions:original.permissions,encoding:content.encoding,isDeleted:content.isDeleted)
    }
}

/// Source CWorkingFile permits a named missing input as an empty pane. This
/// opt-in does not weaken normal working-tree readers or grant folder access.
public enum MergeToolFileInput {
    public static func read(at url:URL,absentPermissions:Int=0o644)throws->ComparisonFileContent {
        try MergeToolOutputTarget(capturing:url,absentPermissions:absentPermissions).content
    }
}
extension WorkingFileComparison {
    public func readForMergeTool(replacements:[Bool:ComparisonFileContent]=[:])throws->FileComparisonDocument {
        FileComparisonDocument(base:try replacements[true] ?? MergeToolFileInput.read(at:base),destination:try replacements[false] ?? MergeToolFileInput.read(at:destination))
    }
}
