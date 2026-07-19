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
    /// The message-kind marker, so one applicationContext/userInfo channel can carry more than one
    /// payload shape and the receiver routes on it.
    static let kindKey = "kind"
    static let recentThoughtsKind = "recentThoughts"

    // MARK: Capture metadata

    /// Encode capture metadata into the file-transfer `metadata` dictionary. ISO-8601 for the date so
    /// it is stable across encoders and human-readable in a log.
    static func encode(_ metadata: WatchCaptureMetadata) -> [String: Any] {
        [
            "captureID": metadata.captureID.uuidString,
            "capturedAt": iso8601.string(from: metadata.capturedAt),
            "folderHint": metadata.folderHint,
        ]
    }

    /// Decode capture metadata from a file-transfer `metadata` dictionary, or nil when it is missing the
    /// required fields (so a stray transfer is ignored rather than filed with a bogus id/date).
    static func decodeCaptureMetadata(_ dictionary: [String: Any]?) -> WatchCaptureMetadata? {
        guard let dictionary,
              let idString = dictionary["captureID"] as? String,
              let captureID = UUID(uuidString: idString),
              let dateString = dictionary["capturedAt"] as? String,
              let capturedAt = iso8601.date(from: dateString) else {
            return nil
        }
        let folderHint = (dictionary["folderHint"] as? [String]) ?? []
        return WatchCaptureMetadata(captureID: captureID, capturedAt: capturedAt, folderHint: folderHint)
    }

    // MARK: Recent-thoughts projection

    /// Encode a recent-thoughts projection into an applicationContext/userInfo dictionary. Carries the
    /// kind marker so the watch routes it, and each item as a plist-safe sub-dictionary.
    static func encode(recentThoughts: [RecentThoughtProjection]) -> [String: Any] {
        let items: [[String: Any]] = recentThoughts.map { thought in
            [
                "id": thought.id.uuidString,
                "title": thought.title,
                "preview": thought.preview,
                "duration": thought.duration,
                "hasAudio": thought.hasAudio,
            ]
        }
        return [kindKey: recentThoughtsKind, "items": items]
    }

    /// Decode a recent-thoughts projection from an applicationContext/userInfo dictionary, or nil when
    /// the dictionary is not a recent-thoughts message. Individual malformed items are skipped (not
    /// fatal), so one bad row never drops the whole list.
    static func decodeRecentThoughts(_ dictionary: [String: Any]?) -> [RecentThoughtProjection]? {
        guard let dictionary,
              dictionary[kindKey] as? String == recentThoughtsKind,
              let items = dictionary["items"] as? [[String: Any]] else {
            return nil
        }
        return items.compactMap { item in
            guard let idString = item["id"] as? String,
                  let id = UUID(uuidString: idString),
                  let title = item["title"] as? String else {
                return nil
            }
            let preview = (item["preview"] as? String) ?? ""
            let duration = (item["duration"] as? Double) ?? 0
            let hasAudio = (item["hasAudio"] as? Bool) ?? false
            return RecentThoughtProjection(
                id: id, title: title, preview: preview, duration: duration, hasAudio: hasAudio)
        }
    }

    private static let iso8601: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
}
