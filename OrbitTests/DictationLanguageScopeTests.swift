import FluidAudio
import XCTest

final class DictationLanguageScopeTests: XCTestCase {

    func testEmptySelectionDisablesFiltering() {
        XCTAssertNil(DictationLanguageScope.hint(for: []))
    }

    func testUnknownCodesAreIgnored() {
        XCTAssertNil(DictationLanguageScope.hint(for: ["xx", "not-a-language"]))
    }

    func testEnglishWinsAnyLatinSelection() {
        XCTAssertEqual(DictationLanguageScope.hint(for: ["en", "sv"]), .english)
        XCTAssertEqual(DictationLanguageScope.hint(for: ["sv", "de", "en"]), .english)
        XCTAssertEqual(DictationLanguageScope.hint(for: ["en"]), .english)
    }

    func testLatinWithoutEnglishUsesLowestRawValue() {
        XCTAssertEqual(DictationLanguageScope.hint(for: ["sv"]), .swedish)
        XCTAssertEqual(DictationLanguageScope.hint(for: ["sv", "de"]), .german)
    }

    func testMixedScriptsDisableFiltering() {
        XCTAssertNil(DictationLanguageScope.hint(for: ["sv", "ru"]))
        XCTAssertNil(DictationLanguageScope.hint(for: ["en", "el"]))
        XCTAssertNil(DictationLanguageScope.hint(for: ["ru", "el"]))
    }

    func testCyrillicUsesLowestRawValue() {
        XCTAssertEqual(DictationLanguageScope.hint(for: ["ru"]), .russian)
        XCTAssertEqual(DictationLanguageScope.hint(for: ["ru", "uk"]), .russian)
    }

    func testGreekSelection() {
        XCTAssertEqual(DictationLanguageScope.hint(for: ["el"]), .greek)
    }

    func testSupportedCodesComeFromFluidAudio() {
        XCTAssertTrue(DictationLanguageScope.supportedCodes.contains("en"))
        XCTAssertTrue(DictationLanguageScope.supportedCodes.contains("sv"))
        XCTAssertTrue(DictationLanguageScope.supportedCodes.contains("ru"))
        XCTAssertTrue(DictationLanguageScope.supportedCodes.contains("el"))
        XCTAssertFalse(DictationLanguageScope.supportedCodes.contains("zh"))
        XCTAssertEqual(DictationLanguageScope.supportedCodes, Set(Language.allCases.map(\.rawValue)))
    }
}
