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

## A guard that can abort belongs before the teardown, and invisible teardown needs its own test (spec 0008)

When an operation both (a) tears down current state to make room and (b) can abort early on a guard,
run the guard BEFORE the teardown - otherwise the abort path strands half-cleared state. The playback
controller stopped the current recording and then bailed on a no-audio note, leaving the OLD note in
`MPNowPlayingInfoCenter` with live remote handlers wired to a stopped controller. The same shape bit
the failed-resolve branch (cleared the note but not the system Now Playing / remote wiring). Two rules
generalize past playback: for any "validate, then mutate shared state" sequence, the validation gate
comes first; and give the stop/switch path ONE unambiguous helper that fully clears everything, rather
than a "stop but keep the wiring to re-use" helper that is easy to call on an abort. The coverage twin:
INVISIBLE teardown - clearing `MPNowPlayingInfoCenter`, unregistering `MPRemoteCommandCenter` handlers,
dropping a singleton's state - is exactly what a happy-path test misses, because nothing on screen
proves it. Assert the CLEARED state explicitly with a spy (Now Playing is nil, no remote wired) for
the natural-finish, the failed-play, and the switch-to-another cases. Generalizes to any controller
that mutates shared OS/system state on stop.

## Weigh every system-surfaced value against the app's privacy posture (spec 0008)

