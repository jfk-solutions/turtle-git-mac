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
    public enum Kind:String, Sendable {case slideAdded,slideDeleted,slideMoved,shapeAdded,shapeDeleted,shapeChanged,shapeOrder,slideEnvironment,presentation,commentAdded,commentDeleted,commentChanged}
    public let id:String,title:String,detail:String,baseSlideIndex:Int?,destinationSlideIndex:Int?,kind:Kind
    public let groupPath:[String]
    public var depth:Int {groupPath.count}
    public var slideIndex:Int? {destinationSlideIndex ?? baseSlideIndex}
    public init(id:String,title:String,detail:String,baseSlideIndex:Int?,destinationSlideIndex:Int?,kind:Kind,groupPath:[String]=[]) {
        self.id=id;self.title=title;self.detail=detail;self.baseSlideIndex=baseSlideIndex;self.destinationSlideIndex=destinationSlideIndex;self.kind=kind;self.groupPath=groupPath
    }
}

/// A two-way revision review. Accept selects New; reject selects Base. Groups
/// retain their shells while children are reviewed within each matched parent.
/// Changed group shells select a whole group. Slide environments with
/// interdependent content select a whole slide to preserve their references.
public struct PresentationRevisionReview: Sendable {
    public let changes:[PresentationRevisionChange]
    public let baseManifest:PresentationSlideManifest,destinationManifest:PresentationSlideManifest
    public let requiredFileExtension:String
    public var suggestedExtension:String {requiredFileExtension}
    public let invalidatesDigitalSignatures:Bool
    public let notices:[String]
    public private(set) var decisions:[String:Bool]=[:]
    private let base:PresentationPackage,destination:PresentationPackage
    private let originalBase:PresentationPackage,originalDestination:PresentationPackage
    private let oldComments:RevisionComments,newComments:RevisionComments
    public let commentChanges:[String:PresentationCommentChange]
    public var baseComments:[PresentationComment] {oldComments.records.values.sorted{$0.order<$1.order}.map(\.value)}
    public var destinationComments:[PresentationComment] {newComments.records.values.sorted{$0.order<$1.order}.map(\.value)}

    private let plans:[RevisionSlidePlan]
    private let baseOrder:[String],destinationOrder:[String]
    private let environmentChange:String?,orderChange:String?
    private var history:[[RevisionDecisionDelta]]=[],future:[[RevisionDecisionDelta]]=[]
    public var canUndo:Bool {!history.isEmpty}
    public var canRedo:Bool {!future.isEmpty}
    public var unresolvedCount:Int {changes.filter{decisions[$0.id]==nil && !commentIsDeleted(changeID:$0.id)}.count}
    public var isDirty:Bool {!decisions.isEmpty}

    public init(base:PresentationPackage,destination:PresentationPackage,cancellation:OperationCancellation? = nil)throws {
        var old=try RevisionDeck(base,cancellation:cancellation),new=try RevisionDeck(destination,cancellation:cancellation)
        originalBase=base;originalDestination=destination
        let originalBaseManifest=try old.manifest(),originalDestinationManifest=try new.manifest()
        let oldByID=Dictionary(uniqueKeysWithValues:old.slides.map{($0.id,$0)}),newByID=Dictionary(uniqueKeysWithValues:new.slides.map{($0.id,$0)})
        let identities=try revisionMatch(old.slides.map(\.id),new.slides.map(\.id),fingerprint:{isNew,id in
            let deck=isNew ? new:old,slide=(isNew ? newByID[id]:oldByID[id])!
            return try deck.slideIdentityFingerprint(slide,cancellation:cancellation)
        },similarity:{a,b in try old.slideSimilarity(oldByID[a]!,new,newByID[b]!)},cancellation:cancellation)
        let oldKeys=Dictionary(uniqueKeysWithValues:identities.compactMap{pair in pair.base.map{($0,pair.id)}}),newKeys=Dictionary(uniqueKeysWithValues:identities.compactMap{pair in pair.destination.map{($0,pair.id)}})
        oldComments=try RevisionComments.read(base,slideKeys:Dictionary(uniqueKeysWithValues:old.slides.map{($0.path,oldKeys[$0.id]!)}),cancellation:cancellation)
        newComments=try RevisionComments.read(destination,slideKeys:Dictionary(uniqueKeysWithValues:new.slides.map{($0.path,newKeys[$0.id]!)}),cancellation:cancellation)
        self.base=oldComments.stripped;self.destination=newComments.stripped
        old=try RevisionDeck(self.base,cancellation:cancellation);new=try RevisionDeck(self.destination,cancellation:cancellation)
        baseOrder=old.slides.map{oldKeys[$0.id]!};destinationOrder=new.slides.map{newKeys[$0.id]!}
        baseManifest=originalBaseManifest
        let manifestIDs=Dictionary(uniqueKeysWithValues:identities.compactMap{pair in pair.destination.map{($0,pair.base ?? $0)}})
        destinationManifest=PresentationSlideManifest(slides:originalDestinationManifest.slides.map {slide in PresentationSlide(pageIndex:slide.pageIndex,stableID:slide.stableID.flatMap{manifestIDs[$0]},text:slide.text,notes:slide.notes,visualFingerprint:slide.visualFingerprint)})
        requiredFileExtension=(old.hasMacros || new.hasMacros) ? "pptm":"pptx"
        invalidatesDigitalSignatures=old.hasSignatures || new.hasSignatures
        notices=(invalidatesDigitalSignatures ? ["Saving a reviewed presentation removes package digital signatures. The saved deck must be signed again."]:[]) + (oldComments.unsupported || newComments.unsupported ? ["Unknown comment or person extensions can be preserved only by choosing one complete revision. Independent mixed comment review is unavailable for those extensions."]:[])
        var changes:[PresentationRevisionChange]=[],plans:[RevisionSlidePlan]=[]
        func change(_ id:String,_ title:String,_ detail:String,_ kind:PresentationRevisionChange.Kind,_ a:Int?=nil,_ b:Int?=nil)->String {
            changes.append(.init(id:id,title:title,detail:detail,baseSlideIndex:a,destinationSlideIndex:b,kind:kind));return id
        }
        let environmentChanged=try old.environmentFingerprint(cancellation:cancellation) != new.environmentFingerprint(cancellation:cancellation)
        environmentChange=environmentChanged ? change("presentation","Presentation properties and shared content","Choose the presentation settings, metadata, macros and content outside the slides. Imported slide dependencies remain attached to their chosen slides.",.presentation):nil
        let common=Set(baseOrder).intersection(destinationOrder)
        let reordered=baseOrder.filter{common.contains($0)} != destinationOrder.filter{common.contains($0)}
        orderChange=reordered ? change("slide-order","Slide order","Accept New's slide order or retain Base's order. Added and restored slides keep their neighboring positions.",.slideMoved):nil
        var shapeCount=0
        for identity in identities {
            let id=identity.id
            try cancellation?.check()
            let priorSlide=identity.base.flatMap{oldByID[$0]},newSlide=identity.destination.flatMap{newByID[$0]},prefix="slide-"+id
            if priorSlide == nil || newSlide == nil {
                let added=priorSlide == nil,index=(newSlide ?? priorSlide)!.index
                let key=change(prefix, "Slide \(index+1): " + (added ? "added":"deleted"), added ? "Accept to include the complete New slide and its dependencies.":"Accept to remove this slide; reject to restore the complete Base slide.",added ? .slideAdded:.slideDeleted,priorSlide?.index,newSlide?.index)
                plans.append(.init(id:id,base:priorSlide?.path,destination:newSlide?.path,baseID:identity.base,destinationID:identity.destination,whole:key,container:nil));continue
            }
            let a=priorSlide!,b=newSlide!
            let oldShapes=try old.shapes(a),newShapes=try new.shapes(b)
            let matched=try revisionMatchContainer(oldShapes,newShapes,base:old,destination:new,oldSlide:a,newSlide:b,prefix:prefix,cancellation:cancellation)
            var oldKeys:[String:String]=[:],newKeys:[String:String]=[:]
            revisionIdentityMaps(matched,old:&oldKeys,new:&newKeys)
            shapeCount += oldKeys.count+newKeys.count
            guard shapeCount<=40000 else{throw PresentationRevisionFailure.unsupported("More than 20,000 shapes per compared deck")}
            var slideChanges:[PresentationRevisionChange]=[]
            let container=try revisionReviewContainer(matched,oldShapes,newShapes,base:old,destination:new,oldSlide:a,newSlide:b,oldKeys:oldKeys,newKeys:newKeys,path:[],changes:&slideChanges,cancellation:cancellation)
            let envChanged=try old.slideEnvironmentFingerprint(a,cancellation:cancellation) != new.slideEnvironmentFingerprint(b,cancellation:cancellation)
            let inseparable=try old.requiresAtomicSlide(a) || new.requiresAtomicSlide(b)
            if envChanged || (inseparable && !slideChanges.isEmpty) {
                let key=change(prefix+"-environment","Slide \(b.index+1): slide content and environment","Choose the complete slide, including shapes, notes, layout, timing, transitions and dependent content. These changes are reviewed together to preserve their references.",.slideEnvironment,a.index,b.index)
                plans.append(.init(id:id,base:a.path,destination:b.path,baseID:identity.base,destinationID:identity.destination,whole:key,container:nil))
            } else {
                changes += slideChanges
                plans.append(.init(id:id,base:a.path,destination:b.path,baseID:identity.base,destinationID:identity.destination,whole:nil,container:container))
            }
        }
        var comments:[String:PresentationCommentChange]=[:]
        for id in Set(oldComments.records.keys).union(newComments.records.keys).sorted() {
            let a=oldComments.records[id],b=newComments.records[id]
            comments[id]=PresentationCommentChange(base:a?.value,destination:b?.value)
            if a.map({Data($0.node.utf8)}) != b.map({Data($0.node.utf8)}) || a.map({Data($0.authorNode.utf8)}) != b.map({Data($0.authorNode.utf8)}) || a?.value.parentID != b?.value.parentID {
                let item=b?.value ?? a!.value
                changes.append(.init(id:id,title:"Slide \(item.slideIndex+1): comment"+(item.depth>0 ? " reply":""),detail:item.text,baseSlideIndex:a?.value.slideIndex,destinationSlideIndex:b?.value.slideIndex,kind:a==nil ? .commentAdded:b==nil ? .commentDeleted:.commentChanged,groupPath:[]))
            }
        }
        commentChanges=comments;self.changes=changes;self.plans=plans
    }
    public mutating func decide(changeID:String,accept:Bool) {
        guard changes.contains(where:{$0.id==changeID}),decisions[changeID] != accept else{return}
        history.append([.init(id:changeID,old:decisions[changeID],new:accept)]);future=[];decisions[changeID]=accept
    }
    public mutating func decideAll(accept:Bool) {
        var next=decisions
        for change in changes {next[change.id]=accept}
        guard next != decisions else{return};history.append(changes.compactMap {change in decisions[change.id] == accept ? nil:.init(id:change.id,old:decisions[change.id],new:accept)});future=[];decisions=next
    }
    public func commentIsDeleted(changeID:String)->Bool {
        var current:String?=changeID,seen=Set<String>()
        while let id=current,seen.insert(id).inserted {
            if decisions["delete-"+id]==true{return true}
            let pair=commentChanges[id]
            current=(decisions[id]==true ? pair?.destination:pair?.base ?? pair?.destination)?.parentID
        }
        return false
    }
    public func commentIsDirectlyDeleted(changeID:String)->Bool {decisions["delete-"+changeID]==true}
    public mutating func deleteComment(changeID:String) {setCommentDeletion(changeID,true)}
    public mutating func restoreComment(changeID:String) {setCommentDeletion(changeID,false)}
    private mutating func setCommentDeletion(_ id:String,_ deleted:Bool) {
        guard commentChanges[id] != nil else{return}
        let key="delete-"+id,next:Bool?=deleted ? true:nil
        guard decisions[key] != next else{return}
        history.append([.init(id:key,old:decisions[key],new:next)]);future=[];decisions[key]=next
    }
    public mutating func undo() {guard let previous=history.popLast() else{return};future.append(previous);for delta in previous{decisions[delta.id]=delta.old}}
    public mutating func redo() {guard let next=future.popLast() else{return};history.append(next);for delta in next{decisions[delta.id]=delta.new}}

