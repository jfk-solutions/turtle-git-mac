import AppKit
import SwiftUI
import ImageIO
import UniformTypeIdentifiers
import TurtleGitCore
import Darwin

/// WMF follows the source enhanced-metafile convention. EMF is its explicit
/// modern extension; both contain genuine enhanced-metafile vector records.
extension StatisticsGraphFormat {
    var title: String { self == .jpeg ? "JPEG" : rawValue.uppercased() }
    var contentType: UTType {
        switch self { case .pdf: return .pdf; case .png: return .png; case .jpeg: return .jpeg; case .bmp: return .bmp; case .gif: return .gif; case .wmf: return UTType(filenameExtension:"wmf") ?? .data; case .emf: return UTType(filenameExtension:"emf") ?? .data }
    }
}

enum StatisticsGraphExportFailure: LocalizedError {
    case unavailable, invalidSize, rendering, encoding, finalDestination
    var errorDescription: String? {
        switch self {
        case .unavailable: return "Select a graph before saving statistics."
        case .invalidSize: return "The graph is too large to export at this size."
        case .rendering: return "The statistics graph could not be rendered."
        case .encoding: return "The statistics graph could not be encoded in the selected format."
        case .finalDestination: return "Confirm the final graph filename in the Save panel before exporting."
        }
    }
}

@MainActor enum StatisticsGraphExport {
    static func data(graph: LogStatisticsGraph, metric: LogStatisticsMetric, style: LogStatisticsStyle, size: CGSize, dark: Bool, format: StatisticsGraphFormat) throws -> Data {
        guard metric != .statistics else { throw StatisticsGraphExportFailure.unavailable }
        guard validSize(size) else { throw StatisticsGraphExportFailure.invalidSize }
        let drawing=StatisticsVectorScene.make(graph:graph,style:style,size:size,dark:dark)
        switch format {
        case .pdf:return try MacGraphVectorRenderer.pdf(drawing.scene,title:metric.title)
        case .wmf,.emf:return try MacGraphVectorRenderer.emf(drawing.scene)
        case .png,.jpeg,.bmp,.gif:return try MacGraphVectorRenderer.raster(drawing.scene,type:format.contentType,jpegQuality:0.9)
        }
    }
    private static func validSize(_ size: CGSize) -> Bool {
        size.width.isFinite && size.height.isFinite && size.width >= 1 && size.height >= 1 && size.width <= 16384 && size.height <= 16384 && size.width * size.height <= 32_000_000
    }

    /// Keep the exact accepted file URL's scope through real IO. All bytes stay
    /// private until the last cancellation check and the atomic rename; a later
    /// cancellation cannot turn an already published graph into a failed save.
    nonisolated static func write(data:Data,to url:URL,cancellation:OperationCancellation) async throws {
        try await withTaskCancellationHandler(operation:{
            try await Task.detached(priority:.userInitiated) {try writeStaged(data,to:url,cancellation:cancellation)}.value
        },onCancel:{cancellation.cancel()})
    }
    private nonisolated static func writeStaged(_ data:Data,to url:URL,cancellation:OperationCancellation) throws {
        try cancellation.check()
        let name=url.lastPathComponent
        guard url.isFileURL,!url.hasDirectoryPath,url.path.hasPrefix("/"),!name.isEmpty,name != ".",name != "..",!name.contains("\0") else {throw StatisticsGraphExportFailure.finalDestination}
        let scoped=url.startAccessingSecurityScopedResource()
        defer {if scoped {url.stopAccessingSecurityScopedResource()}}
        if GitRuntime.isAppStoreBuild && !scoped {throw RepositoryAccessFailure.securityScopeUnavailable}
        var coordinationError:NSError?,failure:Error?,published=false
        NSFileCoordinator().coordinate(writingItemAt:url,options:.forReplacing,error:&coordinationError) { destination in
            var workspace:URL?
            defer {if let workspace {try? FileManager.default.removeItem(at:workspace)}}
            do {
                try cancellation.check()
                guard destination.standardizedFileURL.path.utf8.elementsEqual(url.standardizedFileURL.path.utf8) else {throw StatisticsGraphExportFailure.finalDestination}
                let parent=open(destination.deletingLastPathComponent().path,O_RDONLY|O_DIRECTORY|O_CLOEXEC)
                guard parent>=0 else {throw POSIXError(POSIXErrorCode(rawValue:errno) ?? .EIO)}
                defer {Darwin.close(parent)}
                // The panel may grant only the final file. Foundation selects
                // a same-volume workspace without requiring arbitrary siblings.
                let replacement=try FileManager.default.url(for:.itemReplacementDirectory,in:.userDomainMask,appropriateFor:destination,create:true)
                workspace=replacement
                var parentInfo=stat(),replacementInfo=stat()
                guard fstat(parent,&parentInfo)==0,lstat(replacement.path,&replacementInfo)==0,
                    replacementInfo.st_mode & S_IFMT == S_IFDIR,parentInfo.st_dev==replacementInfo.st_dev else {throw StatisticsGraphExportFailure.finalDestination}
                try FileManager.default.setAttributes([.posixPermissions:0o700],ofItemAtPath:replacement.path)
                let stagingDirectory=open(replacement.path,O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC)
                guard stagingDirectory>=0 else {throw POSIXError(POSIXErrorCode(rawValue:errno) ?? .EIO)}
                defer {Darwin.close(stagingDirectory)}
                let descriptor=openat(stagingDirectory,"graph",O_WRONLY|O_CREAT|O_EXCL|O_NOFOLLOW|O_CLOEXEC,mode_t(0o600))
                guard descriptor>=0 else {throw POSIXError(POSIXErrorCode(rawValue:errno) ?? .EIO)}
                defer {Darwin.close(descriptor)}
                try data.withUnsafeBytes { bytes in
                    var offset=0
                    while offset<bytes.count {
                        try cancellation.check()
                        let written=Darwin.write(descriptor,bytes.baseAddress!.advanced(by:offset),min(65536,bytes.count-offset))
                        if written<0 && errno==EINTR {continue}
                        guard written>0 else {throw POSIXError(POSIXErrorCode(rawValue:errno) ?? .EIO)}
                        offset += written
                    }
                }
                try cancellation.check()
                guard renameat(stagingDirectory,"graph",parent,destination.lastPathComponent)==0 else {throw POSIXError(POSIXErrorCode(rawValue:errno) ?? .EIO)}
                published=true
            } catch {failure=error}
        }
        if published {return}
        if let failure {throw failure}
        if let coordinationError {throw coordinationError}
        throw StatisticsGraphExportFailure.finalDestination
    }
}

