import XCTest
@testable import TurtleGitCore

final class HistoryMessagePresentationTests: XCTestCase {
    private let parser = URL(fileURLWithPath:#filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("build/issue-regex-runtime/IssueRegex/issue-regex")
    private func values(_ text: String, _ ranges: [NSRange]) -> [String] { ranges.map { (text as NSString).substring(with:$0) } }
    func testSourceHashBoundariesTrailersAndUTF16Offsets() throws {
        let text = "🦎 deadbeef (g12345678), ABCDEF12, xdeadbeef deadbeefx deadbeef@example.invalid\nSigned-off-by: deadbeef\nChange-Id: deadbeef\ngit-svn-id: deadbeef\nagain 01234567 and " + String(repeating:"a",count:41)
        let ranges = try HistoryMessageHash.ranges(in:text)
        XCTAssertEqual(values(text,ranges),["deadbeef","12345678","01234567"])
        XCTAssertEqual(ranges.first?.location,3)
        XCTAssertEqual(try values("abcdef abcdefgh",HistoryMessageHash.ranges(in:"abcdef abcdefgh",minimum:3)),["abcdef"])
    }
    func testMinimumHashLengthUsesSourceSignedDWORDClamp() throws {
        let suite="TurtleGit.HistoryMessage.Test." + UUID().uuidString, prefs=UserDefaults(suiteName:suite)!
        defer { prefs.removePersistentDomain(forName:suite) }
        XCTAssertEqual(HistoryMessageOptions(defaults:prefs).minimumHashLength,8)
        for (value,expected) in [(0,3),(2,3),(9,9),(99,40),(Int(UInt32.max),3)] {
            prefs.set(value,forKey:"ShortHashLengthForHyperLinkInLogMessage")
            XCTAssertEqual(HistoryMessageOptions(defaults:prefs).minimumHashLength,expected)
        }
    }
    func testVisibleNavigationSearchesDownWrapsAndExcludesCurrent() {
        let hashes=["abcd0001","abcd0002","dddd0001","abcd0003"]
        XCTAssertEqual(HistoryMessageHash.target(prefix:"abcd",hashes:hashes,current:"abcd0001"),"abcd0002")
        XCTAssertEqual(HistoryMessageHash.target(prefix:"abcd",hashes:hashes,current:"abcd0003"),"abcd0001")
        XCTAssertNil(HistoryMessageHash.target(prefix:"dddd",hashes:hashes,current:"dddd0001"))
        XCTAssertNil(HistoryMessageHash.target(prefix:"ABCD",hashes:hashes,current:"abcd0001"))
        XCTAssertNil(HistoryMessageHash.target(prefix:"abcd",hashes:hashes,current:"missing"))
    }
    func testDocumentSectionsNormalizeCRAndExcludeHeaderAndDescribeHashes() async throws {
        let doc=HistoryMessageDocument(hash:String(repeating:"a",count:40),describe:"tag-gdeadbeef",subject:"fix\r",body:"references deadbeef",notes:"note\r\n",tagInfo:"tag",asterisk:true)
        XCTAssertFalse(doc.text.contains("\r")); XCTAssertTrue(doc.text.contains("* fix\nreferences deadbeef\n* Notes:\n"))
        XCTAssertEqual(values(doc.text,doc.bold),["fix","Notes:\n","Tag Info:\n"])
        let styles=try await HistoryMessageStyler().prepare(doc,properties:IssueTrackerProperties(),options:HistoryMessageOptions())
        XCTAssertEqual(styles.links.filter{$0.kind == .hash}.map(\.target),["deadbeef"])
        XCTAssertEqual(doc.sections.map(\.fields),[.revisions,[.subject,.messages],.messages,.notes,.tagInfo])
    }
    func testRichEditFormattingUsesUTF16AndAccumulatesOverlaps() async throws {
        XCTAssertTrue(HistoryMessageStyler.formatting("*zero*",marker:42).isEmpty)
        let text=" *bold ^both^ end* _under_ ^italic^\n *last !*"
        XCTAssertEqual(values(text,HistoryMessageStyler.formatting(text,marker:42)),["bold ^both^ end","last !"])
        XCTAssertEqual(values(text,HistoryMessageStyler.formatting(text,marker:94)),["both","italic"])
        let styles=try await HistoryMessageStyler().prepare(.init(plain:text),properties:IssueTrackerProperties(),options:HistoryMessageOptions())
        XCTAssertTrue(styles.bold.contains { bold in styles.italic.contains { NSIntersectionRange(bold,$0).length>0 } })
        XCTAssertEqual(values(text,styles.underlined),["under"])
        var disabled=HistoryMessageOptions();disabled.formatting=false
        let plain=try await HistoryMessageStyler().prepare(.init(plain:text),properties:IssueTrackerProperties(),options:disabled)
        XCTAssertTrue(plain.bold.isEmpty && plain.italic.isEmpty && plain.underlined.isEmpty)
    }
    func testUTF16IssueLinksURLPriorityAndFormattingKeepLinkTargets() async throws {
        let doc=HistoryMessageDocument(hash:String(repeating:"b",count:40),subject:"fix",body:"🦎 issue #42 and deadbeef https://example.invalid/deadbeef\n *https://example.invalid/*")
        let properties=IssueTrackerProperties(values:["bugtraq.logregex":"issue #(\\d+)","bugtraq.url":"https://tickets.invalid/%BUGID%"])
        let result=try await HistoryMessageStyler().prepare(doc,properties:properties,options:HistoryMessageOptions(),executable:parser)
        XCTAssertEqual(result.links.map(\.target),["https://tickets.invalid/42","deadbeef","https://example.invalid/deadbeef","https://example.invalid/"])
        XCTAssertEqual(values(doc.text,result.links.filter{$0.target.contains("tickets")}.map(\.range)),["42"])
        XCTAssertEqual(result.links.filter{$0.kind == .hash}.count,1)
    }
    func testTemplateIssuePositionsAndInvalidRegexFallback() async throws {
        let properties=IssueTrackerProperties(values:["bugtraq.message":"Issues: %BUGID%.","bugtraq.url":"https://tickets.invalid/%BUGID%"])
        let text="subject\nIssues: 42,73.\n"
        XCTAssertEqual(try values(text,properties.logIssuePositions(in:text)),["42","73"])
        let invalid=IssueTrackerProperties(values:["bugtraq.logregex":"(?<=#)(42)","bugtraq.url":"https://tickets.invalid/%BUGID%"])
        let doc=HistoryMessageDocument(hash:String(repeating:"a",count:40),subject:"fix",body:"#42 deadbeef https://example.invalid/")
        let styles=try await HistoryMessageStyler().prepare(doc,properties:invalid,options:HistoryMessageOptions(),executable:parser)
        XCTAssertEqual(styles.links.map(\.target),["deadbeef","https://example.invalid/"])
    }
    func testHighlightsRespectSectionsAndCancellation() async throws {
        let doc=HistoryMessageDocument(hash:String(repeating:"a",count:40),subject:"needle",body:"needle",notes:"needle")
        var options=HistoryMessageOptions();options.query="needle";options.fields = .notes
        let worker=HistoryMessageStyler(), styles=try await worker.prepare(doc,properties:IssueTrackerProperties(),options:options)
        XCTAssertEqual(styles.highlights.count,1);XCTAssertEqual(styles.highlights.first?.location,(doc.text as NSString).range(of:"needle",options:.backwards).location)
        let token=OperationCancellation();token.cancel()
        do { _=try await worker.prepare(doc,properties:IssueTrackerProperties(),options:options,cancellation:token);XCTFail("Cancelled styling accepted") }
        catch { XCTAssertTrue(error is OperationCancellationFailure) }
    }
}
