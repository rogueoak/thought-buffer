import Foundation

/// One row in the CarPlay recordings browser: a thought that HAS a recording, with the display fields a
/// `CPListItem` needs. Kept as a small value so the projection (audio-only, sorted, formatted) is a
/// pure, unit-testable mapping and the CarPlay scene stays presentational.
struct RecordingEntry: Equatable, Identifiable {
    var id: UUID { thought.id }
    /// The underlying thought, carried so a row tap can hand the whole thought to the shared playback
    /// controller (it needs the id + audio reference to resolve, and the title + duration for Now
    /// Playing).
    let thought: Thought
    /// The row title (the thought title).
    let title: String
    /// The row detail line: relative date + formatted recording duration ("2h ago - 1:23").
    let detail: String
}

/// Headless model for the CarPlay recordings browser (spec 0008): projects the shared
/// `ThoughtStoreDriver`'s thought list to only the thoughts that have a recording, newest first, each with a
/// formatted duration, and refreshes when the driver's list changes.
///
/// `@MainActor` because it wraps the main-actor `ThoughtStoreDriver` and the CarPlay scene (also
/// main-actor) reads it. No SwiftUI dependency - it is a plain observable-by-callback model like the
/// driver, so it can be driven from the CarPlay scene delegate, which is UIKit, not SwiftUI. Mirrors
/// `StreamFeed`'s relationship to the driver but filters + formats for the browser.
@MainActor
final class RecordingsListModel {
    /// The recordings to list, newest first. Only thoughts with a playable recording appear. Empty until
    /// the first load completes (or when no thought has audio).
    private(set) var entries: [RecordingEntry] = []
    /// True once an initial load has finished, so a consumer can tell "empty" from "not loaded yet".
    private(set) var didLoad = false

    /// Fires (on the main actor) after any change to `entries` - the first load, or a driver reload
    /// from a saved session / synced-in thought - so the CarPlay scene rebuilds its list template.
    var onChange: (() -> Void)?

    private let driver: ThoughtStoreDriver
    /// Injected so tests can pin the relative-date reference; production uses "now".
    private let referenceDate: () -> Date

    init(driver: ThoughtStoreDriver, referenceDate: @escaping () -> Date = Date.init) {
        self.driver = driver
        self.referenceDate = referenceDate
        driver.onStateChange = { [weak self] in self?.rebuild() }
    }

    /// Convenience: build over a fresh driver from a store + optional iCloud observer.
    convenience init(
        store: ThoughtStoring,
        observer: UbiquitousThoughtObserving? = nil,
        referenceDate: @escaping () -> Date = Date.init
    ) {
        self.init(driver: ThoughtStoreDriver(store: store, observer: observer), referenceDate: referenceDate)
    }

    /// Do the initial load and wire the iCloud observer (if any). Call when the CarPlay scene
    /// connects.
    func start() async { await driver.start() }

    /// Tear down the observer and drop the change closure. Call when the CarPlay scene disconnects.
    func stop() { driver.stop() }

    /// Copy the driver's current thoughts into `entries`, filtered to those with audio and formatted.
    private func rebuild() {
        // The driver already returns thoughts newest first; keep that order after filtering.
        entries = driver.thoughts
            .filter { $0.hasAudio }
            .map { thought in
                RecordingEntry(
                    thought: thought,
                    title: thought.title,
                    detail: Self.detailLabel(for: thought, relativeTo: referenceDate())
                )
            }
        didLoad = driver.didLoad
        onChange?()
    }

    // MARK: - Pure formatting (unit-tested directly)

    /// The row detail line: the relative date and the formatted recording duration, joined with a
    /// spaced hyphen ("2h ago - 1:23").
    static func detailLabel(for thought: Thought, relativeTo reference: Date) -> String {
        let date = RelativeTime.label(for: thought.createdAt, relativeTo: reference)
        return "\(date) - \(durationLabel(thought.recordingDuration))"
    }

    /// Format a duration in seconds as "m:ss" (or "h:mm:ss" past an hour). Delegates to
    /// `Thought.durationLabel`, the single source of truth for the app's duration formatting (feedback
    /// 0010); kept here so existing call sites and tests stay put.
    static func durationLabel(_ seconds: Double) -> String {
        Thought.durationLabel(seconds)
    }
}
