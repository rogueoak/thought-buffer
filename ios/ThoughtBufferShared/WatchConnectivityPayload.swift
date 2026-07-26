import Foundation

/// The pure, transport-agnostic payloads exchanged between the watch and the phone (spec 0023), plus
/// their codecs. These types have NO WatchConnectivity import: a `WCSession` moves `[String: Any]`
/// dictionaries (application context, user info) and file-transfer metadata, so the encode/decode to
/// and from that dictionary form is the part worth testing - it round-trips a capture from the wrist
/// to the phone and a recent-thoughts projection back. Keeping the codecs pure means the whole
/// serialization contract is provable on iOS without a real watch, a paired session, or a live
/// transfer (the same discipline the storage and speech seams follow).
///
/// Compiled into BOTH the iOS app and the watchOS app so the two sides share ONE definition of the
/// wire format and cannot drift.

// MARK: - Watch -> phone: capture metadata

/// The small metadata payload that rides alongside a transferred `.m4a` from the watch (spec 0023):
/// when the capture was made and an optional folder hint. The audio file itself is moved by
/// `transferFile`; this travels as the transfer's `metadata` dictionary so the phone can file the
/// resulting thought with the right timestamp (not the receive time) and, if the watch was browsing a
/// folder, into that folder.
struct WatchCaptureMetadata: Equatable {
    /// A stable id for this capture, so a ret/re-delivered transfer is de-duplicated on the phone and
    /// the resulting thought has a deterministic id (the capture id IS the thought id). A capture
    /// queued while the phone is unreachable keeps this id across the eventual delivery.
    let captureID: UUID
    /// When the recording was made ON THE WATCH (not when the phone received it). The filed thought's
    /// `createdAt` uses this so a capture that syncs minutes later still sorts by when it was spoken.
    let capturedAt: Date
    /// The folder the watch was browsing when the capture was made, or empty for the top level. A hint:
    /// the phone files the thought here when the folder still exists, else at the top level (never a
    /// failure).
    let folderHint: [String]

    init(captureID: UUID, capturedAt: Date, folderHint: [String] = []) {
        self.captureID = captureID
        self.capturedAt = capturedAt
        self.folderHint = folderHint
    }
}

// MARK: - Phone -> watch: recent-thoughts projection

/// One thought as projected from the phone to the watch for the browse list (spec 0023): just enough
/// to render a row (title + short preview + duration) and to request the audio for playback (the id).
/// The full `Thought` never crosses - the watch shows a lightweight, glanceable summary.
struct RecentThoughtProjection: Equatable, Hashable, Identifiable {
    let id: UUID
    /// The thought's title (its first sentence, derived on the phone).
    let title: String
    /// A short one-line preview drawn from the body, already trimmed/capped on the phone so the watch
    /// renders a plain string.
    let preview: String
    /// The recording length in seconds, 0 for a text-only thought. The watch formats it for display via
    /// the shared `Thought.durationLabel`.
    let duration: Double
    /// Whether the thought has a playable recording, so the watch shows a play affordance only when
    /// there is audio to fetch (a text-only thought is view-text-only on the wrist).
    let hasAudio: Bool

    init(id: UUID, title: String, preview: String, duration: Double, hasAudio: Bool) {
        self.id = id
        self.title = title
        self.preview = preview
        self.duration = duration
        self.hasAudio = hasAudio
    }
}

// MARK: - Codecs

/// Pure encode/decode between the payloads above and the `[String: Any]` dictionary form a `WCSession`
/// moves. Split from the session objects so the wire contract is unit-testable without WatchConnectivity.
///
/// The dictionaries use only property-list types (String, Double, Array) so they are valid
/// `applicationContext` / `transferUserInfo` / file-transfer `metadata` values. Decoding is TOLERANT:
/// a missing or wrong-typed field yields nil rather than trapping, so a malformed or
/// future-versioned message is ignored, never a crash.
enum WatchConnectivityCodec {
    /// The message-kind marker present on EVERY payload, so a receiver routes STRUCTURALLY (on the kind)
    /// rather than by which fields happen to be present. A `capture` metadata dict and an `audioRequest`
    /// message could otherwise be confused if their fields overlapped; the kind removes that ambiguity and
    /// lets the wire format add shapes without a decoder guessing.
    static let kindKey = "kind"
    static let captureKind = "capture"
    static let recentThoughtsKind = "recentThoughts"
    static let audioRequestKind = "audioRequest"
    static let audioResponseKind = "audioResponse"

    /// The wire field names, centralized so the phone and watch cannot drift on a raw string literal (the
    /// audio request/response keys were previously typed by hand at each call site).
    private static let captureIDKey = "captureID"
    private static let capturedAtKey = "capturedAt"
    private static let folderHintKey = "folderHint"
    private static let itemsKey = "items"
    private static let idKey = "id"
    private static let titleKey = "title"
    private static let previewKey = "preview"
    private static let durationKey = "duration"
    private static let hasAudioKey = "hasAudio"
    private static let thoughtIDKey = "thoughtID"

