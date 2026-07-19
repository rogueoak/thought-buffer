import Foundation
import AVFoundation
import Combine
#if canImport(WatchKit)
import WatchKit
#endif

/// Records a voice capture on the watch to a compressed `.m4a` (spec 0023). The watch does NOT transcribe -
/// it captures audio and hands the finished file to `WatchConnectivityManager` for transfer to the phone,
/// which transcribes and files it. Uses `AVAudioRecorder` (the watch mic), with the AAC `.m4a` settings
/// that match the phone's recording format so playback is identical.
///
/// `@MainActor` and observable so the record screen binds to `isRecording` and drives start/stop; a haptic
/// fires on start and stop through `WKInterfaceDevice` so the capture is confirmable without looking.
@MainActor
final class WatchRecorder: NSObject, ObservableObject {
    /// Whether a capture is in progress, so the button shows the recording state.
    @Published private(set) var isRecording = false
    /// A permission-denied flag so the UI can prompt the user to enable the mic.
    @Published private(set) var micDenied = false

    private var recorder: AVAudioRecorder?
    private var currentURL: URL?
    private var startedAt: Date?

    /// The capture id for the in-progress recording, so its metadata and (later) the phone's thought id
    /// are stable and a re-delivered transfer de-duplicates.
    private var captureID = UUID()

    /// Request mic permission and begin recording to a fresh temp `.m4a`. Returns false if permission is
    /// denied or the recorder could not start (the UI shows the denied state).
    @discardableResult
    func start() async -> Bool {
        let granted = await requestMicPermission()
        guard granted else {
            micDenied = true
            return false
        }
        micDenied = false

        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.record, mode: .default)
            try session.setActive(true)

            captureID = UUID()
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("watch-capture-\(captureID.uuidString).m4a")
            let settings: [String: Any] = [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: 44_100.0,
                AVNumberOfChannelsKey: 1,
                AVEncoderAudioQualityKey: AVAudioQuality.medium.rawValue,
            ]
            let recorder = try AVAudioRecorder(url: url, settings: settings)
            guard recorder.record() else { return false }
            self.recorder = recorder
            self.currentURL = url
            self.startedAt = Date()
            isRecording = true
            playHaptic(.start)
            return true
        } catch {
            return false
        }
    }

    /// Stop recording and return the finished file + its capture metadata for transfer, or nil when there
    /// was no active recording. A haptic confirms the stop.
    @discardableResult
    func stop(folderHint: [String] = []) -> (url: URL, metadata: WatchCaptureMetadata)? {
        guard let recorder, let url = currentURL, let startedAt else {
            isRecording = false
            return nil
        }
        recorder.stop()
        playHaptic(.stop)
        try? AVAudioSession.sharedInstance().setActive(false)
        isRecording = false
        self.recorder = nil
        self.currentURL = nil
        self.startedAt = nil
        let metadata = WatchCaptureMetadata(
            captureID: captureID, capturedAt: startedAt, folderHint: folderHint)
        return (url, metadata)
    }

    private func requestMicPermission() async -> Bool {
        await withCheckedContinuation { continuation in
            AVAudioApplication.requestRecordPermission { granted in
                continuation.resume(returning: granted)
            }
        }
    }

    private enum HapticKind { case start, stop }

    private func playHaptic(_ kind: HapticKind) {
        #if canImport(WatchKit)
        let type: WKHapticType = (kind == .start) ? .start : .stop
        WKInterfaceDevice.current().play(type)
        #endif
    }
}
