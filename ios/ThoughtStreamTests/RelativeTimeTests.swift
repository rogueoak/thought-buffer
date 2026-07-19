import XCTest
@testable import ThoughtStream

/// The stale "x mins ago" bug (feedback 0011) came from a relative-time label that never recomputed
/// against a current reference. The `ThoughtCard` fix wraps the label in a `TimelineView` and passes the
/// live `context.date` as `relativeTo`. These tests pin the contract that fix depends on: the label
/// is a function of the reference instant, not a constant - so a label rendered at save time cannot
/// be correct forever.
final class RelativeTimeTests: XCTestCase {
    func testLabelChangesAsReferenceAdvances() {
        let created = Date(timeIntervalSince1970: 1_000_000)

        // "Just after creation" vs "an hour later": the same created date must read differently as
        // the reference moves forward, which is what keeps the list card from freezing.
        let nearLabel = RelativeTime.label(for: created, relativeTo: created.addingTimeInterval(90))
        let laterLabel = RelativeTime.label(for: created, relativeTo: created.addingTimeInterval(3600))

        XCTAssertNotEqual(
            nearLabel, laterLabel,
            "Relative-time label must track its reference date; a frozen reference is the stale bug."
        )
    }

    func testDefaultReferenceIsNow() {
        // Passing no reference uses the current time. A date one hour in the past should not read the
        // same as that date measured from itself (which would be "now"/"0s").
        let anHourAgo = Date().addingTimeInterval(-3600)
        let fromNow = RelativeTime.label(for: anHourAgo)
        let fromCreation = RelativeTime.label(for: anHourAgo, relativeTo: anHourAgo)
        XCTAssertNotEqual(fromNow, fromCreation)
    }
}
