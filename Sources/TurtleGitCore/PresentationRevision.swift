// SPDX-License-Identifier: GPL-2.0-or-later
import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif
import CryptoKit

public enum PresentationRevisionFailure: LocalizedError, Sendable {
    case invalid(String), unsupported(String), unresolved
    public var errorDescription:String? {
        switch self {
        case .invalid(let reason):return "Invalid presentation package: " + reason
        case .unsupported(let reason):return "This presentation cannot be combined safely: " + reason
        case .unresolved:return "Accept or reject every presentation change before saving the editable deck."
        }
    }
}

public struct PresentationRevisionChange: Identifiable, Sendable, Equatable {
    public enum Kind:String, Sendable {case slideAdded,slideDeleted,slideMoved,shapeAdded,shapeDeleted,shapeChanged,shapeOrder,slideEnvironment,presentation}
    public let id:String,title:String,detail:String,baseSlideIndex:Int?,destinationSlideIndex:Int?,kind:Kind
    public var slideIndex:Int? {destinationSlideIndex ?? baseSlideIndex}
}

/// A two-way revision review. Accept selects New; reject selects Base. Groups
/// are atomic shapes. Slide environments with interdependent content are atomic
/// slides, rather than pretending that animation/notes/layout changes are text.
public struct PresentationRevisionReview: Sendable {
    public let changes:[PresentationRevisionChange]
    public let baseManifest:PresentationSlideManifest,destinationManifest:PresentationSlideManifest
    public let requiredFileExtension:String
    public var suggestedExtension:String {requiredFileExtension}
    public let invalidatesDigitalSignatures:Bool
    public let notices:[String]
    public private(set) var decisions:[String:Bool]=[:]
    private let base:PresentationPackage,destination:PresentationPackage
    private let plans:[RevisionSlidePlan]
    private let baseOrder:[String],destinationOrder:[String]
    private let environmentChange:String?,orderChange:String?
    private var history:[[RevisionDecisionDelta]]=[],future:[[RevisionDecisionDelta]]=[]
    public var canUndo:Bool {!history.isEmpty}
    public var canRedo:Bool {!future.isEmpty}
    public var unresolvedCount:Int {changes.count-decisions.count}
    public var isDirty:Bool {!decisions.isEmpty}

    public init(base:PresentationPackage,destination:PresentationPackage,cancellation:OperationCancellation? = nil)throws {
        let old=try RevisionDeck(base,cancellation:cancellation),new=try RevisionDeck(destination,cancellation:cancellation)
        self.base=base;self.destination=destination
        baseManifest=try old.manifest();destinationManifest=try new.manifest()
        baseOrder=old.slides.map(\.id);destinationOrder=new.slides.map(\.id)
        requiredFileExtension=(old.hasMacros || new.hasMacros) ? "pptm":"pptx"
        invalidatesDigitalSignatures=old.hasSignatures || new.hasSignatures
        notices=invalidatesDigitalSignatures ? ["Saving a reviewed presentation removes package digital signatures. The saved deck must be signed again."]:[]
        var changes:[PresentationRevisionChange]=[],plans:[RevisionSlidePlan]=[]
        func change(_ id:String,_ title:String,_ detail:String,_ kind:PresentationRevisionChange.Kind,_ a:Int?=nil,_ b:Int?=nil)->String {
            changes.append(.init(id:id,title:title,detail:detail,baseSlideIndex:a,destinationSlideIndex:b,kind:kind));return id
        }
        let environmentChanged=try old.environmentFingerprint(cancellation:cancellation) != new.environmentFingerprint(cancellation:cancellation)
        environmentChange=environmentChanged ? change("presentation","Presentation properties and shared content","Choose the presentation settings, metadata, macros and content outside the slides. Imported slide dependencies remain attached to their chosen slides.",.presentation):nil
        let common=Set(baseOrder).intersection(destinationOrder)
        let reordered=baseOrder.filter{common.contains($0)} != destinationOrder.filter{common.contains($0)}
        orderChange=reordered ? change("slide-order","Slide order","Accept New's slide order or retain Base's order. Added and restored slides keep their neighboring positions.",.slideMoved):nil
        let oldByID=Dictionary(uniqueKeysWithValues:old.slides.map{($0.id,$0)}),newByID=Dictionary(uniqueKeysWithValues:new.slides.map{($0.id,$0)})
        var shapeCount=0
        for id in baseOrder + destinationOrder.filter({oldByID[$0] == nil}) {
            try cancellation?.check()
            let priorSlide=oldByID[id],newSlide=newByID[id],prefix="slide-"+id
            if priorSlide == nil || newSlide == nil {
                let added=priorSlide == nil,index=(newSlide ?? priorSlide)!.index
                let key=change(prefix, "Slide \(index+1): " + (added ? "added":"deleted"), added ? "Accept to include the complete New slide and its dependencies.":"Accept to remove this slide; reject to restore the complete Base slide.",added ? .slideAdded:.slideDeleted,priorSlide?.index,newSlide?.index)
                plans.append(.init(id:id,base:priorSlide?.path,destination:newSlide?.path,whole:key,shapes:[],order:nil));continue
            }
            let a=priorSlide!,b=newSlide!
            let oldShapes=try old.shapes(a),newShapes=try new.shapes(b)
            shapeCount += oldShapes.count+newShapes.count;guard shapeCount<=40000 else{throw PresentationRevisionFailure.unsupported("More than 20,000 shapes per compared deck")}
            let oldMap=Dictionary(uniqueKeysWithValues:oldShapes.map{($0.id,$0)}),newMap=Dictionary(uniqueKeysWithValues:newShapes.map{($0.id,$0)})
            let ids=oldShapes.map(\.id)+newShapes.map(\.id).filter{oldMap[$0] == nil}
            var shapeChanges:[RevisionShapePlan]=[]
            for shapeID in ids {
                let x=oldMap[shapeID],y=newMap[shapeID]
                if try old.shapeFingerprint(x,slide:a,cancellation:cancellation) != new.shapeFingerprint(y,slide:b,cancellation:cancellation) {
                    let kind:PresentationRevisionChange.Kind=x == nil ? .shapeAdded:y == nil ? .shapeDeleted:.shapeChanged
                    shapeChanges.append(.init(id:shapeID,change:prefix+"-shape-"+shapeID,kind:kind,name:y?.name ?? x?.name ?? "Shape "+shapeID))
                }
            }
            let shapeOrderChanged=oldShapes.map(\.id).filter{newMap[$0] != nil} != newShapes.map(\.id).filter{oldMap[$0] != nil}
            let envChanged=try old.slideEnvironmentFingerprint(a,cancellation:cancellation) != new.slideEnvironmentFingerprint(b,cancellation:cancellation)
            let inseparable=try old.requiresAtomicSlide(a) || new.requiresAtomicSlide(b)
            if envChanged || (inseparable && (!shapeChanges.isEmpty || shapeOrderChanged)) {
                let key=change(prefix+"-environment","Slide \(b.index+1): slide content and environment","Choose the complete slide, including shapes, notes, layout, timing, transitions and dependent content. These changes are reviewed together to preserve their references.",.slideEnvironment,a.index,b.index)
                plans.append(.init(id:id,base:a.path,destination:b.path,whole:key,shapes:[],order:nil))
            } else {
                for shape in shapeChanges {
                    _=change(shape.change,"Slide \(b.index+1): "+shape.name,shape.kind == .shapeAdded ? "Added shape or group, including its linked content.":shape.kind == .shapeDeleted ? "Deleted shape or group.":"Changed shape or group, including its formatting and linked content.",shape.kind,a.index,b.index)
                }
                let order=shapeOrderChanged ? change(prefix+"-shape-order","Slide \(b.index+1): shape order","Choose New or Base stacking order for the retained shapes.",.shapeOrder,a.index,b.index):nil
                plans.append(.init(id:id,base:a.path,destination:b.path,whole:nil,shapes:shapeChanges,order:order))
            }
        }
        self.changes=changes;self.plans=plans
    }
    public mutating func decide(changeID:String,accept:Bool) {
        guard changes.contains(where:{$0.id==changeID}),decisions[changeID] != accept else{return}
        history.append([.init(id:changeID,old:decisions[changeID],new:accept)]);future=[];decisions[changeID]=accept
    }
    public mutating func decideAll(accept:Bool) {
        let next=Dictionary(uniqueKeysWithValues:changes.map{($0.id,accept)})
        guard next != decisions else{return};history.append(changes.compactMap {change in decisions[change.id] == accept ? nil:.init(id:change.id,old:decisions[change.id],new:accept)});future=[];decisions=next
    }
    public mutating func undo() {guard let previous=history.popLast() else{return};future.append(previous);for delta in previous{decisions[delta.id]=delta.old}}
    public mutating func redo() {guard let next=future.popLast() else{return};history.append(next);for delta in next{decisions[delta.id]=delta.new}}

