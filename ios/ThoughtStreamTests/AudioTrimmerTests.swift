import XCTest
import AVFoundation
@testable import ThoughtStream

/// The AVFoundation rewrite service (spec 0019): reads an `.m4a`, computes RMS, trims via the pure
/// analyzer, verifies, and atomically replaces the original. Uses a synthesized `.m4a` with a known
/// long silence so the shorter-file + removed-range behavior is provable in the test bundle.
final class AudioTrimmerTests: XCTestCase {
    private let sampleRate = 44_100.0

    /// Write an `.m4a` at `url`: `leadSeconds` of tone, `silenceSeconds` of silence, `tailSeconds` of
    /// tone. Returns the total duration.
    @discardableResult
    private func writeClip(
        to url: URL,
        leadSeconds: Double,
        silenceSeconds: Double,
        tailSeconds: Double
    ) throws -> Double {
        let format = try XCTUnwrap(AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: 1,
            interleaved: false
        ))
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1,
        ]
        let file = try AVAudioFile(forWriting: url, settings: settings)

        func appendTone(seconds: Double, amplitude: Float) throws {
            guard seconds > 0 else { return }
            let frames = AVAudioFrameCount(seconds * sampleRate)
            let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames))
            buffer.frameLength = frames
            let channel = buffer.floatChannelData![0]
            for i in 0..<Int(frames) {
                // A 440Hz sine so loud sections have real energy; silence is exact zero.
                channel[i] = amplitude * sinf(2 * .pi * 440 * Float(i) / Float(sampleRate))
            }
            try file.write(from: buffer)
        }

        try appendTone(seconds: leadSeconds, amplitude: 0.5)
        try appendTone(seconds: silenceSeconds, amplitude: 0.0)
        try appendTone(seconds: tailSeconds, amplitude: 0.5)
        return leadSeconds + silenceSeconds + tailSeconds
    }

    private func duration(of url: URL) throws -> Double {
        let file = try AVAudioFile(forReading: url)
        return Double(file.length) / file.processingFormat.sampleRate
    }

    func testTrimsLongSilenceAndProducesShorterFile() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("trimtest-\(UUID().uuidString).m4a")
        defer { try? FileManager.default.removeItem(at: url) }

        // 1s tone, 4s silence, 1s tone -> 6s total. The 4s silence is well over the 2s min pause.
        let total = try writeClip(to: url, leadSeconds: 1, silenceSeconds: 4, tailSeconds: 1)
        let originalDuration = try duration(of: url)
        XCTAssertEqual(originalDuration, total, accuracy: 0.2)

        let trimmer = AudioTrimmer()
        let result = await trimmer.trim(fileAt: url)

        guard case .trimmed(let removed) = result else {
            return XCTFail("Expected a trim of the 4s silence, got \(result)")
        }
        // Something was removed, and only from the silent middle (roughly [1.3, 4.7) with a 0.6s gap).
        XCTAssertFalse(removed.isEmpty)
        let removedTotal = removed.reduce(0) { $0 + $1.duration }
        // ~3.4s removed (4s silence minus the 0.6s kept breath gap), allow slack for window rounding.
        XCTAssertEqual(removedTotal, 3.4, accuracy: 0.4)

        // The rewritten file is shorter than the original by about the removed amount.
        let newDuration = try duration(of: url)
        XCTAssertLessThan(newDuration, originalDuration - 2.0)
        // And it is still a valid, non-empty audio file.
        XCTAssertGreaterThan(newDuration, 0)
    }

    func testNoLongSilenceLeavesFileUntouched() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("trimtest-\(UUID().uuidString).m4a")
        defer { try? FileManager.default.removeItem(at: url) }

        // 2s of continuous tone, no pause worth trimming.
        try writeClip(to: url, leadSeconds: 2, silenceSeconds: 0, tailSeconds: 0)
        let before = try Data(contentsOf: url)

        let result = await AudioTrimmer().trim(fileAt: url)
        XCTAssertEqual(result, .notTrimmed)

        // The file is byte-for-byte unchanged (no code path rewrote it).
        let after = try Data(contentsOf: url)
        XCTAssertEqual(before, after)
    }

    func testUnreadableFileReturnsNotTrimmed() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("missing-\(UUID().uuidString).m4a")
        let result = await AudioTrimmer().trim(fileAt: url)
        XCTAssertEqual(result, .notTrimmed)
    }
}
