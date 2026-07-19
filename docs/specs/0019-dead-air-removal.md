# Spec 0019 - Automatic dead-air removal from recordings

## Motivation

Device feedback from Matthew (2026-07-19):

> For the recording itself, can we do automatic (configurable) post processing to
> remove the dead air time? Periods of long pauses should just be cut out.

Spoken notes accumulate long silences (thinking pauses). Trimming them makes
playback tighter and files smaller, without changing the words.

## Open product decisions (confirm before build)

- **Destructive vs. keep-original**: does trimming REPLACE the recording, or keep
  the original and store a trimmed copy? (Storage vs. reversibility.) DEFAULT
  assumed here: replace on save, non-reversible - matches "post processing".
- **Default state + threshold**: "automatic (configurable)" implies default ON.
  DEFAULT assumed: cut silences longer than 2.0 s down to a 0.5 s natural gap.
- **Retroactive**: apply only to NEW recordings on save (assumed), with a possible
  future manual "tidy audio" action for existing notes (out of scope here).

This spec is written against those defaults; adjust after confirmation.

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
