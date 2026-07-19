# Feedback 0017 - Dead-air trim PR review (spec 0019, PR #29)

Captured from the four-persona Spectra review of PR #29 (feat/0019-dead-air). Two majors and
several minors were raised and fixed in the same PR before merge.

## Symptom

The first implementation of automatic dead-air removal had three unsafe or incorrect behaviors that
the happy-path tests did not surface:

1. **Stale-snapshot re-save race** (architect + engineer, MAJOR). The off-main trim re-saved the
   full `Note` snapshot captured at `finish()`. Because the app navigates to the note detail
   immediately after saving, a user could rename / edit / move / delete the note while a slow trim
   ran; the trim's later re-save then reverted that edit (or resurrected a deleted note) - a
   last-writer-wins data race.
2. **iCloud coordination bypass** (security, MAJOR). The atomic replace used a bare
   `FileManager.replaceItemAt` directly on `store.audioURL(for:)`, which on the iCloud backend is an
   `NSFileCoordinator`-coordinated ubiquity-container file. A non-reversible replace that skips
   coordination races the sync daemon.
3. **Unprotected temp copy** (security, major - already fixed locally before review landed). The
   trimmed `.m4a` (a full copy of raw voice) was written to the shared temp dir without file
   protection during the write+verify window.

Minors: after the re-save the feed was not reloaded (the in-memory note kept un-remapped timings
against the shorter audio); a not-trimmed test used an arbitrary `Task.sleep`; and the safety branch
(verify-fails -> original survives) was untested from a valid source.

## Root cause

A destructive, non-reversible transform of a user artifact was built as "do the mutation in the
component that computes it", so it (a) owned the atomic replace itself instead of routing through the
store seam that already coordinates that file, and (b) re-persisted a stale snapshot from a deferred
task instead of re-reading the current record and applying only its delta.

## Fix

- `AudioTrimmer.trim` now PRODUCES and verifies a protected temp file and returns it (plus the removed
  ranges); it never touches the original.
- The coordinated atomic swap is a store seam, `NoteStoring.replaceAudio(from:for:)`: `NoteStore` uses
  `replaceItemAt`; `ICloudNoteStore` does `replaceItemAt` inside an `NSFileCoordinator` `.forReplacing`
  block. Both re-assert `completeUnlessOpen`.
- The temp file is created protected before `AVAudioFile` writes into it (mirrors `RecordingWriter`).
- `DictationViewModel.scheduleTrim` re-reads the note fresh by id, applies only the timings remap via
  `Note.withTimings`, skips if the note is gone, and calls `onTrimmed` so the host reloads the feed.
- New tests: strict-boundary (exactly at the min-pause floor), verify-failure-from-a-valid-source, and
  a concurrent-edit test proving a rename during the trim is preserved. The `Task.sleep` was replaced
  with an invocation await.

## Round 2 (independent re-review)

A second, independent persona pass (security approve; engineer + tester needs-changes) found a MAJOR
the round-1 self-review missed, plus four smaller items - all fixed in the same PR.

- **MAJOR (engineer + tester, independently): delete-mid-trim orphaned a raw-voice `.m4a`.** The
  round-1 fix re-read the note fresh but called `store.replaceAudio(...)` BEFORE confirming the note
  still existed. If the user soft-deleted the note (spec 0020 trash) during the trim window, its `.md`
  is hidden in `.trash`, so `audioURL(for:)` resolves to the (absent) root slot; `replaceAudio` then
  fell through to `saveAudio` and MOVED the trimmed temp to `root/<id>.m4a` - a full copy of the raw
  recording the user just deleted, invisible to `loadAll`, never cleared by `purgeAllTrash`. It
  defeated the delete (privacy + disk leak). Fixed at BOTH layers: (a) `scheduleTrim` re-reads and
  confirms the note EXISTS before `replaceAudio`, deleting the temp and bailing if gone (and skips the
  timings re-save when `replaceAudio` returns nil, so a delete that races the swap does not resurrect
  the note); (b) `replaceAudio` now returns `URL?` and NEVER creates a file when the slot is absent -
  it deletes the temp and returns nil. Regression: `testNoteSoftDeletedDuringTrimLeavesNoOrphanAudio`
  (verified to fail without either layer).
- **minor (tester): `replaceAudio` had no store-level test.** Added `NoteStore` + `ICloudNoteStore`
  tests (the coordinated `NSFileCoordinator .forReplacing` variant was the untested load-bearing part):
  swap-existing, replace-when-absent no-ops + consumes temp, and original-survives-a-failed-replace.
- **minor (tester): the frame-copy writer was only tested with one mid-clip silence.** Added
  end-to-end leading / trailing / back-to-back geometry tests against synthesized fixtures.
- **minor (security): temp leak on a mid-write failure.** `writeTrimmed` now `defer`s removal of the
  temp on every non-success exit, so a throw from open/copy/write never orphans a partial voice copy.
- **minor (engineer): an already-open `NoteDetailView` keeps un-remapped timings after the trim.**
  Harmless today (detail playback is whole-file), so left as-is with an explicit `onTrimmed` code
  comment that a future per-paragraph seek MUST revisit it.

## Learning

Folded into `overview/learnings.md` ("A non-reversible rewrite is verify-then-atomic-replace..."):
route a destructive swap through the seam that already coordinates the file; write sensitive
intermediates protected from byte zero; when a deferred task re-persists a record, re-read-and-delta
rather than re-save-a-snapshot; and a "replace" primitive over a slot that a DELETE can vacate must
refuse to create the slot (return "nothing to replace"), or the replace resurrects the deleted
artifact as an orphan - gate both the caller (existence recheck) and the primitive (no-create).
