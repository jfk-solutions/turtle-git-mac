// SPDX-License-Identifier: GPL-2.0-or-later
import Foundation

public struct SubversionMergeConfiguration: Sendable {
    public var executable: URL
    public var runtimeRoot: URL
    public var regexExecutable: URL?
    public var filter: MergeRegexFilter?
    public var options: MergeComparisonOptions
    public var commentTokens: MergeCommentTokens?
    public init(executable: URL, runtimeRoot: URL, regexExecutable: URL? = nil, filter: MergeRegexFilter? = nil, options: MergeComparisonOptions = .exact) {
        self.executable = executable; self.runtimeRoot = runtimeRoot; self.regexExecutable = regexExecutable; self.filter = filter
        self.options = options
        self.commentTokens = nil
    }
    public static func bundled(filter: MergeRegexFilter? = nil) throws -> Self {
        let bundle = SubversionMergeDiff.applicationBundle()
        return .init(executable: try SubversionMergeDiff.executable(bundle: bundle), runtimeRoot: try SubversionMergeDiff.runtimeRoot(bundle: bundle),
                     regexExecutable: filter == nil ? nil : try IssueRegexRuntime.executable(bundle: bundle), filter: filter, options: .load())
    }
    public func plan(base: String, mine: String, theirs: String? = nil, cancellation: OperationCancellation? = nil) throws -> SubversionDiffPlan {
        try SubversionMergeDiff.plan(base: base, mine: mine, theirs: theirs, filter: filter, executable: executable, runtimeRoot: runtimeRoot,
                                    regexExecutable: regexExecutable, options: options, commentTokens: commentTokens, cancellation: cancellation)
    }
}
public struct SubversionComparisonPresentation: Sendable {
    public let alignment: FileComparisonAlignment
    public init(plan: SubversionDiffPlan) throws {
        guard plan.theirs == nil else { throw SubversionMergeDiffFailure.invalidOutput }
        var rows: [FileComparisonRow] = [], differences: [Range<Int>] = []
        func cell(_ lines: [String], _ index: Int, _ state: MergeSourceState) -> MergeSourceCell {
            .init(text: lines[index], lineNumber: index + 1, state: state)
        }
        let gap = MergeSourceCell(text: "", lineNumber: nil, state: .empty)
        for segment in plan.segments {
            switch segment.kind {
            case .common:
                for offset in 0..<segment.base.count {
                    let a = segment.base.lowerBound + offset, b = segment.mine.lowerBound + offset
                    let state: MergeSourceState = plan.base[a].utf8.elementsEqual(plan.mine[b].utf8) ? .normal : .filtered
                    rows.append(.init(base: cell(plan.base, a, state), destination: cell(plan.mine, b, state)))
                }
            case .modified:
                let start = rows.count
                for offset in 0..<max(segment.base.count, segment.mine.count) {
                    rows.append(.init(base: offset < segment.base.count ? cell(plan.base, segment.base.lowerBound + offset, .removed) : gap,
                                      destination: offset < segment.mine.count ? cell(plan.mine, segment.mine.lowerBound + offset, .added) : gap))
                }
                differences.append(start..<rows.count)
            default: throw SubversionMergeDiffFailure.invalidOutput
            }
        }
        alignment = FileComparisonAlignment(rows: rows, differences: differences)
    }
}
/// Follows DiffData.cpp's common, identical-change, one-side-change and conflict
/// row groups. Removed base rows are display-only; numbered rows retain originals.
public struct SubversionMergePresentation: Sendable {
    public let sources: MergeSourceComparison
    public let result: String
    public init(plan: SubversionDiffPlan) throws {
        guard let theirs = plan.theirs else { throw SubversionMergeDiffFailure.invalidOutput }
        var rows: [MergeSourceRow] = [], output = "", anchors: [Int: Int] = [:]
        var spans: [(Range<Int>, MergeSourceState)] = [], outputLength = 0
        var ignoredConflicts: [IgnoredMergeConflict] = []
        func append(_ text: String, state: MergeSourceState) {
            let count = text.utf16.count
            if count > 0 { spans.append((outputLength..<outputLength + count, state)); outputLength += count }
            output += text
        }
        func cell(_ source: [String], _ index: Int, _ state: MergeSourceState) -> MergeSourceCell {
            .init(text: source[index], lineNumber: index + 1, state: state)
        }
        func gap(_ state: MergeSourceState = .empty) -> MergeSourceCell { .init(text: "", lineNumber: nil, state: state) }
        func equal(_ a: String, _ b: String) -> Bool { a.utf8.elementsEqual(b.utf8) }
        func separated(_ text: String) -> String {
            guard !text.isEmpty, let last = MergeRegexFilters.lines(text).last,
                  equal(last, MergeLineEndings.droppingFinalEnding(last)) else { return text }
            return text + "\n"
        }
        // DiffData's post-pass compares raw payloads and endings separately;
        // pairwise differences must occur in one channel, not across both.
        func ignored(_ base: Int, _ mine: Int, _ other: Int) -> Bool {
            guard plan.normalizedComparison, plan.base.indices.contains(base), plan.mine.indices.contains(mine), theirs.indices.contains(other) else { return false }
            let values = [plan.base[base], plan.mine[mine], theirs[other]]
            let contents = values.map(MergeLineEndings.droppingFinalEnding)
            let endings = zip(values,contents).map { ($0 as NSString).substring(from:$1.utf16.count) }
            func distinct(_ strings:[String]) -> Bool { !equal(strings[0],strings[1]) && !equal(strings[0],strings[2]) && !equal(strings[1],strings[2]) }
            return distinct(contents) || distinct(endings)
        }
        func appendIgnored(base: Int, mine: Int, other: Int, ordinaryState: MergeSourceState) {
            let conflict = ignored(base,mine,other)
            if conflict { ignoredConflicts.append(.init(range:NSRange(location:outputLength,length:plan.mine[mine].utf16.count),mine:plan.mine[mine],base:plan.base[base],theirs:theirs[other])) }
            append(plan.mine[mine],state:conflict ? .conflictedIgnored : ordinaryState)
        }
        for segment in plan.segments {
            let baseText = plan.base[segment.base].joined(), mineText = plan.mine[segment.mine].joined(), theirsText = theirs[segment.theirs].joined()
            if segment.kind == .common {
                let firstRow = rows.count
                for offset in 0..<segment.base.count {
                    let b = segment.base.lowerBound + offset, m = segment.mine.lowerBound + offset, t = segment.theirs.lowerBound + offset
                    let state: MergeSourceState = ignored(b,m,t) ? .conflictAdded : equal(plan.base[b], plan.mine[m]) && equal(plan.mine[m], theirs[t]) ? .normal : .filtered
                    rows.append(.init(mine: cell(plan.mine, m, state), theirs: cell(theirs, t, state)))
                }
                for offset in 0..<segment.mine.count {
                    let m = segment.mine.lowerBound + offset, b = segment.base.lowerBound + offset, t = segment.theirs.lowerBound + offset
                    anchors[firstRow + offset] = outputLength
                    appendIgnored(base:b,mine:m,other:t,ordinaryState:equal(plan.base[b], plan.mine[m]) && equal(plan.mine[m], theirs[t]) ? .normal : .filtered)
                }
                continue
            }
            // DiffData's conflict loop pads the removed Base section using
            // the first resolved child's overlapping Mine/Theirs lengths.
            // It still treats the complete parent as unresolved.
            let resolvedPadding = segment.kind == .conflict ? segment.resolved.first.flatMap { child in child.mine.flatMap { mine in child.theirs.map { min(mine.count, $0.count) } } } ?? 0 : 0
            for offset in 0..<max(segment.base.count, resolvedPadding) {
                let removedState: MergeSourceState = segment.kind == .modified ? .yoursRemoved : segment.kind == .latest ? .theirsRemoved : .identicalRemoved
                let removed = MergeSourceCell(text: offset < segment.base.count ? plan.base[segment.base.lowerBound + offset] : "", lineNumber: nil, state: removedState)
                rows.append(.init(
                    mine: segment.kind == .latest ? cell(plan.mine, segment.mine.lowerBound + offset, .normal) : removed,
                    theirs: segment.kind == .modified ? cell(theirs, segment.theirs.lowerBound + offset, .normal) : removed))
            }
            let mineAdded = segment.kind == .latest ? 0 : segment.mine.count
            let theirsAdded = segment.kind == .modified ? 0 : segment.theirs.count
            for offset in 0..<max(mineAdded, theirsAdded) {
                // DiffData uses IdenticalAdded for Mine-only source rows, while
                // the result records YoursAdded. Theirs keeps TheirsAdded.
                let hiddenConflict = segment.kind == .same && ignored(segment.base.upperBound,segment.mine.lowerBound + offset,segment.theirs.lowerBound + offset)
                let state: MergeSourceState = segment.kind == .conflict || hiddenConflict ? .conflictAdded : segment.kind == .latest ? .theirsAdded : .identicalAdded
                rows.append(.init(mine: offset < mineAdded ? cell(plan.mine, segment.mine.lowerBound + offset, state) : gap(segment.kind == .conflict ? .conflictEmpty : .empty),
                                  theirs: offset < theirsAdded ? cell(theirs, segment.theirs.lowerBound + offset, state) : gap(segment.kind == .conflict ? .conflictEmpty : .empty)))
            }
            switch segment.kind {
            case .common: break
            case .modified: append(mineText, state: .yoursAdded)
            case .same:
                for offset in 0..<segment.mine.count { appendIgnored(base:segment.base.upperBound,mine:segment.mine.lowerBound + offset,other:segment.theirs.lowerBound + offset,ordinaryState:.identicalAdded) }
            case .latest: append(theirsText, state: .theirsAdded)
            case .conflict:
                let separator = separated(output).utf16.count > outputLength ? "\n" : ""
                append(separator + "<<<<<<< Mine\n" + separated(mineText) + "||||||| Base\n" + separated(baseText) + "=======\n" + separated(theirsText) + ">>>>>>> Theirs\n", state: .conflicted)
            }
        }
        sources = MergeSourceComparison(rows: rows, resultLocator: MergeLocatorResult(text: output, spans: spans), resultAnchors: anchors, ignoredConflicts: ignoredConflicts); result = output
    }
}
