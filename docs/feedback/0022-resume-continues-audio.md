# Feedback 0022 - Resume continues the audio recording, not text-only

## Source

Device feedback from Matthew (2026-07-19):

> When I resume a recording from within a thought, it is adding more text but it isn't continuing
> with the audio recording.

## Symptom

Resuming a thought that ALREADY had a recording appended only TEXT: the newly spoken words became
paragraphs, but no new audio was captured or attached. The resumed thought kept exactly its original
`.m4a`, so playing it back never included anything said after the resume - the recording did not
continue.

## Root cause

Two decisions, made together, made a has-audio resume text-only:

1. `StreamListView`'s resume cover passed `recordsAudio: !thought.hasAudio &&
   settingsStore.audioRetention.recordsAudio`. The `!thought.hasAudio` term forced `recordsAudio` to
   FALSE for any thought that already had a recording, so the capture session never armed its file
   writer - no new audio was recorded at all. It also nil'd the `audioTrimmer` for a has-audio thought.
2. `DictationViewModel` was built (feedback 0008) on the assumption that "a resumed session records no
   new audio": appended paragraphs were text-only, and only the pre-existing paragraphs' timings were
   preserved. There was no path to record a new segment and join it onto the existing recording.

So even if `recordsAudio` had been true, the model's save path would have OVERWRITTEN the thought's
`.m4a` with just the new segment (via `saveAudio`), losing the original.

This SUPERSEDES the feedback-0008 choice "a resumed session records no new audio" - that was a
simplification, not the desired behavior. Resuming should CONTINUE the recording.

## Fix

Resuming a thought that already has audio, with audio retention on, now RECORDS a new segment and
CONCATENATES it onto the thought's existing `.m4a` so the recording continues as ONE file, with the
new paragraphs' timings offset past the original so playback seeks correctly across the seam.

- **Record on resume.** `StreamListView` now passes `recordsAudio:
  settingsStore.audioRetention.recordsAudio` for the resume cover, regardless of `thought.hasAudio`,
  and passes an `AudioConcatenator` when the thought already has audio and the policy records audio.
- **Concatenate safely (`AudioConcatenator`, `AudioConcatenating` seam).** A thin AVFoundation type
  (mirroring `AudioTrimmer`) reads the existing `.m4a` and the new segment `.m4a`, writes ONE combined
  AAC file to a PROTECTED temp URL (`completeUnlessOpen`, defer-cleaned on any mid-write failure),
  verifies it is a valid non-empty audio file, and reports the existing recording's measured duration.
  It NEVER touches either input; the caller adopts the verified temp through the store's COORDINATED
  `replaceAudio` seam (so an iCloud swap goes through `NSFileCoordinator`, never a bare replace).
- **Offset timings (pure `RecordingTiming.offsetResumedTimings`).** The newly-recorded paragraphs are
  timed relative to the NEW segment's start; after the join they actually begin `existingDuration`
  seconds into the combined file. This pure, count-preserving function shifts only the new paragraphs
  (index `>= existingParagraphCount`) right by the measured existing-duration; pre-existing timings are
  untouched, and a zero-length text-only placeholder is left in place (shifting it would fabricate a
  position). Unit-tested against the pure math.
- **Off-main, non-blocking.** `DictationViewModel.finish()` returns immediately with the FALLBACK
  thought (original recording kept, new paragraphs text-only), then schedules a detached
  concatenation - the same shape as spec 0019's background trim. On success it swaps the combined audio
  through `replaceAudio`, re-saves the FRESH thought with the offset timings (preserving a concurrent
  edit; only when the paragraph count still aligns 1:1), and reloads the feed via the shared `onTrimmed`
  hook. The thought is re-read fresh and confirmed to still exist before any audio swap, so a
  soft-delete/move during the join never orphans a raw-voice copy.

## Dead-air trim interaction (spec 0019)

The ORIGINAL recording was already trimmed on its FIRST save, so it must NOT be re-trimmed. Only the
NEW segment is trimmed (when "Trim silences" is on) - inside the concatenation task, before the join.
The offset then anchors the new paragraphs after the (unchanged) original. A fresh session and a
resume onto a TEXT-ONLY thought (spec 0013) still trim the whole newly-adopted recording as before.

## Failure fallback (never lose the original)

Every failure keeps the pre-0022 behavior exactly: the ORIGINAL recording is preserved and the new
paragraphs are saved text-only (they play back via text-to-speech). This is also the SYNCHRONOUS result
of `finish()` - the concatenation is a background UPGRADE, not a precondition. Concatenation returns
`.notConcatenated` (so the fallback stands) when: an input is unreadable, the new segment is empty (the
user resumed but said nothing - it cannot corrupt the original), the two files' formats are
incompatible, or the output fails verification. A soft-delete/move that races the swap makes
`replaceAudio` return nil (it creates no orphan), and the task bails without resurrecting the thought.

## Acceptance

- Resuming a thought with audio + retention on records a new segment, concatenates it onto the
  existing `.m4a`, and the new paragraphs' timings are offset past the original (device-verify + a
  seam-level test).
- Pre-existing paragraphs keep their original timings; the concatenated file is one continuous
  recording (pure offset test + store-seam test).
- Concatenation failure keeps the original recording and text (no data loss) - tested.
- An empty new segment does not corrupt the existing recording - tested.
- Only the new segment is trimmed; the original is never re-trimmed - documented + wired.
- Audio retention OFF stays a text-only append; a text-only thought resuming records a fresh recording
  (spec 0013) - unchanged, tested.
- Full suite green (iPhone 17), no new build warnings.

## Learning

See `overview/learnings.md` - "A resume over a continuous artifact must CONTINUE it, not restart or
append beside it (feedback 0022)".
