// SPDX-License-Identifier: GPL-2.0-or-later
import Foundation

/// Standalone IDiff entry. Parsing grants no access and does not infer image
/// mode from Merge's otherwise-identical three-file command-line arguments.
public struct ImageToolInvocation:Sendable {
    public let base:URL?,mine:URL?,theirs:URL?,result:URL?,left:URL?,right:URL?
    public let titles:[ImageConflictSide:String]
    public let leftTitle:String?,rightTitle:String?
    public let overlay:Bool,fitWidths:Bool,fitHeights:Bool,showInfo:Bool,deleteInputsOnClose:Bool
    public let opensChooser:Bool
    public var isSelection:Bool {base != nil && mine != nil && theirs != nil}
    public struct Failure:Error,LocalizedError,Equatable,Sendable {
        public let message:String
        public init(_ message:String) {self.message=message}
        public var errorDescription:String? {message}
    }
    private static let valued:Set<String>=["base","mine","theirs","result","left","right","basetitle","minetitle","theirstitle","lefttitle","righttitle"]
    private static let flags:Set<String>=["overlay","fit","fitwidth","fitheight","showinfo","deletebasetheirsmineonclose"]
    private static let aliases:[String:String]=["base-title":"basetitle","mine-title":"minetitle","theirs-title":"theirstitle","left-title":"lefttitle","right-title":"righttitle","fit-widths":"fitwidth","fit-heights":"fitheight","show-info":"showinfo","delete-inputs-on-close":"deletebasetheirsmineonclose"]
    private static func option(_ value:String)->(key:String,value:String?,legacy:Bool)? {
        let legacy=value.hasPrefix("/")
        guard legacy || value.hasPrefix("--") else{return nil}
        let parts=value.dropFirst(legacy ? 1:2).split(separator:legacy ? ":":"=",maxSplits:1,omittingEmptySubsequences:false)
        guard let name=parts.first else{return nil}
        let lower=name.lowercased()
        return (aliases[lower] ?? lower,parts.count>1 ? String(parts[1]):nil,legacy)
    }
    public static func parse(arguments:[String],currentDirectory:String)throws->Self? {
        let envelopes=arguments.prefix(while:{$0 != "--"}).compactMap(option).filter{!$0.legacy}
        let marked=envelopes.contains{$0.key == "image-tool"}
        let otherTool=envelopes.contains{["merge-tool","unified-diff-tool","unified-diff"].contains($0.key)}
        if otherTool {
            guard !marked else {throw Failure("Do not mix image-tool and other standalone tool requests.")}
            return nil
        }
        if arguments.contains(where:{option($0)?.key == "command"}) {return nil}
        let comparison=arguments.contains{let key=option($0)?.key;return key == "left" || key == "right"}
        guard marked || comparison else{return nil}
        guard currentDirectory.hasPrefix("/"),!currentDirectory.contains("\0") else{throw Failure("The image-tool working directory must be absolute.")}
        var values:[String:String]=[:],positionals:[String]=[],index=0,marker=false,literal=false
        while index<arguments.count {
            let argument=arguments[index];index+=1
            guard !argument.contains("\0") else{throw Failure("Image-tool arguments cannot contain NUL.")}
            if !literal,let parsed=option(argument),parsed.key == "image-tool",!parsed.legacy {
                guard !marker,parsed.value==nil else{throw Failure("Invalid or duplicate image-tool marker.")}
                marker=true;continue
            }
            if argument == "--",marked {literal=true;continue}
            if !literal,let parsed=option(argument),valued.contains(parsed.key) || flags.contains(parsed.key) {
                guard values[parsed.key]==nil else{throw Failure("Duplicate image-tool option: "+parsed.key)}
                if flags.contains(parsed.key) {
                    guard parsed.value==nil else{throw Failure("Image-tool flag takes no value: "+parsed.key)}
                    values[parsed.key]=""
                } else if let value=parsed.value {values[parsed.key]=value}
                else {
                    guard !parsed.legacy,index<arguments.count,!arguments[index].hasPrefix("--") else{throw Failure("Missing image-tool value: "+parsed.key)}
                    let value=arguments[index];index+=1
                    guard !value.contains("\0") else{throw Failure("Image-tool arguments cannot contain NUL.")}
                    values[parsed.key]=value
                }
            } else if marked,(literal || !argument.hasPrefix("--") && (!argument.hasPrefix("/") || argument.dropFirst().contains("/"))) {positionals.append(argument)}
            else {throw Failure("Unsupported image-tool option: "+argument)}
        }
        if !positionals.isEmpty {
            guard positionals.count==2,values["left"]==nil,values["right"]==nil else{throw Failure("Use two positional comparison files or named inputs.")}
            values["left"]=positionals[0];values["right"]=positionals[1]
        }
        // TortoiseIDiff.cpp posts File/Open for Base alone. This is a
        // comparison chooser seed, not a one-sided three-pane selection.
        let baseOnly=values["base"] != nil && values["mine"]==nil && values["theirs"]==nil && values["left"]==nil && values["right"]==nil
        if baseOnly {
            guard values["result"]==nil,values["deletebasetheirsmineonclose"]==nil else {throw Failure("A selection result or cleanup requires all three input files.")}
            values["left"]=values.removeValue(forKey:"base")
            if let title=values["basetitle"] {values["lefttitle"]=title}
        }
        let selectionKeys=["base","mine","theirs"],hasSelection=selectionKeys.contains{values[$0] != nil}
        if hasSelection {
            guard selectionKeys.allSatisfy({values[$0] != nil}),values["left"]==nil,values["right"]==nil else{throw Failure("Image selection requires Base, Mine and Theirs without comparison inputs.")}
        } else if values["result"] != nil || values["deletebasetheirsmineonclose"] != nil {throw Failure("An image selection result or input cleanup requires all three input files.")}
        func location(_ key:String)throws->URL? {
            guard let raw=values[key] else{return nil}
            guard !raw.isEmpty else{throw Failure("Empty image-tool file: "+key)}
            let absolute=raw.hasPrefix("/") ? raw:currentDirectory+"/"+raw
            return FileTransferPaths.fileURL(FileTransferPaths.lexicalPath(absolute))
        }
        var titles:[ImageConflictSide:String]=[:]
        for (side,key) in [(ImageConflictSide.base,"basetitle"),(.mine,"minetitle"),(.theirs,"theirstitle")] {titles[side]=values[key]}
        return Self(base:try location("base"),mine:try location("mine"),theirs:try location("theirs"),result:try location("result"),left:try location("left"),right:try location("right"),titles:titles,leftTitle:values["lefttitle"],rightTitle:values["righttitle"],overlay:values["overlay"] != nil,fitWidths:values["fit"] != nil || values["fitwidth"] != nil,fitHeights:values["fit"] != nil || values["fitheight"] != nil,showInfo:values["showinfo"] != nil,deleteInputsOnClose:values["deletebasetheirsmineonclose"] != nil,opensChooser:baseOnly || !hasSelection && values["left"]==nil && values["right"]==nil)
    }
    /// FileType values are selection results, not generic process success/error.
    /// Cancellation returns 0; a generic failure must not be mistaken for Mine.
    public static func selectionExitCode(_ side:ImageConflictSide)->Int32 {
        switch side {case .mine:return 1;case .theirs:return 2;case .base:return 3}
    }
}

extension ImageConflictSide {
    public var imageSelectionExitStatus:Int32 {ImageToolInvocation.selectionExitCode(self)}
}