    public func exported(cancellation:OperationCancellation? = nil)throws->PresentationPackage {
        try cancellation?.check();guard unresolvedCount==0 else{throw PresentationRevisionFailure.unresolved}
        let old=try RevisionDeck(base,cancellation:cancellation),new=try RevisionDeck(destination,cancellation:cancellation)
        // Choosing either complete revision preserves every opaque package member.
        if changes.allSatisfy({decisions[$0.id] == true}) {return try RevisionOutput.finish(destination,extension:requiredFileExtension,cancellation:cancellation)}
        if changes.allSatisfy({decisions[$0.id] == false}) {return try RevisionOutput.finish(base,extension:requiredFileExtension,cancellation:cancellation)}
        if old.types.values.contains(where:{$0.lowercased().contains("comment") || $0.lowercased().contains("person")}) || new.types.values.contains(where:{$0.lowercased().contains("comment") || $0.lowercased().contains("person")}) {
            throw PresentationRevisionFailure.unsupported("Mixed decisions in presentations with comment/author registries are not supported. Choose one complete revision to preserve comment identities.")
        }
        let anchorNew=environmentChange.map{decisions[$0] == true} ?? false
        let anchor=anchorNew ? new:old,other=anchorNew ? old:new
        var output=try RevisionOutput(anchor:anchor,foreign:other,cancellation:cancellation)
        let selected=plans.filter {plan in
            if plan.base == nil {return decisions[plan.whole!] == true}
            if plan.destination == nil {return decisions[plan.whole!] == false}
            return true
        }
        let selectedIDs=Set(selected.map(\.id))
        let useNewOrder=orderChange.map{decisions[$0] == true} ?? anchorNew
        let ordered=revisionMergedOrder(primary:useNewOrder ? destinationOrder:baseOrder,secondary:useNewOrder ? baseOrder:destinationOrder,included:selectedIDs)
        // Preallocate every slide before importing its graph, so slide hyperlinks
        // and notes back-references resolve to the selected deck rather than copies.
        for plan in selected {
            let anchorPath=anchorNew ? plan.destination:plan.base
            let foreignPath=anchorNew ? plan.base:plan.destination
            try output.reserveSlide(id:plan.id,anchor:anchorPath,foreign:foreignPath)
        }
        for plan in selected {
            try cancellation?.check()
            let chooseNew:Bool
            if let whole=plan.whole {chooseNew=decisions[whole] == true}
            else {chooseNew=anchorNew}
            let source=chooseNew ? new:old,path=chooseNew ? plan.destination!:plan.base!
            let target=output.slidePaths[plan.id]!
            if let _=plan.whole {
                try output.copyWholeSlide(source:source,path:path,target:target,fromAnchor:chooseNew == anchorNew,cancellation:cancellation)
            } else {
                try output.mergeSlide(plan:plan,base:old,destination:new,target:target,anchorNew:anchorNew,decisions:decisions,cancellation:cancellation)
            }
        }
        try output.registerSlides(ordered,cancellation:cancellation)
        return try RevisionOutput.finish(try PresentationPackage(entries:output.entries),extension:requiredFileExtension,cancellation:cancellation)
    }
}

