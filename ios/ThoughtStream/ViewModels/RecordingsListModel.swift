import Foundation

/// One row in the CarPlay recordings browser: a note that HAS a recording, with the display fields a
/// `CPListItem` needs. Kept as a small value so the projection (audio-only, sorted, formatted) is a
/// pure, unit-testable mapping and the CarPlay scene stays presentational.
struct RecordingEntry: Equatable, Identifiable {
    var id: UUID { note.id }
    /// The underlying note, carried so a row tap can hand the whole note to the shared playback
    /// controller (it needs the id + audio reference to resolve, and the title + duration for Now
    /// Playing).
    let note: Note
    /// The row title (the note title).
    let title: String
    /// The row detail line: relative date + formatted recording duration ("2h ago - 1:23").
    let detail: String
}

/// Headless model for the CarPlay recordings browser (spec 0008): projects the shared
/// `NoteStoreDriver`'s note list to only the notes that have a recording, newest first, each with a
/// formatted duration, and refreshes when the driver's list changes.
///
/// `@MainActor` because it wraps the main-actor `NoteStoreDriver` and the CarPlay scene (also
/// main-actor) reads it. No SwiftUI dependency - it is a plain observable-by-callback model like the
/// driver, so it can be driven from the CarPlay scene delegate, which is UIKit, not SwiftUI. Mirrors
/// `StreamFeed`'s relationship to the driver but filters + formats for the browser.
@MainActor
final class RecordingsListModel {
    /// The recordings to list, newest first. Only notes with a playable recording appear. Empty until
    /// the first load completes (or when no note has audio).
    private(set) var entries: [RecordingEntry] = []
    /// True once an initial load has finished, so a consumer can tell "empty" from "not loaded yet".
    private(set) var didLoad = false

    /// Fires (on the main actor) after any change to `entries` - the first load, or a driver reload
    /// from a saved session / synced-in note - so the CarPlay scene rebuilds its list template.
    var onChange: (() -> Void)?

    private let driver: NoteStoreDriver
    /// Injected so tests can pin the relative-date reference; production uses "now".
    private let referenceDate: () -> Date

    init(driver: NoteStoreDriver, referenceDate: @escaping () -> Date = Date.init) {
        self.driver = driver
        self.referenceDate = referenceDate
        driver.onStateChange = { [weak self] in self?.rebuild() }
    }

    /// Convenience: build over a fresh driver from a store + optional iCloud observer.
    convenience init(
        store: NoteStoring,
        observer: UbiquitousNoteObserving? = nil,
        referenceDate: @escaping () -> Date = Date.init
    ) {
        self.init(driver: NoteStoreDriver(store: store, observer: observer), referenceDate: referenceDate)
    }

    /// Do the initial load and wire the iCloud observer (if any). Call when the CarPlay scene
    /// connects.
    func start() async { await driver.start() }

    /// Tear down the observer and drop the change closure. Call when the CarPlay scene disconnects.
    func stop() { driver.stop() }

    /// Copy the driver's current notes into `entries`, filtered to those with audio and formatted.
    private func rebuild() {
        // The driver already returns notes newest first; keep that order after filtering.
        entries = driver.notes
            .filter { $0.hasAudio }
            .map { note in
                RecordingEntry(
                    note: note,
                    title: note.title,
                    detail: Self.detailLabel(for: note, relativeTo: referenceDate())
                )
            }
        didLoad = driver.didLoad
        onChange?()
    }

    // MARK: - Pure formatting (unit-tested directly)

    /// The row detail line: the relative date and the formatted recording duration, joined with a
    /// spaced hyphen ("2h ago - 1:23").
    static func detailLabel(for note: Note, relativeTo reference: Date) -> String {
        let date = RelativeTime.label(for: note.createdAt, relativeTo: reference)
        return "\(date) - \(durationLabel(note.recordingDuration))"
    }

    /// Format a duration in seconds as "m:ss" (or "h:mm:ss" past an hour). Delegates to
    /// `Note.durationLabel`, the single source of truth for the app's duration formatting (feedback
    /// 0010); kept here so existing call sites and tests stay put.
    static func durationLabel(_ seconds: Double) -> String {
        Note.durationLabel(seconds)
    }
}
