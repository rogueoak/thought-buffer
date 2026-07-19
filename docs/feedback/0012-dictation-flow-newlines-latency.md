# Feedback 0012 - Dictation flow: over-eager newlines and perceived latency

## Source

Device feedback from Matthew (2026-07-19), after the swipe-to-play milestone:

> I noticed there is a large delay in seeing text appear while you speak. And we
> are inserting more new lines than I would expect. I used the native speech to
> text in the notes app and it was more smooth.

## Observations

Two distinct problems, one shared root in how finalized results become paragraphs.

### 1. Too many newlines (primary)

Today the capture path treats **every finalized `SpeechTranscriber.Result` as its
own paragraph**. `SpeechAnalyzerService.handle(result:)` emits one
`.finalizedSegment` per `result.isFinal`, and `DictationViewModel.commitParagraph`
appends each as a new array element, joined with blank lines on save
(`Note.bodyMarkdown` uses `"\n\n"`).

The iOS 26 transcriber finalizes on **short** pauses (a breath mid-thought), so a
single spoken sentence that spans a pause is split into two paragraphs. The native
Notes app keeps text flowing and only breaks on longer silences. That difference
is the whole complaint - and it is also why single sentences "get split across
lines" (see spec 0016, which builds on this fix).

### 2. Perceived latency (secondary)

The app itself adds **no** buffering, throttle, or wait-for-finalization: volatile
results emit straight to `@Published` state (`emit` -> `onEvent` -> view model).
The likely contributors are:

- Microphone tap buffer size (4096 frames ~= 256 ms at 16 kHz).
- The transcriber's own volatile-result cadence (on-device, Apple-managed).

This one cannot be fully diagnosed or tuned from a simulator; it needs a device
pass. The newline fix also helps the *perception* of smoothness because text stops
jumping to a new line on every micro-pause.

## Fix

### Flowing, Notes-style paragraph breaks (decision: "flowing, like Notes")

Introduce a pure, unit-testable `ParagraphGrouper` that decides, per finalized
segment, whether to **append to the current paragraph** or **start a new one**,
based on the silence gap between the previous segment's end and the new segment's
start (from the transcriber `CMTimeRange`, which is present even for text-only
sessions because it is relative to analysis start, independent of audio teeing).

- Gap `< threshold` (default ~1.5 s): same paragraph, joined with a single space.
- Gap `>= threshold`: new paragraph.
- The threshold is a single named constant so it is easy to tune on device.
- Cross-pause/resume seam: a resume starts a fresh analysis (range resets to ~0);
  treat the first segment after a resume as a paragraph boundary (do not compute a
  bogus gap across the seam).

Timings stay aligned: when segments merge into one paragraph, their ranges merge
into one `ParagraphTiming` (start of first, through end of last) so playback and
the timing invariant (`timings.count <= paragraphs.count`) still hold.

### Latency

- Add lightweight opt-in instrumentation (timestamp each partial/final) so the
  device pass can measure real cadence.
- Evaluate a smaller tap buffer as a safe lever; keep it a named constant.
- Explicitly defer final tuning to a device session; document the result here.

## Acceptance

- A sentence spoken with a mid-thought breath lands in ONE paragraph, not two.
- Distinct thoughts separated by a clear pause still break into separate
  paragraphs.
- Paragraph timings remain aligned with merged paragraphs; playback still seeks
  correctly.
- Pure grouper is unit-tested across: no-gap merge, large-gap break, resume-seam
  boundary, text-only (no recording) sessions, and empty/whitespace segments.
- No regression in the existing dictation, Mira-command, and dual-capture tests.

## Out of scope (tracked in spec 0016)

Filler-word removal, the "delete the last line" command, and the auto-clean
setting. This doc is only the paragraph-flow and latency fix.
