import XCTest
@testable import TurtleGitCore

final class AppLanguageTests: XCTestCase {
    func testCountTemplatesReorderIntegerFieldsWithoutPrintfExecution() {
        let english="{checked} files checked, {shown} files shown"
        XCTAssertEqual(LocalizedCountTemplate.render(english,translation:"Affichés : {shown}; cochés : {checked}",values:["checked":1,"shown":2000]),"Affichés : 2000; cochés : 1")
        XCTAssertEqual(LocalizedCountTemplate.render("{value}",translation:"Wert {value}",values:["value":Int.min]),"Wert "+String(Int.min))
    }
    func testMissingDuplicateUnknownAndMalformedCountFieldsUseEnglish() {
        let english="{checked} checked, {shown} shown",values=["checked":0,"shown":3]
        for invalid in ["", "{checked}", "{checked} {checked}", "{checked} {other}", "{checked} {shown", "{checked} {shown}}", "{checked} {shown} %n", "{checked} {shown} {extra}", "{Checked} {shown}"] {
            XCTAssertFalse(LocalizedCountTemplate.accepts(invalid,for:english),invalid)
            XCTAssertEqual(LocalizedCountTemplate.render(english,translation:invalid,values:values),"0 checked, 3 shown",invalid)
        }
    }
    func testInvalidCountContractsDoNotCrashOrLoseTheOriginalTemplate() {
        for english in ["{count", "{count} {count}", "no fields", "{cöunt}"] {
            XCTAssertEqual(LocalizedCountTemplate.render(english,translation:"bad",values:["count":1]),english)
        }
        XCTAssertEqual(LocalizedCountTemplate.render("{count}",translation:"{count}",values:[:]),"{count}")
        XCTAssertEqual(LocalizedCountTemplate.render("{count}",translation:"{count}",values:["count":1,"other":2]),"{count}")
    }
    func testChoicesAreBundledUniqueAndHaveReadableTitles() {
        XCTAssertEqual(AppLanguageChoice.bundledIDs.count,38)
        XCTAssertEqual(Set(AppLanguageChoice.bundledIDs).count,38)
        XCTAssertEqual(AppLanguageChoice.choices.first?.id,AppLanguageChoice.system)
        XCTAssertEqual(AppLanguageChoice.choices[1].id,"en")
        XCTAssertTrue(AppLanguageChoice.choices.allSatisfy { !$0.title.isEmpty })
        for id in ["en","de","fr","zh-Hans","zh-Hant","sr","sr-Latn","pt-BR"] { XCTAssertTrue(AppLanguageChoice.isAvailable(id)) }
        for id in ["", "unknown", "de/../../", "en\0"] { XCTAssertFalse(AppLanguageChoice.isAvailable(id)) }
    }
    func testPrivatePreferenceSelectionAndSystemReset() throws {
        let name="TurtleGit.Language.Core."+UUID().uuidString,prefs=UserDefaults(suiteName:name)!
        defer {prefs.removePersistentDomain(forName:name)}
        prefs.set(["fr","en"],forKey:"AppleLanguages")
        XCTAssertEqual(AppLanguageChoice.selected(in:prefs),AppLanguageChoice.system)
        // Merely reading a page preserves macOS' existing language order.
        XCTAssertEqual(prefs.stringArray(forKey:"AppleLanguages"),["fr","en"])
        try AppLanguageChoice.save("de",to:prefs)
        XCTAssertEqual(AppLanguageChoice.selected(in:prefs),"de")
        XCTAssertEqual(prefs.stringArray(forKey:"AppleLanguages"),["de"])
        let saved=prefs.persistentDomain(forName:name)!
        XCTAssertThrowsError(try AppLanguageChoice.save("invalid",to:prefs))
        XCTAssertEqual(NSDictionary(dictionary:prefs.persistentDomain(forName:name)!),NSDictionary(dictionary:saved))
        try AppLanguageChoice.save(AppLanguageChoice.system,to:prefs)
        XCTAssertEqual(AppLanguageChoice.selected(in:prefs),AppLanguageChoice.system)
        XCTAssertNil(prefs.persistentDomain(forName:name)?["AppleLanguages"])
        XCTAssertNil(prefs.persistentDomain(forName:name)?["TurtleGit.AppLanguage"])
    }
    func testUnknownSavedChoiceFallsBackWithoutMutatingPreferences() {
        let name="TurtleGit.Language.Unknown."+UUID().uuidString,prefs=UserDefaults(suiteName:name)!
        defer {prefs.removePersistentDomain(forName:name)}
        prefs.set("future-language",forKey:"TurtleGit.AppLanguage")
        XCTAssertEqual(AppLanguageChoice.selected(in:prefs),AppLanguageChoice.system)
        XCTAssertEqual(prefs.string(forKey:"TurtleGit.AppLanguage"),"future-language")
    }
}
