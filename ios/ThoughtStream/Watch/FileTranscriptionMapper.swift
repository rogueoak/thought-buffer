import Foundation

/// One decoded segment from a FILE-based transcription of a watch recording (spec 0023): a piece of
/// recognized text plus its time range in the audio file, in seconds from the start. This is the
/// coordinate the recognizer reports directly for a file (an `SFTranscriptionSegment` or a
/// `SpeechTranscriber.Result` range over the whole file), independent of any live-capture analysis
/// restart - a file has ONE continuous timeline, so there is no offset/resume seam to anchor across.
struct TranscribedSegment: Equatable {
    let text: String
    /// Seconds from the start of the recording to where this segment begins.
    let startSeconds: Double
    /// The segment's length in seconds.
    let durationSeconds: Double

    init(text: String, startSeconds: Double, durationSeconds: Double) {
        self.text = text
        self.startSeconds = startSeconds
        self.durationSeconds = durationSeconds
    }
}

/// Maps decoded file-transcription segments to the app's paragraph + timing model (spec 0023). This is
/// the file-based analogue of the LIVE-capture path in `DictationViewModel.handleFinalized`: the live
/// path groups finalized segments into paragraphs by silence gap and anchors each range to absolute
/// recording time across analysis restarts; a FILE has one continuous timeline and every segment at
/// once, so the mapping is a single pure pass with no offset, no analysis-start seam, and no live-partial.
///
/// It reuses the SAME two pure seams the live path uses, so the two agree on paragraph shape:
/// - `ParagraphGrouper` decides, per segment, flow-vs-break by the silence gap between consecutive
///   segments (default 1.5s), so a mid-thought breath stays in one paragraph and a real pause breaks -
///   exactly like dictation.
/// - `ParagraphTiming.merged` combines the ranges of segments that flow into one paragraph, so a
///   merged paragraph's stored range spans first-start through last-end (per-paragraph playback works).
///
/// Pure and free of Speech/AVFoundation, so the whole mapping is unit-testable with plain segment
/// values - no live mic, no real watch, no file. The phone's file-transcription engine (SpeechAnalyzer
/// over the file, or an `SFSpeechURLRecognitionRequest` fallback) is the thin, device-verified caller
/// that decodes the recognizer's segments into `[TranscribedSegment]` and hands them here.
enum FileTranscriptionMapper {
    /// The result of mapping a file transcription: paragraphs and their per-paragraph timings, aligned
    /// 1:1 (every paragraph has exactly one timing, spanning its merged segments), so it drops straight
    /// into `Thought(paragraphs:timings:)`.
    struct Mapping: Equatable {
        let paragraphs: [String]
        let timings: [ParagraphTiming]

        init(paragraphs: [String], timings: [ParagraphTiming]) {
            self.paragraphs = paragraphs
            self.timings = timings
        }

        /// A mapping with no recognized text (an empty or non-speech recording), so the caller files an
        /// audio-only thought.
        static let empty = Mapping(paragraphs: [], timings: [])
    }

    /// Group segments into paragraphs by silence gap and build one merged timing per paragraph. Segments
    /// whose text is empty/whitespace are skipped (they carry no words). A file has one timeline, so
    /// `isAnalysisStart` is true only for the FIRST kept segment (there is no resume seam mid-file), and
    /// the timing offset is zero (the segment seconds ARE the file seconds).
    static func map(
        segments: [TranscribedSegment],
        gapThreshold: Double = ParagraphGrouper.defaultGapThreshold
    ) -> Mapping {
        var grouper = ParagraphGrouper(gapThreshold: gapThreshold)
        var paragraphs: [String] = []
        var timings: [ParagraphTiming] = []
        var isFirst = true

        for segment in segments {
            let text = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }

            let decision = grouper.decide(
                startSeconds: segment.startSeconds,
                durationSeconds: segment.durationSeconds,
                isAnalysisStart: isFirst
            )
            isFirst = false

            // The segment's own range in the file (offset 0: file seconds are absolute recording time).
            let range = timing(for: segment)

            switch decision {
            case .newParagraph:
                paragraphs.append(text)
                timings.append(range ?? ParagraphTiming(start: 0, duration: 0))
            case .appendToCurrent:
                guard let last = paragraphs.indices.last else {
                    // Defensive: the grouper forces `.newParagraph` for the first segment, so this is
                    // unreachable; treat a stray append as a new paragraph rather than dropping text.
                    paragraphs.append(text)
                    timings.append(range ?? ParagraphTiming(start: 0, duration: 0))
                    continue
                }
                paragraphs[last] = paragraphs[last] + " " + text
                timings[last] = ParagraphTiming.merged(timings[last], range) ?? timings[last]
            }
        }

        return Mapping(paragraphs: paragraphs, timings: timings)
    }

    /// The absolute range for a file segment: its start/duration are already file-relative, so this is a
    /// zero-offset `RecordingTiming.absolute` (nil for a degenerate, all-zero, or non-finite range, so a
    /// segment with no real timing falls back to a zero-length placeholder above).
    private static func timing(for segment: TranscribedSegment) -> ParagraphTiming? {
        guard segment.startSeconds.isFinite, segment.durationSeconds.isFinite,
              segment.durationSeconds > 0 else {
            return nil
        }
        return RecordingTiming.absolute(
            offset: 0,
            relative: (start: segment.startSeconds, duration: segment.durationSeconds)
        )
    }
}
