# 0026 - Capture pipeline: transcription quality and dead-air trim removal

Two device-reported problems with the capture pipeline, fixed together because both live in the
speech/recording path.

## Symptom

1. **Transcription regressed.** "Text to speech regressed. Now it is really really bad. Is there any
   way we can make it actually good?" (Dictation / speech-to-text, not TTS.) On device the saved text
   read poorly.
2. **Dead-air trim was not worth it.** "Dead space editing is not working well just cut that feature.
   It's not important." The automatic silence-trimming of recordings (spec 0019) misbehaved.

## Root cause

### Concern 1 - transcription quality

- **Audio session mode.** `configureSession()` set `AVAudioSession` mode to `.measurement`, which
  DISABLES the input signal conditioning (automatic gain, noise reduction, echo cancellation) that
  speech recognition relies on. `.measurement` is for level metering, not dictation. Apple's dictation
  guidance is `.spokenAudio`. Feeding the recognizer unconditioned input degrades the transcription.
- **Transcription options - the assumption did not hold.** A prior investigation guessed that
  `SpeechTranscriber(transcriptionOptions: [])` stripped punctuation and readable formatting, gated
  behind options that needed populating. VERIFIED against the installed iOS 26.5 SDK
  (`Speech.swiftinterface` and the framework headers): this is FALSE for `SpeechTranscriber`. Its
  `TranscriptionOption` enum has exactly ONE case - `etiquetteReplacements`. The `punctuation` / `emoji`
  cases exist only on the SEPARATE `DictationTranscriber.TranscriptionOption`, and `addsPunctuation` is
  a property of the LEGACY `SFSpeechRecognitionRequest`. `SpeechTranscriber` punctuates and formats
  NATIVELY from its language model; `[]` was not the cause of bare output. So the highest-leverage fix
  was the session mode, not a punctuation option.
- **Refinement layer.** The default-on filler removal (`FillerRemovalProcessor`) and pause-based
  paragraph grouping (`ParagraphGrouper`, 1.5s gap) were reviewed for non-destructiveness. They were
  already conservative: filler removal is whole-token, case-insensitive, excludes units/interjections
  and quoted spans; grouping breaks on a real silence gap. No damage found; they were pinned with tests
  rather than changed.

### Concern 2 - dead-air trim (spec 0019)

The feature trimmed long silences from a finished recording and remapped paragraph timings. In practice
the edited playback was poor and the feature carried real complexity (an `AudioTrimmer` seam, the pure
`SilenceTrimmer` + `TimingRemapper`, a `trimSilence` setting, a coordinated `replaceAudio` swap, and a
per-new-segment trim inside the resume-concatenation path). The user asked to cut it.

## Fix

### Concern 1

- `SpeechAnalyzerService.configureSession()`: mode `.measurement` -> `.spokenAudio` (keeping
  `.duckOthers`). This is the single highest-leverage transcription fix.
- `SpeechAnalyzerService.makeTranscriber()`: `transcriptionOptions: []` ->
  `[.etiquetteReplacements]` - the only option `SpeechTranscriber` exposes in this SDK - with a comment
  recording the SDK verification and the punctuation-is-native finding.
- Audited the refinement layer and PINNED "good output" with `CapturePipelineRefinementTests`:
  representative multi-sentence transcripts with fillers, numbers, units, punctuation, quotes, and a
  natural pause, asserting the refined text is clean and faithful (punctuation preserved, real
  words/units not eaten, fillers struck only when genuine, paragraphing sensible). The 1.5s grouper
  threshold was kept (it still reads like Notes with punctuation present) and its now-obsolete coupling
  comment (it used to have to stay below the 2.0s trim floor) was updated for the trim removal.

### Concern 2

- Deleted the trim source: `AudioTrimmer.swift`, `SilenceTrimmer.swift`, `TimingRemapper.swift`, and
  their tests (`AudioTrimmerTests`, `SilenceTrimmerTests`, `TimingRemapperTests`, `DeadAirTrimViewModelTests`).
- Removed the trim from the recording/save path: `DictationViewModel` lost its `audioTrimmer` seam,
  `scheduleTrim`, `remapNewParagraphsOntoSegment`, and the `didAdoptNewRecording` gate; the resume
  concatenation (feedback 0022) now joins the new segment AS CAPTURED (no per-segment trim + remap).
- Removed the setting: `SettingsStoring.trimSilence` and the `trimSilenceSection` toggle in
  `SettingsView`. The `settings.trimSilence` UserDefaults KEY is left untouched in storage (no longer
  read or written) so an old stored value cannot crash on read - it is simply an ignored orphan.
- `StreamListView.makeAudioTrimmer()` and the `audioTrimmer:` wiring are gone.
- KEPT `ThoughtStoring.replaceAudio` (the coordinated atomic swap) and `Thought.withTimings`: both are
  still used by the resume-continues-audio concatenation (feedback 0022), which is a SEPARATE feature.
  Their docs were re-pointed from spec 0019 to feedback 0022.
- Regenerated the Xcode project (files were added and removed).

## Learning

When an investigation hands you a "root cause" that names a specific API case, VERIFY the case exists on
the exact type you use before building the fix on it - sibling types in the same framework
(`SpeechTranscriber` vs `DictationTranscriber`) can carry different option enums, and an old API's flag
(`SFSpeechRecognitionRequest.addsPunctuation`) does not carry to its replacement. Here the confidently
asserted "populate `transcriptionOptions` for punctuation" was wrong for `SpeechTranscriber` (punctuation
is native), and only the SDK `.swiftinterface` said so. The real win was the session mode. Also: a
DEVICE-only quality path (real transcription does not run in the Simulator) still deserves a CI gate on
its pure, testable half - here the refinement layer - so "good output" is pinned even though the raw
recognition quality can only be judged on hardware.

## Device-verify (cannot be checked in the Simulator)

- Real on-device transcription quality with `.spokenAudio` + `[.etiquetteReplacements]` (the Simulator
  does not run real recognition). The punctuation improvement in particular is device-only. If output is
  still poor on hardware, this is where to look next.
