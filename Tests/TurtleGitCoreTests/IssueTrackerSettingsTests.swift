// SPDX-License-Identifier: GPL-2.0-or-later
import XCTest
@testable import TurtleGitCore

final class IssueTrackerSettingsTests: XCTestCase {
    func fixture(_ global:String="") async throws -> (URL,URL,GitRepository) {
        let value=try GeneralSetupBatchTests().fixture(global)
        _=try await value.2.run(["init","-b","main"])
        return value
    }
    func testScopedRoundTripPreservesIncludesOtherKeysAndFeedsCommitProperties() async throws {
        let (root,_,repo)=try await fixture("[bugtraq]\nurl = https://global.invalid/%BUGID%\n[include]\npath = included.config\n")
        defer{try? FileManager.default.removeItem(at:root)}
        let include=root.appendingPathComponent("included.config"),bytes=Data("[bugtraq]\nproviderparams = retained include\n[credential]\nhelper = retained\n".utf8)
        try bytes.write(to:include)
        _=try await repo.run(["config","--local","user.name","retained"])
        var settings=IssueTrackerSettings()
        settings.fields[.url]=GitConfigurationIdentity(value:"https://local.invalid/%BUGID%",inherit:false)
        settings.fields[.message]=GitConfigurationIdentity(value:"",inherit:false)
        settings.fields[.label]=GitConfigurationIdentity(value:"Ticket 雪",inherit:false)
        settings.fields[.regex]=GitConfigurationIdentity(value:"#[0-9]+\r\n[0-9]+",inherit:false)
        settings.fields[.provider32]=GitConfigurationIdentity(value:"{windows-32}",inherit:false)
        settings.fields[.provider64]=GitConfigurationIdentity(value:"{windows-64}",inherit:false)
        settings.number = .disabled;settings.warnIfNoIssue = .enabled
        try await repo.saveIssueTrackerSettings(settings,destination:.local)
        let local=try await repo.issueTrackerSettings(source:.local),effective=try await repo.issueTrackerSettings(source:.effective),consumer=try await repo.issueTrackerProperties()
        XCTAssertEqual(local.fields[.regex]?.value,"#[0-9]+\n[0-9]+");XCTAssertEqual(local.fields[.message],GitConfigurationIdentity(value:"",inherit:false))
        XCTAssertEqual(local.append,.inherit);XCTAssertEqual(effective.append,.enabled)
        XCTAssertEqual(consumer.label,"Ticket 雪");XCTAssertFalse(consumer.numbersOnly);XCTAssertTrue(consumer.warnIfNoIssue)
        XCTAssertEqual(consumer.checkExpression,"#[0-9]+");XCTAssertEqual(consumer.extractionExpression,"[0-9]+")
        XCTAssertEqual(try Data(contentsOf:include),bytes)
        let user=try await repo.run(["config","--get","user.name"]);XCTAssertEqual(user.text,"retained\n")
        settings.fields[.url]=GitConfigurationIdentity();try await repo.saveIssueTrackerSettings(settings,destination:.local)
        let inherited=try await repo.issueTrackerProperties();XCTAssertEqual(inherited.urlTemplate,"https://global.invalid/%BUGID%")
    }
    func testProjectAndBareReadsDestinationRefusalAndPreflightNUL() async throws {
        let (root,global,repo)=try await fixture();defer{try? FileManager.default.removeItem(at:root)}
        _=try await repo.run(["config","user.name","QA"]);_=try await repo.run(["config","user.email","qa@example.invalid"])
        var settings=IssueTrackerSettings();settings.fields[.message]=GitConfigurationIdentity(value:"Refs %BUGID%",inherit:false);settings.append = .disabled
        try await repo.saveIssueTrackerSettings(settings,destination:.project)
        try await repo.stage([".tgitconfig"]);_=try await repo.commit(message:"project")
        let bare=root.appendingPathComponent("bare.git");_=try await repo.run(["clone","--bare",root.path,bare.path])
        let other=GitRepository(root:bare,executable:repo.executable),stored=try await other.issueTrackerSettings(source:.project)
        XCTAssertEqual(stored.fields[.message]?.value,"Refs %BUGID%");XCTAssertEqual(stored.append,.disabled)
        do{try await other.saveIssueTrackerSettings(settings,destination:.project);XCTFail("Bare project write accepted")}catch GitConfigurationFailure.destination{}
        let before=try Data(contentsOf:global);settings.fields[.label]=GitConfigurationIdentity(value:"bad\0value",inherit:false)
        do{try await repo.saveIssueTrackerSettings(settings,destination:.global);XCTFail("NUL accepted")}catch GitConfigurationFailure.invalidValue{}
        XCTAssertEqual(try Data(contentsOf:global),before)
        do{try await repo.saveIssueTrackerSettings(IssueTrackerSettings(),destination:.system);XCTFail("System write accepted")}catch GitConfigurationFailure.destination{}
        let cancelled=OperationCancellation();cancelled.cancel()
        do{_=try await repo.issueTrackerSettings(source:.local,cancellation:cancelled);XCTFail("Cancelled read accepted")}catch{}
    }
    func testBooleanPresenceAndSharedDialogsReaderWriterRegression() async throws {
        let (root,_,repo)=try await fixture("[bugtraq]\nappend\nnumber =\nwarnifnoissue = -2\n[tgit]\nprojectlanguage = 1033\nlogwidthmarker = 72\n")
        defer{try? FileManager.default.removeItem(at:root)}
        let settings=try await repo.issueTrackerSettings(source:.global)
        XCTAssertEqual(settings.append,.enabled);XCTAssertEqual(settings.number,.disabled);XCTAssertEqual(settings.warnIfNoIssue,.enabled)
        var dialogs=try await repo.projectDialogSettings(source:.global)
        XCTAssertEqual(dialogs.language.value,"1033");XCTAssertEqual(dialogs.messageWidthMarker.value,"72")
        dialogs.minimumMessageLength=GitConfigurationIdentity(value:"12",inherit:false)
        try await repo.saveProjectDialogSettings(dialogs,destination:.local)
        let stored=try await repo.projectDialogSettings(source:.local),issue=try await repo.issueTrackerSettings(source:.global)
        XCTAssertEqual(stored.minimumLength,12);XCTAssertEqual(issue,settings)
    }
}
