import XCTest
@testable import AgentPanel

final class ProjectNamingTests: XCTestCase {
    func testASimpleNameBecomesALowercaseSlug() {
        XCTAssertEqual(ProjectNaming.slug(from: "Recipe Box"), "recipe-box")
    }

    func testTurkishLettersAreSimplified() {
        XCTAssertEqual(ProjectNaming.slug(from: "Çiçek Bahçesi Şirin"), "cicek-bahcesi-sirin")
        XCTAssertEqual(ProjectNaming.slug(from: "ığüöİ"), "iguoi")
    }

    func testSymbolsAndRepeatedSeparatorsCollapseToSingleDashes() {
        XCTAssertEqual(ProjectNaming.slug(from: "  My   App!!  v2 "), "my-app-v2")
        XCTAssertEqual(ProjectNaming.slug(from: "a__b--c"), "a-b-c")
    }

    func testPathTricksCannotEscapeTheFolder() {
        XCTAssertEqual(ProjectNaming.slug(from: "../x"), nil, "one letter is too short to be a project name")
        XCTAssertEqual(ProjectNaming.slug(from: "../../etc/passwd"), "etc-passwd")
        XCTAssertEqual(ProjectNaming.slug(from: "a/b"), "a-b")
    }

    func testEmptyOrSymbolOnlyOrDigitFirstNamesHaveNoSlug() {
        XCTAssertNil(ProjectNaming.slug(from: ""))
        XCTAssertNil(ProjectNaming.slug(from: "   "))
        XCTAssertNil(ProjectNaming.slug(from: "!!!"))
        XCTAssertNil(ProjectNaming.slug(from: "2048 Game"))
    }

    func testALongNameIsCutAt40CharactersWithoutATrailingDash() throws {
        let slug = try XCTUnwrap(ProjectNaming.slug(from: String(repeating: "abcd ", count: 20)))
        XCTAssertLessThanOrEqual(slug.count, 40)
        XCTAssertFalse(slug.hasSuffix("-"))
        XCTAssertTrue(slug.hasPrefix("abcd-abcd"))
    }

    func testTheXcodeNameIsPascalCaseWithoutSymbols() {
        XCTAssertEqual(ProjectNaming.xcodeName(from: "Recipe Box"), "RecipeBox")
        XCTAssertEqual(ProjectNaming.xcodeName(from: "çiçek bahçesi"), "CicekBahcesi")
        XCTAssertEqual(ProjectNaming.xcodeName(from: "my-app v2"), "MyAppV2")
        XCTAssertEqual(ProjectNaming.xcodeName(from: "2048"), "App2048")
    }

    func testAVeryLongNameGivesAShortXcodeName() {
        XCTAssertLessThanOrEqual(ProjectNaming.xcodeName(from: String(repeating: "Word ", count: 40)).count, 60)
    }

    func testTheNamesAreBuiltFromTheChosenFolders() throws {
        let n = try XCTUnwrap(ProjectNaming.names(for: "Recipe Box", repoParent: "/Users/me/GitHub", dataRoot: "/Users/me/wiki/projects"))
        XCTAssertEqual(n.slug, "recipe-box")
        XCTAssertEqual(n.repoDir, "/Users/me/GitHub/recipe-box")
        XCTAssertEqual(n.dataDir, "/Users/me/wiki/projects/recipe-box")
        XCTAssertEqual(n.xcodeName, "RecipeBox")
    }

    func testCollisionsNameWhatIsAlreadyThere() throws {
        let n = try XCTUnwrap(ProjectNaming.names(for: "Recipe Box", repoParent: "/g", dataRoot: "/w"))
        XCTAssertEqual(ProjectNaming.collisions(of: n, existingIDs: [], fileExists: { _ in false }), [])
        XCTAssertEqual(ProjectNaming.collisions(of: n, existingIDs: ["recipe-box"], fileExists: { _ in false }).count, 1)
        XCTAssertTrue(ProjectNaming.collisions(of: n, existingIDs: [], fileExists: { $0 == "/g/recipe-box" })[0].contains("/g/recipe-box"))
        XCTAssertEqual(ProjectNaming.collisions(of: n, existingIDs: ["recipe-box"], fileExists: { _ in true }).count, 3)
    }
}
