import Foundation
#if canImport(WatchConnectivity)
import WatchConnectivity
#endif

/// The phone side of the watch link (spec 0023). Owns the `WCSession`, receives transferred `.m4a`
/// captures (each ingested into a thought via `WatchCaptureIngestService`), and pushes the recent-thoughts
/// projection back to the watch so it can browse. One instance, created at launch and held by the
/// composition root.
///
/// The wire codecs (`WatchConnectivityCodec`) and the ingest logic are factored out and unit-tested; this
/// object is the thin `WCSessionDelegate` shell that is only meaningfully exercisable on a paired device /
/// simulator. It compiles and no-ops where WatchConnectivity is unavailable, so the iOS build stays green.
final class PhoneConnectivityCoordinator: NSObject {
    private let ingestService: WatchCaptureIngestService
    /// Loads the current recent-thoughts projection to push to the watch. Injected so the coordinator does
    /// not reach into a store/driver directly and stays testable.
    private let recentThoughtsProvider: @Sendable () -> [RecentThoughtProjection]
    /// Resolves a thought id to its recording URL for on-demand playback transfer to the watch.
    private let audioURLProvider: @Sendable (UUID) -> URL?

    init(
        ingestService: WatchCaptureIngestService,
        recentThoughtsProvider: @escaping @Sendable () -> [RecentThoughtProjection],
        audioURLProvider: @escaping @Sendable (UUID) -> URL?
    ) {
        self.ingestService = ingestService
        self.recentThoughtsProvider = recentThoughtsProvider
        self.audioURLProvider = audioURLProvider
        super.init()
    }

    /// Activate the session if the phone supports it (a no-op on an iPad or where WatchConnectivity is
    /// absent). Safe to call at launch.
    func start() {
        #if canImport(WatchConnectivity)
        guard WCSession.isSupported() else { return }
        let session = WCSession.default
        session.delegate = self
        session.activate()
        #endif
    }

    /// Push the latest recent-thoughts projection to the watch as the application context (the watch reads
    /// it whenever it next comes up, coalesced to the newest). Called after a save / sync / ingest so the
    /// wrist list stays fresh. No-op when no watch is reachable/paired.
    func pushRecentThoughts() {
        #if canImport(WatchConnectivity)
        guard WCSession.isSupported() else { return }
        let session = WCSession.default
        guard session.activationState == .activated else { return }
        let projection = recentThoughtsProvider()
        let context = WatchConnectivityCodec.encode(recentThoughts: projection)
        try? session.updateApplicationContext(context)
        #endif
    }
}

#if canImport(WatchConnectivity)
extension PhoneConnectivityCoordinator: WCSessionDelegate {
    func session(
        _ session: WCSession,
        activationDidCompleteWith activationState: WCSessionActivationState,
        error: Error?
    ) {
        // On activation push the current list so a freshly-launched or freshly-paired watch has data.
        if activationState == .activated {
            pushRecentThoughts()
        }
    }

    // The phone can be re-paired to a different watch; iOS requires these two no-op hooks so the session
    // can reactivate for the new device without the app restarting.
    func sessionDidBecomeInactive(_ session: WCSession) {}
    func sessionDidDeactivate(_ session: WCSession) {
        WCSession.default.activate()
    }

    /// A capture arrived from the watch: ingest the `.m4a` into a thought, then refresh the watch list so
    /// the new thought shows there too. The file WCSession hands us is a temp we own for the duration of
    /// this call; the ingest service moves it into the store (or leaves it, and the OS cleans the temp).
    func session(_ session: WCSession, didReceive file: WCSessionFile) {
        let metadata = WatchConnectivityCodec.decodeCaptureMetadata(file.metadata)
        // A transfer with no / unreadable metadata cannot be filed deterministically; still ingest it with
        // a synthesized fallback so a capture is never silently dropped.
        let resolved = metadata ?? WatchCaptureMetadata(captureID: UUID(), capturedAt: Date())
        // Copy the file out of WCSession's transient inbox before the async work, since the URL is only
        // valid for the duration of this delegate call.
        let localURL = Self.copyToTemp(file.fileURL)
        let ingestService = self.ingestService
        Task { [weak self] in
            _ = await ingestService.ingest(fileURL: localURL, metadata: resolved)
            try? FileManager.default.removeItem(at: localURL)
            self?.pushRecentThoughts()
        }
    }

    /// The watch asked for a thought's audio to play: transfer the `.m4a` back on demand with the id in the
    /// metadata so the watch matches it to the row. A message with an `audioRequest` id triggers this.
    func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
        guard let idString = message["audioRequest"] as? String,
              let id = UUID(uuidString: idString),
              let url = audioURLProvider(id),
              FileManager.default.fileExists(atPath: url.path) else {
            return
        }
        session.transferFile(url, metadata: ["audioResponse": id.uuidString])
    }

    /// Copy a received file into our own temp location so it outlives the delegate call. Falls back to the
    /// original URL if the copy fails (best effort - never crash the receive path).
    private static func copyToTemp(_ url: URL) -> URL {
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("watch-capture-\(UUID().uuidString).\(ThoughtStore.audioFileExtension)")
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