private struct RevisionDecisionDelta:Sendable {let id:String,old:Bool?,new:Bool}
private struct RevisionSlidePlan:Sendable {let id:String,base:String?,destination:String?,whole:String?,shapes:[RevisionShapePlan],order:String?}
private struct RevisionShapePlan:Sendable {let id:String,change:String,kind:PresentationRevisionChange.Kind,name:String}
private struct RevisionSlide {let id:String,path:String,index:Int}
private struct RevisionShape {let id:String,name:String,element:XMLElement}
private let revisionRelationshipNS="http://schemas.openxmlformats.org/package/2006/relationships"
private let revisionOfficeRelationshipNS="http://schemas.openxmlformats.org/officeDocument/2006/relationships"
private func revisionLocal(_ node:XMLNode)->String {(node.name ?? "").split(separator:":").last.map(String.init) ?? ""}
private func revisionChildren(_ node:XMLElement)->[XMLElement] {(node.children ?? []).compactMap{$0 as? XMLElement}}
private func revisionChild(_ node:XMLElement,_ name:String)->XMLElement? {revisionChildren(node).first{revisionLocal($0)==name}}
private func revisionDescendants(_ node:XMLElement)->[XMLElement] {[node]+revisionChildren(node).flatMap(revisionDescendants)}
private func revisionAttribute(_ node:XMLElement,_ name:String)->String? {node.attribute(forName:name)?.stringValue}
private func revisionSet(_ node:XMLElement,_ name:String,_ value:String) {if let attr=node.attribute(forName:name){attr.stringValue=value}else{node.addAttribute(XMLNode.attribute(withName:name,stringValue:value) as! XMLNode)}}
private func revisionXML(_ data:Data,_ path:String)throws->XMLDocument {
    guard data.count<=64*1024*1024 else{throw PresentationRevisionFailure.invalid("XML part exceeds its size budget: "+path)}
    // Office packages do not require DTDs or entity definitions. Reject before
    // FoundationXML can consult a filesystem or network entity resolver.
    guard let xmlText=String(data:data,encoding:.utf8),!data.contains(0) else{throw PresentationRevisionFailure.unsupported("Only UTF-8 XML parts can be reviewed: "+path)}
    let probe=xmlText.uppercased()
    guard !probe.contains("<!DOCTYPE"),!probe.contains("<!ENTITY"),!data.starts(with:[0xff,0xfe]),!data.starts(with:[0xfe,0xff]) else{throw PresentationRevisionFailure.unsupported("DTD/entity or UTF-16 XML in "+path)}
    let document:XMLDocument
    do {document=try XMLDocument(data:data,options:[.nodePreserveAll,.nodeLoadExternalEntitiesNever])}
    catch {throw PresentationRevisionFailure.invalid("Unreadable XML: "+path)}
    guard let root=document.rootElement() else{throw PresentationRevisionFailure.invalid("Missing XML root: "+path)}
    var pending:[(XMLElement,Int)]=[(root,0)],count=0
    while let (node,depth)=pending.popLast() {
        count += 1;guard depth<=128,count<=200000 else{throw PresentationRevisionFailure.unsupported("XML depth/node budget exceeded: "+path)}
        pending.append(contentsOf:revisionChildren(node).map{($0,depth+1)})
    }
    return document
}
private func revisionData(_ document:XMLDocument)->Data {document.xmlData(options:[.nodePreserveAll])}
private func revisionHash(_ data:Data)->String {SHA256.hash(data:data).map{String(format:"%02x",$0)}.joined()}
private func revisionRelsPath(_ path:String)->String {if path.isEmpty{return "_rels/.rels"};let url=URL(fileURLWithPath:"/"+path);return String(url.deletingLastPathComponent().path.dropFirst()) + (url.deletingLastPathComponent().path == "/" ? "":"/") + "_rels/"+url.lastPathComponent+".rels"}
private func revisionTarget(_ raw:String,from path:String)throws->String {
    guard !raw.isEmpty,!raw.contains("\\"),!raw.contains("\0"),!raw.contains("?"),!raw.contains("#"),!raw.contains(":") else{throw PresentationRevisionFailure.unsupported("Invalid internal relationship target: "+raw)}
    guard let decoded=raw.removingPercentEncoding,!decoded.contains("\\"),!decoded.contains("\0"),!decoded.contains(":") else{throw PresentationRevisionFailure.invalid("Invalid relationship URI")}
    var result:[String]=raw.hasPrefix("/") ? []:path.split(separator:"/").dropLast().map(String.init)
    for component in decoded.split(separator:"/") {
        if component=="." {continue}
        if component==".." {guard !result.isEmpty else{throw PresentationRevisionFailure.invalid("Relationship escapes its package")};result.removeLast()}
        else {result.append(String(component))}
    }
    guard !result.isEmpty else{throw PresentationRevisionFailure.invalid("Empty relationship target")};return result.joined(separator:"/")
}
private func revisionRelative(_ target:String,from path:String)->String {
    let a=path.split(separator:"/").dropLast().map(String.init),b=target.split(separator:"/").map(String.init)
    var common=0;while common<min(a.count,b.count),a[common]==b[common]{common += 1}
    return (Array(repeating:"..",count:a.count-common)+b.dropFirst(common)).map{part in part.addingPercentEncoding(withAllowedCharacters:CharacterSet.urlPathAllowed.subtracting(CharacterSet(charactersIn:"%#?"))) ?? part}.joined(separator:"/")
}
private struct RevisionRelationship {let id:String,type:String,target:String,external:Bool,element:XMLElement}
private func revisionRelationships(_ entries:[String:Data],part:String)throws->[RevisionRelationship] {
    guard let data=entries[revisionRelsPath(part)] else{return []}
    let doc=try revisionXML(data,revisionRelsPath(part));guard revisionIs(doc.rootElement()!,"Relationships",revisionRelationshipNS) else{throw PresentationRevisionFailure.unsupported("Unsupported relationships namespace")};var seen=Set<String>()
    return try revisionChildren(doc.rootElement()!).map {element in
        guard revisionIs(element,"Relationship",revisionRelationshipNS),let id=revisionAttribute(element,"Id"),!id.isEmpty,seen.insert(id).inserted,let type=revisionAttribute(element,"Type"),let target=revisionAttribute(element,"Target") else{throw PresentationRevisionFailure.invalid("Malformed relationships for "+part)}
        let mode=revisionAttribute(element,"TargetMode");guard mode==nil || mode=="External" || mode=="Internal" else{throw PresentationRevisionFailure.invalid("Unknown relationship mode")}
        return RevisionRelationship(id:id,type:type,target:target,external:mode=="External",element:element)
    }
}
private func revisionRelationshipIDs(_ element:XMLElement)->Set<String> {
    Set(revisionDescendants(element).flatMap{node in (node.attributes ?? []).compactMap{attribute->String? in
        let name=attribute.name ?? "",prefix=String(name.split(separator:":").first ?? "")
        if attribute.uri==revisionOfficeRelationshipNS || (name.contains(":") && node.resolveNamespace(forName:prefix)?.stringValue==revisionOfficeRelationshipNS) {return attribute.stringValue};return nil
    }})
}
private func revisionMergedOrder(primary:[String],secondary:[String],included:Set<String>)->[String] {
    var result=primary.filter{included.contains($0)}
    for (index,id) in secondary.enumerated() where included.contains(id) && !result.contains(id) {
        if let before=secondary[..<index].reversed().first(where:{result.contains($0)}),let position=result.firstIndex(of:before){result.insert(id,at:position+1)}
        else if let after=secondary.dropFirst(index+1).first(where:{result.contains($0)}),let position=result.firstIndex(of:after){result.insert(id,at:position)}
        else{result.append(id)}
    }
    return result
}

