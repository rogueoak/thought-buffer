import Foundation
#if canImport(WatchConnectivity)
import WatchConnectivity
#endif

/// Serializes watch-capture ingests so a batch delivered on reconnect never runs concurrent
/// `SpeechAnalyzer` passes (architect review). An actor with a single-threaded task chain: each `enqueue`
/// awaits the previous ingest before starting, so at most ONE transcription runs at a time regardless of
/// how many `didReceive` deliveries arrive at once.
actor IngestQueue {
    private let ingestService: WatchCaptureIngestService
    private var tail: Task<Void, Never> = Task {}

    init(ingestService: WatchCaptureIngestService) {
        self.ingestService = ingestService
    }

    /// Chain an ingest after any already-queued one, then run `onFinished` (e.g. push the refreshed list).
    /// The file is cleaned up after the ingest regardless of outcome.
    func enqueue(fileURL: URL, metadata: WatchCaptureMetadata, onFinished: @escaping @Sendable () -> Void) {
        let previous = tail
        let service = ingestService
        tail = Task {
            await previous.value
            _ = await service.ingest(fileURL: fileURL, metadata: metadata)
            try? FileManager.default.removeItem(at: fileURL)
            onFinished()
        }
    }
}

/// The phone side of the watch link (spec 0023). Owns the `WCSession`, receives transferred `.m4a`
/// captures (each ingested into a thought via `WatchCaptureIngestService`, serialized through
/// `IngestQueue`), and pushes the recent-thoughts projection back to the watch so it can browse. One
/// instance, created at launch and held by the composition root.
///
/// The wire codecs (`WatchConnectivityCodec`) and the ingest logic are factored out and unit-tested; this
/// object is the thin `WCSessionDelegate` shell that is only meaningfully exercisable on a paired device /
/// simulator. It compiles and no-ops where WatchConnectivity is unavailable, so the iOS build stays green.
final class PhoneConnectivityCoordinator: NSObject, @unchecked Sendable {
    /// Loads the current recent-thoughts projection to push to the watch. Injected so the coordinator does
    /// not reach into a store/driver directly and stays testable. Runs OFF the delegate thread (it does a
    /// `store.loadAll()`), so it must be safe to call from a background task.
    private let recentThoughtsProvider: @Sendable () -> [RecentThoughtProjection]
    /// Resolves a thought id to its recording URL for on-demand playback transfer to the watch.
    private let audioURLProvider: @Sendable (UUID) -> URL?

    private let ingestQueue: IngestQueue

    /// Serializes/coalesces the recent-thoughts push (fix 4). A rapid burst (a synced-in batch, a
    /// multi-delete) would otherwise fire N `store.loadAll()` + N context writes on the caller thread;
    /// instead a push is DEBOUNCED and the load runs on a background task. Guarded by `pushLock`.
    private let pushLock = NSLock()
    private var pendingPush = false
    private var pushInFlight = false

    /// How long to coalesce a burst of change notifications into one push.
    private static let pushDebounce: Duration = .milliseconds(300)

    init(
        ingestService: WatchCaptureIngestService,
        recentThoughtsProvider: @escaping @Sendable () -> [RecentThoughtProjection],
        audioURLProvider: @escaping @Sendable (UUID) -> URL?
    ) {
        self.recentThoughtsProvider = recentThoughtsProvider
        self.audioURLProvider = audioURLProvider
        self.ingestQueue = IngestQueue(ingestService: ingestService)
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

    /// Push the latest recent-thoughts projection to the watch (fix 4): DEBOUNCED and OFF the delegate
    /// thread. Rapid callers (every `onThoughtsChanged`) coalesce into one background load + one context
    /// write, so a synced-in batch or a multi-delete does not fire N loads. No-op when no watch is paired.
    func pushRecentThoughts() {
        pushLock.lock()
        if pushInFlight {
            // A push is already scheduled/running; mark that another change arrived so it re-pushes once.
            pendingPush = true
            pushLock.unlock()
            return
        }
        pushInFlight = true
        pushLock.unlock()

        Task.detached { [weak self] in
            try? await Task.sleep(for: Self.pushDebounce)
            await self?.drainPush()
        }
    }

    /// Do one push (background), then re-push if more changes arrived while it ran. Loads the projection
    /// off the delegate thread and writes the application context.
    private func drainPush() async {
        // Coalesce everything that arrived during the debounce window into this one push.
        pushLock.lock()
        pendingPush = false
        pushLock.unlock()

        let projection = recentThoughtsProvider()
        writeApplicationContext(WatchConnectivityCodec.encode(recentThoughts: projection))

        pushLock.lock()
        let again = pendingPush
        if again {
            // More changes landed during the load/write; keep pushInFlight set and loop.
            pushLock.unlock()
            await drainPush()
            return
        }
        pushInFlight = false
        pushLock.unlock()
    }

    /// Write the application context to the session, if activated. Isolated so the debounce path has one
    /// place that touches `WCSession`.
    private func writeApplicationContext(_ context: [String: Any]) {
        #if canImport(WatchConnectivity)
        guard WCSession.isSupported() else { return }
        let session = WCSession.default
        guard session.activationState == .activated else { return }
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

    /// A capture arrived from the watch: ingest the `.m4a` into a thought (SERIALIZED through the ingest
    /// queue so a reconnect batch never runs concurrent transcriptions), then refresh the watch list. The
    /// file WCSession hands us is valid only for this delegate call, so it is copied out first; the ingest
    /// queue removes the copy when done.
    func session(_ session: WCSession, didReceive file: WCSessionFile) {
        let metadata = WatchConnectivityCodec.decodeCaptureMetadata(file.metadata)
        // A transfer with no / unreadable metadata cannot be filed deterministically; still ingest it with
        // a synthesized fallback so a capture is never silently dropped.
        let resolved = metadata ?? WatchCaptureMetadata(captureID: UUID(), capturedAt: Date())
        let localURL = Self.copyToTemp(file.fileURL)
        Task { [weak self] in
            guard let self else {
                try? FileManager.default.removeItem(at: localURL)
                return
            }
            await self.ingestQueue.enqueue(fileURL: localURL, metadata: resolved) { [weak self] in
                self?.pushRecentThoughts()
            }
        }
    }

    /// The watch asked for a thought's audio to play: transfer the `.m4a` back on demand, tagged with the
    /// id so the watch matches it to the row. Routed structurally on the message kind (fix 2).
    func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
        guard let id = WatchConnectivityCodec.decodeAudioRequest(message),
              let url = audioURLProvider(id),
              FileManager.default.fileExists(atPath: url.path) else {
            return
        }
        session.transferFile(url, metadata: WatchConnectivityCodec.encode(audioResponseFor: id))
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
