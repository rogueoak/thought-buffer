import XCTest
import AVFoundation
@testable import ThoughtBuffer

/// The AVFoundation concatenation service (feedback 0022): reads a thought's existing `.m4a` plus a
/// freshly-recorded segment, writes ONE combined file, and reports the existing recording's duration for
/// the timing offset. Uses synthesized `.m4a` fixtures so the combined-length + fallback behavior is
/// provable in the test bundle, without live capture.
final class AudioConcatenatorTests: XCTestCase {
    private let sampleRate = 44_100.0

    /// Write `seconds` of 440Hz tone as an `.m4a` at `url`. Returns the requested duration.
    @discardableResult
    private func writeTone(to url: URL, seconds: Double, channels: AVAudioChannelCount = 1) throws -> Double {
        let format = try XCTUnwrap(AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: channels, interleaved: false))
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: sampleRate, AVNumberOfChannelsKey: channels]
        let file = try AVAudioFile(forWriting: url, settings: settings)
        let frames = AVAudioFrameCount(seconds * sampleRate)
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames))
        buffer.frameLength = frames
        for channel in 0..<Int(channels) {
            let data = buffer.floatChannelData![channel]
            for i in 0..<Int(frames) {
                data[i] = 0.5 * sinf(2 * .pi * 440 * Float(i) / Float(sampleRate))
            }
        }
        try file.write(from: buffer)
        return seconds
    }

    private func duration(of url: URL) throws -> Double {
        let file = try AVAudioFile(forReading: url)
        return Double(file.length) / file.processingFormat.sampleRate
    }

    private func tempURL() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("concat-\(UUID().uuidString).m4a")
    }

    func testConcatenatesExistingPlusNewIntoOneLongerFile() async throws {
        let existing = tempURL(); let new = tempURL()
        defer { try? FileManager.default.removeItem(at: existing); try? FileManager.default.removeItem(at: new) }
        try writeTone(to: existing, seconds: 3.0)
        try writeTone(to: new, seconds: 2.0)
        let existingBytes = try Data(contentsOf: existing)
        let newBytes = try Data(contentsOf: new)

        let result = await AudioConcatenator().concatenate(existing: existing, new: new)
        guard case .concatenated(let combinedURL, let existingDuration) = result else {
            return XCTFail("expected a concatenation, got \(result)")
        }
        defer { try? FileManager.default.removeItem(at: combinedURL) }

        // The combined file is about existing + new long, and valid.
        let combinedDuration = try duration(of: combinedURL)
        XCTAssertEqual(combinedDuration, 5.0, accuracy: 0.3, "combined = existing + new")
        XCTAssertGreaterThan(combinedDuration, 0)
        // The reported existing-duration (used to offset the new timings) matches the original.
        XCTAssertEqual(existingDuration, 3.0, accuracy: 0.2)

        // BOTH inputs are untouched - the concatenator never replaces them (the store's coordinated seam does).
        XCTAssertEqual(try Data(contentsOf: existing), existingBytes)
        XCTAssertEqual(try Data(contentsOf: new), newBytes)
    }

    func testEmptyNewSegmentDoesNotProduceAFile() async throws {
        // The user resumed but said nothing: the new segment is a zero-length (missing) file. There is
        // nothing to append, so no combined file is produced and the caller keeps the original untouched.
        let existing = tempURL()
        defer { try? FileManager.default.removeItem(at: existing) }
        try writeTone(to: existing, seconds: 2.0)
        let missingNew = tempURL() // never written

        let result = await AudioConcatenator().concatenate(existing: existing, new: missingNew)
        XCTAssertEqual(result, .notConcatenated, "an empty/missing new segment cannot corrupt the original")
    }

    func testUnreadableExistingReturnsNotConcatenated() async throws {
        let new = tempURL()
        defer { try? FileManager.default.removeItem(at: new) }
        try writeTone(to: new, seconds: 1.0)
        let missingExisting = tempURL()

        let result = await AudioConcatenator().concatenate(existing: missingExisting, new: new)
        XCTAssertEqual(result, .notConcatenated)
    }

    func testMismatchedFormatFallsBackSafely() async throws {
        // A mono existing and a stereo new segment cannot be joined in one format; rather than write a
        // garbled file, the concatenator falls back so the caller keeps the original recording.
        let existing = tempURL(); let new = tempURL()
        defer { try? FileManager.default.removeItem(at: existing); try? FileManager.default.removeItem(at: new) }
        try writeTone(to: existing, seconds: 2.0, channels: 1)
        try writeTone(to: new, seconds: 2.0, channels: 2)
        let existingBytes = try Data(contentsOf: existing)

        let result = await AudioConcatenator().concatenate(existing: existing, new: new)
        XCTAssertEqual(result, .notConcatenated)
        XCTAssertEqual(try Data(contentsOf: existing), existingBytes, "the original is left intact")
    }

    func testVerifyFailureFromValidInputsLeavesInputsIntact() async throws {
        // A concatenator whose output verification always fails must return `.notConcatenated`, write no
        // adopted output, and leave both inputs intact - the branch that protects a real recording.
        let existing = tempURL(); let new = tempURL()
        defer { try? FileManager.default.removeItem(at: existing); try? FileManager.default.removeItem(at: new) }
        try writeTone(to: existing, seconds: 2.0)
        try writeTone(to: new, seconds: 1.0)
        let existingBytes = try Data(contentsOf: existing)
        let newBytes = try Data(contentsOf: new)

        let result = await AudioConcatenator(validateOutput: { _ in false })
            .concatenate(existing: existing, new: new)
        XCTAssertEqual(result, .notConcatenated)
        XCTAssertEqual(try Data(contentsOf: existing), existingBytes)
        XCTAssertEqual(try Data(contentsOf: new), newBytes)
    }
}
