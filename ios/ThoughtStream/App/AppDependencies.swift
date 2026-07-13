import Foundation

/// The app's composition root: the single place that wires up concrete implementations of the
/// app's seams (note storage today; more later). Created once in `ThoughtStreamApp` and passed
/// down, so no view or view model allocates its own concrete store.
struct AppDependencies {
    /// The note persistence backend used across the app.
    let noteStore: NoteStoring

    /// Builds the text processor for a dictation session. Returns a fresh one each time so a
    /// stateful processor never leaks across sessions. Defaults to the Mira control-word
    /// processor with the built-in control word.
    let makeTextProcessor: () -> TextProcessor

    init(
        noteStore: NoteStoring = NoteStore(),
        makeTextProcessor: @escaping () -> TextProcessor = { MiraTextProcessor() }
    ) {
        self.noteStore = noteStore
        self.makeTextProcessor = makeTextProcessor
    }
}