    public func exported(cancellation:OperationCancellation? = nil)throws->PresentationPackage {
        try cancellation?.check();guard unresolvedCount==0 else{throw PresentationRevisionFailure.unresolved}
        let old=try RevisionDeck(base,cancellation:cancellation),new=try RevisionDeck(destination,cancellation:cancellation)
        // Choosing either complete revision preserves every opaque package member.
        let deleted=decisions.keys.contains{$0.hasPrefix("delete-")}
        if !deleted,changes.allSatisfy({decisions[$0.id] == true}) {return try RevisionOutput.finish(originalDestination,extension:requiredFileExtension,cancellation:cancellation)}
        if !deleted,changes.allSatisfy({decisions[$0.id] == false}) {return try RevisionOutput.finish(originalBase,extension:requiredFileExtension,cancellation:cancellation)}
        guard !oldComments.unsupported,!newComments.unsupported else{throw PresentationRevisionFailure.unsupported("Unknown comment/person extension requires a complete revision choice")}
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
            try output.reserveSlide(id:plan.id,anchor:anchorPath,foreign:foreignPath,anchorID:anchorNew ? plan.destinationID:plan.baseID,foreignID:anchorNew ? plan.baseID:plan.destinationID)
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
        try output.installComments(old:oldComments,new:newComments,plans:selected,decisions:decisions,anchorNew:anchorNew,cancellation:cancellation)
        return try RevisionOutput.finish(try PresentationPackage(entries:output.entries),extension:requiredFileExtension,cancellation:cancellation)
    }
}

private struct RevisionIdentity:Sendable {let id:String,base:String?,destination:String?}
/// Match only mutually unique candidates. Ambiguous duplicates deliberately stay
/// additions/deletions; ordinal proximity is never evidence of identity.
private func revisionMatch(_ base:[String],_ destination:[String],fingerprint:(Bool,String)throws->String,similarity:(String,String)throws->Double,cancellation:OperationCancellation?)throws->[RevisionIdentity] {
    var pairs:[String:String]=[:],used=Set<String>()
    for id in base where destination.contains(id){pairs[id]=id;used.insert(id)}
    var old:[String:[String]]=[:],new:[String:[String]]=[:]
    for id in base where pairs[id]==nil {try cancellation?.check();old[try fingerprint(false,id),default:[]].append(id)}
    for id in destination where !used.contains(id) {try cancellation?.check();new[try fingerprint(true,id),default:[]].append(id)}
    for key in old.keys.sorted() where old[key]!.count==1 && new[key]?.count==1 {let a=old[key]![0],b=new[key]![0];pairs[a]=b;used.insert(b)}
    let remainingOld=base.filter{pairs[$0]==nil},remainingNew=destination.filter{!used.contains($0)}
    // Bound the quadratic fallback. Exact matches above remain available even
    // for very large shape collections.
    if remainingOld.count*remainingNew.count<=262144 {
        var aBest:[String:(String,Double,Double)]=[:],bBest:[String:(String,Double,Double)]=[:]
        for a in remainingOld {for b in remainingNew {
            try cancellation?.check();let score=try similarity(a,b)
            func update(_ old:(String,Double,Double)?,_ id:String)->(String,Double,Double) {
                guard let old else{return(id,score,0)}
                if score>old.1{return(id,score,old.1)};return(old.0,old.1,max(old.2,score))
            }
            aBest[a]=update(aBest[a],b);bBest[b]=update(bBest[b],a)
        }}
        for a in remainingOld {
            guard let best=aBest[a],best.1>=0.82,best.1-best.2>=0.12,let reverse=bBest[best.0],reverse.0==a,reverse.1>=0.82,reverse.1-reverse.2>=0.12 else{continue}
            pairs[a]=best.0;used.insert(best.0)
        }
    }
    return base.map{RevisionIdentity(id:"b"+$0,base:$0,destination:pairs[$0])}+destination.filter{!used.contains($0)}.map{RevisionIdentity(id:"n"+$0,base:nil,destination:$0)}
}
private func revisionWords(_ text:String)->Set<String> {Set(text.lowercased().split{!$0.isLetter && !$0.isNumber}.map(String.init))}
private func revisionOverlap(_ a:Set<String>,_ b:Set<String>)->Double {if a.isEmpty && b.isEmpty{return 1};return Double(a.intersection(b).count)/Double(a.union(b).count)}
/// Prefix-independent structural XML, preserving meaningful leaf text, unknown
/// attributes and comments. Relationship and shape identity values are supplied
/// by callers; namespace declaration spelling and XML declarations are not data.
private func revisionCanonical(_ node:XMLNode,ids:[String:String]=[:],relationships:[String:String]=[:],ignoreNames:Bool=false)->String {
    guard let element=node as? XMLElement else {
        if node.kind == .comment{return "comment:"+(node.stringValue ?? "")}
        return "text:"+(node.stringValue ?? "")
    }
    let name="{"+(element.uri ?? "")+"}"+revisionLocal(element)
    let attributes=(element.attributes ?? []).compactMap {attr->String? in
        let local=revisionLocal(attr),uri=attr.uri ?? ""
        var value=attr.stringValue ?? ""
        if revisionIs(element,"cNvPr",revisionPresentationNS) {
            if local=="id"{value=revisionAttribute(element,"id") ?? value;value=ids[value] ?? value}
            if local=="name",ignoreNames{return nil}
        }
        if (element.uri==revisionDrawingNS && ["stCxn","endCxn"].contains(revisionLocal(element)) && local=="id") || (element.uri==revisionPresentationNS && local=="spid") {value=revisionAttribute(element,local) ?? value;value=ids[value] ?? value}
        if uri==revisionOfficeRelationshipNS {value=relationships[value] ?? value}
        return "{"+uri+"}"+local+"="+String(value.utf8.count)+":"+value
    }.sorted().joined(separator:"|")
    let hasElements = !revisionChildren(element).isEmpty
    let children=(element.children ?? []).filter {child in !(hasElements && child.kind == .text && (child.stringValue ?? "").trimmingCharacters(in:.whitespacesAndNewlines).isEmpty)}.map{revisionCanonical($0,ids:ids,relationships:relationships,ignoreNames:ignoreNames)}.joined(separator:"|")
    return name+"["+attributes+"]("+children+")"
}

