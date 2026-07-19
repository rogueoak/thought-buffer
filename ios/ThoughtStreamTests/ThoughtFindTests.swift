import XCTest
@testable import ThoughtStream

/// `ThoughtFind` + `ThoughtFindNavigator` (spec 0025): the pure in-thought find. `matches(title:paragraphs:query:)`
/// returns the ordered match locations (region + character range) within ONE thought; the navigator steps
/// through them (wrapping) and formats the "N of M" count. All provable without SwiftUI.
final class ThoughtFindTests: XCTestCase {
    /// The substring of a region's text a match covers, for readable assertions.
    private func text(of match: ThoughtFind.Match, title: String, paragraphs: [String]) -> String {
        let source: String
        switch match.region {
        case .title:
            source = title
        case let .paragraph(index):
            source = paragraphs[index]
        }
        return String(source[match.range])
    }

    // MARK: - Region matches: title / body / ordering

    func testMatchesInTitle() {
        let matches = ThoughtFind.matches(title: "The Plan", paragraphs: ["nothing here"], query: "plan")
        XCTAssertEqual(matches.count, 1)
        XCTAssertEqual(matches[0].region, .title)
        XCTAssertEqual(text(of: matches[0], title: "The Plan", paragraphs: ["nothing here"]), "Plan")
    }

    func testMatchesInBodyParagraph() {
        let paragraphs = ["intro paragraph", "discuss the budget now"]
        let matches = ThoughtFind.matches(title: "Meeting", paragraphs: paragraphs, query: "budget")
        XCTAssertEqual(matches.count, 1)
        XCTAssertEqual(matches[0].region, .paragraph(1))
        XCTAssertEqual(text(of: matches[0], title: "Meeting", paragraphs: paragraphs), "budget")
    }

    func testOrderingTitleThenParagraphsInOrder() {
        // "find" appears in the title, paragraph 0, and paragraph 2 (twice) - title first, then paragraphs in
        // order, then left-to-right within a paragraph.
        let title = "find it"
        let paragraphs = ["please find me", "nothing", "find and find again"]
        let matches = ThoughtFind.matches(title: title, paragraphs: paragraphs, query: "find")
        XCTAssertEqual(matches.map(\.region), [
            .title,
            .paragraph(0),
            .paragraph(2),
            .paragraph(2),
        ])
    }

    func testMultipleMatchesAcrossThoughtAreLeftToRightWithinRegion() {
        let paragraphs = ["aa then aa"]
        let matches = ThoughtFind.matches(title: "no", paragraphs: paragraphs, query: "aa")
        XCTAssertEqual(matches.count, 2)
        // Non-overlapping, so the two "aa" runs are distinct and ordered by start.
        XCTAssertTrue(matches[0].range.lowerBound < matches[1].range.lowerBound)
    }

    // MARK: - Case / diacritic insensitivity

    func testCaseInsensitive() {
        let matches = ThoughtFind.matches(title: "PLAN the thing", paragraphs: [], query: "plan")
        XCTAssertEqual(matches.count, 1)
        XCTAssertEqual(text(of: matches[0], title: "PLAN the thing", paragraphs: []), "PLAN")
    }

    func testDiacriticInsensitive() {
        // A plain query finds accented text; the highlighted range covers the ORIGINAL accented characters.
        let paragraphs = ["Meet at the caf\u{00E9} today"]
        let matches = ThoughtFind.matches(title: "no", paragraphs: paragraphs, query: "cafe")
        XCTAssertEqual(matches.count, 1)
        XCTAssertEqual(text(of: matches[0], title: "no", paragraphs: paragraphs), "caf\u{00E9}")
    }

    func testAccentedQueryFindsPlainText() {
        let paragraphs = ["send the resume please"]
        let matches = ThoughtFind.matches(title: "no", paragraphs: paragraphs, query: "r\u{00E9}sum\u{00E9}")
        XCTAssertEqual(matches.count, 1)
        XCTAssertEqual(text(of: matches[0], title: "no", paragraphs: paragraphs), "resume")
    }

