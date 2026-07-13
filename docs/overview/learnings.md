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

## An OS-triggered entry point needs a resolution-independent latch (spec 0005)

When an OS-instantiated entry point (an App Intent with `openAppWhenRun`, a scene delegate) reaches
app state through a process-wide accessor, that accessor must be valid at the EARLIEST moment the
entry point can fire - which for a hands-free intent is a COLD launch, before async startup
resolution finishes and before any UI exists. A "buffer for requests made while off-screen" only
works if the buffer exists independent of the UI/startup that populates it; otherwise the very first
request (the one that launched the app) is the one it silently drops. So: back the seam with a
resolution-independent latch that the composition root adopts when it comes up, and never let the
request path return a nil/no-op starter. Make presentation a pure function of the pending state
(`PendingSessionRoute.shouldPresent`) so it is unit-testable and has no lost-edge cases (a start requested
while backgrounded opens on appear; a re-request after a session ends re-opens). Generalizes to any
future OS-triggered entry point that starts an in-app flow.

## A file being written is not a file you can read - honor the finalize boundary (spec 0007)

A container format (AAC/`.m4a`, and most compressed media) is only playable once its writer has
finalized it - closed the file so the trailing index/`moov` atom is written. So an in-flight
recording is NOT a readable file, even though it exists on disk with content. The tempting shortcut -
play the session's own recording for in-session "read that back" - fails: the writer is finalized at
`stop()`, not at the `pause()` read-back uses, so the player gets an unfinalized file and silently
degrades. The fix respects the boundary: play recorded audio only where the file IS finalized (a
SAVED note) and use the already-available text-to-speech path for the in-session case. Encode the
boundary in the seam's contract too - the "give me the recording URL" method documents that the file
is finalized only after `stop()`, and a separate `discardRecording()` cleans up an orphan (including
a zero-frame file the content-gated URL getter would not even report), so the next consumer (a
headless CarPlay Audio browser) can't repeat the mistake. Generalizes to any producer/consumer split
over a container-format artifact: a consumer may touch it only after the producer signals finalized,
and the seam should say so rather than leave the lifetime implicit.

## Push an existence/availability check behind the storage seam, not a bare fileExists (spec 0007)

Deciding "is there a recording to play?" with `FileManager.fileExists` in the view leaks storage
internals and is wrong for a coordinated backend: `ICloudNoteStore` wraps IO in `NSFileCoordinator`,
so a bare `fileExists` races the sync daemon and mis-reports a synced-but-not-downloaded file as
absent (the Play affordance silently vanishes). Put the question on the `NoteStoring` seam
(`audioExists(for:)`, coordinated on iCloud, plain on local) so the view asks "is there a recording?"
without knowing how storage answers - and the same coordinated check is ready for the future headless
consumer. Generalizes: any "does X exist / is X available" decision over a store belongs on the
store's protocol, not inlined at the call site, especially when one backend needs coordination.

## Tee a live stream at its existing fork, and keep one sink alive across the other's churn (spec 0007)

When a live audio stream already fans out to more than one consumer (the input tap fed the
recognizer and the waveform), adding a third sink is a tee at that SAME fork, not a second capture
path: the tap forks each buffer to the recognizer AND a file writer, one mic, one engine. The trap
is lifetime coupling. The recognizer restarts its task many times per session, but the recording
must be ONE continuous file, so the file writer must live for the whole session and be created once
(guarded by "only if none exists" so pause/resume and restart reuse it), while the churny consumer
is rebuilt freely around it. Because each consumer keeps its OWN clock (segment timestamps reset to
zero every restart), map back to the shared timeline by tracking an offset in the durable sink's own
terms (audio seconds = frames written / sample rate, read at each restart) and adding it - never wall
clock, so a pause that writes no frames does not advance the recording clock. Keep the off-main sink
thread-safe on its own (a lock, `@unchecked Sendable`) exactly as the tap already treats
`request.append`, so no isolated state crosses the audio thread. Generalizes to any second recorder,
meter, or analyzer teed onto a stream whose primary consumer restarts under it.

## Validate a config value against its consumer's contract, not just its shape (spec 0006)

A user-editable setting must be validated against what DOWNSTREAM does with it, not merely that it
looks reasonable. A control phrase that is non-empty and short still breaks every command if the
parser matches a single token and the phrase is multi-word ("Hey Nova"); a spelling override with a
filled `from` but a blank `to` maps a real word to "" and silently DELETES it. Both pass a
shape check (non-empty, within length) and both fail silently - the app keeps running and does the
wrong thing, with no error to notice. So: when you validate a setting, trace the exact contract of
the code that reads it (the parser tokenizes -> collapse to one token; a blank replacement is a
deletion -> require both sides) and encode that. Two supports make this cheap and safe: put the
rule in a shared seam both the store and the UI call (so the view never reaches into a concrete
store and the rule can't drift), and bound any user-editable persisted collection (row count,
field length) so a stuck field cannot grow storage without limit. Generalizes to any configurable
value that feeds a parser, a transform, or a persisted collection.