Standard platform UX can leak content on a privacy-forward app. `MPNowPlayingInfoCenter` shows the
track title on the LOCKED lock screen and Control Center; for a private voice-notes app whose title is
the note's first line, that is note content visible without authentication - a real regression from a
"nothing leaves the device" posture, even though nothing does leave the device. When you add any value
to a system surface (Now Playing, notifications, widgets, share sheets, Spotlight), weigh it against
the posture: keep it generic, gate it behind a setting, or at minimum disclose the tradeoff in the
privacy copy (here: the user's own content, on their own device, hideable via iOS's "Show on Lock
Screen"). Generalizes to any feature that hands user content to an OS-rendered surface.

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

## A restart-to-continue loop must commit the in-progress phrase at the seam (feedback 0005)

`SFSpeechRecognitionTask` ends on its own - on a clean `isFinal` result AND on an ERROR (a
no-speech / natural-pause timeout, a duration limit). The service auto-restarts a fresh task to keep
dictation continuous. The bug: text was committed as a paragraph only on `isFinal`; an error-ended
task emitted its last words as a transient partial, and the replacement task's first (empty) partials
overwrote it, so the words spoken right before a pause vanished. The rule: when a subtask feeding a
stream ENDS, whatever it holds must be COMMITTED at the seam, never left as transient state the next
subtask can clobber - and "ends" includes error/timeout ends, not just clean completions. Generalizes
to any auto-restart loop over a continuous source (speech, network reconnection, paginated cursors).

## A strict "no false-fire" rule can turn into a "silent literal" bug (feedback 0005)

The control-word parser was made strict (spec 0003) to avoid misfiring on a passing mention. But
rejecting a keyword-led near-miss BACK INTO the transcript is itself a failure the user notices:
"Mira read that back to me" got written into the note verbatim. When the user's stated intent is
"anything starting with my keyword is a command", make keyword-led the trigger, parse the remainder
tolerantly (strip outer/inner filler), and DROP an unrecognized keyword-led phrase with visible
feedback (a chip) rather than transcribing it - no wrong action fires, and no command phrase is
silently committed as text. Generalizes to any recognizer choosing between over-firing and silently
passing input through when the trigger is explicit: prefer a visible drop over a silent literal.

## Pin a floating control with safeAreaInset, not a ZStack overlay (feedback 0005)

A floating Record button layered in a `ZStack(alignment: .bottom)` overlapped the centered
empty-state text: the scrolling list padded room for it, the centered empty state did not.
`.safeAreaInset(edge:)` reserves real layout space under ALL content states, so nothing (list or
centered empty state) can sit under the control. Generalizes to any pinned affordance over content
that is sometimes scrollable and sometimes centered.

## Extract the perceptual mapping so a device-only feature still has a CI gate (feedback 0005)

The waveform bars sat at the floor because the RMS->level mapping (`rms * 12`) was too weak for
normal speech and the smoothing pulled it lower. The end-to-end path (mic emits level -> bars move)
is only judgeable on a physical device, but the RMS->bar-height math is pure. Extracting it into a
testable `normalizedLevel(fromRMS:)` (perceptual `sqrt` curve, tuned gain) lets a regression that
flattens the bars fail in CI even though the live mic can only be confirmed on hardware. Generalizes:
when a feature is device-only end to end, carve out the pure numeric core and unit-test it so at
least the tunable part is guarded.

## Model the real stream, not the simulator's simplified one (feedback 0006)

The feedback 0005 fix reasoned about `SFSpeechRecognitionTask` as one short phrase per pause, so it
committed text only when the ending result carried text and fired a command only when the segment
STARTED with the control word. On device the task ACCUMULATES the whole passage into one growing
transcription and finalizes only on end - sometimes an error end with a NIL result - so the fix
looked correct in the simulator and still shipped two CRITICAL bugs (a pause that lost the words, a
command that never fired). Two rules fall out. First: when the real behavior is device-only, extract
the decision into a pure function and TEST it against the REAL shape (nil result, accumulating
partial, mid-segment keyword), not the shape the simulator emits - `resolveEnd(resultText:lastPartial:)`
and the split parser are both pure and unit-tested against the device shape. Second: "at the start"
is the wrong anchor for a marker in an accumulating stream; a control token arrives mid/end, so match
it ANYWHERE and split around it, and keep the words before it. Anchoring to position zero silently
disables the feature for the exact continuous input it was built for. Generalizes to any restart-to-
continue loop over a growing stream where a subtask can end empty and a marker can land anywhere.

## Two commit paths over one accumulating stream double-count (feedback 0008)

Committing paragraphs from BOTH the live-partial reset (0007) and the task-end result (0006) meant
the same words could land twice: on device the recognizer's final transcription is non-monotonic and
can restore an utterance the reset already committed, so a following command's split re-committed it
(a paragraph doubled after "Mira ..."). The fix makes the two paths aware of each other with a single
per-task marker: record what the reset committed (`committedThisTask`) and strip that lead from the
task-end transcription before committing the remainder - REPLACE not append, because the recognizer's
accumulation only ever extends from its most recent internal reset, so only the latest reset-committed
utterance can recur. Tolerant matching (character-level common prefix, word-boundary trim) absorbs the
recognizer's revisions, and a non-matching lead means the recognizer already dropped it, so nothing is
stripped. Generalizes: when two independent commit paths consume one accumulating stream, give them a
shared high-water marker so neither re-commits what the other did; reconciling after the fact by
content is what breaks on messy, non-monotonic input.

## A character prefix is the wrong similarity metric for revision-vs-new-utterance (feedback 0009)

Deciding whether a new recognizer partial REVISES the current utterance or STARTS a new one drove the
duplicate paragraphs both times. The first metric (character-level common prefix) broke on any
revision that edits the START: collapsing spacing into a URL ("I'm saying the" -> "I'msayingthe.com")
or dropping a leading word ("What kind of games" -> "Kind of games") diverges at character zero, so
the prefix ratio read a same-utterance rewrite as a brand-new one and committed the stale version as
its own paragraph. Two fixes fall out. First: normalize away the exact thing the recognizer keeps
rewriting - lowercase and strip whitespace and punctuation - before comparing, so spacing/URL/case
churn is invisible to the decision. Second: a revision can edit EITHER end, so test containment (one
compact string inside the other) plus overlap at the start OR the end, not just the front. The
residual risk flips direction (it could now merge a genuinely new utterance that is a substring of the
prior), but that trades a frequent, visible bug (duplicate paragraphs) for a rare, less-bad one (an
occasional missed paragraph break), and unrelated-utterance tests guard the common case. Generalizes:
when matching noisy machine output against itself, normalize on the dimension the machine is unstable
on and compare on the invariant that survives its edits, not on raw position.

## When the platform can give you the boundary, stop inferring it (spec 0002)

Five feedback rounds (0005-0009) were spent inferring utterance boundaries from `SFSpeechRecognizer`'s
accumulating single-task stream - reset detection, task-end dedup, restart-to-continue, overlap
ratios. The iOS 26 `SpeechAnalyzer` / `SpeechTranscriber` reports volatile-vs-finalized results
directly, so ALL of that inference deleted at once and the whole bug class went with it. The lesson is
not "use the new API" but the shape of the decision: when you find yourself building ever-more-elaborate
heuristics to reconstruct a signal the platform withholds, the highest-leverage move is often to change
the SOURCE of the signal, not to refine the heuristic. Two enablers made the swap cheap and safe: the
capture backend sat behind a narrow protocol (`SpeechCaptureService`) whose consumer had its own tests,
so the entire recognizer could be replaced with the view-model suite passing untouched as the proof;
and the design was pinned in a spec while the exact new-API signatures were verified against the
installed SDK's `.swiftinterface` before writing code, not guessed. Generalizes: isolate volatile
platform dependencies behind a seam with consumer-side tests, and periodically ask whether a hard
problem is inherent or just an artifact of an API that predates a better one.

## A SwiftUI label built from "now" is frozen at render, not live (feedback 0011)

The note card's "x mins ago" read the note's own recording length and never updated, while the same
code in the detail view looked correct. There was no data difference: `RelativeTime.label(for:)`
defaults its reference to `Date()` and is evaluated ONCE when the view body is built. SwiftUI has no
wall-clock dependency to invalidate on, so the string freezes - and the list most recently rendered
right after a save, when time-since-`createdAt` (captured at session start) is about the recording's
duration. The detail view only looked right because it is reconstructed on each navigation, so it
recomputes against a fresh now - which MASKED the bug (the buggy screen was the long-lived one, the
"correct" screen was just freshly built). The fix gives the label an explicit time dependency: a
`TimelineView(.periodic(by: 60))` re-evaluating against `context.date`. Generalizes: any UI that is a
function of the current time - relative timestamps, countdowns, "expires in", elapsed - must carry a
time source (a `TimelineView` or a ticking reference), or it drifts silently on any screen that stays
put; and when two screens share the same time-derived code but disagree, suspect render lifetime
(one is rebuilt, one is not) before suspecting the data.

## Make a location positional, not a serialized field, and let a re-save be the move (spec 0010)

Grouping notes into folders is a STORAGE LOCATION, so it belongs in WHERE the file sits, not in the
file's bytes. Modeling `Note.folderPath` as a positional directory (derived on load from the relative
path, consumed on save to place the file) - never a frontmatter key - keeps the Markdown byte-identical
between a top-level and a foldered note, so every existing file, other app, and the cross-backend
"either store reads either file" invariant is untouched (proved with a bytes-equal test). Two shape
choices made the rest cheap and non-rippling. First: a note being re-filed is just a `save` with a new
`folderPath`; `save` detects the change (its file is located in a different directory than the
destination) and relocates BOTH the `.md` and the sibling `.m4a`, deleting the old copies, so the move
leaves nothing behind - there is no separate "move" API to keep in sync. Second: keep the id-only audio
surface (`audioURL`/`saveAudio`/`deleteAudio`/`audioExists`) id-only by having them SCAN the tree for
`<id>.md` (`locateFile`), so the folder feature does not widen the `NoteStoring` seam and nothing
downstream (the `AudioURLResolving` resolver, playback controller, recordings browser) changes or even
recompiles differently. A consequence for the writer ordering: because audio now lands BESIDE the
located note file, the note `.md` must be written to its folder BEFORE its recording is adopted -
otherwise, with subfolders, `locateFile` finds nothing and the recording falls back to the root. And
mirror every new tree walk / move / cascade / dir-create through `NSFileCoordinator` on the iCloud
path, exactly as the existing file IO, or a folder op races the sync daemon. Generalizes: when a
feature is really "where does this artifact live", encode it as position and let the existing
save/scan operations carry it, rather than adding a field, a second API, and a wider seam.

