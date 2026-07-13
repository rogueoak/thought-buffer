import XCTest
import AVFoundation
@testable import ThoughtStream

/// The tee'd audio writer (spec 0007): injecting PCM buffers writes a file and tracks elapsed audio
/// time. Uses synthesized buffers so it does not depend on a real mic.
final class RecordingWriterTests: XCTestCase {

    private let sampleRate = 44_100.0

    func testAppendWritesFileAndTracksElapsed() throws {
        let writer = RecordingWriter()
        defer { writer.discard() }

        XCTAssertFalse(writer.hasContent)
        XCTAssertEqual(writer.elapsedSeconds, 0)

        // Append one second of audio in two half-second buffers.
        writer.append(try makeBuffer(seconds: 0.5))
        writer.append(try makeBuffer(seconds: 0.5))
        writer.finish()

        XCTAssertTrue(writer.hasContent)
        // Elapsed tracks written frames / sample rate: about one second.
        XCTAssertEqual(writer.elapsedSeconds, 1.0, accuracy: 0.05)
        XCTAssertTrue(FileManager.default.fileExists(atPath: writer.url.path))
        // The file is a real, non-empty AAC recording.
        let size = try FileManager.default.attributesOfItem(atPath: writer.url.path)[.size] as? Int ?? 0
        XCTAssertGreaterThan(size, 0)
    }

    func testDiscardRemovesFile() throws {
        let writer = RecordingWriter()
        writer.append(try makeBuffer(seconds: 0.25))
        writer.finish()
        XCTAssertTrue(FileManager.default.fileExists(atPath: writer.url.path))
        writer.discard()
        XCTAssertFalse(FileManager.default.fileExists(atPath: writer.url.path))
    }

    func testEmptyWriterHasNoContent() {
        let writer = RecordingWriter()
        defer { writer.discard() }
        writer.finish()
        XCTAssertFalse(writer.hasContent)
    }

    /// Build a buffer of `seconds` of silence at the writer's expected format.
    private func makeBuffer(seconds: Double) throws -> AVAudioPCMBuffer {
        let format = try XCTUnwrap(AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: 1,
            interleaved: false
        ))
        let frames = AVAudioFrameCount(seconds * sampleRate)
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames))
        buffer.frameLength = frames
        // Leave the samples at zero (silence); the writer only cares about frame counts and bytes.
        return buffer
    }
}