private let revisionPresentationNS="http://schemas.openxmlformats.org/presentationml/2006/main"
private let revisionDrawingNS="http://schemas.openxmlformats.org/drawingml/2006/main"
private let revisionContentNS="http://schemas.openxmlformats.org/package/2006/content-types"
private func revisionIs(_ node:XMLElement,_ name:String,_ uri:String)->Bool {revisionLocal(node)==name && node.uri==uri}
private final class RevisionFingerprintCache {var raw:[String:String]=[:];var graph:[String:String]=[:]}
private struct RevisionDeck {
    private let fingerprints=RevisionFingerprintCache()
    let entries:[String:Data],presentation:String,slides:[RevisionSlide],types:[String:String],defaults:[String:String]
    var hasMacros:Bool {types.values.contains{$0.contains("macroEnabled") || $0.contains("vbaProject")} || entries.keys.contains{$0.lowercased().hasSuffix("vbaproject.bin")}}
    var hasSignatures:Bool {entries.keys.contains{$0.hasPrefix("_xmlsignatures/")} || ((try? revisionRelationships(entries,part:"").contains{$0.type.contains("digital-signature")}) ?? false)}
    init(_ package:PresentationPackage,cancellation:OperationCancellation?)throws {
        entries=package.entries
        guard let typeData=entries["[Content_Types].xml"] else{throw PresentationRevisionFailure.invalid("Missing [Content_Types].xml")}
        let typeRoot=try revisionXML(typeData,"[Content_Types].xml").rootElement()!
        guard revisionIs(typeRoot,"Types",revisionContentNS) else{throw PresentationRevisionFailure.unsupported("Unsupported content-types namespace")}
        var types:[String:String]=[:],defaults:[String:String]=[:]
        for item in revisionChildren(typeRoot) {
            guard item.uri==revisionContentNS,let type=revisionAttribute(item,"ContentType"),!type.isEmpty else{throw PresentationRevisionFailure.invalid("Malformed content type")}
            if revisionLocal(item)=="Override",let name=revisionAttribute(item,"PartName"),name.hasPrefix("/") {
                let path=try revisionTarget(name,from:"");guard types.updateValue(type,forKey:path)==nil else{throw PresentationRevisionFailure.invalid("Duplicate content type")}
            } else if revisionLocal(item)=="Default",let ext=revisionAttribute(item,"Extension"),!ext.isEmpty {
                guard defaults.updateValue(type,forKey:ext.lowercased())==nil else{throw PresentationRevisionFailure.invalid("Duplicate content type default")}
            } else{throw PresentationRevisionFailure.invalid("Malformed content type entry")}
        }
        self.types=types;self.defaults=defaults
        let rootRels=try revisionRelationships(entries,part:"")
        guard let main=rootRels.first(where:{$0.type==revisionOfficeRelationshipNS+"/officeDocument"}),!main.external,rootRels.filter({$0.type==revisionOfficeRelationshipNS+"/officeDocument"}).count==1 else{throw PresentationRevisionFailure.unsupported("A transitional OOXML presentation is required")}
        presentation=try revisionTarget(main.target,from:"")
        guard let data=entries[presentation] else{throw PresentationRevisionFailure.invalid("Missing presentation part")}
        let root=try revisionXML(data,presentation).rootElement()!
        guard revisionIs(root,"presentation",revisionPresentationNS) else{throw PresentationRevisionFailure.unsupported("Unsupported presentation namespace")}
        let rels=try revisionRelationships(entries,part:presentation),byID=Dictionary(uniqueKeysWithValues:rels.map{($0.id,$0)})
        var slides:[RevisionSlide]=[],seen=Set<String>(),paths=Set<String>()
        if let list=revisionChildren(root).first(where:{revisionIs($0,"sldIdLst",revisionPresentationNS)}) {
            for node in revisionChildren(list) {
                try cancellation?.check()
                guard revisionIs(node,"sldId",revisionPresentationNS),let id=revisionAttribute(node,"id"),let numeric=UInt32(id),numeric>=256,seen.insert(id).inserted,let rid=Self.relationshipID(node),let rel=byID[rid],!rel.external,rel.type==revisionOfficeRelationshipNS+"/slide" else{throw PresentationRevisionFailure.invalid("Invalid or duplicate slide identity")}
                let path=try revisionTarget(rel.target,from:presentation)
                guard entries[path] != nil,paths.insert(path).inserted else{throw PresentationRevisionFailure.invalid("Missing or duplicate slide part")}
                slides.append(.init(id:id,path:path,index:slides.count))
            }
        }
        guard slides.count<=512 else{throw PresentationRevisionFailure.unsupported("More than 512 slides")}
        self.slides=slides
        var shapeCount=0
        for slide in slides {try cancellation?.check();shapeCount += try shapes(slide).count;guard shapeCount<=20000 else{throw PresentationRevisionFailure.unsupported("More than 20,000 shapes in a deck")}}
        // Validate every declared internal edge, including opaque content which
        // the review preserves without interpreting or executing it.
        for path in entries.keys where path.hasSuffix(".rels") {
            try cancellation?.check()
            let owner=try Self.owner(of:path)
            for rel in try revisionRelationships(entries,part:owner) where !rel.external {
                let target=try revisionTarget(rel.target,from:owner)
                guard entries[target] != nil else{throw PresentationRevisionFailure.invalid("Missing relationship target: "+target)}
            }
        }
    }
    static func owner(of rels:String)throws->String {
        if rels=="_rels/.rels" {return ""}
        guard let range=rels.range(of:"/_rels/",options:.backwards),rels.hasSuffix(".rels") else{throw PresentationRevisionFailure.invalid("Malformed relationship part path")}
        return String(rels[..<range.lowerBound])+"/"+String(rels[range.upperBound...].dropLast(5))
    }
    static func relationshipID(_ node:XMLElement)->String? {(node.attributes ?? []).first{revisionLocal($0)=="id" && $0.uri==revisionOfficeRelationshipNS}?.stringValue}
    func contentType(_ path:String)throws->String {
        if let value=types[path] ?? defaults[(path as NSString).pathExtension.lowercased()] {return value}
        throw PresentationRevisionFailure.invalid("Missing content type: "+path)
    }
    func document(_ path:String)throws->XMLDocument {guard let data=entries[path] else{throw PresentationRevisionFailure.invalid("Missing part: "+path)};return try revisionXML(data,path)}
    func tree(_ slide:RevisionSlide)throws->XMLElement {
        let root=try document(slide.path).rootElement()!
        guard revisionIs(root,"sld",revisionPresentationNS),let cs=revisionChildren(root).first(where:{revisionIs($0,"cSld",revisionPresentationNS)}),let tree=revisionChildren(cs).first(where:{revisionIs($0,"spTree",revisionPresentationNS)}) else{throw PresentationRevisionFailure.invalid("Missing slide shape tree")};return tree
    }
    func shapes(_ slide:RevisionSlide)throws->[RevisionShape] {
        let shapeTree=try tree(slide)
        var seen=Set<String>(),allIDs=Set(revisionChildren(shapeTree).filter{revisionIs($0,"nvGrpSpPr",revisionPresentationNS)}.flatMap(revisionDescendants).filter{revisionIs($0,"cNvPr",revisionPresentationNS)}.compactMap{revisionAttribute($0,"id")}),result:[RevisionShape]=[]
        for node in revisionChildren(shapeTree) where !["nvGrpSpPr","grpSpPr","extLst"].contains(revisionLocal(node)) {
            guard node.uri==revisionPresentationNS,["sp","pic","graphicFrame","cxnSp","grpSp","contentPart"].contains(revisionLocal(node)) else{throw PresentationRevisionFailure.unsupported("Unknown shape tree element in slide \(slide.index+1)")}
            let ids=revisionDescendants(node).filter{revisionIs($0,"cNvPr",revisionPresentationNS)}
            for item in ids {guard let id=revisionAttribute(item,"id"),UInt32(id) != nil,allIDs.insert(id).inserted else{throw PresentationRevisionFailure.invalid("Duplicate nested shape identity")}}
            guard let identity=ids.first,let id=revisionAttribute(identity,"id"),UInt32(id) != nil,seen.insert(id).inserted else{throw PresentationRevisionFailure.invalid("Missing or duplicate shape identity")}
            result.append(.init(id:id,name:revisionAttribute(identity,"name") ?? "Shape "+id,element:node))
        }
        return result
    }
    func manifest()throws->PresentationSlideManifest {
        let result=try PresentationSlideManifest(slides:slides.map {slide in
            let root=try document(slide.path).rootElement()!
            let text=revisionDescendants(root).filter{revisionIs($0,"t",revisionDrawingNS)}.compactMap(\.stringValue).joined(separator:"\n")
            var notes=""
            for rel in try revisionRelationships(entries,part:slide.path) where !rel.external && rel.type==revisionOfficeRelationshipNS+"/notesSlide" {
                let part=try revisionTarget(rel.target,from:slide.path)
                notes += revisionDescendants(try document(part).rootElement()!).filter{revisionIs($0,"t",revisionDrawingNS)}.compactMap(\.stringValue).joined(separator:"\n")
            }
            return PresentationSlide(pageIndex:slide.index,stableID:slide.id,text:text,notes:notes)
        })
        try result.validate(cancellation:OperationCancellation());return result
    }
    func graphFingerprint(_ part:String,excluding:Set<String>,cancellation:OperationCancellation?)throws->String {
        let key=part+"|"+excluding.sorted().joined(separator:"|")
        if let value=fingerprints.graph[key]{try cancellation?.check();return value}
        var visited=Set<String>(),records:[String]=[]
        func visit(_ path:String,_ depth:Int)throws {
            try cancellation?.check();guard depth<=128,visited.count<=20000 else{throw PresentationRevisionFailure.unsupported("Dependency graph exceeds review budget")}
            if excluding.contains(path) {records.append("reference:"+path);return}
            guard visited.insert(path).inserted else{records.append("cycle:"+path);return}
            guard let data=entries[path] else{throw PresentationRevisionFailure.invalid("Missing dependency "+path)}
            let hash=fingerprints.raw[path] ?? revisionHash(data);fingerprints.raw[path]=hash;records.append(path+":"+hash)
            for rel in try revisionRelationships(entries,part:path).sorted(by:{$0.id<$1.id}) {
                records.append(rel.id+":"+rel.type+":"+rel.target+":"+String(rel.external))
                if !rel.external {try visit(revisionTarget(rel.target,from:path),depth+1)}
            }
        }
        try visit(part,0);let value=revisionHash(Data(records.joined(separator:"\n").utf8));if fingerprints.graph.count<50000{fingerprints.graph[key]=value};return value
    }
    func shapeFingerprint(_ shape:RevisionShape?,slide:RevisionSlide,cancellation:OperationCancellation?)throws->String? {
        guard let shape else{return nil}
        let refs=revisionRelationshipIDs(shape.element),rels=try revisionRelationships(entries,part:slide.path),map=Dictionary(uniqueKeysWithValues:rels.map{($0.id,$0)})
        var parts=[shape.element.xmlString(options:[.nodePreserveAll])]
        for id in refs.sorted() {
            guard let rel=map[id] else{throw PresentationRevisionFailure.invalid("Shape references a missing relationship")}
            parts.append(id+":"+rel.type+":"+rel.target)
            if !rel.external {parts.append(try graphFingerprint(revisionTarget(rel.target,from:slide.path),excluding:[slide.path,presentation],cancellation:cancellation))}
        }
        return revisionHash(Data(parts.joined(separator:"\n").utf8))
    }
    func slideEnvironmentFingerprint(_ slide:RevisionSlide,cancellation:OperationCancellation?)throws->String {
        let doc=try document(slide.path),root=doc.rootElement()!,shapes=try shapes(slide)
        let shapeRefs=shapes.reduce(into:Set<String>()){$0.formUnion(revisionRelationshipIDs($1.element))}
        guard let cs=revisionChild(root,"cSld"),let tree=revisionChild(cs,"spTree") else{throw PresentationRevisionFailure.invalid("Missing shape tree")}
        for node in revisionChildren(tree) where !["nvGrpSpPr","grpSpPr","extLst"].contains(revisionLocal(node)){node.detach()}
        let envRefs=revisionRelationshipIDs(root)
        var parts=[root.xmlString(options:[.nodePreserveAll])]
        for rel in try revisionRelationships(entries,part:slide.path).sorted(by:{$0.id<$1.id}) where !shapeRefs.contains(rel.id) || envRefs.contains(rel.id) {
            parts.append(rel.id+":"+rel.type+":"+rel.target)
            if !rel.external {parts.append(try graphFingerprint(revisionTarget(rel.target,from:slide.path),excluding:[slide.path,presentation],cancellation:cancellation))}
        }
        return revisionHash(Data(parts.joined(separator:"\n").utf8))
    }
    func requiresAtomicSlide(_ slide:RevisionSlide)throws->Bool {
        let root=try document(slide.path).rootElement()!
        return revisionDescendants(root).contains {node in
            (node.uri==revisionPresentationNS && ["timing","controls","legacyDrawing","extLst"].contains(revisionLocal(node))) || node.uri=="http://schemas.openxmlformats.org/markup-compatibility/2006"
        }
    }
    func environmentFingerprint(cancellation:OperationCancellation?)throws->String {
        var excluded=Set<String>()
        func visit(_ path:String,_ depth:Int=0)throws {
            try cancellation?.check();guard depth<=128,excluded.count<=40000 else{throw PresentationRevisionFailure.unsupported("Dependency graph exceeds review budget")};guard path != presentation,excluded.insert(path).inserted else{return}
            excluded.insert(revisionRelsPath(path))
            for rel in try revisionRelationships(entries,part:path) where !rel.external {try visit(revisionTarget(rel.target,from:path),depth+1)}
        }
        for slide in slides {try visit(slide.path)}
        let doc=try document(presentation),root=doc.rootElement()!
        revisionChildren(root).filter{revisionIs($0,"sldIdLst",revisionPresentationNS)}.forEach{$0.detach()}
        let relDoc=try document(revisionRelsPath(presentation))
        revisionChildren(relDoc.rootElement()!).filter{revisionAttribute($0,"Type")==revisionOfficeRelationshipNS+"/slide"}.forEach{$0.detach()}
        let typeDoc=try document("[Content_Types].xml")
        for node in revisionChildren(typeDoc.rootElement()!) {
            if let name=revisionAttribute(node,"PartName"),excluded.contains(try revisionTarget(name,from:"")){node.detach()}
        }
        var records=[revisionHash(revisionData(doc)),revisionHash(revisionData(relDoc)),revisionHash(revisionData(typeDoc))]
        excluded.formUnion([presentation,revisionRelsPath(presentation),"[Content_Types].xml"])
        for path in entries.keys.sorted() where !excluded.contains(path) {records.append(path+":"+revisionHash(entries[path]!))}
        return revisionHash(Data(records.joined(separator:"\n").utf8))
    }
}

