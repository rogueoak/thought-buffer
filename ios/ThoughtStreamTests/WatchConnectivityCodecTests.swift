import XCTest
@testable import ThoughtStream

/// Round-trip tests for the watch <-> phone wire codecs (spec 0023). The codecs turn the payloads into
/// the plist-safe `[String: Any]` dictionaries a `WCSession` moves, so proving encode -> decode is
/// identity (and that decode is tolerant of garbage) is the whole serialization contract, provable
/// without a real watch or a paired session.
final class WatchConnectivityCodecTests: XCTestCase {
    // MARK: Capture metadata (watch -> phone)

    func testCaptureMetadataRoundTrips() {
        let id = UUID()
        let date = Date(timeIntervalSince1970: 1_700_000_000.5)
        let metadata = WatchCaptureMetadata(captureID: id, capturedAt: date, folderHint: ["Work", "Ideas"])

        let encoded = WatchConnectivityCodec.encode(metadata)
        let decoded = WatchConnectivityCodec.decodeCaptureMetadata(encoded)

        XCTAssertEqual(decoded?.captureID, id)
        XCTAssertEqual(decoded?.folderHint, ["Work", "Ideas"])
        // The date round-trips to sub-second precision (ISO-8601 with fractional seconds).
        XCTAssertEqual(decoded?.capturedAt.timeIntervalSince1970 ?? 0, date.timeIntervalSince1970, accuracy: 0.01)
    }

    func testCaptureMetadataDefaultsFolderHintEmpty() {
        let metadata = WatchCaptureMetadata(captureID: UUID(), capturedAt: Date())
        let decoded = WatchConnectivityCodec.decodeCaptureMetadata(WatchConnectivityCodec.encode(metadata))
        XCTAssertEqual(decoded?.folderHint, [])
    }

    func testCaptureMetadataDecodeRejectsMissingFields() {
        XCTAssertNil(WatchConnectivityCodec.decodeCaptureMetadata(nil))
        XCTAssertNil(WatchConnectivityCodec.decodeCaptureMetadata([:]))
        XCTAssertNil(WatchConnectivityCodec.decodeCaptureMetadata(["captureID": "not-a-uuid"]))
        // A valid id but no date is still rejected (cannot file deterministically).
        XCTAssertNil(WatchConnectivityCodec.decodeCaptureMetadata(["captureID": UUID().uuidString]))
    }

    // MARK: Recent-thoughts projection (phone -> watch)

    func testRecentThoughtsRoundTrip() {
        let items = [
            RecentThoughtProjection(id: UUID(), title: "Morning drive", preview: "Call the supplier", duration: 12.5, hasAudio: true),
            RecentThoughtProjection(id: UUID(), title: "Grocery list", preview: "Milk, eggs", duration: 0, hasAudio: false),
        ]

        let encoded = WatchConnectivityCodec.encode(recentThoughts: items)
        let decoded = WatchConnectivityCodec.decodeRecentThoughts(encoded)

        XCTAssertEqual(decoded, items)
    }

    func testRecentThoughtsDecodeRejectsWrongKind() {
        // A capture-metadata dictionary is not a recent-thoughts message.
        let notRecent: [String: Any] = ["kind": "somethingElse", "items": []]
        XCTAssertNil(WatchConnectivityCodec.decodeRecentThoughts(notRecent))
        XCTAssertNil(WatchConnectivityCodec.decodeRecentThoughts(nil))
    }

    func testRecentThoughtsDecodeSkipsMalformedRows() {
        let goodID = UUID()
        let dictionary: [String: Any] = [
            "kind": "recentThoughts",
            "items": [
                ["id": goodID.uuidString, "title": "Good", "preview": "p", "duration": 3.0, "hasAudio": true],
                ["id": "not-a-uuid", "title": "Bad"], // dropped
                ["title": "No id"],                     // dropped
            ],
        ]
        let decoded = WatchConnectivityCodec.decodeRecentThoughts(dictionary)
        XCTAssertEqual(decoded?.count, 1)
        XCTAssertEqual(decoded?.first?.id, goodID)
        XCTAssertEqual(decoded?.first?.title, "Good")
    }

    func testRecentThoughtsEmptyListRoundTrips() {
        let encoded = WatchConnectivityCodec.encode(recentThoughts: [])
        XCTAssertEqual(WatchConnectivityCodec.decodeRecentThoughts(encoded), [])
    }

    // MARK: Kind markers (structural routing)

    func testEveryPayloadCarriesItsKindMarker() {
        // Each channel's payload is tagged so a receiver routes STRUCTURALLY, never by guessing fields.
        let capture = WatchConnectivityCodec.encode(
            WatchCaptureMetadata(captureID: UUID(), capturedAt: Date()))
        XCTAssertEqual(capture[WatchConnectivityCodec.kindKey] as? String, WatchConnectivityCodec.captureKind)

        let recent = WatchConnectivityCodec.encode(recentThoughts: [])
        XCTAssertEqual(recent[WatchConnectivityCodec.kindKey] as? String, WatchConnectivityCodec.recentThoughtsKind)

        let request = WatchConnectivityCodec.encode(audioRequestFor: UUID())
        XCTAssertEqual(request[WatchConnectivityCodec.kindKey] as? String, WatchConnectivityCodec.audioRequestKind)

        let response = WatchConnectivityCodec.encode(audioResponseFor: UUID())
        XCTAssertEqual(response[WatchConnectivityCodec.kindKey] as? String, WatchConnectivityCodec.audioResponseKind)
    }

    // MARK: Audio request / response (on-demand playback)

    func testAudioRequestRoundTrips() {
        let id = UUID()
        let encoded = WatchConnectivityCodec.encode(audioRequestFor: id)
        XCTAssertEqual(WatchConnectivityCodec.decodeAudioRequest(encoded), id)
    }

    func testAudioResponseRoundTrips() {
        let id = UUID()
        let encoded = WatchConnectivityCodec.encode(audioResponseFor: id)
        XCTAssertEqual(WatchConnectivityCodec.decodeAudioResponse(encoded), id)
    }

    func testAudioRequestAndResponseAreNotConfusedStructurally() {
        // A response payload must NOT decode as a request (and vice versa) even though both carry a
        // thought id - the kind marker keeps them distinct.
        let id = UUID()
        let request = WatchConnectivityCodec.encode(audioRequestFor: id)
        let response = WatchConnectivityCodec.encode(audioResponseFor: id)
        XCTAssertNil(WatchConnectivityCodec.decodeAudioResponse(request))
        XCTAssertNil(WatchConnectivityCodec.decodeAudioRequest(response))
        // And neither is mistaken for the recent-thoughts channel.
        XCTAssertNil(WatchConnectivityCodec.decodeRecentThoughts(request))
    }

    func testAudioRequestDecodeRejectsMissingKindOrID() {
        XCTAssertNil(WatchConnectivityCodec.decodeAudioRequest(nil))
        XCTAssertNil(WatchConnectivityCodec.decodeAudioRequest(["thoughtID": UUID().uuidString])) // no kind
        XCTAssertNil(WatchConnectivityCodec.decodeAudioRequest([
            WatchConnectivityCodec.kindKey: WatchConnectivityCodec.audioRequestKind])) // no id
    }
}
