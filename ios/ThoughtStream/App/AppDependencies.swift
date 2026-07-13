import Foundation

/// The app's composition root: the single place that wires up concrete implementations of the
/// app's seams (note storage today; more later). Created once in `ThoughtStreamApp` and passed
/// down, so no view or view model allocates its own concrete store.
struct AppDependencies {
    /// The note persistence backend used across the app.
    let noteStore: NoteStoring

    init(noteStore: NoteStoring = NoteStore()) {
        self.noteStore = noteStore
    }
}
