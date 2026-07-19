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
        // The match carries CHARACTER OFFSETS; resolve them against the region text (as the view does).
        let lower = source.index(source.startIndex, offsetBy: match.characterRange.lowerBound)
        let upper = source.index(source.startIndex, offsetBy: match.characterRange.upperBound)
        return String(source[lower..<upper])
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
        XCTAssertTrue(matches[0].characterRange.lowerBound < matches[1].characterRange.lowerBound)
    }

    func testOverlappingRunsAreNonOverlapping() {
        // "aaa" contains "aa" twice if overlapping is allowed; non-overlapping yields exactly ONE match,
        // covering the first two characters (tester review - the "aa then aa" test passes either way).
        let matches = ThoughtFind.matches(title: "aaa", paragraphs: [], query: "aa")
        XCTAssertEqual(matches.count, 1)
        XCTAssertEqual(matches[0].characterRange, 0..<2)
    }

    func testMatchAtEndOfRegion() {
        // A match ending at the very LAST character exercises the upper-bound offset the highlight consumes
        // (tester review): the range must cover through the final character without overrunning.
        let paragraphs = ["ends with plan"]
        let matches = ThoughtFind.matches(title: "no", paragraphs: paragraphs, query: "plan")
        XCTAssertEqual(matches.count, 1)
        XCTAssertEqual(matches[0].characterRange.upperBound, paragraphs[0].count)
        XCTAssertEqual(text(of: matches[0], title: "no", paragraphs: paragraphs), "plan")
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

    // MARK: - First match (open-from-search seam, feedback 0030 item 9)

    func testFirstMatchInTitleWhenTitleMatches() {
        // A query that hits the title returns the TITLE match as the first hit (title precedes paragraphs),
        // so opening a thought from a search whose query is in the title seeks the title.
        let first = ThoughtFind.firstMatch(title: "The Plan", paragraphs: ["plan the trip"], query: "plan")
        XCTAssertEqual(first?.region, .title)
    }

    func testFirstMatchIsEarliestParagraphWhenTitleDoesNotMatch() {
        // No title hit, so the first match is the earliest matching paragraph (paragraph 1 here), which is
        // where the in-note find seeks and highlights on open-from-search.
        let paragraphs = ["intro", "discuss the budget", "budget again"]
        let first = ThoughtFind.firstMatch(title: "Meeting", paragraphs: paragraphs, query: "budget")
        XCTAssertEqual(first?.region, .paragraph(1))
    }

    func testFirstMatchNilWhenNoMatchOrEmptyQuery() {
        // A thought opened NOT from a search (empty query) or with no hit yields nil - the detail seeds
        // nothing and the in-note find stays inert.
        XCTAssertNil(ThoughtFind.firstMatch(title: "Grocery", paragraphs: ["milk"], query: "xyzzy"))
        XCTAssertNil(ThoughtFind.firstMatch(title: "Grocery", paragraphs: ["milk"], query: ""))
        XCTAssertNil(ThoughtFind.firstMatch(title: "Grocery", paragraphs: ["milk"], query: "   "))
    }

    func testFirstMatchEqualsMatchesFirst() {
        // The seam is exactly `matches(...).first` (documented equivalence), so the highlight the view draws
        // for the seeded first hit is the same match `matches` produced.
        let paragraphs = ["find me here", "and find me here too"]
        let first = ThoughtFind.firstMatch(title: "no", paragraphs: paragraphs, query: "find")
        XCTAssertEqual(first, ThoughtFind.matches(title: "no", paragraphs: paragraphs, query: "find").first)
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

    func testCombiningMarkOnlyQueryHasNoMatches() {
        // A query of only a lone combining mark folds AWAY (distinct from whitespace, which trims): the
        // folded needle is empty, so there are no matches (tester review). U+0301 = combining acute accent.
        let matches = ThoughtFind.matches(title: "cafe", paragraphs: ["resume"], query: "\u{0301}")
        XCTAssertTrue(matches.isEmpty)
    }

    // MARK: - Multi-scalar grapheme (emoji) - per-Character folding

    func testEmojiQueryMatchesByGraphemeCluster() {
        // A multi-scalar emoji is ONE `Character`; the per-`Character` fold matches it as a single unit and
        // the character range maps back to the whole grapheme (tester review). Flag emoji = two scalars.
        let paragraphs = ["party \u{1F389} time"] // party popper emoji
        let matches = ThoughtFind.matches(title: "no", paragraphs: paragraphs, query: "\u{1F389}")
        XCTAssertEqual(matches.count, 1)
        XCTAssertEqual(text(of: matches[0], title: "no", paragraphs: paragraphs), "\u{1F389}")
    }

    func testMatchAfterEmojiHasCorrectOffset() {
        // A match FOLLOWING a multi-scalar emoji must use character (grapheme) offsets, not scalar/UTF-16
        // offsets, so the range still lands on the word (per-Character offset contract, tester review).
        let paragraphs = ["\u{1F389} find me"]
        let matches = ThoughtFind.matches(title: "no", paragraphs: paragraphs, query: "find")
        XCTAssertEqual(matches.count, 1)
        XCTAssertEqual(text(of: matches[0], title: "no", paragraphs: paragraphs), "find")
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

    func testRebuildingNavigatorResetsToFirstMatch() {
        // The view rebuilds the navigator whenever the query changes (`refreshFind`), so navigating and then
        // rebuilding must return to the first match - the "changed query seeks to the first hit" contract
        // (tester review). Modeled here at the pure boundary: a fresh navigator over new matches is index 0.
        let matches = ThoughtFind.matches(title: "a a a", paragraphs: [], query: "a")
        var nav = ThoughtFindNavigator(matches: matches)
        nav.next()
        nav.next()
        XCTAssertEqual(nav.currentIndex, 2)
        // A new query rebuilds the navigator from scratch.
        let rebuilt = ThoughtFindNavigator(matches: ThoughtFind.matches(title: "a a a", paragraphs: [], query: "a"))
        XCTAssertEqual(rebuilt.currentIndex, 0)
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
