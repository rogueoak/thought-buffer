import Foundation
import Combine
#if canImport(WatchConnectivity)
import WatchConnectivity
#endif

/// The watch side of the phone link (spec 0023): a `WCSession` that transfers captured `.m4a` files to
/// the phone (with capture metadata), receives the recent-thoughts projection the phone pushes, and
/// requests a thought's audio on demand for playback. An `ObservableObject` so the browse list binds to
/// `recentThoughts`.
///
/// The transfer is RELIABLE / BACKGROUND: `transferFile` queues the capture and the OS delivers it when
/// the phone is reachable, so a capture made while the phone is away is not lost - it syncs once
/// connectivity returns, surviving the watch app closing. The wire codec is the shared
/// `WatchConnectivityCodec`, so both sides serialize identically.
@MainActor
final class WatchConnectivityManager: NSObject, ObservableObject {
    /// The recent thoughts the phone pushed, newest first, for the browse list. Empty until the first
    /// application-context arrives.
    @Published private(set) var recentThoughts: [RecentThoughtProjection] = []
    /// The number of captures still queued for transfer (not yet confirmed delivered), so the UI can show
    /// a "will sync" state. Decremented as `transferFile` completes.
    @Published private(set) var pendingTransfers = 0
    /// The URL of an audio file the phone sent back for playback, keyed by thought id, so the player can
    /// pick it up. Cleared after consumption.
    @Published private(set) var receivedAudio: [UUID: URL] = [:]

    static let shared = WatchConnectivityManager()

    override init() {
        super.init()
    }

    /// Activate the session. Call once at launch.
    func start() {
        #if canImport(WatchConnectivity)
        guard WCSession.isSupported() else { return }
        let session = WCSession.default
        session.delegate = self
        session.activate()
        #endif
    }

    /// Queue a captured recording for reliable transfer to the phone, with its capture metadata. Survives
    /// the app closing and a temporarily unreachable phone (the OS delivers it later). The metadata's
    /// capture id is the thought id the phone will file it under.
    func sendCapture(fileURL: URL, metadata: WatchCaptureMetadata) {
        #if canImport(WatchConnectivity)
        guard WCSession.isSupported() else { return }
        let session = WCSession.default
        let payload = WatchConnectivityCodec.encode(metadata)
        pendingTransfers += 1
        session.transferFile(fileURL, metadata: payload)
        #endif
    }

    /// Ask the phone to send a thought's audio back so the watch can play it. The phone replies with a
    /// file transfer tagged with the id, which lands in `receivedAudio`.
    func requestAudio(for thoughtID: UUID) {
        #if canImport(WatchConnectivity)
        guard WCSession.isSupported() else { return }
        let session = WCSession.default
        guard session.activationState == .activated else { return }
        session.sendMessage(["audioRequest": thoughtID.uuidString], replyHandler: nil, errorHandler: nil)
        #endif
    }

    /// Consume (and clear) an audio file the phone sent for a thought id, so a subsequent request is not
    /// served a stale file.
    func consumeAudio(for thoughtID: UUID) -> URL? {
        let url = receivedAudio[thoughtID]
        receivedAudio[thoughtID] = nil
        return url
    }
}

#if canImport(WatchConnectivity)
extension WatchConnectivityManager: WCSessionDelegate {
    nonisolated func session(
        _ session: WCSession,
        activationDidCompleteWith activationState: WCSessionActivationState,
        error: Error?
    ) {
        // If the phone already had a context queued, apply it on activation.
        let context = session.receivedApplicationContext
        Task { @MainActor in
            self.applyRecentThoughts(from: context)
        }
    }

    /// The phone pushed a fresh recent-thoughts projection (its application context, coalesced to newest).
    nonisolated func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String: Any]) {
        Task { @MainActor in
            self.applyRecentThoughts(from: applicationContext)
        }
    }

    /// A capture transfer finished (delivered or errored). Decrement the pending count either way so the
    /// UI does not show "syncing" forever; the OS retries a failed transfer under the hood.
    nonisolated func session(_ session: WCSession, didFinish fileTransfer: WCSessionFileTransfer, error: Error?) {
        Task { @MainActor in
            self.pendingTransfers = max(0, self.pendingTransfers - 1)
        }
    }

    /// The phone sent a thought's audio back for playback (tagged with the id in metadata). Copy it out of
    /// the transient inbox and expose it for the player.
    nonisolated func session(_ session: WCSession, didReceive file: WCSessionFile) {
        guard let idString = file.metadata?["audioResponse"] as? String,
              let id = UUID(uuidString: idString) else {
            return
        }
        let localURL = Self.copyToTemp(file.fileURL, id: id)
        Task { @MainActor in
            self.receivedAudio[id] = localURL
        }
    }

    private func applyRecentThoughts(from context: [String: Any]) {
        if let projection = WatchConnectivityCodec.decodeRecentThoughts(context) {
            recentThoughts = projection
        }
    }

    /// Copy a received audio file into our own temp location so it outlives the delegate call.
    nonisolated private static func copyToTemp(_ url: URL, id: UUID) -> URL {
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("watch-play-\(id.uuidString).m4a")
        do {
            if FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.removeItem(at: destination)
            }
            try FileManager.default.copyItem(at: url, to: destination)
            return destination
        } catch {
            return url
        }
    }
}
#endif