    func testSubstringNotJustWholeWord() {
        let matches = ThoughtFind.matches(title: "Planning ahead", paragraphs: [], query: "plan")
        XCTAssertEqual(matches.count, 1)
    }

    // MARK: - No match / empty query

    func testNoMatch() {
        XCTAssertTrue(ThoughtFind.matches(title: "Grocery", paragraphs: ["milk", "eggs"], query: "xyzzy").isEmpty)
    }

    func testEmptyOrWhitespaceQueryHasNoMatches() {
        XCTAssertTrue(ThoughtFind.matches(title: "anything", paragraphs: ["body"], query: "").isEmpty)
        XCTAssertTrue(ThoughtFind.matches(title: "anything", paragraphs: ["body"], query: "   \n\t ").isEmpty)
    }

    func testOuterWhitespaceOfQueryIsTrimmed() {
        // A user typing a padded query still finds the word.
        let matches = ThoughtFind.matches(title: "The Plan", paragraphs: [], query: "  plan  ")
        XCTAssertEqual(matches.count, 1)
    }

    // MARK: - Navigator: current, next / previous (wrap), count

    func testNavigatorStartsOnFirstMatch() {
        let matches = ThoughtFind.matches(title: "a a a", paragraphs: [], query: "a")
        let nav = ThoughtFindNavigator(matches: matches)
        XCTAssertTrue(nav.hasMatches)
        XCTAssertEqual(nav.currentIndex, 0)
        XCTAssertEqual(nav.currentMatch, matches[0])
    }

    func testNavigatorNextAndPreviousWalkTheList() {
        let matches = ThoughtFind.matches(title: "a a a", paragraphs: [], query: "a")
        var nav = ThoughtFindNavigator(matches: matches)
        nav.next()
        XCTAssertEqual(nav.currentIndex, 1)
        nav.next()
        XCTAssertEqual(nav.currentIndex, 2)
        nav.previous()
        XCTAssertEqual(nav.currentIndex, 1)
    }

    func testNavigatorNextWrapsPastLast() {
        let matches = ThoughtFind.matches(title: "a a", paragraphs: [], query: "a")
        var nav = ThoughtFindNavigator(matches: matches)
        nav.next() // index 1 (last)
        nav.next() // wraps to 0
        XCTAssertEqual(nav.currentIndex, 0)
    }

    func testNavigatorPreviousWrapsBeforeFirst() {
        let matches = ThoughtFind.matches(title: "a a", paragraphs: [], query: "a")
        var nav = ThoughtFindNavigator(matches: matches)
        nav.previous() // wraps from 0 to last (1)
        XCTAssertEqual(nav.currentIndex, 1)
    }

    func testNavigatorCountLabel() {
        let matches = ThoughtFind.matches(title: "a a a", paragraphs: [], query: "a")
        var nav = ThoughtFindNavigator(matches: matches)
        XCTAssertEqual(nav.countLabel, "1 of 3")
        nav.next()
        XCTAssertEqual(nav.countLabel, "2 of 3")
    }

    func testNavigatorEmptyListHasNoCurrentAndEmptyCount() {
        var nav = ThoughtFindNavigator(matches: [])
        XCTAssertFalse(nav.hasMatches)
        XCTAssertNil(nav.currentIndex)
        XCTAssertNil(nav.currentMatch)
        XCTAssertEqual(nav.countLabel, "")
        // Navigation is a no-op with no matches.
        nav.next()
        nav.previous()
        XCTAssertNil(nav.currentIndex)
    }

    // MARK: - Region -> scroll anchor id

    func testRegionScrollIDs() {
        XCTAssertEqual(ThoughtFind.Region.title.scrollID, "find.title")
        XCTAssertEqual(ThoughtFind.Region.paragraph(0).scrollID, "find.paragraph.0")
        XCTAssertEqual(ThoughtFind.Region.paragraph(3).scrollID, "find.paragraph.3")
        // Distinct paragraphs get distinct anchors.
        XCTAssertNotEqual(ThoughtFind.Region.paragraph(0).scrollID, ThoughtFind.Region.paragraph(1).scrollID)
    }
}
