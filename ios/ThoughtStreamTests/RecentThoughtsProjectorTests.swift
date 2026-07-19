import XCTest
@testable import ThoughtStream

/// Tests for the phone -> watch recent-thoughts projection (spec 0023): the pure mapping from `[Thought]`
/// to the glanceable `[RecentThoughtProjection]` the watch browses. Provable without a real watch.
final class RecentThoughtsProjectorTests: XCTestCase {
    func testProjectsTitlePreviewDurationAndAudioFlag() {
        let recorded = Thought(
            title: "Morning drive",
            paragraphs: ["Call the supplier about the order.", "Second."],
            createdAt: Date(),
            audioFileName: "a.m4a",
            timings: [ParagraphTiming(start: 0, duration: 4), ParagraphTiming(start: 4, duration: 3)]
        )
        let textOnly = Thought(title: "Idea", paragraphs: ["A quick idea"], createdAt: Date())

        let projected = RecentThoughtsProjector.project([recorded, textOnly])

        XCTAssertEqual(projected.count, 2)
        XCTAssertEqual(projected[0].title, "Morning drive")
        XCTAssertEqual(projected[0].preview, "Call the supplier about the order.")
        XCTAssertEqual(projected[0].duration, 7, accuracy: 0.001)
        XCTAssertTrue(projected[0].hasAudio)

        XCTAssertFalse(projected[1].hasAudio)
        XCTAssertEqual(projected[1].duration, 0)
    }

    func testPreviewIsFlattenedAndCapped() {
        let long = String(repeating: "word ", count: 40) // > previewCap
        let thought = Thought(title: "T", paragraphs: ["line one\nline two \(long)"], createdAt: Date())
        let preview = RecentThoughtsProjector.preview(for: thought)
        // No newline, capped with an ellipsis.
        XCTAssertFalse(preview.contains("\n"))
        XCTAssertTrue(preview.hasSuffix("..."))
        XCTAssertLessThanOrEqual(preview.count, RecentThoughtsProjector.previewCap + 3)
    }

    func testLimitCapsTheList() {
        let thoughts = (0..<50).map { Thought(title: "T\($0)", paragraphs: ["p"], createdAt: Date()) }
        let projected = RecentThoughtsProjector.project(thoughts, limit: 10)
        XCTAssertEqual(projected.count, 10)
    }

    func testPreservesOrder() {
        let a = Thought(title: "A", paragraphs: ["p"], createdAt: Date())
        let b = Thought(title: "B", paragraphs: ["p"], createdAt: Date())
        let projected = RecentThoughtsProjector.project([a, b])
        XCTAssertEqual(projected.map(\.title), ["A", "B"])
    }
}
