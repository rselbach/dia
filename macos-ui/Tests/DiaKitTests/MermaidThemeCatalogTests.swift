import XCTest
@testable import DiaKit

final class MermaidThemeCatalogTests: XCTestCase {
    func testCatalogContainsElevenThemes() {
        XCTAssertEqual(MermaidThemeCatalog.themes.count, 11)
    }

    func testCatalogContainsExpectedThemeIDs() {
        let ids = Set(MermaidThemeCatalog.themes.map(\.id))
        let want: Set<String> = [
            "default", "dark", "forest", "neutral",
            "catppuccin", "dracula", "nord", "synthwave",
            "rose", "ocean", "solarized",
        ]
        XCTAssertEqual(ids, want)
    }

    func testDefaultThemeID() {
        XCTAssertEqual(MermaidThemeCatalog.defaultThemeID, "default")
    }

    func testNormalizeKnownThemeReturnsItself() {
        XCTAssertEqual(MermaidThemeCatalog.normalizeThemeID("forest"), "forest")
        XCTAssertEqual(MermaidThemeCatalog.normalizeThemeID("dracula"), "dracula")
    }

    func testNormalizeUnknownThemeReturnsDefault() {
        XCTAssertEqual(MermaidThemeCatalog.normalizeThemeID("not-a-theme"), "default")
        XCTAssertEqual(MermaidThemeCatalog.normalizeThemeID(""), "default")
    }

    func testConfigJSForBuiltInTheme() {
        let forest = MermaidThemeCatalog.mermaidConfigJS(for: "forest")
        XCTAssertTrue(forest.contains("theme: \"forest\""))
        XCTAssertTrue(forest.contains("securityLevel: \"strict\""))
        XCTAssertTrue(forest.contains("startOnLoad: false"))
    }

    func testConfigJSForCustomTheme() {
        let dracula = MermaidThemeCatalog.mermaidConfigJS(for: "dracula")
        XCTAssertTrue(dracula.contains("theme: \"base\""))
        XCTAssertTrue(dracula.contains("themeVariables:"))
        XCTAssertTrue(dracula.contains("primaryColor: \"#bd93f9\""))
    }

    func testConfigJSForUnknownThemeFallsBackToDefault() {
        let unknown = MermaidThemeCatalog.mermaidConfigJS(for: "nonexistent")
        XCTAssertTrue(unknown.contains("theme: \"default\""))
    }

    func testAllThemesHaveNonEmptyFields() {
        for theme in MermaidThemeCatalog.themes {
            XCTAssertFalse(theme.id.isEmpty, "theme ID must not be empty")
            XCTAssertFalse(theme.label.isEmpty, "theme \(theme.id) label must not be empty")
            XCTAssertTrue(theme.previewBackground.hasPrefix("#"), "theme \(theme.id) background must be a color")
            XCTAssertTrue(theme.errorColor.hasPrefix("#"), "theme \(theme.id) errorColor must be a color")
        }
    }
}
