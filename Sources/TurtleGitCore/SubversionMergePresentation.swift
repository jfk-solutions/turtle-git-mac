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
    public let movedBlocks: [MergeMovedBlock]
    public init(plan: SubversionDiffPlan, detectMovedBlocks: Bool = false, whitespace: MergeWhitespaceComparison = .compare, cancellation: OperationCancellation? = nil) throws {
        guard plan.theirs == nil else { throw SubversionMergeDiffFailure.invalidOutput }
        var rows: [FileComparisonRow] = [], differences: [Range<Int>] = []
        func cell(_ lines: [String], _ index: Int, _ state: MergeSourceState, hidden: Bool? = nil) -> MergeSourceCell {
            .init(text: lines[index], lineNumber: index + 1, state: state, hiddenByComparison: hidden)
        }
        let gap = MergeSourceCell(text: "", lineNumber: nil, state: .empty)
        // MovedBlocksDetect can split a changed interval into adjacent pieces.
        // DiffData::StickAndSkip restores one display block when moves are on.
        var segments: [SubversionDiffSegment] = []
        for segment in plan.segments {
            try cancellation?.check()
            guard segment.base.lowerBound >= 0, segment.base.upperBound <= plan.base.count,
                  segment.mine.lowerBound >= 0, segment.mine.upperBound <= plan.mine.count,
                  segment.kind == .common || segment.kind == .modified,
                  segment.kind != .common || segment.base.count == segment.mine.count else {
                throw SubversionMergeDiffFailure.invalidOutput
            }
            if detectMovedBlocks, segment.kind == .modified, let previous = segments.last, previous.kind == .modified,
               previous.base.upperBound == segment.base.lowerBound, previous.mine.upperBound == segment.mine.lowerBound {
                segments[segments.count - 1] = .init(kind:.modified,base:previous.base.lowerBound..<segment.base.upperBound,
                                                   mine:previous.mine.lowerBound..<segment.mine.upperBound,theirs:0..<0)
            } else { segments.append(segment) }
        }
        for segment in segments {
            try cancellation?.check()
            switch segment.kind {
            case .common:
                for offset in 0..<segment.base.count {
                    if offset % 256 == 0 { try cancellation?.check() }
                    let a = segment.base.lowerBound + offset, b = segment.mine.lowerBound + offset
                    let payloadDiffers = !MergeLineEndings.droppingFinalEnding(plan.base[a]).utf8.elementsEqual(MergeLineEndings.droppingFinalEnding(plan.mine[b]).utf8)
                    // DoTwoWayDiff resets its provisional Whitespace state to
                    // Normal before applying regex/case/comment FilteredDiff.
                    // Equal payloads (even with unequal endings) always hide.
                    let state: MergeSourceState = payloadDiffers && plan.contentFiltered ? .filtered : .normal
                    let hidden = !payloadDiffers || state == .normal && plan.options.whitespace != .compare
                    rows.append(.init(base: cell(plan.base, a, state, hidden: hidden), destination: cell(plan.mine, b, state, hidden: hidden)))
                }
            case .modified:
                let start = rows.count
                for offset in 0..<max(segment.base.count, segment.mine.count) {
                    if offset % 256 == 0 { try cancellation?.check() }
                    rows.append(.init(base: offset < segment.base.count ? cell(plan.base, segment.base.lowerBound + offset, .removed) : gap,
                                      destination: offset < segment.mine.count ? cell(plan.mine, segment.mine.lowerBound + offset, .added) : gap))
                }
                if start < rows.count { differences.append(start..<rows.count) }
            default: throw SubversionMergeDiffFailure.invalidOutput
            }
        }
        // FileTextLines::Load retains a final NoEnding record, including for an
        // empty file. svn_diff does not report an empty final token. DiffData's
        // two-pane post-pass adds it, or fills the first trailing Empty slot.
        let baseEOF = plan.base.isEmpty || plan.base.last.map(MergeLineEndings.hasFinalEnding) == true
        let mineEOF = plan.mine.isEmpty || plan.mine.last.map(MergeLineEndings.hasFinalEnding) == true
        if baseEOF && mineEOF {
            rows.append(.init(base:.init(text:"",lineNumber:plan.base.count + 1,state:.normal,hiddenByComparison:false),
                              destination:.init(text:"",lineNumber:plan.mine.count + 1,state:.normal,hiddenByComparison:false)))
        } else if baseEOF || mineEOF {
            let terminal = MergeSourceCell(text:"",lineNumber:(baseEOF ? plan.base.count:plan.mine.count) + 1,state:baseEOF ? .removed:.added,hiddenByComparison:false)
            var target = rows.count
            while target > 0 && (baseEOF ? rows[target - 1].base:rows[target - 1].destination).state == .empty { target -= 1 }
            if target < rows.count {
                let old = rows[target]
                rows[target] = .init(base:baseEOF ? terminal:old.base,destination:baseEOF ? old.destination:terminal)
            } else { rows.append(.init(base:baseEOF ? terminal:gap,destination:baseEOF ? gap:terminal)) }
            if !differences.contains(where:{$0.contains(target)}) {
                if let last = differences.last,last.upperBound == target { differences[differences.count - 1] = last.lowerBound..<(target + 1) }
                else { differences.append(target..<(target + 1)) }
            }
        }
        try cancellation?.check()
        alignment = FileComparisonAlignment(rows: rows, differences: differences)
        movedBlocks = detectMovedBlocks ? try MergeMovedBlock.detect(plan:plan,whitespace:whitespace,cancellation:cancellation) : []
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
        var navigation: [MergeNavigationMap.Entry] = []
        var resultRows: [MergeSourceCell] = [], resultLine = 0
        func appendResultRow(_ text: String, state: MergeSourceState) {
            let numbered = !state.isRemoval && state != .empty && state != .conflictEmpty
            if numbered { resultLine += 1 }
            resultRows.append(.init(text:text,lineNumber:numbered ? resultLine : nil,state:state))
        }
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
                    appendResultRow(plan.mine[m],state:ignored(b,m,t) ? .conflictedIgnored : state)
                }
                for offset in 0..<segment.mine.count {
                    let m = segment.mine.lowerBound + offset, b = segment.base.lowerBound + offset, t = segment.theirs.lowerBound + offset
                    anchors[firstRow + offset] = outputLength
                    navigation.append(.init(sourceRows:(firstRow + offset)..<(firstRow + offset + 1),resultRange:NSRange(location:outputLength,length:plan.mine[m].utf16.count)))
                    appendIgnored(base:b,mine:m,other:t,ordinaryState:equal(plan.base[b], plan.mine[m]) && equal(plan.mine[m], theirs[t]) ? .normal : .filtered)
                }
                continue
            }
            let sourceStart = rows.count, resultStart = outputLength
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
                appendResultRow(removed.text,state:removedState)
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
                if segment.kind == .conflict { appendResultRow("",state:.conflicted) }
                else if segment.kind == .latest { appendResultRow(theirs[segment.theirs.lowerBound + offset],state:.theirsAdded) }
                else { appendResultRow(plan.mine[segment.mine.lowerBound + offset],state:hiddenConflict ? .conflictedIgnored : segment.kind == .modified ? .yoursAdded : .identicalAdded) }
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
            if rows.count > sourceStart {
                if segment.kind == .conflict {
                    navigation.append(.init(sourceRows:sourceStart..<rows.count,resultRange:NSRange(location:resultStart,length:outputLength - resultStart)))
                } else {
                    // Removed Base rows occupy real aligned rows but no saved
                    // result bytes. Added rows map individually, so choosing a
                    // sub-block never replaces its neighboring additions.
                    let removedCount = max(segment.base.count, resolvedPadding)
                    var offset = resultStart
                    let lines = segment.kind == .latest ? Array(theirs[segment.theirs]) : Array(plan.mine[segment.mine])
                    for row in sourceStart..<rows.count {
                        let added = row - sourceStart - removedCount
                        let length = added >= 0 && lines.indices.contains(added) ? lines[added].utf16.count : 0
                        navigation.append(.init(sourceRows:row..<(row + 1),resultRange:NSRange(location:offset,length:length)))
                        offset += length
                    }
                }
            }
        }
        sources = MergeSourceComparison(rows: rows, resultLocator: MergeLocatorResult(text: output, spans: spans), resultAnchors: anchors, ignoredConflicts: ignoredConflicts, navigationMap:.init(entries:navigation),alignedResultRows:resultRows); result = output
    }
}


