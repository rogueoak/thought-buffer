# Learnings

What we learned, change by change.

## Simulator speech is not a gate (spec 0002)

On-device `SFSpeechRecognizer` capture is unreliable in the iOS Simulator (it may fall back to
the Mac mic or refuse on-device recognition), and `simctl privacy grant` cannot set the
speech-recognition permission. Do not block a milestone on live simulator speech. Instead, make
the capture path injectable (feed finalized text without audio) so the full flow - permission
request, save, reload, render - is provable structurally in the sim and by tests, and leave real
speech for a physical device.

## Keep persisted files tolerant from day one (spec 0002)

Notes are Markdown files that outlive any single app version. The parser ignores unknown
frontmatter keys and still loads a body without frontmatter, so later fields (tags, source,
edits) can be added without a migration and an old or hand-edited file never fails to load.

## Drive audio-mode transitions off "finished", not a timer (spec 0003)

Playing audio (text to speech) while the mic is live feeds the output straight back into
recognition. Do not overlap the two: pause capture, switch the session to `.playback`, speak,
and only reactivate the record session when the synthesizer reports the utterance actually
finished (its delegate callback), not after a guessed duration. Model the player as a protocol
that exposes an `onFinish` callback so the resume is event-driven and the player stays stubbable
in tests. This record -> playback -> record handshake generalizes to any future feature that
plays audio during a live capture session.

## An unavailable external service is a normal path, not an error (spec 0004)

iCloud may be absent (not signed in, no provisioning, the Simulator with no account). Model that
as a first-class branch selected once in the composition root - a factory resolves the ubiquity
container off the main actor (the lookup can block) and returns a store plus a `kind`, falling
back to the local store when nil - not as a thrown error the callers must catch. The rest of the
app depends only on the `NoteStoring` seam and never re-runs availability logic, so the offline
path stays identical to before and the choice is observable for a later Settings status. This
generalizes to any optional backend (a future server, a share extension): decide once, expose the
choice, keep the seam narrow.

## iCloud entitlements do not have to break the unsigned Simulator build (spec 0004)

Adding an iCloud capability (entitlements + `NSUbiquitousContainers` Info.plist) keeps the
teamless Simulator build green because code signing is disabled for the Simulator config
(`CODE_SIGNING_ALLOWED=NO`), so the embedded entitlement is not validated and `DEVELOPMENT_TEAM`
can stay empty. Declare the capability in `ios/project.yml` (XcodeGen writes the committed
`.entitlements` and `Info.plist`); real provisioning waits for the developer's Team on a device.
Note that `NSUbiquitousContainers` is a nested dict, so it needs an explicit `info.properties`
plist in XcodeGen rather than the flat `INFOPLIST_KEY_*` build settings.

## Coordinate all iCloud file IO through NSFileCoordinator (spec 0004)

A store that shares files with the iCloud sync daemon must wrap every read, write, and delete
(and directory creation) in `NSFileCoordinator`, or it races the daemon writing the same file.
Keep the file format identical to the local store (same `Note` Markdown) so a file written by
either backend loads through either - that is what makes switching backends lossless. Put the
`NSMetadataQuery` live-update behind a protocol with a pure mapping so the enumeration and
download-trigger logic is unit-testable with stub items, with no real iCloud.

## Blocking storage reads belong off the main actor, in a testable feed model (spec 0004)

The same off-main discipline applied to iCloud container resolution has to extend to the store
read: `ICloudNoteStore.loadAll()` is a chain of `NSFileCoordinator` reads that can block on the
sync daemon and fires on every metadata change, so running it on the main actor stutters the UI.
Put the load and the live-update observer wiring in a small `@MainActor` model (`StreamFeed`) that
loads on a detached task and only hops back to main to publish - not inline in the SwiftUI view.
Two payoffs: the boundary is drawn once at the read, and the glue (initial load, observer
`start`/`stop`, `onChange` -> reload, the local no-observer path) becomes unit-testable with a
stub store and stub observer. Bind that model's lifecycle to a single `.task` (cancellation tears
the observer down and clears its closure), not to `onAppear`/`onDisappear`, so a long-lived
observer is not restarted on every navigation push/pop and never holds a stale reference into a
gone view. This generalizes to any future feature that reads a slow or coordinated backend to feed
a list.

## Widen a seam by returning a result, not by adding a branch (spec 0003)

When a transform seam needs to do more than transform (here, consume a segment as a command
instead of committing it), change its return type to a small result enum (`.text` / `.command` /
`.drop`) rather than bolting a side channel onto the caller. The caller routes on the case, the
default implementation keeps its old behavior in one case, and future processors compose without
touching the view model or capture service.
