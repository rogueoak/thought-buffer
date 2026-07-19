import Foundation

/// The pure, SwiftUI-free playback-progress math for the bottom player and the Now Playing scrubber
/// (spec 0027). Kept here (no AVFoundation, no MediaPlayer, no controller) so the clamp, the progress
/// fraction, and the elapsed/remaining time labels are unit-tested without real audio.
///
/// The clamp is the SAME rule `SystemAudioThoughtPlayer.clampedSeekTime` applies at the player, expressed
/// once so a seek/skip target and the player's own clamp cannot drift; the time labels delegate to
/// `Thought.durationLabel`, the app's single duration formatter (0:00, 0:09, 1:24, hour rollover).
enum PlaybackProgress {
    /// Clamp a seek/skip target `time` into the playable window `[0, duration]`: a skip-forward past the
    /// end pins to `duration`, a skip-back below 0 pins to 0. A non-finite or non-positive `duration`
    /// clamps to 0 (nothing to seek into), so a slipped timing never produces an out-of-range target.
    static func clamp(_ time: Double, duration: Double) -> Double {
        guard duration.isFinite, duration > 0 else { return 0 }
        return max(0, min(time, duration))
    }

    /// The progress fraction in `[0, 1]` for a slider / progress bar: `elapsed / duration`, clamped so a
    /// slightly-over elapsed never exceeds 1 and a non-positive duration reads 0 (an empty bar, not NaN).
    static func fraction(elapsed: Double, duration: Double) -> Double {
        guard duration.isFinite, duration > 0 else { return 0 }
        return max(0, min(elapsed / duration, 1))
    }

    /// The elapsed-time label ("0:00", "1:24", "1:02:03" past an hour) for the left of the progress bar.
    /// Delegates to the app's single duration formatter so it cannot drift from the card / detail stats.
    static func elapsedLabel(_ elapsed: Double) -> String {
        Thought.durationLabel(elapsed)
    }

    /// The remaining-time label as a countdown ("-1:15") for the right of the progress bar: the time left
    /// until the end, formatted like the elapsed label with a leading minus. At or past the end it reads
    /// "-0:00" (never a positive or garbage value).
    static func remainingLabel(elapsed: Double, duration: Double) -> String {
        let remaining = max(0, duration - elapsed)
        return "-" + Thought.durationLabel(remaining)
    }
}