@MainActor final class StatisticsGraphSavePanel: NSObject,NSOpenSavePanelDelegate {
    let panel = NSSavePanel()
    let formats = NSPopUpButton(frame: NSRect(x: 72, y: 0, width: 160, height: 26))
    private var retired=false
    var filter:StatisticsGraphExportFilter {formats.indexOfSelectedItem==1 ? .allFiles:.pictures}
    var format: StatisticsGraphFormat {(try? StatisticsGraphExportDestination(url:URL(fileURLWithPath:"/"+panel.nameFieldStringValue),filter:filter).format) ?? .wmf}
    override init() {
        super.init()
        panel.title = "Save Graph As"; panel.nameFieldStringValue = "statistics.wmf"; panel.canCreateDirectories = true
        panel.delegate=self;panel.allowsOtherFileTypes = true
        let accessory = NSView(frame: NSRect(x: 0, y: 0, width: 232, height: 26))
        let label = NSTextField(labelWithString: "Format:"); label.frame = NSRect(x: 0, y: 4, width: 66, height: 18)
        formats.addItems(withTitles:["Pictures","All Files"]); formats.target = self; formats.action = #selector(changeFormat)
        accessory.addSubview(label); accessory.addSubview(formats); panel.accessoryView = accessory
        changeFormat()
    }
    @objc func changeFormat() {
        guard !retired else{return}
        panel.allowedContentTypes = filter == .pictures ? StatisticsGraphFormat.allCases.map(\.contentType):[]
        // The filter supplies only an extensionless default. Changing it never
        // rewrites a user-selected or custom suffix; filename picks the encoder.
    }
    func normalizedFilename(_ filename:String)throws->String {try StatisticsGraphExportDestination.normalizedFilename(filename,filter:filter)}
    func panel(_ sender:Any,userEnteredFilename filename:String,confirmed okFlag:Bool)->String? {
        guard !retired else{return nil};guard okFlag else{return filename}
        return (try? normalizedFilename(filename)) ?? filename
    }
    func panel(_ sender:Any,validate url:URL)throws {_ = try destination(for:url)}
    func destination(for acceptedURL:URL)throws->StatisticsGraphExportDestination {
        guard !retired else{throw StatisticsGraphExportFailure.finalDestination}
        let result=try StatisticsGraphExportDestination(url:acceptedURL,filter:filter)
        guard result.url.path.utf8.elementsEqual(acceptedURL.path.utf8) else {throw StatisticsGraphExportFailure.finalDestination}
        return result
    }
    func retire() {retired=true;panel.delegate=nil;formats.target=nil;formats.action=nil}
}