// Moved-block algorithm adapted from TortoiseGit (2023) and TortoiseSVN
// (2010-2013, 2020), GPL-2.0-or-later; pinned source recorded in the parity guide.
/// Source MovedBlocks.cpp's two-pass unique-line seed/extension algorithm.
/// Coordinates refer to original source records, never to display padding.
public struct MergeMovedBlock: Equatable, Sendable {
    public let base: Range<Int>
    public let mine: Range<Int>
    public init(base: Range<Int>, mine: Range<Int>) { self.base = base; self.mine = mine }
    private final class Group {
        var left = Set<Int>(), right = Set<Int>()
        var perfect: Bool { left.count == 1 && right.count == 1 }
    }
    private final class Chunk {
        var base: Range<Int>, mine: Range<Int>
        init(_ base: Range<Int>, _ mine: Range<Int>) { self.base = base; self.mine = mine }
    }
    private final class Extension {
        var base: Chunk, next: Extension?
        var to: Int?, from: Int?
        init(_ base: Chunk) { self.base = base }
    }
    public static func enabled(defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey:"TurtleGitMerge.ViewMovedBlocks") == nil || defaults.bool(forKey:"TurtleGitMerge.ViewMovedBlocks")
    }
    public static func detect(plan: SubversionDiffPlan, whitespace: MergeWhitespaceComparison = .compare,
                              cancellation: OperationCancellation? = nil) throws -> [Self] {
        try cancellation?.check()
        guard plan.theirs == nil else { return [] }
        // FileTextLines strips EOL before the source move detector. Its own WS
        // normalization deliberately differs from svn's comparison keys.
        func key(_ line: String) -> Data {
            var value = Array(MergeLineEndings.droppingFinalEnding(line).utf8)
            if whitespace == .ignoreAll { value.removeAll { $0 == 32 || $0 == 9 } }
            else if whitespace == .ignoreChanges {
                let first = value.firstIndex { $0 != 32 && $0 != 9 } ?? value.count
                value.removeFirst(first)
            }
            return Data(value)
        }
        func sourceKeys(_ lines: [String]) -> [Data] {
            var result = lines.map(key)
            if lines.isEmpty || lines.last.map({ !MergeLineEndings.styles(in:$0).isEmpty }) == true { result.append(Data()) }
            return result
        }
        let a = sourceKeys(plan.base), b = sourceKeys(plan.mine)
        var groups: [Data:Group] = [:], chunks: [Chunk] = []
        for segment in plan.segments where segment.kind == .modified {
            try cancellation?.check()
            guard segment.base.lowerBound >= 0,segment.base.upperBound <= plan.base.count,
                  segment.mine.lowerBound >= 0,segment.mine.upperBound <= plan.mine.count else { throw SubversionMergeDiffFailure.invalidOutput }
            // Source refuses detection when a changed interval consumes its
            // final NoEnding record. Ended files have a synthetic empty record.
            guard segment.base.upperBound < a.count,segment.mine.upperBound < b.count else { return [] }
            chunks.append(Chunk(segment.base,segment.mine))
            for i in segment.base { let group = groups[a[i]] ?? Group();group.left.insert(i);groups[a[i]] = group }
            for j in segment.mine { let group = groups[b[j]] ?? Group();group.right.insert(j);groups[b[j]] = group }
        }
        // Extension can include repeated lines surrounding a unique seed. Remove
        // those occurrences, but retain the seed as in the pinned implementation.
        func consume(_ i: Int, _ j: Int) -> Bool {
            guard a.indices.contains(i),b.indices.contains(j),let left = groups[a[i]],let right = groups[b[j]],left === right else { return false }
            left.left.remove(i);right.right.remove(j);return true
        }
        var head: Extension?, tail: Extension?
        var index = 0
        while index < chunks.count {
            try cancellation?.check()
            var chunk = chunks[index]
            guard let seed = chunk.base.first(where:{groups[a[$0]]?.perfect == true}),let j = groups[a[seed]]?.right.first else { index += 1;continue }
            var i1 = seed - 1,j1 = j - 1
            while i1 >= chunk.base.lowerBound && j1 >= 0 && consume(i1,j1) { i1 -= 1;j1 -= 1 }
            i1 += 1;j1 += 1
            var i2 = seed + 1,j2 = j + 1
            while i2 < chunk.base.upperBound && consume(i2,j2) { i2 += 1;j2 += 1 }
            let added = Extension(chunk)
            if head == nil { head = added } else { tail?.next = added }
            tail = added
            if i1 > chunk.base.lowerBound {
                let rest = Chunk(i1..<chunk.base.upperBound,chunk.mine.upperBound..<chunk.mine.upperBound)
                chunk.base = chunk.base.lowerBound..<i1;chunks.insert(rest,at:index + 1);index += 1;chunk = rest
                added.base = rest
            }
            added.to = j1
            if i2 < chunk.base.upperBound {
                let suffix = Chunk(i2..<chunk.base.upperBound,chunk.mine)
                chunk.base = chunk.base.lowerBound..<i2;chunk.mine = chunk.mine.lowerBound..<chunk.mine.lowerBound
                chunks.insert(suffix,at:index + 1)
            }
            index += 1
        }
        var existing = head
        tail = nil
        func adjust(_ chunk: Chunk) {
            if let current = existing,current.base === chunk {
                if let tail,tail !== current { tail.next = current }
                tail = current;existing = current.next
            }
        }
        index = 0
        while index < chunks.count {
            try cancellation?.check()
            var chunk = chunks[index]
            guard let seed = chunk.mine.first(where:{groups[b[$0]]?.perfect == true}),let i = groups[b[seed]]?.left.first else { adjust(chunk);index += 1;continue }
            if i == 0 { index += 1;continue }
            var i1 = i - 1,j1 = seed - 1
            while j1 >= chunk.mine.lowerBound && i1 >= 0 && consume(i1,j1) { i1 -= 1;j1 -= 1 }
            i1 += 1;j1 += 1
            var i2 = i + 1,j2 = seed + 1
            while j2 < chunk.mine.upperBound && consume(i2,j2) { i2 += 1;j2 += 1 }
            let added: Extension
            if let current = existing,current.base === chunk { added = current }
            else {
                added = Extension(chunk)
                if head == nil { head = added }
                else if let tail { added.next = tail.next;tail.next = added }
            }
            tail = added
            if j1 > chunk.mine.lowerBound {
                let rest = Chunk(chunk.base.upperBound..<chunk.base.upperBound,j1..<chunk.mine.upperBound)
                if existing === added {
                    let split = Extension(rest);split.next = tail?.next;tail?.next = split;tail = split
                }
                tail?.base = rest
                chunk.mine = chunk.mine.lowerBound..<j1;chunks.insert(rest,at:index + 1);index += 1;chunk = rest
            }
            tail?.from = i1
            if j2 < chunk.mine.upperBound {
                let suffix = Chunk(chunk.base,j2..<chunk.mine.upperBound)
                let split = Extension(suffix);split.to = tail?.to;tail?.to = nil
                chunk.mine = chunk.mine.lowerBound..<j2;chunk.base = chunk.base.lowerBound..<chunk.base.lowerBound
                chunks.insert(suffix,at:index + 1)
                split.next = tail?.next;tail?.next = split;existing = split;tail = split
            }
            adjust(chunk);index += 1
        }
        var links: [Int:Int] = [:], current = head
        while let entry = current {
            try cancellation?.check()
            let chunk = entry.base
            if let to = entry.to { for (offset,i) in chunk.base.enumerated() where plan.mine.indices.contains(to + offset) && plan.base.indices.contains(i) { links[i] = to + offset } }
            if let from = entry.from { for (offset,j) in chunk.mine.enumerated() where plan.base.indices.contains(from + offset) && plan.mine.indices.contains(j) { links[from + offset] = j } }
            current = entry.next
        }
        var result: [Self] = []
        for i in links.keys.sorted() {
            let j = links[i]!
            if let previous = result.last,previous.base.upperBound == i,previous.mine.upperBound == j {
                result[result.count - 1] = Self(base:previous.base.lowerBound..<(i + 1),mine:previous.mine.lowerBound..<(j + 1))
            } else { result.append(Self(base:i..<(i + 1),mine:j..<(j + 1))) }
        }
        return result
    }
}
