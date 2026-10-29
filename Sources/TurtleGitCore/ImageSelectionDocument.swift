// SPDX-License-Identifier: GPL-2.0-or-later
import Foundation

/// Original container bytes are independent of decoding and frame selection.
/// This is the standalone counterpart of IDiff's Mine/Base/Theirs buttons;
/// repository conflict detection and optional Resolve belong to the native owner.
public struct ImageSelectionDocument:Sendable {
    public let invocation:ImageToolInvocation
    public let inputs:[ImageConflictSide:ComparisonFileContent]
    public let inputFailures:[ImageConflictSide:String]
    public let output:MergeToolOutputTarget?
    public let outputDirectories:MergeOutputDirectories?
    public let selectedSide:ImageConflictSide?
    private let inputTargets:[ImageConflictSide:MergeToolOutputTarget]
    public static func capture(invocation:ImageToolInvocation,cancellation:OperationCancellation?=nil)throws->Self {
        guard invocation.isSelection else{throw ImageToolInvocation.Failure("Three image-selection inputs are required.")}
        var inputs:[ImageConflictSide:ComparisonFileContent]=[:],failures:[ImageConflictSide:String]=[:],targets:[ImageConflictSide:MergeToolOutputTarget]=[:]
        for (side,url) in [(ImageConflictSide.mine,invocation.mine!),(.base,invocation.base!),(.theirs,invocation.theirs!)] {
            try cancellation?.check();try Task.checkCancellation()
            do {
                let target=try MergeToolOutputTarget(capturing:url)
                inputs[side]=target.content;targets[side]=target
            } catch {
                try cancellation?.check();try Task.checkCancellation()
                failures[side]=error.localizedDescription
            }
        }
        try cancellation?.check();try Task.checkCancellation()
        let output=try invocation.result.map{try MergeToolOutputTarget(capturing:$0)}
        if invocation.deleteInputsOnClose,let result=invocation.result {
            guard ![invocation.mine!,invocation.base!,invocation.theirs!].contains(where:{sameLocation($0,result)}) else {
                throw ImageToolInvocation.Failure("Input cleanup cannot delete the selected result file. Choose a separate output or disable input cleanup.")
            }
        }
        let directories=try output.map{try MergeOutputDirectories(capturing:$0.url)}
        try cancellation?.check();try Task.checkCancellation()
        return Self(invocation:invocation,inputs:inputs,inputFailures:failures,output:output,outputDirectories:directories,selectedSide:nil,inputTargets:targets)
    }
    public func selectionBytes(_ side:ImageConflictSide)->Data? {
        guard let input=inputs[side],!input.isDeleted else{return nil}
        return input.bytes
    }
    public func image(_ side:ImageConflictSide,cancellation:OperationCancellation?=nil)->ComparisonImage? {
        selectionBytes(side).flatMap{ComparisonImage(bytes:$0,cancellation:cancellation)}
    }
    public func select(_ side:ImageConflictSide,cancellation:OperationCancellation?=nil)throws->Self {
        try cancellation?.check();try Task.checkCancellation()
        guard let bytes=selectionBytes(side) else{throw ImageConflictFailure.unavailable}
        for target in inputTargets.values {try cancellation?.check();try target.validate()}
        try output?.validate();try cancellation?.check();try Task.checkCancellation()
        guard let output else {
            return Self(invocation:invocation,inputs:inputs,inputFailures:inputFailures,output:nil,outputDirectories:nil,selectedSide:side,inputTargets:inputTargets)
        }
        let saved=try output.save(bytes:bytes,options:.init(backupOriginal:false,emptyResult:.keep,outputDirectories:outputDirectories),cancellation:cancellation,validatingInputs:{
            try cancellation?.check();try Task.checkCancellation()
            for target in inputTargets.values {try target.validate()}
        })
        // Disk publication is already accepted. Do not reject its receipt on a
        // late Cancel. Exact output/input aliases advance only the private CAS
        // witness; the originally displayed selection bytes remain immutable.
        var targets=inputTargets
        for (key,target) in targets where Self.sameLocation(target.url,saved.url) {targets[key]=saved}
        return Self(invocation:invocation,inputs:inputs,inputFailures:inputFailures,output:saved,
                    outputDirectories:try MergeOutputDirectories(capturing:saved.url),selectedSide:side,inputTargets:targets)
    }
    private static func sameLocation(_ a:URL,_ b:URL)->Bool {
        GitReferenceName.equal(a.standardizedFileURL.resolvingSymlinksInPath().path,b.standardizedFileURL.resolvingSymlinksInPath().path)
    }
}