private struct RevisionOutput {
    var entries:[String:Data],slidePaths:[String:String]=[:]
    let anchor:RevisionDeck,foreign:RevisionDeck
    private var mapping:[String:String]=[:],pinned=Set<String>(),imported=Set<String>(),counter=0
    private var typeOverrides:[String:String]=[:]
    init(anchor:RevisionDeck,foreign:RevisionDeck,cancellation:OperationCancellation?)throws {
        try cancellation?.check();self.anchor=anchor;self.foreign=foreign;entries=anchor.entries
        mapping[foreign.presentation]=anchor.presentation;pinned.insert(foreign.presentation)
    }
    mutating func reserveSlide(id:String,anchor:String?,foreign:String?)throws {
        let path=anchor ?? allocate(foreign ?? "ppt/slides/slide.xml")
        slidePaths[id]=path
        if let foreign {mapping[foreign]=path;pinned.insert(foreign)}
    }
    private mutating func allocate(_ source:String)->String {
        let url=URL(fileURLWithPath:"/"+source),directory=String(url.deletingLastPathComponent().path.dropFirst())
        while true {
            counter += 1
            let name=(directory.isEmpty ? "":directory+"/")+"turtlegit-\(counter)-"+url.lastPathComponent
            if entries[name]==nil && !mapping.values.contains(name) && !slidePaths.values.contains(name){return name}
        }
    }
    private mutating func importPart(_ path:String,cancellation:OperationCancellation?,depth:Int=0)throws->String {
        try cancellation?.check();guard depth<=128,imported.count<=20000 else{throw PresentationRevisionFailure.unsupported("Dependency graph exceeds export budget")}
        if let mapped=mapping[path],pinned.contains(path) || imported.contains(path){return mapped}
        guard foreign.entries[path] != nil else{throw PresentationRevisionFailure.invalid("Missing imported dependency "+path)}
        // A notes master is presentation-wide and cannot be registered twice.
        // Reuse only a byte/dependency-equivalent master; otherwise an independent
        // slide choice would silently change another slide's notes formatting.
        let type=try foreign.contentType(path)
        if type.contains("notesMaster") || type.contains("handoutMaster") {
            let existing=anchor.types.filter{$0.value==type}.map(\.key)
            if let first=existing.first {
                if try foreign.graphFingerprint(path,excluding:[foreign.presentation],cancellation:cancellation)==anchor.graphFingerprint(first,excluding:[anchor.presentation],cancellation:cancellation) {mapping[path]=first;pinned.insert(path);return first}
                throw PresentationRevisionFailure.unsupported("Mixed slides require different presentation-wide notes or handout masters. Choose one complete revision instead.")
            }
        }
        let target=mapping[path] ?? allocate(path);mapping[path]=target;imported.insert(path)
        entries[target]=foreign.entries[path];typeOverrides[target]=type
        try copyRelationships(from:path,to:target,cancellation:cancellation,depth:depth+1)
        return target
    }
    private mutating func copyRelationships(from source:String,to target:String,cancellation:OperationCancellation?,depth:Int=0)throws {
        let rels=try revisionRelationships(foreign.entries,part:source)
        guard !rels.isEmpty else{entries.removeValue(forKey:revisionRelsPath(target));return}
        guard let bytes=foreign.entries[revisionRelsPath(source)] else{return}
        let doc=try revisionXML(bytes,revisionRelsPath(source))
        for node in revisionChildren(doc.rootElement()!) {
            try cancellation?.check()
            guard let id=revisionAttribute(node,"Id"),let rel=rels.first(where:{$0.id==id}) else{throw PresentationRevisionFailure.invalid("Relationship identity changed during export")}
            if !rel.external {
                let part=try revisionTarget(rel.target,from:source)
                let mapped=try importPart(part,cancellation:cancellation,depth:depth)
                revisionSet(node,"Target",revisionRelative(mapped,from:target))
            }
        }
        entries[revisionRelsPath(target)]=revisionData(doc)
    }
    mutating func copyWholeSlide(source:RevisionDeck,path:String,target:String,fromAnchor:Bool,cancellation:OperationCancellation?)throws {
        if fromAnchor {
            guard path==target else{throw PresentationRevisionFailure.invalid("Unexpected anchor slide mapping")};return
        }
        guard let bytes=source.entries[path] else{throw PresentationRevisionFailure.invalid("Missing selected slide")}
        entries[target]=bytes;typeOverrides[target]=try source.contentType(path)
        try copyRelationships(from:path,to:target,cancellation:cancellation)
    }
    mutating func mergeSlide(plan:RevisionSlidePlan,base:RevisionDeck,destination:RevisionDeck,target:String,anchorNew:Bool,decisions:[String:Bool],cancellation:OperationCancellation?)throws {
        let old=RevisionSlide(id:plan.id,path:plan.base!,index:0),new=RevisionSlide(id:plan.id,path:plan.destination!,index:0)
        let oldShapes=try base.shapes(old),newShapes=try destination.shapes(new)
        let oldMap=Dictionary(uniqueKeysWithValues:oldShapes.map{($0.id,$0)}),newMap=Dictionary(uniqueKeysWithValues:newShapes.map{($0.id,$0)})
        let changeMap=Dictionary(uniqueKeysWithValues:plan.shapes.map{($0.id,$0)})
        var chosen:[String:Bool]=[:]
        for id in Set(oldMap.keys).union(newMap.keys) {
            let useNew=changeMap[id].map{decisions[$0.change] == true} ?? anchorNew
            if (useNew ? newMap[id]:oldMap[id]) != nil {chosen[id]=useNew}
        }
        let orderNew=plan.order.map{decisions[$0] == true} ?? anchorNew
        let order=revisionMergedOrder(primary:(orderNew ? newShapes:oldShapes).map(\.id),secondary:(orderNew ? oldShapes:newShapes).map(\.id),included:Set(chosen.keys))
        let doc=try anchor.document(anchorNew ? new.path:old.path),root=doc.rootElement()!
        guard let cs=revisionChild(root,"cSld"),let tree=revisionChild(cs,"spTree") else{throw PresentationRevisionFailure.invalid("Missing output shape tree")}
        for node in revisionChildren(tree) where !["nvGrpSpPr","grpSpPr","extLst"].contains(revisionLocal(node)){node.detach()}
        let relPath=revisionRelsPath(target),relDoc:XMLDocument
        if let bytes=entries[relPath] {relDoc=try revisionXML(bytes,relPath)}
        else {relDoc=try revisionXML(Data(("<Relationships xmlns=\""+revisionRelationshipNS+"\"/>").utf8),relPath)}
        var used=Set(revisionChildren(relDoc.rootElement()!).compactMap{revisionAttribute($0,"Id")})
        for id in order {
            try cancellation?.check()
            let useNew=chosen[id]!,source=useNew ? destination:base,sourceSlide=useNew ? new:old
            let original=(useNew ? newMap[id]:oldMap[id])!.element
            let node=original.copy() as! XMLElement
            if useNew != anchorNew {
                // Preserve foreign prefixes used anywhere in the imported shape.
                let foreignRoot=try source.document(sourceSlide.path).rootElement()!
                for ns in foreignRoot.namespaces ?? [] {
                    let prefix=ns.name ?? "",value=ns.stringValue ?? ""
                    if let current=root.namespace(forPrefix:prefix) {
                        guard current.stringValue==value else{throw PresentationRevisionFailure.unsupported("Conflicting XML namespace prefixes between selected shapes")}
                    } else {root.addNamespace(ns.copy() as! XMLNode)}
                }
                let relationships=try revisionRelationships(source.entries,part:sourceSlide.path),map=Dictionary(uniqueKeysWithValues:relationships.map{($0.id,$0)})
                for oldID in revisionRelationshipIDs(original).sorted() {
                    guard let rel=map[oldID] else{throw PresentationRevisionFailure.invalid("Missing selected shape dependency")}
                    var n=1;while used.contains("rIdTurtleGit\(n)"){n += 1};let newID="rIdTurtleGit\(n)";used.insert(newID)
                    let copied=rel.element.copy() as! XMLElement;revisionSet(copied,"Id",newID)
                    if !rel.external {let mapped=try importPart(revisionTarget(rel.target,from:sourceSlide.path),cancellation:cancellation);revisionSet(copied,"Target",revisionRelative(mapped,from:target))}
                    relDoc.rootElement()!.addChild(copied)
                    for descendant in revisionDescendants(node) {
                        for attr in descendant.attributes ?? [] where attr.stringValue==oldID && attr.uri==revisionOfficeRelationshipNS {attr.stringValue=newID}
                    }
                }
            }
            // extLst is the shape-tree's final child under the OOXML schema.
            if let ext=revisionChildren(tree).first(where:{revisionLocal($0)=="extLst"}),let index=tree.children?.firstIndex(of:ext){tree.insertChild(node,at:index)}else{tree.addChild(node)}
        }
        let ids=revisionDescendants(tree).filter{revisionIs($0,"cNvPr",revisionPresentationNS)}.compactMap{revisionAttribute($0,"id")}
        guard Set(ids).count==ids.count else{throw PresentationRevisionFailure.unsupported("Selected groups contain colliding child-shape identities. Choose the complete slide instead.")}
        let available=Set(ids)
        for node in revisionDescendants(tree) where node.uri==revisionDrawingNS && ["stCxn","endCxn"].contains(revisionLocal(node)) {
            if let id=revisionAttribute(node,"id"),!available.contains(id){throw PresentationRevisionFailure.unsupported("A selected connector references a rejected shape. Accept or reject the dependent shapes together.")}
        }
        entries[target]=revisionData(doc);entries[relPath]=revisionData(relDoc)
    }
    mutating func registerSlides(_ order:[String],cancellation:OperationCancellation?)throws {
        guard !order.isEmpty else{throw PresentationRevisionFailure.unsupported("An editable presentation must contain at least one slide")}
        let doc=try anchor.document(anchor.presentation),root=doc.rootElement()!,relPath=revisionRelsPath(anchor.presentation)
        for (prefix,uri) in [("p",revisionPresentationNS),("r",revisionOfficeRelationshipNS)] {
            if let ns=root.namespace(forPrefix:prefix) {guard ns.stringValue==uri else{throw PresentationRevisionFailure.unsupported("Conflicting presentation namespace prefix")}}
            else {root.addNamespace(XMLNode.namespace(withName:prefix,stringValue:uri) as! XMLNode)}
        }
        let relDoc=try anchor.document(relPath),relsRoot=relDoc.rootElement()!
        var previous:[String:String]=[:]
        for rel in revisionChildren(relsRoot) where revisionAttribute(rel,"Type")==revisionOfficeRelationshipNS+"/slide" {
            if let id=revisionAttribute(rel,"Id"),let raw=revisionAttribute(rel,"Target"){previous[id]=try revisionTarget(raw,from:anchor.presentation)};rel.detach()
        }
        let list=revisionChild(root,"sldIdLst") ?? XMLElement(name:"p:sldIdLst",uri:revisionPresentationNS)
        if list.parent==nil {let before=revisionChildren(root).first{!["sldMasterIdLst","notesMasterIdLst","handoutMasterIdLst"].contains(revisionLocal($0))};let position=before.flatMap{root.children?.firstIndex(of:$0)} ?? root.childCount;root.insertChild(list,at:position)}
        list.setChildren([])
        var used=Set(revisionChildren(relsRoot).compactMap{revisionAttribute($0,"Id")}),pathToRel:[String:String]=[:]
        func nextID()->String {var i=1;while used.contains("rIdTurtleGit\(i)"){i += 1};let id="rIdTurtleGit\(i)";used.insert(id);return id}
        for id in order {
            try cancellation?.check();let path=slidePaths[id]!,rid=nextID();pathToRel[path]=rid
            let rel=XMLElement(name:"Relationship",uri:revisionRelationshipNS);revisionSet(rel,"Id",rid);revisionSet(rel,"Type",revisionOfficeRelationshipNS+"/slide");revisionSet(rel,"Target",revisionRelative(path,from:anchor.presentation));relsRoot.addChild(rel)
            let node=XMLElement(name:"p:sldId",uri:revisionPresentationNS);revisionSet(node,"id",id);revisionSet(node,"r:id",rid);list.addChild(node)
        }
        // Custom shows contain relationship IDs; sections contain numeric slide
        // IDs. Rewrite retained references and refuse a dangling selection.
        let listNodes=Set(revisionDescendants(list).map{ObjectIdentifier($0)})
        for node in revisionDescendants(root) where !listNodes.contains(ObjectIdentifier(node)) {
            if revisionIs(node,"sld",revisionPresentationNS),let oldID=RevisionDeck.relationshipID(node),let path=previous[oldID] {
                guard let rid=pathToRel[path] else{throw PresentationRevisionFailure.unsupported("A custom show refers to a rejected slide. Choose a complete revision or retain that slide.")};revisionSet(node,"r:id",rid)
            }
            if revisionLocal(node)=="sldId",node.parent !== list,let id=revisionAttribute(node,"id"),!order.contains(id){throw PresentationRevisionFailure.unsupported("A presentation section refers to a rejected slide. Choose a complete revision or retain that slide.")}
        }
        // Register imported master graphs so PowerPoint treats their themes and
        // layouts as editable presentation content, not unreachable package parts.
        for (path,type) in typeOverrides.sorted(by:{$0.key<$1.key}) {
            let listName:String,itemName:String,relationship:String
            if type.contains("slideMaster+xml") {listName="sldMasterIdLst";itemName="sldMasterId";relationship="slideMaster"}
            else if type.contains("notesMaster+xml") {listName="notesMasterIdLst";itemName="notesMasterId";relationship="notesMaster"}
            else if type.contains("handoutMaster+xml") {listName="handoutMasterIdLst";itemName="handoutMasterId";relationship="handoutMaster"}
            else{continue}
            let list=revisionChild(root,listName) ?? XMLElement(name:"p:"+listName,uri:revisionPresentationNS)
            if list.parent==nil {let precedence=["sldMasterIdLst","notesMasterIdLst","handoutMasterIdLst","sldIdLst"];let rank=precedence.firstIndex(of:listName)!;let before=revisionChildren(root).first{child in (precedence.firstIndex(of:revisionLocal(child)) ?? 99)>rank};let pos=before.flatMap{root.children?.firstIndex(of:$0)} ?? root.childCount;root.insertChild(list,at:pos)}
            if relationship != "slideMaster",!revisionChildren(list).isEmpty {throw PresentationRevisionFailure.unsupported("Multiple presentation-wide notes or handout masters cannot be merged independently")}
            let rid=nextID(),rel=XMLElement(name:"Relationship",uri:revisionRelationshipNS);revisionSet(rel,"Id",rid);revisionSet(rel,"Type",revisionOfficeRelationshipNS+"/"+relationship);revisionSet(rel,"Target",revisionRelative(path,from:anchor.presentation));relsRoot.addChild(rel)
            let item=XMLElement(name:"p:"+itemName,uri:revisionPresentationNS);revisionSet(item,"r:id",rid)
            if relationship=="slideMaster" {let used=Set(revisionChildren(list).compactMap{revisionAttribute($0,"id")}.compactMap(UInt32.init));var numeric:UInt32=2147483648;while used.contains(numeric){guard numeric<UInt32.max else{throw PresentationRevisionFailure.unsupported("Master identity budget")};numeric += 1};revisionSet(item,"id",String(numeric))}
            list.addChild(item)
        }
        entries[anchor.presentation]=revisionData(doc);entries[relPath]=revisionData(relDoc)
        let ct=try anchor.document("[Content_Types].xml"),ctRoot=ct.rootElement()!
        for (path,type) in typeOverrides.sorted(by:{$0.key<$1.key}) {
            for item in revisionChildren(ctRoot) where revisionAttribute(item,"PartName")=="/"+path {item.detach()}
            let item=XMLElement(name:"Override",uri:revisionContentNS);revisionSet(item,"PartName","/"+path);revisionSet(item,"ContentType",type);ctRoot.addChild(item)
        }
        entries["[Content_Types].xml"]=revisionData(ct)
        // Retained slide hyperlinks must resolve to listed slides. Keeping an old
        // orphan part would hide a rejected slide behind a clickable action.
        let listed=Set(slidePaths.values)
        for path in listed {
            for rel in try revisionRelationships(entries,part:path) where !rel.external && rel.type==revisionOfficeRelationshipNS+"/slide" {
                guard listed.contains(try revisionTarget(rel.target,from:path)) else{throw PresentationRevisionFailure.unsupported("A retained slide links to a rejected slide. Retain its target or choose a complete revision.")}
            }
        }
    }
    static func finish(_ package:PresentationPackage,extension ext:String,cancellation:OperationCancellation?)throws->PresentationPackage {
        try cancellation?.check();var entries=package.entries
        let deck=try RevisionDeck(package,cancellation:cancellation)
        // A generated deck is a new document. Package signatures cannot attest to
        // its selected content; strip both signature parts and origin edges.
        var signatures=Set<String>(),hasSignatureEdges=false
        func collectSignature(_ part:String,_ depth:Int)throws {
            guard depth<=128 else{throw PresentationRevisionFailure.unsupported("Signature graph depth budget")}
            guard signatures.insert(part).inserted else{return}
            signatures.insert(revisionRelsPath(part))
            for rel in try revisionRelationships(entries,part:part) where !rel.external {try collectSignature(revisionTarget(rel.target,from:part),depth+1)}
        }
        for path in entries.keys.filter({$0.hasPrefix("_xmlsignatures/")}) {try collectSignature(path,0)}
        for path in entries.keys.filter({$0.hasSuffix(".rels")}) {
            let owner=try RevisionDeck.owner(of:path)
            for rel in try revisionRelationships(entries,part:owner) where rel.type.contains("digital-signature") {
                hasSignatureEdges=true
                if !rel.external {try collectSignature(revisionTarget(rel.target,from:owner),0)}
            }
        }
        let mainType=ext=="pptm" ? "application/vnd.ms-powerpoint.presentation.macroEnabled.main+xml":"application/vnd.openxmlformats-officedocument.presentationml.presentation.main+xml"
        // A complete accepted/rejected unsigned revision is already a valid
        // editable deck. Preserve every member byte, including XML declaration
        // and whitespace, when no security/type change is actually necessary.
        if signatures.isEmpty,!hasSignatureEdges,!deck.types.values.contains(where:{$0.contains("digital-signature")}),!deck.defaults.values.contains(where:{$0.contains("digital-signature")}),try deck.contentType(deck.presentation)==mainType {return package}
        entries=entries.filter{!signatures.contains($0.key)}
        for path in entries.keys.filter({$0.hasSuffix(".rels")}) {
            let doc=try revisionXML(entries[path]!,path);var changed=false
            for node in revisionChildren(doc.rootElement()!) where (revisionAttribute(node,"Type") ?? "").contains("digital-signature") {node.detach();changed=true}
            if changed{entries[path]=revisionData(doc)}
        }
        let ct=try revisionXML(entries["[Content_Types].xml"]!,"[Content_Types].xml"),root=ct.rootElement()!
        for node in revisionChildren(root) {
            if signatures.contains(String((revisionAttribute(node,"PartName") ?? "").dropFirst())) || (revisionAttribute(node,"ContentType") ?? "").contains("digital-signature") {node.detach();continue}
            if revisionAttribute(node,"PartName")=="/"+deck.presentation {
                revisionSet(node,"ContentType",ext=="pptm" ? "application/vnd.ms-powerpoint.presentation.macroEnabled.main+xml":"application/vnd.openxmlformats-officedocument.presentationml.presentation.main+xml")
            }
        }
        if !revisionChildren(root).contains(where:{revisionAttribute($0,"PartName")=="/"+deck.presentation}) {
            let node=XMLElement(name:"Override",uri:revisionContentNS);revisionSet(node,"PartName","/"+deck.presentation);revisionSet(node,"ContentType",ext=="pptm" ? "application/vnd.ms-powerpoint.presentation.macroEnabled.main+xml":"application/vnd.openxmlformats-officedocument.presentationml.presentation.main+xml");root.addChild(node)
        }
        entries["[Content_Types].xml"]=revisionData(ct)
        let result=try PresentationPackage(entries:entries)
        _=try RevisionDeck(result,cancellation:cancellation)
        return result
    }
}
