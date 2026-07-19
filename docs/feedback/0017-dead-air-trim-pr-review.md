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

## Learning

Folded into `overview/learnings.md` ("A non-reversible rewrite is verify-then-atomic-replace..."):
route a destructive swap through the seam that already coordinates the file; write sensitive
intermediates protected from byte zero; and when a deferred task re-persists a record, re-read-and-
delta rather than re-save-a-snapshot.