private let revisionShapeNames:Set<String>=["sp","pic","graphicFrame","cxnSp","grpSp","contentPart"]
/// Opaque extension/compatibility children keep their enclosing group atomic.
/// Only understood direct children may be split into independent decisions.
private func revisionSupportsGroupChildren(_ container:XMLElement)->Bool {
    revisionChildren(container).allSatisfy {node in
        node.uri==revisionPresentationNS && (revisionShapeNames.contains(revisionLocal(node)) || ["nvGrpSpPr","grpSpPr","extLst"].contains(revisionLocal(node)))
    }
}
private func revisionContainerShapes(_ container:XMLElement)throws->[RevisionShape] {
    try revisionChildren(container).compactMap {node in
        if node.uri==revisionPresentationNS,["nvGrpSpPr","grpSpPr","extLst"].contains(revisionLocal(node)){return nil}
        guard node.uri==revisionPresentationNS,revisionShapeNames.contains(revisionLocal(node)),let identity=revisionDescendants(node).first(where:{revisionIs($0,"cNvPr",revisionPresentationNS)}),let id=revisionAttribute(identity,"id") else{throw PresentationRevisionFailure.unsupported("Unknown or malformed group child")}
        return .init(id:id,name:revisionAttribute(identity,"name") ?? "Shape "+id,element:node)
    }
}
private func revisionGroupShell(_ element:XMLElement)->XMLElement {
    let copy=element.copy() as! XMLElement
    for child in revisionChildren(copy) where child.uri==revisionPresentationNS && revisionShapeNames.contains(revisionLocal(child)){child.detach()}
    return copy
}
private func revisionShapeText(_ shape:RevisionShape)->String {revisionDescendants(shape.element).filter{revisionIs($0,"t",revisionDrawingNS)}.compactMap(\.stringValue).joined(separator:" ")}
private func revisionShapeGeometry(_ shape:RevisionShape)->String {revisionLocal(shape.element)+"|"+revisionDescendants(shape.element).filter{revisionIs($0,"xfrm",revisionDrawingNS)}.map{revisionCanonical($0)}.joined(separator:"|")}
private func revisionShapeSimilarity(_ a:RevisionShape,_ b:RevisionShape)->Double {
    guard revisionLocal(a.element)==revisionLocal(b.element) else{return 0}
    let old=revisionShapeText(a),new=revisionShapeText(b),sameGeometry=revisionShapeGeometry(a)==revisionShapeGeometry(b)
    let sameName = !a.name.isEmpty && a.name==b.name && a.name.range(of:"^(Shape|Picture|TextBox|Rectangle|Oval|Connector|Group) [0-9]+$",options:.regularExpression)==nil
    if revisionIs(a.element,"grpSp",revisionPresentationNS),sameName {
        let shellA=revisionGroupShell(a.element),shellB=revisionGroupShell(b.element)
        let geometryA=revisionDescendants(shellA).filter{revisionIs($0,"xfrm",revisionDrawingNS)}.map{revisionCanonical($0)}
        let geometryB=revisionDescendants(shellB).filter{revisionIs($0,"xfrm",revisionDrawingNS)}.map{revisionCanonical($0)}
        if geometryA==geometryB{return 0.96}
    }
    if !old.isEmpty,old==new {return sameGeometry ? 0.98:sameName ? 0.90:0}
    // A unique custom object name plus identical geometry remains useful when
    // a regenerated-ID child has entirely new text. Mutual uniqueness and the
    // runner-up margin in revisionMatch still reject duplicate named siblings.
    if sameName,sameGeometry{return 0.92}
    return 0
}
private struct RevisionDecisionDelta:Sendable {let id:String,old:Bool?,new:Bool?}
private struct RevisionSlidePlan:Sendable {let id:String,base:String?,destination:String?,baseID:String?,destinationID:String?,whole:String?,container:RevisionContainerPlan?}
private struct RevisionContainerPlan:Sendable {
    var shapes:[RevisionShapePlan]
    let baseOrder:[String],destinationOrder:[String],prefix:String
    var order:String?=nil
}
private struct RevisionShapePlan:Sendable {
    let id:String,base:String?,destination:String?
    var children:RevisionContainerPlan?
    var change:String?=nil
    var granular:Bool=false
}
private func revisionMatchContainer(_ a:[RevisionShape],_ b:[RevisionShape],base:RevisionDeck,destination:RevisionDeck,oldSlide:RevisionSlide,newSlide:RevisionSlide,prefix:String,cancellation:OperationCancellation?)throws->RevisionContainerPlan {
    let oldMap=Dictionary(uniqueKeysWithValues:a.map{($0.id,$0)}),newMap=Dictionary(uniqueKeysWithValues:b.map{($0.id,$0)})
    let pairs=try revisionMatch(a.map(\.id),b.map(\.id),fingerprint:{isNew,id in try (isNew ? destination:base).shapeIdentityFingerprint((isNew ? newMap:oldMap)[id]!,slide:isNew ? newSlide:oldSlide,cancellation:cancellation)},similarity:{a,b in revisionShapeSimilarity(oldMap[a]!,newMap[b]!)},cancellation:cancellation)
    var nodes:[RevisionShapePlan]=[]
    for pair in pairs {
        try cancellation?.check();let id=prefix+"-shape-"+pair.id
        var children:RevisionContainerPlan?
        if let x=pair.base.flatMap({oldMap[$0]}),let y=pair.destination.flatMap({newMap[$0]}),revisionIs(x.element,"grpSp",revisionPresentationNS),revisionIs(y.element,"grpSp",revisionPresentationNS),revisionSupportsGroupChildren(x.element),revisionSupportsGroupChildren(y.element) {
            children=try revisionMatchContainer(revisionContainerShapes(x.element),revisionContainerShapes(y.element),base:base,destination:destination,oldSlide:oldSlide,newSlide:newSlide,prefix:id,cancellation:cancellation)
        }
        nodes.append(.init(id:id,base:pair.base,destination:pair.destination,children:children))
    }
    let oldKeys=Dictionary(uniqueKeysWithValues:nodes.compactMap{node in node.base.map{($0,node.id)}}),newKeys=Dictionary(uniqueKeysWithValues:nodes.compactMap{node in node.destination.map{($0,node.id)}})
    return .init(shapes:nodes,baseOrder:a.map{oldKeys[$0.id]!},destinationOrder:b.map{newKeys[$0.id]!},prefix:prefix)
}
private func revisionIdentityMaps(_ container:RevisionContainerPlan,old:inout[String:String],new:inout[String:String]) {
    for node in container.shapes {if let id=node.base{old[id]=node.id};if let id=node.destination{new[id]=node.id};if let children=node.children{revisionIdentityMaps(children,old:&old,new:&new)}}
}
private func revisionReviewContainer(_ matched:RevisionContainerPlan,_ a:[RevisionShape],_ b:[RevisionShape],base:RevisionDeck,destination:RevisionDeck,oldSlide:RevisionSlide,newSlide:RevisionSlide,oldKeys:[String:String],newKeys:[String:String],path:[String],changes:inout[PresentationRevisionChange],cancellation:OperationCancellation?)throws->RevisionContainerPlan {
    let oldMap=Dictionary(uniqueKeysWithValues:a.map{($0.id,$0)}),newMap=Dictionary(uniqueKeysWithValues:b.map{($0.id,$0)})
    var result=matched
    for index in result.shapes.indices {
        try cancellation?.check();var node=result.shapes[index]
        let x=node.base.flatMap{oldMap[$0]},y=node.destination.flatMap{newMap[$0]},name=y?.name ?? x?.name ?? "Shape"
        if let children=node.children,let x,let y {
            let shellA=revisionCanonical(revisionGroupShell(x.element),ids:oldKeys,relationships:try base.semanticRelationships(oldSlide,cancellation:cancellation))
            let shellB=revisionCanonical(revisionGroupShell(y.element),ids:newKeys,relationships:try destination.semanticRelationships(newSlide,cancellation:cancellation))
            if shellA==shellB {
                node.granular=true
                node.children=try revisionReviewContainer(children,revisionContainerShapes(x.element),revisionContainerShapes(y.element),base:base,destination:destination,oldSlide:oldSlide,newSlide:newSlide,oldKeys:oldKeys,newKeys:newKeys,path:path+[name],changes:&changes,cancellation:cancellation)
            }
        }
        if !node.granular,try base.shapeFingerprint(x,slide:oldSlide,identities:oldKeys,cancellation:cancellation) != destination.shapeFingerprint(y,slide:newSlide,identities:newKeys,cancellation:cancellation) {
            node.change=node.id
            let kind:PresentationRevisionChange.Kind=x == nil ? .shapeAdded:y == nil ? .shapeDeleted:.shapeChanged
            let group=(x.map{revisionIs($0.element,"grpSp",revisionPresentationNS)} ?? false) || (y.map{revisionIs($0.element,"grpSp",revisionPresentationNS)} ?? false)
            let detail:String
            if group {detail=kind == .shapeAdded ? "Added whole group, including every nested shape and its linked content.":kind == .shapeDeleted ? "Deleted whole group, including every nested shape.":"Changed group properties. Choose the whole group, including its nested shapes, transforms, formatting and linked content."}
            else {detail=kind == .shapeAdded ? "Added shape, including its linked content.":kind == .shapeDeleted ? "Deleted shape.":"Changed shape, including its formatting and linked content."}
            changes.append(.init(id:node.id,title:"Slide \(newSlide.index+1): "+name+(group ? " (whole group)":""),detail:detail,baseSlideIndex:oldSlide.index,destinationSlideIndex:newSlide.index,kind:kind,groupPath:path))
        }
        result.shapes[index]=node
    }
    let common=Set(matched.shapes.filter{$0.base != nil && $0.destination != nil}.map(\.id))
    if matched.baseOrder.filter({common.contains($0)}) != matched.destinationOrder.filter({common.contains($0)}) {
        let id=matched.prefix+"-shape-order";result.order=id
        changes.append(.init(id:id,title:"Slide \(newSlide.index+1): shape order",detail:"Choose New or Base stacking order for the retained shapes in this container.",baseSlideIndex:oldSlide.index,destinationSlideIndex:newSlide.index,kind:.shapeOrder,groupPath:path))
    }
    return result
}
private struct RevisionSelectedShape {
    let plan:RevisionShapePlan,shape:RevisionShape,useNew:Bool,children:[RevisionSelectedShape]?
}
private struct RevisionSelectedIdentity {let base:String?,destination:String?,selected:String,useNew:Bool}
private func revisionSelectContainer(_ plan:RevisionContainerPlan,_ a:[RevisionShape],_ b:[RevisionShape],anchorNew:Bool,decisions:[String:Bool],cancellation:OperationCancellation?)throws->[RevisionSelectedShape] {
    let oldMap=Dictionary(uniqueKeysWithValues:a.map{($0.id,$0)}),newMap=Dictionary(uniqueKeysWithValues:b.map{($0.id,$0)})
    var selected:[String:RevisionSelectedShape]=[:]
    for node in plan.shapes {
        try cancellation?.check()
        let useNew=node.change.map{decisions[$0] == true} ?? anchorNew
        guard let raw=useNew ? node.destination:node.base,let shape=(useNew ? newMap:oldMap)[raw] else{continue}
        var children:[RevisionSelectedShape]?
        if node.granular,let container=node.children,let x=node.base.flatMap({oldMap[$0]}),let y=node.destination.flatMap({newMap[$0]}) {
            children=try revisionSelectContainer(container,revisionContainerShapes(x.element),revisionContainerShapes(y.element),anchorNew:anchorNew,decisions:decisions,cancellation:cancellation)
        }
        selected[node.id] = .init(plan:node,shape:shape,useNew:useNew,children:children)
    }
    let newOrder=plan.order.map{decisions[$0] == true} ?? anchorNew
    return revisionMergedOrder(primary:newOrder ? plan.destinationOrder:plan.baseOrder,secondary:newOrder ? plan.baseOrder:plan.destinationOrder,included:Set(selected.keys)).compactMap{selected[$0]}
}
private func revisionSelectedIdentities(_ node:RevisionSelectedShape,records:inout[RevisionSelectedIdentity],cancellation:OperationCancellation?)throws {
    try cancellation?.check()
    records.append(.init(base:node.plan.base,destination:node.plan.destination,selected:node.shape.id,useNew:node.useNew))
    if let children=node.children {for child in children {try revisionSelectedIdentities(child,records:&records,cancellation:cancellation)};return}
    // For an atomic subtree only descendants actually retained from the chosen
    // source get output IDs. Pair aliases come from recursive sibling matches.
    var old:[String:String]=[:],new:[String:String]=[:]
    if let children=node.plan.children{revisionIdentityMaps(children,old:&old,new:&new)}
    let oldByKey=Dictionary(uniqueKeysWithValues:old.map{($0.value,$0.key)}),newByKey=Dictionary(uniqueKeysWithValues:new.map{($0.value,$0.key)})
    for child in revisionDescendants(node.shape.element).filter({revisionIs($0,"cNvPr",revisionPresentationNS)}).dropFirst() {
        try cancellation?.check();guard let raw=revisionAttribute(child,"id") else{throw PresentationRevisionFailure.invalid("Missing nested shape identity")}
        let key=(node.useNew ? new:old)[raw]
        records.append(.init(base:node.useNew ? key.flatMap{oldByKey[$0]}:raw,destination:node.useNew ? raw:key.flatMap{newByKey[$0]},selected:raw,useNew:node.useNew))
    }
}
private func revisionAppendShape(_ node:XMLElement,to container:XMLElement) {
    if let ext=revisionChildren(container).first(where:{revisionIs($0,"extLst",revisionPresentationNS)}),let index=container.children?.firstIndex(of:ext){container.insertChild(node,at:index)}else{container.addChild(node)}
}
private struct RevisionSlide {let id:String,path:String,index:Int}
private struct RevisionShape {let id:String,name:String,element:XMLElement}
private let revisionRelationshipNS="http://schemas.openxmlformats.org/package/2006/relationships"
private let revisionOfficeRelationshipNS="http://schemas.openxmlformats.org/officeDocument/2006/relationships"
private func revisionLocal(_ node:XMLNode)->String {(node.name ?? "").split(separator:":").last.map(String.init) ?? ""}
private func revisionChildren(_ node:XMLElement)->[XMLElement] {(node.children ?? []).compactMap{$0 as? XMLElement}}
private func revisionChild(_ node:XMLElement,_ name:String)->XMLElement? {revisionChildren(node).first{revisionLocal($0)==name}}
private func revisionDescendants(_ node:XMLElement)->[XMLElement] {[node]+revisionChildren(node).flatMap(revisionDescendants)}
private func revisionAttribute(_ node:XMLElement,_ name:String)->String? {
    guard let value=node.attribute(forName:name)?.stringValue else{return nil}
    let local=revisionLocal(node)
    let numeric=(node.uri==revisionPresentationNS && ((name=="id" && ["sldId","sldMasterId","cNvPr","cmAuthor"].contains(local)) || (name=="authorId" && local=="cm") || (name=="idx" && local=="cm"))) || (node.uri==revisionDrawingNS && name=="id" && ["stCxn","endCxn"].contains(local))
    return numeric ? UInt32(value).map(String.init) ?? value:value
}
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
private let revisionClassicCommentsType="application/vnd.openxmlformats-officedocument.presentationml.comments+xml"
private let revisionClassicAuthorsType="application/vnd.openxmlformats-officedocument.presentationml.commentAuthors+xml"
private let revisionContentNS="http://schemas.openxmlformats.org/package/2006/content-types"
private func revisionIs(_ node:XMLElement,_ name:String,_ uri:String)->Bool {revisionLocal(node)==name && node.uri==uri}
private final class RevisionFingerprintCache {var raw:[String:String]=[:];var graph:[String:String]=[:];var relations:[String:[String:String]]=[:];var shapes:[String:[RevisionShape]]=[:]}
private struct RevisionDeck {
    private let fingerprints=RevisionFingerprintCache()
    let entries:[String:Data],presentation:String,slides:[RevisionSlide],types:[String:String],defaults:[String:String]
    var partTypes:[String:String] {Dictionary(uniqueKeysWithValues:entries.keys.compactMap {path in
        guard !path.hasSuffix("/"),!path.hasSuffix(".rels"),let type=types[path] ?? defaults[(path as NSString).pathExtension.lowercased()] else{return nil};return(path,type)
    })}
    var hasMacros:Bool {partTypes.values.contains{$0.contains("macroEnabled") || $0.contains("vbaProject")} || entries.keys.contains{$0.lowercased().hasSuffix("vbaproject.bin")}}
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
        for slide in slides {try cancellation?.check();shapeCount += try shapes(slide).reduce(0){$0+revisionDescendants($1.element).filter{revisionIs($0,"cNvPr",revisionPresentationNS)}.count};guard shapeCount<=20000 else{throw PresentationRevisionFailure.unsupported("More than 20,000 shapes in a deck")}}
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
        if rels.hasPrefix("_rels/"),rels.hasSuffix(".rels") {
            let name=String(rels.dropFirst(6).dropLast(5))
            guard !name.isEmpty,!name.contains("/"),name != ".",name != ".." else{throw PresentationRevisionFailure.invalid("Malformed root relationship part path")}
            return name
        }
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
        if let cached=fingerprints.shapes[slide.path]{return cached}
        let shapeTree=try tree(slide)
        var seen=Set<String>(),allIDs=Set(revisionChildren(shapeTree).filter{revisionIs($0,"nvGrpSpPr",revisionPresentationNS)}.flatMap(revisionDescendants).filter{revisionIs($0,"cNvPr",revisionPresentationNS)}.compactMap{revisionAttribute($0,"id")}),result:[RevisionShape]=[]
        for node in revisionChildren(shapeTree) where !["nvGrpSpPr","grpSpPr","extLst"].contains(revisionLocal(node)) {
            guard node.uri==revisionPresentationNS,["sp","pic","graphicFrame","cxnSp","grpSp","contentPart"].contains(revisionLocal(node)) else{throw PresentationRevisionFailure.unsupported("Unknown shape tree element in slide \(slide.index+1)")}
            let ids=revisionDescendants(node).filter{revisionIs($0,"cNvPr",revisionPresentationNS)}
            for item in ids {guard let id=revisionAttribute(item,"id"),UInt32(id) != nil,allIDs.insert(id).inserted else{throw PresentationRevisionFailure.invalid("Duplicate nested shape identity")}}
            guard let identity=ids.first,let id=revisionAttribute(identity,"id"),UInt32(id) != nil,seen.insert(id).inserted else{throw PresentationRevisionFailure.invalid("Missing or duplicate shape identity")}
            result.append(.init(id:id,name:revisionAttribute(identity,"name") ?? "Shape "+id,element:node))
        }
        fingerprints.shapes[slide.path]=result;return result
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
    var hasModernComments:Bool {partTypes.values.contains {type in let value=type.lowercased();return value.contains("person") || (value.contains("comment") && type != revisionClassicCommentsType && type != revisionClassicAuthorsType)}}
    func classicAuthorSemantics()throws->[String:String] {
        let registries=try revisionRelationships(entries,part:presentation).filter{$0.type==revisionOfficeRelationshipNS+"/commentAuthors" && !$0.external}
        guard registries.count==1 else{throw PresentationRevisionFailure.invalid("Classic comments require one author registry")}
        let root=try document(revisionTarget(registries[0].target,from:presentation)).rootElement()!
        guard revisionIs(root,"cmAuthorLst",revisionPresentationNS) else{throw PresentationRevisionFailure.invalid("Invalid classic comment author registry")}
        var result:[String:String]=[:]
        for author in revisionChildren(root) {
            guard revisionIs(author,"cmAuthor",revisionPresentationNS),let id=revisionAttribute(author,"id"),result[id]==nil else{throw PresentationRevisionFailure.invalid("Invalid classic comment author identity")}
            let copy=author.copy() as! XMLElement;copy.removeAttribute(forName:"id");copy.removeAttribute(forName:"lastIdx");result[id]=revisionHash(Data(revisionCanonical(copy).utf8))
        }
        return result
    }
    func semanticGraphFingerprint(_ part:String,excluding:Set<String>,cancellation:OperationCancellation?)throws->String {
        let cacheKey="semantic:"+part+"|"+excluding.sorted().joined(separator:"|")
        if let value=fingerprints.graph[cacheKey]{try cancellation?.check();return value}
        var count=0
        func visit(_ path:String,_ ancestry:Set<String>)throws->String {
            try cancellation?.check();count += 1
            guard ancestry.count<=128,count<=40000 else{throw PresentationRevisionFailure.unsupported("Semantic dependency graph exceeds review budget")}
            let type=try contentType(path)
            if excluding.contains(path){return "reference:"+type}
            if ancestry.contains(path){return "cycle:"+type}
            guard let data=entries[path] else{throw PresentationRevisionFailure.invalid("Missing dependency "+path)}
            var next=ancestry;next.insert(path)
            var relations:[String:String]=[:]
            for rel in try revisionRelationships(entries,part:path) {
                relations[rel.id]=rel.type+":"+(rel.external ? "external:"+rel.target:try visit(revisionTarget(rel.target,from:path),next))
            }
            let content:String
            if (path as NSString).pathExtension.lowercased()=="xml" || type.hasSuffix("+xml") || type=="application/xml" {
                let root=try revisionXML(data,path).rootElement()!
                if type==revisionClassicCommentsType {
                    let authors=try classicAuthorSemantics()
                    for comment in revisionChildren(root) where revisionIs(comment,"cm",revisionPresentationNS) {
                        guard let id=revisionAttribute(comment,"authorId"),let author=authors[id] else{throw PresentationRevisionFailure.invalid("Classic comment references an unknown author")};revisionSet(comment,"authorId",author)
                    }
                }
                var shapeIDs:[String:String]=[:]
                for (index,node) in revisionDescendants(root).filter({revisionIs($0,"cNvPr",revisionPresentationNS)}).enumerated(){if let id=revisionAttribute(node,"id"){shapeIDs[id]="local-\(index)"}}
                content=revisionCanonical(root,ids:shapeIDs,relationships:relations)
            } else {content=revisionHash(data)}
            return revisionHash(Data((type+"|"+content+"|"+relations.values.sorted().joined(separator:"|")).utf8))
        }
        let value=try visit(part,[]);if fingerprints.graph.count<50000{fingerprints.graph[cacheKey]=value};return value
    }
    func semanticRelationships(_ slide:RevisionSlide,cancellation:OperationCancellation?)throws->[String:String] {
        if let cached=fingerprints.relations[slide.path]{try cancellation?.check();return cached}
        var result:[String:String]=[:]
        for rel in try revisionRelationships(entries,part:slide.path) {
            result[rel.id]=rel.type+":"+(rel.external ? "external:"+rel.target:try semanticGraphFingerprint(revisionTarget(rel.target,from:slide.path),excluding:[slide.path,presentation],cancellation:cancellation))
        }
        fingerprints.relations[slide.path]=result;return result
    }
    func shapeIdentityFingerprint(_ shape:RevisionShape,slide:RevisionSlide,cancellation:OperationCancellation?)throws->String {
        var ids:[String:String]=[:]
        for (index,node) in revisionDescendants(shape.element).filter({revisionIs($0,"cNvPr",revisionPresentationNS)}).enumerated(){if let id=revisionAttribute(node,"id"){ids[id]="local-\(index)"}}
        return revisionHash(Data(revisionCanonical(shape.element,ids:ids,relationships:try semanticRelationships(slide,cancellation:cancellation),ignoreNames:true).utf8))
    }
    func shapeFingerprint(_ shape:RevisionShape?,slide:RevisionSlide,identities:[String:String],cancellation:OperationCancellation?)throws->String? {
        guard let shape else{return nil};var ids=identities
        let identity=identities[shape.id] ?? shape.id
        for (index,node) in revisionDescendants(shape.element).filter({revisionIs($0,"cNvPr",revisionPresentationNS)}).enumerated(){if let id=revisionAttribute(node,"id"),ids[id]==nil{ids[id]=identity+"-child-\(index)"}}
        return revisionHash(Data(revisionCanonical(shape.element,ids:ids,relationships:try semanticRelationships(slide,cancellation:cancellation)).utf8))
    }
    func slideIdentityFingerprint(_ slide:RevisionSlide,cancellation:OperationCancellation?)throws->String {
        let shapeParts=try shapes(slide).map{try shapeIdentityFingerprint($0,slide:slide,cancellation:cancellation)}
        return revisionHash(Data((shapeParts.joined(separator:"|")+"|"+(try slideEnvironmentFingerprint(slide,cancellation:cancellation))).utf8))
    }
    func slideSimilarity(_ slide:RevisionSlide,_ other:RevisionDeck,_ next:RevisionSlide)throws->Double {
        let oldShapes=try shapes(slide),newShapes=try other.shapes(next)
        let oldWords=revisionWords(oldShapes.map{revisionShapeText($0)}.joined(separator:" ")),newWords=revisionWords(newShapes.map{revisionShapeText($0)}.joined(separator:" "))
        guard min(oldWords.count,newWords.count)>=3 else{return 0}
        let text=revisionOverlap(oldWords,newWords);guard text>=0.70 else{return 0}
        let geometry=revisionOverlap(Set(oldShapes.map{revisionShapeGeometry($0)}),Set(newShapes.map{revisionShapeGeometry($0)}))
        return 0.65*text+0.35*geometry
    }
    func slideEnvironmentFingerprint(_ slide:RevisionSlide,cancellation:OperationCancellation?)throws->String {
        let doc=try document(slide.path),root=doc.rootElement()!,shapes=try shapes(slide)
        let shapeRefs=shapes.reduce(into:Set<String>()){$0.formUnion(revisionRelationshipIDs($1.element))}
        guard let cs=revisionChild(root,"cSld"),let tree=revisionChild(cs,"spTree") else{throw PresentationRevisionFailure.invalid("Missing shape tree")}
        for node in revisionChildren(tree) where !["nvGrpSpPr","grpSpPr","extLst"].contains(revisionLocal(node)){node.detach()}
        let envRefs=revisionRelationshipIDs(root)
        var rootIDs:[String:String]=[:];for node in revisionDescendants(root) where revisionIs(node,"cNvPr",revisionPresentationNS){if let id=revisionAttribute(node,"id"){rootIDs[id]="root"}}
        var parts=[revisionCanonical(root,ids:rootIDs,relationships:try semanticRelationships(slide,cancellation:cancellation))]
        for rel in try revisionRelationships(entries,part:slide.path).sorted(by:{$0.id<$1.id}) where !shapeRefs.contains(rel.id) || envRefs.contains(rel.id) {
            parts.append(rel.type+":"+(rel.external ? rel.target:try semanticGraphFingerprint(revisionTarget(rel.target,from:slide.path),excluding:[slide.path,presentation],cancellation:cancellation)))
        }
        return revisionHash(Data((parts.first!+"|"+parts.dropFirst().sorted().joined(separator:"|")).utf8))
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
    var entries:[String:Data],slidePaths:[String:String]=[:],slideNumbers:[String:String]=[:]
    let anchor:RevisionDeck,foreign:RevisionDeck
    private var mapping:[String:String]=[:],pinned=Set<String>(),imported=Set<String>(),counter=0
    private var typeOverrides:[String:String]=[:]
    private var usedSlideNumbers=Set<UInt32>()
    var commentShapeMaps:[String:[String:String]]=[:]
    private var authorsPrepared=false,authorIDs:[String:String]=[:],commentIndices:[String:Set<UInt32>]=[:]
    private var authorsDocument:XMLDocument?,authorsPath:String?,newAuthorRegistry:String?
    init(anchor:RevisionDeck,foreign:RevisionDeck,cancellation:OperationCancellation?)throws {
        try cancellation?.check();self.anchor=anchor;self.foreign=foreign;entries=anchor.entries
        mapping[foreign.presentation]=anchor.presentation;pinned.insert(foreign.presentation);usedSlideNumbers=Set(anchor.slides.compactMap{UInt32($0.id)})
    }
    mutating func reserveSlide(id:String,anchor:String?,foreign:String?,anchorID:String?,foreignID:String?)throws {
        let path=anchor ?? allocate(foreign ?? "ppt/slides/slide.xml")
        slidePaths[id]=path
        if let anchorID {slideNumbers[id]=anchorID}
        else {
            var numeric=UInt32(foreignID ?? "") ?? 256
            if usedSlideNumbers.contains(numeric){numeric=256;while usedSlideNumbers.contains(numeric){guard numeric<UInt32.max else{throw PresentationRevisionFailure.unsupported("Slide identity space exhausted")};numeric += 1}}
            usedSlideNumbers.insert(numeric);slideNumbers[id]=String(numeric)
        }
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
    private mutating func prepareAuthors(cancellation:OperationCancellation?)throws {
        if authorsPrepared{return};authorsPrepared=true
        let sourceEdges=try revisionRelationships(foreign.entries,part:foreign.presentation).filter{$0.type==revisionOfficeRelationshipNS+"/commentAuthors" && !$0.external}
        guard sourceEdges.count==1 else{throw PresentationRevisionFailure.invalid("Classic comments require one author registry")}
        let sourcePath=try revisionTarget(sourceEdges[0].target,from:foreign.presentation),sourceDoc=try foreign.document(sourcePath),sourceRoot=sourceDoc.rootElement()!
        guard revisionIs(sourceRoot,"cmAuthorLst",revisionPresentationNS),try revisionRelationships(foreign.entries,part:sourcePath).isEmpty else{throw PresentationRevisionFailure.unsupported("Extended classic comment author registries cannot be combined independently")}
        let sourceAuthors=revisionChildren(sourceRoot)
        guard sourceAuthors.count<=10000,sourceAuthors.allSatisfy({revisionIs($0,"cmAuthor",revisionPresentationNS) && revisionRelationshipIDs($0).isEmpty}) else{throw PresentationRevisionFailure.unsupported("Unsupported classic comment author registry entries")}
        let anchorEdges=try revisionRelationships(anchor.entries,part:anchor.presentation).filter{$0.type==revisionOfficeRelationshipNS+"/commentAuthors" && !$0.external}
        guard anchorEdges.count<=1 else{throw PresentationRevisionFailure.invalid("Duplicate classic comment author registries")}
        let targetDoc:XMLDocument,targetPath:String
        if let existing=anchorEdges.first {
            targetPath=try revisionTarget(existing.target,from:anchor.presentation);targetDoc=try anchor.document(targetPath)
            guard revisionIs(targetDoc.rootElement()!,"cmAuthorLst",revisionPresentationNS),try revisionRelationships(anchor.entries,part:targetPath).isEmpty else{throw PresentationRevisionFailure.unsupported("Extended classic comment author registries cannot be combined independently")}
        } else {
            targetPath=allocate(sourcePath);targetDoc=sourceDoc.copy() as! XMLDocument
            targetDoc.rootElement()!.setChildren([]);newAuthorRegistry=targetPath
            typeOverrides[targetPath]=revisionClassicAuthorsType
        }
        let root=targetDoc.rootElement()!
        for namespace in sourceRoot.namespaces ?? [] {
            let prefix=namespace.name ?? ""
            if let existing=root.namespace(forPrefix:prefix) {guard existing.stringValue==namespace.stringValue else{throw PresentationRevisionFailure.unsupported("Conflicting comment author namespace prefixes")}}
            else {root.addNamespace(namespace.copy() as! XMLNode)}
        }
        func authorKey(_ node:XMLElement)->String {
            let copied=node.copy() as! XMLElement;copied.removeAttribute(forName:"id");copied.removeAttribute(forName:"lastIdx");return revisionCanonical(copied)
        }
        var used=Set<UInt32>(),known:[String:[String]]=[:]
        for author in revisionChildren(root) {
            guard revisionIs(author,"cmAuthor",revisionPresentationNS),let id=revisionAttribute(author,"id"),let numeric=UInt32(id),used.insert(numeric).inserted else{throw PresentationRevisionFailure.invalid("Invalid classic comment author identity")}
            known[authorKey(author),default:[]].append(id)
        }
        let grouped=Dictionary(grouping:sourceAuthors,by:authorKey)
        var sourceIDs=Set<String>()
        for author in sourceAuthors {
            try cancellation?.check()
            guard let id=revisionAttribute(author,"id"),UInt32(id) != nil,sourceIDs.insert(id).inserted else{throw PresentationRevisionFailure.invalid("Invalid source comment author identity")}
            let key=authorKey(author)
            if let matches=known[key],matches.count==1,grouped[key]?.count==1 {authorIDs[id]=matches[0];continue}
            var numeric=UInt32(id)!
            if used.contains(numeric){numeric=0;while used.contains(numeric){guard numeric<UInt32.max else{throw PresentationRevisionFailure.unsupported("Comment author identity space exhausted")};numeric += 1}}
            used.insert(numeric);let mapped=String(numeric),copied=author.copy() as! XMLElement;revisionSet(copied,"id",mapped)
            root.addChild(copied);known[key,default:[]].append(mapped);authorIDs[id]=mapped
        }
        for (path,type) in anchor.partTypes where type==revisionClassicCommentsType {
            for node in revisionChildren(try anchor.document(path).rootElement()!) where revisionIs(node,"cm",revisionPresentationNS) {
                if let author=revisionAttribute(node,"authorId"),let idx=revisionAttribute(node,"idx").flatMap(UInt32.init){commentIndices[author,default:[]].insert(idx)}
            }
        }
        authorsDocument=targetDoc;authorsPath=targetPath;entries[targetPath]=revisionData(targetDoc)
    }
    private mutating func importClassicComments(_ data:Data,path:String,cancellation:OperationCancellation?)throws->Data {
        try prepareAuthors(cancellation:cancellation)
        let doc=try revisionXML(data,path),root=doc.rootElement()!
        guard revisionIs(root,"cmLst",revisionPresentationNS),revisionChildren(root).count<=50000 else{throw PresentationRevisionFailure.invalid("Invalid classic comments part")}
        for comment in revisionChildren(root) {
            try cancellation?.check()
            guard revisionIs(comment,"cm",revisionPresentationNS),let author=revisionAttribute(comment,"authorId"),let mapped=authorIDs[author],let raw=revisionAttribute(comment,"idx"),var idx=UInt32(raw) else{throw PresentationRevisionFailure.invalid("Classic comment has an unknown author or index")}
            // Legacy comment extensions may encode threading references by index.
            // Do not reinterpret unknown schemas while changing those identities.
            guard !revisionDescendants(comment).contains(where:{revisionLocal($0)=="extLst" || $0.uri != revisionPresentationNS}) else{throw PresentationRevisionFailure.unsupported("Extended/threaded classic comments cannot be remapped independently")}
            if commentIndices[mapped,default:[]].contains(idx) {
                idx=(commentIndices[mapped]?.max() ?? 0)
                repeat {guard idx<UInt32.max else{throw PresentationRevisionFailure.unsupported("Comment index space exhausted")};idx += 1}while commentIndices[mapped,default:[]].contains(idx)
            }
            commentIndices[mapped,default:[]].insert(idx);revisionSet(comment,"authorId",mapped);revisionSet(comment,"idx",String(idx))
            if let node=revisionChildren(authorsDocument!.rootElement()!).first(where:{revisionAttribute($0,"id")==mapped}) {
                let previous=revisionAttribute(node,"lastIdx").flatMap(UInt32.init) ?? 0;revisionSet(node,"lastIdx",String(max(previous,idx)))
            }
        }
        entries[authorsPath!]=revisionData(authorsDocument!);return revisionData(doc)
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
            let existing=anchor.partTypes.filter{$0.value==type}.map(\.key)
            if let first=existing.first {
                if try foreign.semanticGraphFingerprint(path,excluding:[foreign.presentation],cancellation:cancellation)==anchor.semanticGraphFingerprint(first,excluding:[anchor.presentation],cancellation:cancellation) {mapping[path]=first;pinned.insert(path);return first}
                throw PresentationRevisionFailure.unsupported("Mixed slides require different presentation-wide notes or handout masters. Choose one complete revision instead.")
            }
        }
        let target=mapping[path] ?? allocate(path);mapping[path]=target;imported.insert(path)
        if type==revisionClassicAuthorsType {try prepareAuthors(cancellation:cancellation);mapping[path]=authorsPath!;pinned.insert(path);return authorsPath!}
        if type==revisionClassicCommentsType {entries[target]=try importClassicComments(foreign.entries[path]!,path:path,cancellation:cancellation)}
        else {entries[target]=foreign.entries[path]}
        typeOverrides[target]=type
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
        let ids=Dictionary(uniqueKeysWithValues:try source.shapes(RevisionSlide(id:"",path:path,index:0)).flatMap{revisionDescendants($0.element).filter{revisionIs($0,"cNvPr",revisionPresentationNS)}.compactMap{revisionAttribute($0,"id")}}.map{($0,$0)})
        commentShapeMaps[(fromAnchor ? "anchor:":"foreign:")+path]=ids
        if fromAnchor {
            guard path==target else{throw PresentationRevisionFailure.invalid("Unexpected anchor slide mapping")};return
        }
        guard let bytes=source.entries[path] else{throw PresentationRevisionFailure.invalid("Missing selected slide")}
        entries[target]=bytes;typeOverrides[target]=try source.contentType(path)
        try copyRelationships(from:path,to:target,cancellation:cancellation)
    }
    mutating func mergeSlide(plan:RevisionSlidePlan,base:RevisionDeck,destination:RevisionDeck,target:String,anchorNew:Bool,decisions:[String:Bool],cancellation:OperationCancellation?)throws {
        let old=RevisionSlide(id:plan.baseID!,path:plan.base!,index:0),new=RevisionSlide(id:plan.destinationID!,path:plan.destination!,index:0)
        guard let container=plan.container else{throw PresentationRevisionFailure.invalid("Missing recursive shape plan")}
        let selected=try revisionSelectContainer(container,try base.shapes(old),try destination.shapes(new),anchorNew:anchorNew,decisions:decisions,cancellation:cancellation)
        let doc=try anchor.document(anchorNew ? new.path:old.path),root=doc.rootElement()!
        guard let cs=revisionChild(root,"cSld"),let tree=revisionChild(cs,"spTree") else{throw PresentationRevisionFailure.invalid("Missing output shape tree")}
        for node in revisionChildren(tree) where !["nvGrpSpPr","grpSpPr","extLst"].contains(revisionLocal(node)){node.detach()}
        let relPath=revisionRelsPath(target),relDoc:XMLDocument
        if let bytes=entries[relPath] {relDoc=try revisionXML(bytes,relPath)}
        else {relDoc=try revisionXML(Data(("<Relationships xmlns=\""+revisionRelationshipNS+"\"/>").utf8),relPath)}
        var used=Set(revisionChildren(relDoc.rootElement()!).compactMap{revisionAttribute($0,"Id")})
        // Resolve the complete selected tree before allocating IDs. Every source
        // counterpart is mapped within its matched parent, including targets of
        // connectors outside an otherwise atomic group.
        var oldIDs:[String:String]=[:],newIDs:[String:String]=[:]
        var records:[RevisionSelectedIdentity]=[]
        for node in selected {try revisionSelectedIdentities(node,records:&records,cancellation:cancellation)}
        var usedIDs=Set(revisionDescendants(tree).filter{revisionIs($0,"cNvPr",revisionPresentationNS)}.compactMap{revisionAttribute($0,"id")}.compactMap(UInt32.init))
        for record in records where record.useNew==anchorNew {if let id=UInt32(record.selected){usedIDs.insert(id)}}
        for record in records {
            try cancellation?.check()
            var number=UInt32(record.selected) ?? 2
            if record.useNew != anchorNew {
                let preferred=(anchorNew ? record.destination:record.base).flatMap(UInt32.init)
                if let preferred,!usedIDs.contains(preferred){number=preferred}
                else if usedIDs.contains(number){number=2;while usedIDs.contains(number){guard number<UInt32.max else{throw PresentationRevisionFailure.unsupported("Shape identity space exhausted")};number += 1}}
                usedIDs.insert(number)
            }
            let mapped=String(number)
            if let id=record.base{oldIDs[id]=mapped};if let id=record.destination{newIDs[id]=mapped}
        }
        commentShapeMaps[(anchorNew ? "foreign:":"anchor:")+old.path]=oldIDs
        commentShapeMaps[(anchorNew ? "anchor:":"foreign:")+new.path]=newIDs
        // Each piece is either a leaf/atomic subtree or the shell of a granular
        // group. Its source determines both identity and relationship remapping.
        var pieces:[RevisionSelectedShape]=[]
        func collect(_ nodes:[RevisionSelectedShape]) {for node in nodes {pieces.append(node);if let children=node.children{collect(children)}}}
        collect(selected)
        var copies:[String:XMLElement]=[:]
        for piece in pieces {
            try cancellation?.check()
            let source=piece.useNew ? destination:base,sourceSlide=piece.useNew ? new:old
            let original=piece.children == nil ? piece.shape.element:revisionGroupShell(piece.shape.element)
            let node=original.copy() as! XMLElement
            let identityMap=piece.useNew ? newIDs:oldIDs
            for descendant in revisionDescendants(node) {
                if revisionIs(descendant,"cNvPr",revisionPresentationNS),let sourceID=revisionAttribute(descendant,"id") {
                    guard let mapped=identityMap[sourceID] else{throw PresentationRevisionFailure.invalid("Missing selected shape identity")};revisionSet(descendant,"id",mapped)
                }
                if descendant.uri==revisionDrawingNS,["stCxn","endCxn"].contains(revisionLocal(descendant)),let sourceID=revisionAttribute(descendant,"id") {
                    guard let mapped=identityMap[sourceID] else{throw PresentationRevisionFailure.unsupported("A selected connector references a rejected or ambiguously matched shape. Review its target and connector together.")};revisionSet(descendant,"id",mapped)
                }
            }
            if piece.useNew != anchorNew {
                // A selected child can inherit prefixes from a group rather
                // than the slide root. Retain its complete in-scope bindings;
                // refuse conflicting bindings instead of silently retargeting.
                var namespaceScopes:[XMLElement]=[],ancestor:XMLElement?=piece.shape.element
                while let scope=ancestor {namespaceScopes.append(scope);ancestor=scope.parent as? XMLElement}
                for scope in namespaceScopes.reversed() {for ns in scope.namespaces ?? [] {
                    let prefix=ns.name ?? "",value=ns.stringValue ?? ""
                    if let current=root.namespace(forPrefix:prefix) {guard current.stringValue==value else{throw PresentationRevisionFailure.unsupported("Conflicting XML namespace prefixes between selected shapes")}}
                    else {root.addNamespace(ns.copy() as! XMLNode)}
                }}
                let relationships=try revisionRelationships(source.entries,part:sourceSlide.path),map=Dictionary(uniqueKeysWithValues:relationships.map{($0.id,$0)})
                for oldID in revisionRelationshipIDs(original).sorted() {
                    guard let rel=map[oldID] else{throw PresentationRevisionFailure.invalid("Missing selected shape dependency")}
                    var n=1;while used.contains("rIdTurtleGit\(n)"){n += 1};let newID="rIdTurtleGit\(n)";used.insert(newID)
                    let copied=rel.element.copy() as! XMLElement;revisionSet(copied,"Id",newID)
                    if !rel.external {let mapped=try importPart(revisionTarget(rel.target,from:sourceSlide.path),cancellation:cancellation);revisionSet(copied,"Target",revisionRelative(mapped,from:target))}
                    relDoc.rootElement()!.addChild(copied)
                    for descendant in revisionDescendants(node) {for attr in descendant.attributes ?? [] where attr.stringValue==oldID && attr.uri==revisionOfficeRelationshipNS {attr.stringValue=newID}}
                }
            }
            copies[piece.plan.id]=node
        }
        func assemble(_ piece:RevisionSelectedShape)->XMLElement {
            let node=copies[piece.plan.id]!
            if let children=piece.children {for child in children {revisionAppendShape(assemble(child),to:node)}}
            return node
        }
        for piece in selected {revisionAppendShape(assemble(piece),to:tree)}
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
            let node=XMLElement(name:"p:sldId",uri:revisionPresentationNS);revisionSet(node,"id",slideNumbers[id]!);revisionSet(node,"r:id",rid);list.addChild(node)
        }
        // Custom shows contain relationship IDs; sections contain numeric slide
        // IDs. Rewrite retained references and refuse a dangling selection.
        let listNodes=Set(revisionDescendants(list).map{ObjectIdentifier($0)})
        for node in revisionDescendants(root) where !listNodes.contains(ObjectIdentifier(node)) {
            if revisionIs(node,"sld",revisionPresentationNS),let oldID=RevisionDeck.relationshipID(node),let path=previous[oldID] {
                guard let rid=pathToRel[path] else{throw PresentationRevisionFailure.unsupported("A custom show refers to a rejected slide. Choose a complete revision or retain that slide.")};revisionSet(node,"r:id",rid)
            }
            if revisionLocal(node)=="sldId",node.parent !== list,let id=revisionAttribute(node,"id") {
                guard let source=anchor.slides.first(where:{$0.id==id}),let key=slidePaths.first(where:{$0.value==source.path})?.key,let number=slideNumbers[key] else{throw PresentationRevisionFailure.unsupported("A presentation section refers to a rejected slide. Choose a complete revision or retain that slide.")};revisionSet(node,"id",number)
            }
        }
        if let path=newAuthorRegistry {
            let rel=XMLElement(name:"Relationship",uri:revisionRelationshipNS);revisionSet(rel,"Id",nextID());revisionSet(rel,"Type",revisionOfficeRelationshipNS+"/commentAuthors");revisionSet(rel,"Target",revisionRelative(path,from:anchor.presentation));relsRoot.addChild(rel)
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

// Verified PresentationML classic comments and MS-PPTX 2.16 (2018/8) comments.
public struct PresentationComment:Identifiable,Sendable,Equatable {
    public let id:String,threadID:String,text:String,author:String,initials:String,created:String,status:String,anchor:String
    public let parentID:String?
    public let slideIndex:Int,depth:Int
    public let isModern:Bool
}
public struct PresentationCommentChange:Sendable {
    public let base:PresentationComment?,destination:PresentationComment?
}
private let revisionThreadingNS="http://schemas.microsoft.com/office/powerpoint/2012/main"
private func revisionStandalone(_ node:XMLElement)->String {
    let copy=node.copy() as! XMLElement
    var scopes:[XMLElement]=[],parent:XMLElement?=node
    while let value=parent {scopes.append(value);parent=value.parent as? XMLElement}
    for scope in scopes.reversed() {for ns in scope.namespaces ?? [] {
        if copy.namespace(forPrefix:ns.name ?? "")==nil {copy.addNamespace(ns.copy() as! XMLNode)}
    }}
    return copy.xmlString
}
private let revisionModernNS="http://schemas.microsoft.com/office/powerpoint/2018/8/main"
private let revisionModernCommentsType="application/vnd.ms-powerpoint.comments+xml"
private let revisionModernAuthorsType="application/vnd.ms-powerpoint.authors+xml"
private let revisionModernRelationship="http://schemas.microsoft.com/office/2018/10/relationships/"
private struct RevisionCommentRecord:Sendable {
    var value:PresentationComment
    let slidePath:String,node:String,authorNode:String,authorKey:String,assigned:[String:String],modernExtension:String?
    let order:Int
}
private struct RevisionComments:Sendable {
    var records:[String:RevisionCommentRecord]=[:]
    let stripped:PresentationPackage
    let unsupported:Bool
    private init(opaque:PresentationPackage) {stripped=opaque;unsupported=true}
    static func read(_ package:PresentationPackage,slideKeys:[String:String],cancellation:OperationCancellation?)throws->Self {
        do {return try Self(package,slideKeys:slideKeys,cancellation:cancellation)}
        catch PresentationRevisionFailure.unsupported(_) {try cancellation?.check();return Self(opaque:package)}
    }
    init(_ package:PresentationPackage,slideKeys:[String:String],cancellation:OperationCancellation?)throws {
        let deck=try RevisionDeck(package,cancellation:cancellation)
        var records:[String:RevisionCommentRecord]=[:]
        var entries=package.entries,removed=Set<String>(),unknown=false
        var authors:[Bool:[String:String]]=[:]
        for rel in try revisionRelationships(entries,part:deck.presentation) where !rel.external {
            let path=try revisionTarget(rel.target,from:deck.presentation),type=deck.partTypes[path] ?? ""
            let modern=type==revisionModernAuthorsType
            guard modern || type==revisionClassicAuthorsType else{continue}
            guard rel.type==(modern ? revisionModernRelationship+"authors":revisionOfficeRelationshipNS+"/commentAuthors") else{throw PresentationRevisionFailure.invalid("Comment author relationship type mismatch")}
            guard authors[modern]==nil else{throw PresentationRevisionFailure.invalid("Duplicate comment author registry")}
            let doc=try deck.document(path),root=doc.rootElement()!,ns=modern ? revisionModernNS:revisionPresentationNS
            guard revisionIs(root,modern ? "authorLst":"cmAuthorLst",ns),try revisionRelationships(entries,part:path).isEmpty else{throw PresentationRevisionFailure.unsupported("Extended comment author registry")}
            var values:[String:String]=[:]
            for node in revisionChildren(root) {
                guard revisionIs(node,modern ? "author":"cmAuthor",ns),let raw=revisionAttribute(node,"id"),!raw.isEmpty else{throw PresentationRevisionFailure.unsupported("Unknown comment author")}
                guard revisionDescendants(node).dropFirst().allSatisfy({element in
                    !modern && ((element.uri==revisionPresentationNS && ["extLst","ext"].contains(revisionLocal(element))) || revisionIs(element,"presenceInfo",revisionThreadingNS))
                }) else{throw PresentationRevisionFailure.unsupported("Unknown comment author extension")}
                let id:String
                if modern {guard revisionAttribute(node,"name") != nil,revisionAttribute(node,"userId") != nil,revisionAttribute(node,"providerId") != nil,let guid=revisionCommentGUIDIdentity(raw) else{throw PresentationRevisionFailure.invalid("Invalid modern author GUID")};id=guid}
                else {guard let number=UInt32(raw) else{throw PresentationRevisionFailure.invalid("Invalid classic author ID")};id=String(number)}
                guard values[id]==nil else{throw PresentationRevisionFailure.invalid("Duplicate comment author identity")}
                values[id]=revisionStandalone(node)
            }
            authors[modern]=values;removed.insert(path)
        }
        for slide in deck.slides {
            try cancellation?.check()
            let logical=slideKeys[slide.path] ?? slide.id
            var seen=Set<String>()
            let slideDoc=try deck.document(slide.path)
            let modernExtensions=revisionDescendants(slideDoc.rootElement()!).filter{revisionIs($0,"commentRel",revisionModernNS)}
            for rel in try revisionRelationships(entries,part:slide.path) where !rel.external {
                let path=try revisionTarget(rel.target,from:slide.path),type=deck.partTypes[path] ?? ""
                let modern=type==revisionModernCommentsType
                guard modern || type==revisionClassicCommentsType else{continue}
                guard rel.type==(modern ? revisionModernRelationship+"comments":revisionOfficeRelationshipNS+"/comments") else{throw PresentationRevisionFailure.invalid("Comment relationship type mismatch")}
                let doc=try deck.document(path),root=doc.rootElement()!,ns=modern ? revisionModernNS:revisionPresentationNS
                guard revisionIs(root,"cmLst",ns),try revisionRelationships(entries,part:path).isEmpty else{throw PresentationRevisionFailure.unsupported("Comment parts with dependent relationships")}
                let extensionNode=modernExtensions.first{revisionAttribute($0,"id")==rel.id || $0.attributes?.contains(where:{$0.localName=="id" && $0.stringValue==rel.id})==true}?.parent as? XMLElement
                if modern,extensionNode==nil {throw PresentationRevisionFailure.invalid("Modern comment relationship has no slide extension")}
                func read(_ node:XMLElement,parent:String?,thread:String?,depth:Int)throws {
                    try cancellation?.check()
                    guard depth<=64,records.count<50000,revisionIs(node,parent==nil ? "cm":"reply",ns),let rawAuthor=revisionAttribute(node,"authorId") else{throw PresentationRevisionFailure.invalid("Invalid comment identity")}
                    let authorID=modern ? revisionCommentGUIDIdentity(rawAuthor) ?? "":UInt32(rawAuthor).map(String.init) ?? ""
                    guard let authorXML=authors[modern]?[authorID] else{throw PresentationRevisionFailure.invalid("Unknown comment author or reply structure")}
                    let author=try revisionXML(Data(authorXML.utf8),"comment author").rootElement()!
                    let raw=modern ? revisionAttribute(node,"id").flatMap(revisionCommentGUIDIdentity) : revisionAttribute(node,"idx").flatMap(UInt32.init).map{authorID+":"+String($0)}
                    if modern {
                        guard revisionAttribute(node,"created") != nil,let raw,UUID(uuidString:raw.trimmingCharacters(in:CharacterSet(charactersIn:"{}"))) != nil else{throw PresentationRevisionFailure.invalid("Invalid modern comment GUID or creation time")}
                    }
                    guard let raw,!raw.isEmpty,seen.insert(raw).inserted else{throw PresentationRevisionFailure.invalid("Duplicate comment identity")}
                    let id="comment-"+revisionHash(Data((logical+"\0"+String(modern)+"\0"+raw).utf8))
                    let rootID=thread ?? id
                    let shell=try revisionXML(Data(revisionStandalone(node).utf8),"comment").rootElement()!
                    revisionChildren(shell).filter{revisionIs($0,"replyLst",ns)}.forEach{$0.detach()}
                    if modern {
                        let known=Set(["id","authorId","status","created","startDate","dueDate","assignedTo","complete","title"])
                        guard (shell.attributes ?? []).allSatisfy({known.contains(revisionLocal($0)) && ($0.uri ?? "").isEmpty}),!revisionDescendants(shell).contains(where:{revisionLocal($0)=="extLst"}) else{throw PresentationRevisionFailure.unsupported("Unknown modern comment properties or extensions")}
                    } else if let ext=revisionChild(shell,"extLst") {
                        guard revisionDescendants(ext).allSatisfy({element in
                            (element.uri==revisionPresentationNS && ["extLst","ext"].contains(revisionLocal(element))) || (element.uri==revisionThreadingNS && ["threadingInfo","parentCm"].contains(revisionLocal(element)))
                        }) else{throw PresentationRevisionFailure.unsupported("Unknown classic comment extensions")}
                    }
                    if modern {
                        for moniker in revisionDescendants(shell) where moniker.uri=="http://schemas.microsoft.com/office/powerpoint/2013/main/command" && revisionLocal(moniker)=="sldMk" {
                            guard revisionAttribute(moniker,"sldId").flatMap(UInt32.init)==UInt32(slide.id) else{throw PresentationRevisionFailure.invalid("Comment moniker names another slide")}
                        }
                    }
                    let text=modern ? revisionDescendants(shell).filter{revisionIs($0,"t",revisionDrawingNS)}.compactMap(\.stringValue).joined(separator:"") : revisionChild(shell,"text")?.stringValue ?? ""
                    let anchor=revisionChildren(shell).filter{!["txBody","text","replyLst"].contains(revisionLocal($0))}.map(\.xmlString).joined(separator:"\n")
                    var assigned:[String:String]=[:]
                    for aid in (revisionAttribute(node,"assignedTo") ?? "").split(whereSeparator:{$0.isWhitespace}).map(String.init) {
                        guard let value=authors[modern]?[revisionCommentGUIDIdentity(aid) ?? aid] else{throw PresentationRevisionFailure.invalid("Comment assignment references an unknown author")};assigned[aid]=value
                    }
                    let value=PresentationComment(id:id,threadID:rootID,text:text,author:revisionAttribute(author,"name") ?? "",initials:revisionAttribute(author,"initials") ?? "",created:revisionAttribute(node,modern ? "created":"dt") ?? "",status:revisionAttribute(node,"status") ?? "active",anchor:anchor,parentID:parent,slideIndex:slide.index,depth:depth,isModern:modern)
                    if modern,!Set(["active","resolved","closed"]).contains(value.status){throw PresentationRevisionFailure.unsupported("Unknown modern comment status")}
                    records[id]=RevisionCommentRecord(value:value,slidePath:slide.path,node:shell.xmlString,authorNode:authorXML,authorKey:authorID,assigned:assigned,modernExtension:extensionNode.map(revisionStandalone),order:records.count)
                    if let replies=revisionChild(node,"replyLst") {guard parent==nil else{throw PresentationRevisionFailure.invalid("Modern replies cannot contain reply lists")};for reply in revisionChildren(replies){try read(reply,parent:id,thread:rootID,depth:depth+1)}}
                }
                for node in revisionChildren(root){try read(node,parent:nil,thread:nil,depth:0)}
                removed.insert(path)
            }
            for node in modernExtensions {if let parent=node.parent as? XMLElement {parent.detach()}}
            for list in revisionChildren(slideDoc.rootElement()!) where revisionLocal(list)=="extLst" && revisionChildren(list).isEmpty {list.detach()}
            entries[slide.path]=revisionData(slideDoc)
        }
        // Classic parent identity is presentation-wide (authorId, idx), not a
        // nested XML reply. Preserve its actual graph, including cross-slide links.
        var classic:[String:String]=[:]
        for (id,record) in records where !record.value.isModern {
            let node=try revisionXML(Data(record.node.utf8),"classic comment").rootElement()!
            let key=record.authorKey+":"+String(UInt32(revisionAttribute(node,"idx") ?? "")!)
            guard classic.updateValue(id,forKey:key)==nil else{throw PresentationRevisionFailure.invalid("Duplicate presentation-wide classic comment index")}
        }
        var parents:[String:String]=[:]
        for (id,record) in records where !record.value.isModern {
            let node=try revisionXML(Data(record.node.utf8),"classic comment").rootElement()!
            if let parent=revisionDescendants(node).first(where:{revisionIs($0,"parentCm",revisionThreadingNS)}) {
                guard let author=revisionAttribute(parent,"authorId"),let idx=revisionAttribute(parent,"idx"),let a=UInt32(author),let i=UInt32(idx),let target=classic[String(a)+":"+String(i)] else{throw PresentationRevisionFailure.invalid("Classic reply references an unknown parent")}
                parents[id]=target
            }
        }
        for id in parents.keys {
            var current=id,seen=Set<String>(),depth=0
            while let parent=parents[current] {guard seen.insert(current).inserted,depth<64 else{throw PresentationRevisionFailure.invalid("Classic comment thread cycle or depth")};current=parent;depth += 1}
            var record=records[id]!,v=record.value
            v=PresentationComment(id:v.id,threadID:current,text:v.text,author:v.author,initials:v.initials,created:v.created,status:v.status,anchor:v.anchor,parentID:parents[id],slideIndex:v.slideIndex,depth:depth,isModern:false)
            record.value=v;records[id]=record
        }
        for (path,type) in deck.partTypes where type.lowercased().contains("comment") || type.lowercased().contains("person") || type==revisionModernAuthorsType {
            if !removed.contains(path){unknown=true}
        }
        for path in removed {entries.removeValue(forKey:path);entries.removeValue(forKey:revisionRelsPath(path))}
        for path in Array(entries.keys) where path.hasSuffix(".rels") {
            let doc=try revisionXML(entries[path]!,path)
            let source=try RevisionDeck.owner(of:path)
            for node in revisionChildren(doc.rootElement()!) where revisionAttribute(node,"TargetMode") != "External" {
                if let target=revisionAttribute(node,"Target"),removed.contains(try revisionTarget(target,from:source)){node.detach()}
            }
            entries[path]=revisionData(doc)
        }
        let types=try revisionXML(entries["[Content_Types].xml"]!,"content types")
        for node in revisionChildren(types.rootElement()!) {if let part=revisionAttribute(node,"PartName"),removed.contains(try revisionTarget(part,from:"")){node.detach()}}
        entries["[Content_Types].xml"]=revisionData(types)
        self.records=records;stripped=try (removed.isEmpty ? package:PresentationPackage(entries:entries));unsupported=unknown
    }
}

private func revisionCommentGUIDIdentity(_ raw:String)->String? {
    UUID(uuidString:raw.trimmingCharacters(in:CharacterSet(charactersIn:"{}"))).map{"{"+$0.uuidString+"}"}
}
private func revisionCommentGUID(_ seed:String)->String {
    let h=Array(revisionHash(Data(seed.utf8)).prefix(32))
    return "{"+String(h[0..<8])+"-"+String(h[8..<12])+"-"+String(h[12..<16])+"-"+String(h[16..<20])+"-"+String(h[20..<32])+"}"
}
private extension RevisionOutput {
    mutating func installComments(old:RevisionComments,new:RevisionComments,plans:[RevisionSlidePlan],decisions:[String:Bool],anchorNew:Bool,cancellation:OperationCancellation?)throws {
        var chosen:[String:(RevisionCommentRecord,Bool)]=[:]
        let all=Set(old.records.keys).union(new.records.keys)
        func explicitlyDeleted(_ id:String)->Bool {
            var current:String?=id,seen=Set<String>()
            while let key=current,seen.insert(key).inserted {
                if decisions["delete-"+key]==true{return true}
                current=(decisions[key]==true ? new.records[key]:old.records[key] ?? new.records[key])?.value.parentID
            }
            return false
        }
        for id in all.sorted() {
            try cancellation?.check()
            if explicitlyDeleted(id){continue}
            let useNew=decisions[id] ?? anchorNew
            guard let record=(useNew ? new:old).records[id] else{continue}
            guard plans.contains(where:{useNew ? $0.destination==record.slidePath:$0.base==record.slidePath}) else {
                throw PresentationRevisionFailure.unsupported("A selected comment belongs to a rejected slide. Retain its slide or delete the comment.")
            }
            chosen[id]=(record,useNew)
        }
        for (_,pair) in chosen {if let parent=pair.0.value.parentID,chosen[parent]==nil {throw PresentationRevisionFailure.unsupported("A selected reply has no selected parent comment. Review its parent and reply together.")}}
        let orderedIDs=chosen.keys.sorted {a,b in
            let x=chosen[a]!.0.order,y=chosen[b]!.0.order
            return x==y ? a<b:x<y
        }
        var authorNodes:[Bool:[String:XMLElement]]=[:],authorIDs:[String:String]=[:]
        func author(_ xml:String,modern:Bool)throws->String {
            let node=try revisionXML(Data(xml.utf8),"comment author").rootElement()!
            node.detach();node.attribute(forName:"id")?.detach();if !modern {node.attribute(forName:"lastIdx")?.detach()}
            // Identity includes the complete author record, never name alone.
            let key=String(modern)+":"+revisionCanonical(node)
            if let id=authorIDs[key]{return id}
            let id=modern ? revisionCommentGUID(key):String(authorNodes[modern,default:[:]].count)
            revisionSet(node,"id",id);authorNodes[modern,default:[:]][id]=node;authorIDs[key]=id;return id
        }
        var nodes:[String:XMLElement]=[:],classicIndex:[String:Int]=[:]
        for id in orderedIDs {
            let (record,useNew)=chosen[id]!,modern=record.value.isModern
            let node=try revisionXML(Data(record.node.utf8),"comment").rootElement()!
            node.detach()
            let authorID=try author(record.authorNode,modern:modern)
            revisionSet(node,"authorId",authorID)
            if modern {
                revisionSet(node,"id",revisionCommentGUID(id))
                if let assigned=revisionAttribute(node,"assignedTo"),!assigned.isEmpty {
                    let mapped=try assigned.split(whereSeparator:{$0.isWhitespace}).map {value->String in
                        guard let xml=record.assigned[String(value)] else{throw PresentationRevisionFailure.invalid("Missing assigned comment author")}
                        return try author(xml,modern:true)
                    };revisionSet(node,"assignedTo",mapped.joined(separator:" "))
                }
            } else {
                classicIndex[authorID,default:0] += 1
                revisionSet(node,"idx",String(classicIndex[authorID]!))
            }
            guard let plan=plans.first(where:{useNew ? $0.destination==record.slidePath:$0.base==record.slidePath}),let number=slideNumbers[plan.id] else{throw PresentationRevisionFailure.invalid("Missing selected comment slide")}
            let maps=commentShapeMaps[(useNew==anchorNew ? "anchor:":"foreign:")+record.slidePath] ?? [:]
            let sourceDeck=useNew==anchorNew ? anchor:foreign
            let sourceSlide=try sourceDeck.document(record.slidePath).rootElement()!
            let outputSlide=try revisionXML(entries[slidePaths[plan.id]!]!,"comment anchor slide").rootElement()!
            func shape(_ root:XMLElement,_ id:String)->XMLElement? {
                guard let nv=revisionDescendants(root).first(where:{revisionIs($0,"cNvPr",revisionPresentationNS) && revisionAttribute($0,"id")==id}) else{return nil}
                return nv.parent?.parent as? XMLElement
            }
            let textAnchored=revisionDescendants(node).contains{revisionLocal($0)=="txMkLst"}
            for anchor in revisionDescendants(node) {
                if anchor.uri=="http://schemas.microsoft.com/office/powerpoint/2013/main/command",revisionLocal(anchor)=="sldMk" {revisionSet(anchor,"sldId",number)}
                if anchor.uri=="http://schemas.microsoft.com/office/drawing/2013/main/command",["spMk","grpSpMk","graphicFrameMk","cxnSpMk","picMk","inkMk"].contains(revisionLocal(anchor)),let value=revisionAttribute(anchor,"id") {
                    guard let mapped=maps[value],let originalShape=shape(sourceSlide,value),let targetShape=shape(outputSlide,mapped) else{throw PresentationRevisionFailure.unsupported("A comment anchor references a rejected or unknown shape. Retain its anchor shape or reject the comment.")}
                    if textAnchored {
                        let sourceText=revisionDescendants(originalShape).filter{revisionIs($0,"t",revisionDrawingNS)}.compactMap(\.stringValue).joined()
                        let targetText=revisionDescendants(targetShape).filter{revisionIs($0,"t",revisionDrawingNS)}.compactMap(\.stringValue).joined()
                        guard Data(sourceText.utf8)==Data(targetText.utf8) else{throw PresentationRevisionFailure.unsupported("A comment text-range anchor belongs to different selected text. Retain its text shape or reject the comment.")}
                    }
                    if revisionAttribute(anchor,"creationId") != nil {
                        guard let creation=revisionDescendants(targetShape).first(where:{revisionLocal($0)=="creationId"}).flatMap({revisionAttribute($0,"id")}) else{throw PresentationRevisionFailure.unsupported("A comment creation anchor has no selected shape identity")}
                        revisionSet(anchor,"creationId",creation)
                    }
                    revisionSet(anchor,"id",mapped)
                }
            }
            nodes[id]=node
        }
        for id in orderedIDs {
            guard let parent=chosen[id]!.0.value.parentID else{continue}
            if !chosen[id]!.0.value.isModern {
                for element in revisionDescendants(nodes[id]!) where revisionIs(element,"parentCm",revisionThreadingNS) {
                    revisionSet(element,"authorId",revisionAttribute(nodes[parent]!,"authorId")!);revisionSet(element,"idx",revisionAttribute(nodes[parent]!,"idx")!)
                }
                continue
            }
            let parentNode=nodes[parent]!,list=revisionChild(parentNode,"replyLst") ?? {
                let list=XMLElement(name:"p188:replyLst",uri:revisionModernNS)
                // MS-PPTX requires replies before txBody.
                let index=(parentNode.children ?? []).firstIndex{($0 as? XMLElement).map{revisionLocal($0)=="txBody"} ?? false} ?? parentNode.childCount
                parentNode.insertChild(list,at:index);return list
            }()
            list.addChild(nodes[id]!)
        }
        let typeDoc=try revisionXML(entries["[Content_Types].xml"]!,"content types")
        func addType(_ path:String,_ type:String) {
            let node=XMLElement(name:"Override",uri:revisionContentNS);revisionSet(node,"PartName","/"+path);revisionSet(node,"ContentType",type);typeDoc.rootElement()!.addChild(node)
        }
        func addRelationship(_ source:String,_ path:String,_ type:String)throws->String {
            let key=revisionRelsPath(source)
            let doc=try entries[key].map{try revisionXML($0,key)} ?? revisionXML(Data(("<Relationships xmlns=\""+revisionRelationshipNS+"\"/>").utf8),key)
            let used=Set(revisionChildren(doc.rootElement()!).compactMap{revisionAttribute($0,"Id")})
            var n=1;while used.contains("rIdTurtleGitComment\(n)"){n += 1}
            let id="rIdTurtleGitComment\(n)",node=XMLElement(name:"Relationship",uri:revisionRelationshipNS)
            revisionSet(node,"Id",id);revisionSet(node,"Type",type);revisionSet(node,"Target",revisionRelative(path,from:source));doc.rootElement()!.addChild(node);entries[key]=revisionData(doc);return id
        }
        for modern in [false,true] where !(authorNodes[modern] ?? [:]).isEmpty {
            let ns=modern ? revisionModernNS:revisionPresentationNS,path=allocate(modern ? "ppt/authors/authors.xml":"ppt/commentAuthors.xml")
            let root=XMLElement(name:modern ? "p188:authorLst":"p:cmAuthorLst",uri:ns)
            root.addNamespace(XMLNode.namespace(withName:modern ? "p188":"p",stringValue:ns) as! XMLNode)
            for key in authorNodes[modern]!.keys.sorted() {
                let node=authorNodes[modern]![key]!
                if !modern {revisionSet(node,"lastIdx",String(classicIndex[key] ?? 0))}
                root.addChild(node)
            }
            entries[path]=revisionData(XMLDocument(rootElement:root));addType(path,modern ? revisionModernAuthorsType:revisionClassicAuthorsType)
            _=try addRelationship(anchor.presentation,path,modern ? revisionModernRelationship+"authors":revisionOfficeRelationshipNS+"/commentAuthors")
        }
        for plan in plans {
            let target=slidePaths[plan.id]!
            for modern in [false,true] {
                let roots=orderedIDs.filter {id in let (record,useNew)=chosen[id]!;return (record.value.parentID==nil || !modern) && record.value.isModern==modern && (useNew ? plan.destination==record.slidePath:plan.base==record.slidePath)}
                if roots.isEmpty {continue}
                let ns=modern ? revisionModernNS:revisionPresentationNS,path=allocate("ppt/comments/comments.xml")
                let root=XMLElement(name:modern ? "p188:cmLst":"p:cmLst",uri:ns)
                root.addNamespace(XMLNode.namespace(withName:modern ? "p188":"p",stringValue:ns) as! XMLNode)
                root.addNamespace(XMLNode.namespace(withName:"a",stringValue:revisionDrawingNS) as! XMLNode)
                for id in roots{root.addChild(nodes[id]!)}
                entries[path]=revisionData(XMLDocument(rootElement:root));addType(path,modern ? revisionModernCommentsType:revisionClassicCommentsType)
                let relID=try addRelationship(target,path,modern ? revisionModernRelationship+"comments":revisionOfficeRelationshipNS+"/comments")
                if modern {
                    guard let ext=chosen[roots[0]]!.0.modernExtension else{throw PresentationRevisionFailure.invalid("Missing modern comment extension")}
                    let node=try revisionXML(Data(ext.utf8),"comment extension").rootElement()!
                    node.detach()
                    for child in revisionDescendants(node) where revisionIs(child,"commentRel",revisionModernNS) {
                        for attr in child.attributes ?? [] where attr.localName=="id"{attr.stringValue=relID}
                    }
                    let doc=try revisionXML(entries[target]!,target),slide=doc.rootElement()!
                    let list=revisionChild(slide,"extLst") ?? {let value=XMLElement(name:"p:extLst",uri:revisionPresentationNS);slide.addChild(value);return value}()
                    list.addChild(node);entries[target]=revisionData(doc)
                }
            }
        }
        entries["[Content_Types].xml"]=revisionData(typeDoc)
    }
}
