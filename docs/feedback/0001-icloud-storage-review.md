# 0001 - iCloud storage review findings

Feedback from the persona review of PR #4 (spec 0004, iCloud Drive storage).

## Symptom

Two majors and several minors surfaced in review of the first cut:

- **Blocking IO on the main thread (architect, tester).** `StreamListView.reload()` called
  `store.loadAll()` synchronously on the main actor. For the local store that is cheap, but for
  `ICloudNoteStore` it is a chain of `NSFileCoordinator` reads that can block on the sync daemon -
  and it fired on every metadata `onChange`, so a busy sync could stutter the UI.
- **The load-bearing glue was untested (tester).** The observer wiring (initial load, `start()`,
  `onChange` -> reload, `stop()`, and the local no-observer path) lived inline in the SwiftUI view
  with no test, so a regression that dropped `start()` or the rewire would ship green.
- **Observer lifecycle bound to view appearance (architect).** Wiring on `onAppear` and tearing
  down on `onDisappear` restarted the `NSMetadataQuery` on every push/pop within the same
  `NavigationStack` (e.g. opening a note detail).
- **Stale closure on a lifetime observer (engineer).** `onChange` was set but never cleared, so
  the app-lifetime observer kept a closure capturing a gone view.
- **Two same-typed initializers with different semantics (architect).** `ICloudNoteStore` had
  `init(containerDocumentsURL:)` (appends `ThoughtBuffer/`) and `init(directory:)` (exact dir),
  both taking a `URL` - a mislabel footgun at the call site.

## Root cause

The load and observe logic was written inline in the view, which made the async boundary easy to
draw at container resolution but easy to forget at the read path, and left the glue untestable.
The extra initializer was added for test convenience without a label that made its semantics
obvious.

## Fix

- Extracted a `@MainActor` `StreamFeed` ObservableObject that owns the notes state, loads through
  the store on a detached task (only the assignment touches main-actor state), and wires the
  observer once: `start()` (load + observe, idempotent), `stop()` (drop the closure + stop the
  query). The view drives it from a single `.task` whose cancellation calls `stop()`, so the query
  is not restarted on navigation and holds no stale reference.
- Added `StreamFeedTests`: initial load, start wires + starts the observer, `onChange` reloads,
  `stop` clears the closure, the local no-observer path, and start idempotence.
- Made the test-only initializer an explicit `ICloudNoteStore.forTesting(directory:)` and made the
  bare `init(directory:)` private, so the two URL initializers can no longer be confused.
- Added tests for the bare-markdown fallbackID/fallbackDate path and a direct `createdAt`
  round-trip assertion.

## Learning

Draw the off-main boundary at the *store read*, not just at container resolution, and put the
load/observe glue in a testable model rather than inline in the view. Generalized into
`overview/learnings.md`.

## Round 2 (Spectra persona review of the open PR)

A second pass surfaced honesty and concurrency findings, all addressed on the same branch:

- **README privacy copy was misleading** once iCloud is active (it claimed "fully local"). Split
  the promise honestly: speech is 100% on-device always; note storage is local by default and
  optionally syncs through the user's own Apple/iCloud account; "no account" means no Thought
  Stream account.
- **`NoteStoring: Sendable`** so the `Task.detached` store capture is sound under strict
  concurrency; the immutable value-type stores conform for free, test doubles use
  `@unchecked Sendable`.
- **Teardown via `withTaskCancellationHandler`** in `StreamListView` instead of a 1s sleep-poll,
  so `stop()` runs immediately on cancellation.
- **Extracted headless `NoteStoreDriver`** (plain `@MainActor` type, not `ObservableObject`) that
  owns the load + observer wiring so a future CarPlay/Siri session can drive it; `StreamFeed` is
  now a thin projection republishing the driver's state. Behavior unchanged.
- **`queryDidUpdate`** calls `onChange` directly (the `NSMetadataQuery` notification is already on
  the main thread), dropping the redundant `DispatchQueue.main` hop.
- **Tests:** `testFallbackStoreRoundTripsLikeLocal` now exercises the returned `selection.store`;
  added the iCloud->local cross-store compatibility direction and a "change after stop does not
  reload" assertion.