    // MARK: Capture metadata (watch -> phone)

    /// Encode capture metadata into the file-transfer `metadata` dictionary. ISO-8601 for the date so
    /// it is stable across encoders and human-readable in a log. Carries the `capture` kind marker.
    static func encode(_ metadata: WatchCaptureMetadata) -> [String: Any] {
        [
            kindKey: captureKind,
            captureIDKey: metadata.captureID.uuidString,
            capturedAtKey: iso8601.string(from: metadata.capturedAt),
            folderHintKey: metadata.folderHint,
        ]
    }

    /// Decode capture metadata from a file-transfer `metadata` dictionary, or nil when it is missing the
    /// required fields (so a stray transfer is ignored rather than filed with a bogus id/date). Tolerant of
    /// a missing kind marker so a capture from an older watch build (pre-kind) still decodes.
    static func decodeCaptureMetadata(_ dictionary: [String: Any]?) -> WatchCaptureMetadata? {
        guard let dictionary,
              let idString = dictionary[captureIDKey] as? String,
              let captureID = UUID(uuidString: idString),
              let dateString = dictionary[capturedAtKey] as? String,
              let capturedAt = iso8601.date(from: dateString) else {
            return nil
        }
        let folderHint = (dictionary[folderHintKey] as? [String]) ?? []
        return WatchCaptureMetadata(captureID: captureID, capturedAt: capturedAt, folderHint: folderHint)
    }

    // MARK: Recent-thoughts projection (phone -> watch)

    /// Encode a recent-thoughts projection into an applicationContext/userInfo dictionary. Carries the
    /// kind marker so the watch routes it, and each item as a plist-safe sub-dictionary.
    static func encode(recentThoughts: [RecentThoughtProjection]) -> [String: Any] {
        let items: [[String: Any]] = recentThoughts.map { thought in
            [
                idKey: thought.id.uuidString,
                titleKey: thought.title,
                previewKey: thought.preview,
                durationKey: thought.duration,
                hasAudioKey: thought.hasAudio,
            ]
        }
        return [kindKey: recentThoughtsKind, itemsKey: items]
    }

    /// Decode a recent-thoughts projection from an applicationContext/userInfo dictionary, or nil when
    /// the dictionary is not a recent-thoughts message. Individual malformed items are skipped (not
    /// fatal), so one bad row never drops the whole list.
    static func decodeRecentThoughts(_ dictionary: [String: Any]?) -> [RecentThoughtProjection]? {
        guard let dictionary,
              dictionary[kindKey] as? String == recentThoughtsKind,
              let items = dictionary[itemsKey] as? [[String: Any]] else {
            return nil
        }
        return items.compactMap { item in
            guard let idString = item[idKey] as? String,
                  let id = UUID(uuidString: idString),
                  let title = item[titleKey] as? String else {
                return nil
            }
            let preview = (item[previewKey] as? String) ?? ""
            let duration = (item[durationKey] as? Double) ?? 0
            let hasAudio = (item[hasAudioKey] as? Bool) ?? false
            return RecentThoughtProjection(
                id: id, title: title, preview: preview, duration: duration, hasAudio: hasAudio)
        }
    }

    // MARK: Audio request / response (watch <-> phone, on-demand playback)

    /// Encode a watch -> phone "send me this thought's audio" message (a `sendMessage` payload). The kind
    /// marker lets the phone route it structurally, so it can never be confused with another message shape.
    static func encode(audioRequestFor thoughtID: UUID) -> [String: Any] {
        [kindKey: audioRequestKind, thoughtIDKey: thoughtID.uuidString]
    }

    /// Decode an audio-request message into the requested thought id, or nil when it is not an
    /// audio-request message (wrong/missing kind or id).
    static func decodeAudioRequest(_ dictionary: [String: Any]?) -> UUID? {
        guard let dictionary,
              dictionary[kindKey] as? String == audioRequestKind,
              let idString = dictionary[thoughtIDKey] as? String else {
            return nil
        }
        return UUID(uuidString: idString)
    }

    /// Encode the phone -> watch audio-response file-transfer `metadata` (the id the transferred `.m4a`
    /// answers), so the watch matches the file to the requesting row.
    static func encode(audioResponseFor thoughtID: UUID) -> [String: Any] {
        [kindKey: audioResponseKind, thoughtIDKey: thoughtID.uuidString]
    }

    /// Decode an audio-response file-transfer `metadata` into the answered thought id, or nil when it is
    /// not an audio-response (wrong/missing kind or id).
    static func decodeAudioResponse(_ dictionary: [String: Any]?) -> UUID? {
        guard let dictionary,
              dictionary[kindKey] as? String == audioResponseKind,
              let idString = dictionary[thoughtIDKey] as? String else {
            return nil
        }
        return UUID(uuidString: idString)
    }

    private static let iso8601: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
}
