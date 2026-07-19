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
    /// pick it up. Cleared after consumption, and BOUNDED (spec 0023 "cache a few"): only the most recent
    /// `maxCachedAudio` entries are kept, and an evicted entry's temp file is deleted so the cache never
    /// grows without bound.
    @Published private(set) var receivedAudio: [UUID: URL] = [:]
    /// Insertion order of `receivedAudio` keys, oldest first, for LRU-style eviction.
    private var receivedAudioOrder: [UUID] = []

    /// How many fetched recordings the watch caches at once (spec 0023 "cache a few recent ones"). Small
    /// because the wrist has little storage and a playback fetch is cheap to re-request.
    static let maxCachedAudio = 3

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
        session.sendMessage(
            WatchConnectivityCodec.encode(audioRequestFor: thoughtID), replyHandler: nil, errorHandler: nil)
        #endif
    }

    /// Consume (and clear) an audio file the phone sent for a thought id, so a subsequent request is not
    /// served a stale file. Does NOT delete the file - the caller is about to play it; a later cache
    /// insertion or eviction cleans up temp files.
    func consumeAudio(for thoughtID: UUID) -> URL? {
        let url = receivedAudio[thoughtID]
        receivedAudio[thoughtID] = nil
        receivedAudioOrder.removeAll { $0 == thoughtID }
        return url
    }

    /// Cache a fetched audio file, evicting the oldest entry (and deleting its temp file) once the cache
    /// exceeds `maxCachedAudio`, so the wrist never accumulates unbounded temp recordings.
    fileprivate func cacheAudio(_ url: URL, for thoughtID: UUID) {
        // Replacing an existing entry: drop the old file first and refresh its recency.
        if let stale = receivedAudio[thoughtID], stale != url {
            try? FileManager.default.removeItem(at: stale)
        }
        receivedAudioOrder.removeAll { $0 == thoughtID }
        receivedAudio[thoughtID] = url
        receivedAudioOrder.append(thoughtID)

        while receivedAudioOrder.count > Self.maxCachedAudio {
            let evicted = receivedAudioOrder.removeFirst()
            if let evictedURL = receivedAudio.removeValue(forKey: evicted) {
                try? FileManager.default.removeItem(at: evictedURL)
            }
        }
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
    /// the transient inbox and cache it (bounded) for the player.
    nonisolated func session(_ session: WCSession, didReceive file: WCSessionFile) {
        guard let id = WatchConnectivityCodec.decodeAudioResponse(file.metadata) else { return }
        let localURL = Self.copyToTemp(file.fileURL, id: id)
        Task { @MainActor in
            self.cacheAudio(localURL, for: id)
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
