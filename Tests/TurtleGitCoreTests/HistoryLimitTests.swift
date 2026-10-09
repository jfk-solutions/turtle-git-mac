import XCTest
@testable import TurtleGitCore

final class HistoryLimitTests: XCTestCase {
    func testSourceScaleOrderDefaultsAndPositiveLongStorage() {
        let suite = "TurtleGit.HistoryLimit.Core.QA." + UUID().uuidString, defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        XCTAssertEqual(HistoryLimitScale.allCases.map(\.rawValue), Array(0...5))
        XCTAssertEqual(HistoryLimitScale.allCases.map(\.title), ["No limitation", "Last selected date", "Last N commit(s)", "Last N year(s)", "Last N month(s)", "Last N week(s)"])
        XCTAssertEqual(HistoryLimitDefaults.load(defaults: defaults), HistoryLimitDefaults())
        defaults.set("keep", forKey: "other")
        HistoryLimitDefaults.apply(scale: .commits, numberText: "  +12suffix", defaults: defaults)
        XCTAssertEqual(HistoryLimitDefaults.load(defaults: defaults), .init(scale: .commits, number: 12))
        for value in ["0", "-5", "", "invalid"] { HistoryLimitDefaults.apply(scale: .months, numberText: value, defaults: defaults); XCTAssertEqual(HistoryLimitDefaults.load(defaults: defaults).number, 12) }
        HistoryLimitDefaults.apply(scale: .weeks, numberText: "999999999999999999", defaults: defaults)
        XCTAssertEqual(HistoryLimitDefaults.load(defaults: defaults).number, UInt32(Int32.max))
        XCTAssertEqual(HistoryLimitDefaults.signedNumber("-999999999999999999"), Int32.min)
        HistoryLimitDefaults.apply(scale: .noLimit, numberText: "2", defaults: defaults)
        XCTAssertEqual(HistoryLimitDefaults.load(defaults: defaults).number, UInt32(Int32.max))
        XCTAssertEqual(defaults.string(forKey: "other"), "keep")
    }
    func testSourceFixedUnitsMidnightNoLimitAndInclusiveDayEnd() throws {
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let now = calendar.date(from: DateComponents(year: 2026, month: 3, day: 31, hour: 16))!, midnight = calendar.startOfDay(for: now)
        for (scale, days) in [(HistoryLimitScale.years,365),(HistoryLimitScale.months,30),(.weeks,7)] {
            let scope = HistoryLimitScope(defaults: .init(scale: scale, number: 2))
            XCTAssertEqual(scope.since(now: now, calendar: calendar), midnight.addingTimeInterval(TimeInterval(-days * 2 * 86400)))
            var options = HistoryOptions(); scope.apply(to: &options, now: now, calendar: calendar)
            XCTAssertEqual(options.limit, -1); XCTAssertEqual(options.since, scope.since(now: now, calendar: calendar))
        }
        XCTAssertNil(HistoryLimitScope(defaults: .init(scale: .years, number: UInt32.max)).since(now: now, calendar: calendar))
        XCTAssertNil(HistoryLimitScope().since(now: now, calendar: calendar))
        XCTAssertEqual(HistoryLimitScope.endOfDay(now, calendar: calendar), midnight.addingTimeInterval(86399))
        calendar.timeZone = TimeZone(identifier: "Europe/Berlin")!
        let spring = calendar.date(from: DateComponents(year: 2026, month: 3, day: 29, hour: 12))!
        XCTAssertEqual(HistoryLimitScope.endOfDay(spring, calendar: calendar).timeIntervalSince(HistoryLimitScope.startOfDay(spring, calendar: calendar)), 23 * 3600 - 1)
        XCTAssertEqual(HistoryLimitScope.startOfDay(Date(timeIntervalSince1970: -100), calendar: calendar), Date(timeIntervalSince1970: 0))
    }
    func testSavedFromIsRepositoryScopedAndStrict() {
        let suite = "TurtleGit.HistoryLimit.Core.QA." + UUID().uuidString, defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let first = URL(fileURLWithPath: "/tmp/one"), second = URL(fileURLWithPath: "/tmp/two")
        let date = calendar.date(from: DateComponents(year: 2026, month: 3, day: 29, hour: 12))!
        HistoryLimitDefaults.saveFrom(date, root: first, defaults: defaults, calendar: calendar)
        XCTAssertEqual(HistoryLimitDefaults.savedFrom(root: first, defaults: defaults, calendar: calendar), calendar.startOfDay(for: date))
        XCTAssertNil(HistoryLimitDefaults.savedFrom(root: second, defaults: defaults, calendar: calendar))
        defaults.set("2026-02-31", forKey: HistoryLimitDefaults.fromDateKey(root: first)); XCTAssertNil(HistoryLimitDefaults.savedFrom(root: first, defaults: defaults, calendar: calendar))
    }
    func testRealUnlimitedRawCountAndSelectedDateScopesPreserveRepository() async throws {
        let (root, repo, path) = try await GitPatchTests().fixture(); defer { try? FileManager.default.removeItem(at: root) }
        _ = try await repo.run(["commit", "--allow-empty", "-m", "later"])
        let paths = [".git/HEAD", ".git/index", ".git/config", path], before = try paths.map { try Data(contentsOf: root.appendingPathComponent($0)) }
        var options = HistoryOptions(); options.retainFilteredRows = true
        HistoryLimitScope().apply(to: &options)
        let all = try await repo.history(options: options); XCTAssertEqual(all.count, 2)
        HistoryLimitScope(defaults: .init(scale: .commits, number: 1)).apply(to: &options)
        let one = try await repo.history(options: options); XCTAssertEqual(one.count, 1)
        HistoryLimitScope(defaults: .init(scale: .selectedDate), from: Date().addingTimeInterval(86400)).apply(to: &options)
        let future = try await repo.history(options: options); XCTAssertTrue(future.isEmpty)
        HistoryLimitScope(defaults: .init(scale: .commits, number: 0)).apply(to: &options)
        let none = try await repo.history(options: options); XCTAssertTrue(none.isEmpty)
        let after = try paths.map { try Data(contentsOf: root.appendingPathComponent($0)) }; XCTAssertEqual(before, after)
    }
}
