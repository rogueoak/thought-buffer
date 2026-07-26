import SwiftUI

/// The quick-capture screen (spec 0023): one prominent Record control. Tap to record via the watch mic,
/// tap to stop; a haptic and a glanceable recording state confirm each. On stop the file is queued for
/// reliable transfer to the phone (surviving the app closing / a temporarily-unreachable phone), and a
/// lightweight "will sync" line shows while transfers are pending. Uses the shared Canopy tokens.
struct WatchCaptureView: View {
    @EnvironmentObject private var connectivity: WatchConnectivityManager
    @StateObject private var recorder = WatchRecorder()

    var body: some View {
        VStack(spacing: CanopySpacing.x3) {
            recordButton

            Text(statusText)
                .font(CanopyFont.sizeSmFont())
                .foregroundStyle(CanopyColor.textMuted)
                .multilineTextAlignment(.center)

            if connectivity.pendingTransfers > 0 {
                Label(pendingLabel, systemImage: "arrow.triangle.2.circlepath")
                    .font(CanopyFont.sizeXsFont())
                    .foregroundStyle(CanopyColor.textSubtle)
            }
        }
        .padding(CanopySpacing.x3)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(CanopyColor.bg.ignoresSafeArea())
    }

    private var recordButton: some View {
        Button(action: toggleRecording) {
            ZStack {
                Circle()
                    .fill(recorder.isRecording ? CanopyColor.danger : CanopyColor.accent)
                    .frame(width: 96, height: 96)
                Image(systemName: recorder.isRecording ? "stop.fill" : "mic.fill")
                    .font(.system(size: 40))
                    .foregroundStyle(CanopyColor.accentForeground)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(recorder.isRecording ? "Stop recording" : "Record a thought")
    }

    private var statusText: String {
        if recorder.micDenied {
            return "Microphone access is off. Turn it on in the watch Settings."
        }
        return recorder.isRecording ? "Recording... tap to stop" : "Tap to record a thought"
    }

    private var pendingLabel: String {
        let count = connectivity.pendingTransfers
        return count == 1 ? "Syncing 1 capture" : "Syncing \(count) captures"
    }

    private func toggleRecording() {
        if recorder.isRecording {
            if let capture = recorder.stop() {
                connectivity.sendCapture(fileURL: capture.url, metadata: capture.metadata)
            }
        } else {
            Task { await recorder.start() }
        }
    }
}
