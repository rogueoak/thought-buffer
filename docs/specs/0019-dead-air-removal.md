# Spec 0019 - Automatic dead-air removal from recordings

## Motivation

Device feedback from Matthew (2026-07-19):

> For the recording itself, can we do automatic (configurable) post processing to
> remove the dead air time? Periods of long pauses should just be cut out.

Spoken notes accumulate long silences (thinking pauses). Trimming them makes
playback tighter and files smaller, without changing the words.

## Product decisions (confirmed by Matthew 2026-07-19)

- **Replace the original**: trimming REPLACES the recording (non-reversible).
  Smaller files; the removed silence is not retained. There is no kept original.
- **Default ON**, cut silences longer than **2.0 s**. Trimming NEVER produces a
  hard cut: every trimmed silence keeps a short "breath" gap (default ~0.6 s, a
  named constant) so the result still sounds like natural speech, not spliced.
  The threshold is configurable in Settings; the retained breath gap is a tunable
  constant.
- **Retroactive**: apply only to NEW recordings on save. A future manual "tidy
  audio" action for existing notes is out of scope here.

Because the trim is non-reversible, the rewrite MUST be safe: write the trimmed
file to a temp location, verify it is valid and non-empty, and only then atomically
replace the original. Any failure leaves the original recording untouched.

## Scope

1. **Silence detection + trim (pure core).** A pure, unit-testable analyzer that,
   given a sequence of frame RMS levels (or amplitude windows) and a sample rate,
   returns the time ranges to KEEP (i.e. the complement of silences longer than the
   threshold, each trimmed to leave a short natural gap). No AVFoundation in the
   pure type - it operates on numbers so it is fully testable. Parameters
   (silence RMS floor, minimum-pause duration, retained-gap duration) are named
   constants / config.

2. **Audio rewrite.** A service reads the finished recording (.m4a), applies the
   keep-ranges (AVAssetExportSession with a composition, or AVAudioFile
   read/write), and writes the trimmed file. Runs after recording finishes, at/
   around save, off the main actor; failure falls back to keeping the original
   untrimmed (never lose the recording).

   LOAD-BEARING INVARIANT (from feedback 0012 review): the minimum-pause trim
   threshold (2.0 s) MUST stay strictly ABOVE the paragraph gap threshold
   (`ParagraphGrouper.defaultGapThreshold`, 1.5 s). That guarantees any silence long
   enough to trim is always a PARAGRAPH BOUNDARY, never an interior sub-threshold
   silence inside a merged paragraph - so trimming only ever removes time BETWEEN
   paragraphs and the merged `[start, duration]` timings stay remappable by shifting
   paragraph starts. Add a guard test asserting `trimThreshold > groupThreshold`; if
   a future device pass lowers the trim threshold below the group threshold, the
   merged-timing model must first be revisited (retain per-segment sub-ranges).

3. **Timing remap (critical).** Paragraph `ParagraphTiming`s reference ABSOLUTE
   recording time. After trimming, every timing's start/duration must be re-mapped
   onto the compressed timeline (subtract the total removed-silence duration that
   preceded/overlapped it) so playback seeking still lands on the right words. This
   is a pure function over (original timings, removed ranges) and MUST be unit
   tested. Coordinate with the paragraph-timing model established in feedback 0012
   (flow grouping) - build on top of it, do not fork it.

4. **Settings.** Add `trimSilence: Bool` (default ON) and, if simple, a threshold
   choice, to `SettingsStoring` + `SettingsView` ("Trim silences", subtitle: cuts
   long pauses from recordings; text is unaffected). Gated so OFF preserves today's
   behavior exactly.

## Non-goals

- No noise reduction, leveling, or other audio effects - only silence trimming.
- No waveform re-render changes beyond what shorter audio implies.
- No cloud processing (fully on-device).

## Acceptance

- With trim ON, a recording with a long mid pause plays back with the pause cut to
  a short gap; the trimmed file is shorter; the words are unchanged.
- Paragraph timings still seek correctly after trimming (unit-tested remap across:
  silence before a paragraph, between paragraphs, none, and back-to-back silences).
- With trim OFF, recordings are byte-for-byte the untrimmed capture (no code path
  touches the file).
- Trim failure keeps the original recording and the note still saves.
- Silence-detection and timing-remap cores are pure and unit-tested; suite green.