## A rename/move onto an occupied name must reject, not overwrite (spec 0010)

The first `renameFolder` did `if destination exists { removeItem(destination) }` before moving - so
renaming folder "A" to "B" when "B" already existed silently DELETED B and everything in it. A
"replace" is the right primitive when the destination is the SAME logical object (overwriting a note's
own `<id>.m4a` on a re-save), but WRONG when it is a different one (a sibling folder that happens to
share the target name): there the safe answer is to reject the operation and let the UI report the
conflict, never to cascade-delete a bystander. The tell is destructive teardown guarded only by "does
a file exist at the path", with no check on WHOSE file it is. Generalizes to any move/rename/import
that writes to a user-chosen name: distinguish "overwrite my own prior version" from "collide with
someone else's", and only the former may delete.

## Sanitize an untrusted name by rejection, not stripping - and guard the resolved path too (spec 0010)

Folder names are user input that becomes a real filesystem path feeding recursive DELETE/move. The
first sanitizer STRIPPED unsafe bits (leading dots, then trimmed whitespace) - and stripping can
SYNTHESIZE the very thing it removes: `"..\t.."` stripped down to `".."`, a live parent-directory
traversal out of the app container. A subtractive filter over a set of "bad" fragments is a trap,
because a residue of two bad fragments can be a third. Sanitize by REJECTION instead: define what a
valid single path component is (non-empty, not `.`/`..`, no leading dot, no separator `/`\`:`, no
control/newline) and return "rejected" for anything else - never try to launder a bad name into a
good one. Then, because even a correct name-sanitizer returns "" for a rejected component and the
join can SKIP it and collapse a crafted path (`[".."]`) back to the ROOT, add a second, independent
guard at the destructive op: resolve the final URL and refuse it unless it is strictly BELOW the root
(`dir != root && dir.path.hasPrefix(root.path + "/")`), so `deleteFolder`/`renameFolder` can never
target the whole tree or anything outside it. Two layers: reject bad names at the source, and gate the
resolved path at every recursive delete/move. Generalizes to any untrusted string that becomes a path,
a key, or a query fed to a destructive or escaping operation.

## Two concurrent edit modes over one model must be mutually exclusive (spec 0009)

The note page grew a second inline editor (title) beside the existing one (body). Each had its own
`isEditing*` flag, they were independent, and a single Done button branched on which was set. Nothing
stopped BOTH being active at once: with the body editor open you could still tap the title, and Done
then committed the title through `currentNote` - which is rebuilt from the committed `paragraphs`, not
the body editor's in-flight `draft` - silently dropping everything freshly typed in the body. The
symptom only appears when a user does the unusual thing (edit one, tap the other), so happy-path use
and happy-path tests never surface it. Two rules generalize. First: when a view hosts more than one
editor committing into the SAME model, the modes must be mutually exclusive - gate each editor's
"begin edit" on the other not being active (or commit/exit the active one first), so there is always
exactly one in-flight buffer. Second: a commit must read from the ACTIVE editor's buffer, never from
the model's already-committed fields; a derived-from-model snapshot (`currentNote`) is safe to persist
only once every open editor has folded its buffer back into the model. Extracting the pure commit
decision (here `Note.resolveTitleEdit`) also lifts the rule out of view state so it can be unit-tested
instead of only device-verified. Generalizes to any screen with multiple simultaneous editors.
