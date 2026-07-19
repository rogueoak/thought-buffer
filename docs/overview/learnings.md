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

Thoughts are Markdown files that outlive any single app version. The parser ignores unknown
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
app depends only on the `ThoughtStoring` seam and never re-runs availability logic, so the offline
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
Keep the file format identical to the local store (same `Thought` Markdown) so a file written by
either backend loads through either - that is what makes switching backends lossless. Put the
`NSMetadataQuery` live-update behind a protocol with a pure mapping so the enumeration and
download-trigger logic is unit-testable with stub items, with no real iCloud.

## Blocking storage reads belong off the main actor, in a testable feed model (spec 0004)

The same off-main discipline applied to iCloud container resolution has to extend to the store
read: `ICloudThoughtStore.loadAll()` is a chain of `NSFileCoordinator` reads that can block on the
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
SAVED thought) and use the already-available text-to-speech path for the in-session case. Encode the
boundary in the seam's contract too - the "give me the recording URL" method documents that the file
is finalized only after `stop()`, and a separate `discardRecording()` cleans up an orphan (including
a zero-frame file the content-gated URL getter would not even report), so the next consumer (a
headless CarPlay Audio browser) can't repeat the mistake. Generalizes to any producer/consumer split
over a container-format artifact: a consumer may touch it only after the producer signals finalized,
and the seam should say so rather than leave the lifetime implicit.

## Push an existence/availability check behind the storage seam, not a bare fileExists (spec 0007)

Deciding "is there a recording to play?" with `FileManager.fileExists` in the view leaks storage
internals and is wrong for a coordinated backend: `ICloudThoughtStore` wraps IO in `NSFileCoordinator`,
so a bare `fileExists` races the sync daemon and mis-reports a synced-but-not-downloaded file as
absent (the Play affordance silently vanishes). Put the question on the `ThoughtStoring` seam
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
controller stopped the current recording and then bailed on a no-audio thought, leaving the OLD thought in
`MPNowPlayingInfoCenter` with live remote handlers wired to a stopped controller. The same shape bit
the failed-resolve branch (cleared the thought but not the system Now Playing / remote wiring). Two rules
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
track title on the LOCKED lock screen and Control Center; for a private voice-thoughts app whose title is
the thought's first line, that is thought content visible without authentication - a real regression from a
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
"Mira read that back to me" got written into the thought verbatim. When the user's stated intent is
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

The thought card's "x mins ago" read the thought's own recording length and never updated, while the same
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

Grouping thoughts into folders is a STORAGE LOCATION, so it belongs in WHERE the file sits, not in the
file's bytes. Modeling `Thought.folderPath` as a positional directory (derived on load from the relative
path, consumed on save to place the file) - never a frontmatter key - keeps the Markdown byte-identical
between a top-level and a foldered thought, so every existing file, other app, and the cross-backend
"either store reads either file" invariant is untouched (proved with a bytes-equal test). Two shape
choices made the rest cheap and non-rippling. First: a thought being re-filed is just a `save` with a new
`folderPath`; `save` detects the change (its file is located in a different directory than the
destination) and relocates BOTH the `.md` and the sibling `.m4a`, deleting the old copies, so the move
leaves nothing behind - there is no separate "move" API to keep in sync. Second: keep the id-only audio
surface (`audioURL`/`saveAudio`/`deleteAudio`/`audioExists`) id-only by having them SCAN the tree for
`<id>.md` (`locateFile`), so the folder feature does not widen the `ThoughtStoring` seam and nothing
downstream (the `AudioURLResolving` resolver, playback controller, recordings browser) changes or even
recompiles differently. A consequence for the writer ordering: because audio now lands BESIDE the
located thought file, the thought `.md` must be written to its folder BEFORE its recording is adopted -
otherwise, with subfolders, `locateFile` finds nothing and the recording falls back to the root. And
mirror every new tree walk / move / cascade / dir-create through `NSFileCoordinator` on the iCloud
path, exactly as the existing file IO, or a folder op races the sync daemon. Generalizes: when a
feature is really "where does this artifact live", encode it as position and let the existing
save/scan operations carry it, rather than adding a field, a second API, and a wider seam.

## A rename/move onto an occupied name must reject, not overwrite (spec 0010)

The first `renameFolder` did `if destination exists { removeItem(destination) }` before moving - so
renaming folder "A" to "B" when "B" already existed silently DELETED B and everything in it. A
"replace" is the right primitive when the destination is the SAME logical object (overwriting a thought's
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

The thought page grew a second inline editor (title) beside the existing one (body). Each had its own
`isEditing*` flag, they were independent, and a single Done button branched on which was set. Nothing
stopped BOTH being active at once: with the body editor open you could still tap the title, and Done
then committed the title through `currentThought` - which is rebuilt from the committed `paragraphs`, not
the body editor's in-flight `draft` - silently dropping everything freshly typed in the body. The
symptom only appears when a user does the unusual thing (edit one, tap the other), so happy-path use
and happy-path tests never surface it. Two rules generalize. First: when a view hosts more than one
editor committing into the SAME model, the modes must be mutually exclusive - gate each editor's
"begin edit" on the other not being active (or commit/exit the active one first), so there is always
exactly one in-flight buffer. Second: a commit must read from the ACTIVE editor's buffer, never from
the model's already-committed fields; a derived-from-model snapshot (`currentThought`) is safe to persist
only once every open editor has folded its buffer back into the model. Extracting the pure commit
decision (here `Thought.resolveTitleEdit`) also lifts the rule out of view state so it can be unit-tested
instead of only device-verified. Generalizes to any screen with multiple simultaneous editors.

## The app-icon asset cannot be loaded by name in SwiftUI (spec 0012)

The launch cover (spec 0012) wanted to show the app icon. `Image("AppIcon")` does not work: an
`AppIcon.appiconset` is a special icon set the system consumes to render the home-screen icon, and it
is not addressable as a normal named image at runtime - so the code compiles and simply shows nothing.
The fix is a plain `.imageset` (`LaunchIcon`) whose file is a copy of the same 1024 PNG already in the
icon set, loaded with `Image("LaunchIcon")`. Generalizes: to display the app's own icon inside the UI,
add a normal image set - do not reach for the `AppIcon` asset name. A second, smaller gotcha: a helper
that returns `some View` and is called from inside a `TimelineView`/`@ViewBuilder` closure captures its
closure parameters escapingly (the `ForEach` inside holds them), so a bar-height closure passed to such
a helper must be marked `@escaping` or the build fails with "escaping closure captures non-escaping
parameter".

## A derived change-token must cover every change it gates a refresh on (spec 0010)

The folder screen re-fetched its child-folder names with `.task(id: feed.thoughts.count)` - using the
thought COUNT as a "something changed, reload" token. But the count is a lossy projection of the state:
a rename, a move between two existing folders, and an iCloud-synced EMPTY folder all change what
should be on screen while leaving the count identical, so sibling and ancestor screens silently went
stale. A change-token has to be a monotonic signal that ticks on EVERY mutation of the underlying
state, not a value that merely tends to change with it. The fix put a `reloadGeneration` counter on
the driver that bumps wherever the thoughts list is (re)published (so it catches the observer path too)
and keyed the refresh on that. Generalizes to any `onChange`/`.task(id:)`/cache-key/equatable-diff
that watches a summary (a count, a hash of a subset, a "last item id") to decide when to recompute:
if two distinct states can share the token, the refresh is lossy - drive it off a real version
counter bumped at the single write point instead.

## When you add a field to a value type, audit every REBUILD site, not just constructors (spec 0013)

`ThoughtDetailView.currentThought` rebuilds a `Thought` from the view's edited fields and hands it to
`store.save`. When folders (spec 0010) added `Thought.folderPath`, that rebuild was never updated, so it
defaulted `folderPath` to `[]` - and because the store files a thought by its `folderPath`, editing ANY
thought that lived in a folder silently RE-FILED it to the root. The feature that added the field had
green tests and shipped; the regression hid in an unrelated view's rebuild. A fresh `init` with a
default is fine for NEW values, but a REBUILD/copy of an existing value that omits the new field is a
silent data-mutation: it doesn't fail to compile and it doesn't fail a test that only checks the
fields it does set. Two defenses: when adding a field to a shared value type, grep for every site that
reconstructs it (`TypeName(` with an existing instance in scope, `.init(`, "edited copy" helpers) and
carry the field through; and prefer a single `editedCopy(changing:)`-style mutator on the type over
ad-hoc `Thought(...)` rebuilds scattered across views, so there is ONE place that must know all the
fields. Generalizes to any immutable model that is copied-with-changes in more than one place.

## A shared teardown that clears everything is wrong when one caller must keep some state (spec 0015)

`ThoughtPlaybackController.play(thought:)` calls `clearPlayback()` before loading a thought - it stops the
player and drops Now Playing / remote wiring so no stale playback survives a switch. Adding a queue
(a folder swipe that auto-advances) meant the queue had to SURVIVE that same teardown on each advance:
advancing IS a `play(thought:)` under the hood, but it must not wipe the `queue`/`hasNext` it is walking.
The fix split the start path in two - a public `play(thought:)` that clears the queue (a deliberate new
selection ends any queue) and a private `loadAndPlay(thought:)` that does NOT, which the queue advance
and `playQueue` call. The natural-finish advance is told apart from a user stop by the pre-existing
`suppressFinish` flag: a user `stop()` sets it (via `clearPlayback`) AND clears the queue, so
`handleFinish` returns early and cannot advance; only a real end-of-track reaches the advance.
Generalizes: when a shared "reset everything" helper gains a caller that must preserve a slice of the
state, do not add flags to the helper - split the entry points by intent (the caller that resets vs.
the caller that keeps), and keep the "is this a natural event or a deliberate one" distinction on the
single flag that already gates the synchronous-vs-natural teardown, so the two paths never race.

## The failure path of a state machine must honor the same invariant as the happy path (spec 0015)

The queue advanced on a natural end-of-track (`handleFinish`: next-or-teardown), but the FAILED-play
branch of `startPlayback` (a nil / unplayable URL for a mid-queue recording) only called
`clearPlayback()` - not `clearQueue()` - so the queue was left populated with nothing playing:
hands-free playback silently STALLED on a vanished file instead of skipping to the next. A finish and
a failure are two ways the current item "is done"; both must move the queue forward or tear it down,
yet only the finish path had that logic. The fix extracts one `advanceOrFinish()` and calls it from
BOTH, so there is a single definition of "what happens when the current entry ends, however it ends."
The tell: a happy-path transition that maintains an invariant (the queue is always either playing or
empty) paired with an error/early-return branch that quietly drops out without re-establishing it.
Generalizes to any state machine or iterator with a "success -> next" step and a separate "couldn't
do this one" branch: route both through the same advance/cleanup, or the error branch strands state
the success branch would have cleaned. And it needs a test that makes ONE middle item fail (here a
per-thought nil-resolving stub), not just start/first-item failure.

## Per-finalization is the wrong grain for a paragraph; group on the signal the platform gives you (feedback 0012)

"One finalized `SpeechTranscriber.Result` = one paragraph" read cleanly (the iOS 26 API hands you an
explicit finalized boundary, so it looked like the paragraph boundary), but it was the WRONG grain:
the transcriber finalizes on a SHORT mid-thought breath, so a single spoken sentence split into
several paragraphs and dictation felt nothing like the native Notes app. The right paragraph boundary
is a real SILENCE gap, not a finalization event - a coarser signal that has to be COMPUTED from the
finer one. The fix reads the recognizer's `CMTimeRange` (which is analysis-relative and present even
for a text-only session, because it is independent of the audio tee) and groups consecutive segments
by the gap between one's end and the next's start: below a threshold they flow into one paragraph,
at/above it a new paragraph starts. Two shape choices made it clean and provable. First: ALL the
policy lives in a pure `ParagraphGrouper` (no Speech / AVFoundation import) that returns a
`.newParagraph` / `.appendToCurrent` decision, so the gap rule, the device-tunable threshold constant,
and the degenerate-range guard are unit-tested without audio and the view model is a thin caller.
Second: a pause/resume seam restarts analysis, so its time resets to ~0 and a naive gap against the
prior analysis's end goes NEGATIVE and would mis-merge; carry an explicit `isAnalysisStart` flag
through the capture event (set on the first finalized result of each analysis) and force a break on
it, rather than trying to detect the seam from the numbers. When segments merge, their timings merge
too (first start through last end) so the `timings.count <= paragraphs.count` invariant and per-
paragraph playback survive. Generalizes: when the platform's explicit boundary is at a finer grain
than the boundary you actually want, derive the coarser one from a continuous signal it also exposes
(here the time range), keep that derivation pure and tunable, and thread any discontinuity (a restart,
a resume) through as an explicit flag instead of inferring it from a value that resets across it.

## A perceived-latency complaint is not always a latency bug - separate the fixable from the device-only (feedback 0012)

The same device report bundled "too many newlines" with "text is slow to appear". They share a root
(text jumping to a new line on every micro-pause makes the stream FEEL laggy), but only the newline
half is diagnosable and fixable off-device; the raw appear-latency (tap buffer size, the transcriber's
own volatile cadence) can only be measured and tuned on real hardware. The disciplined move was to
FIX the pure, testable half now (pause-based grouping, which also improves the perception of
smoothness) and, for the device-only half, add lightweight `#if DEBUG` timestamp instrumentation at
each emit and leave the tap buffer as a NAMED constant - so a later device pass has a measurement hook
and a single tuning lever - rather than blindly shrinking the buffer and calling it fixed. Generalizes:
when a report mixes a fixable defect with a device-only tuning concern, ship the fixable part behind
a seam and hand the tuning part a measurement + a lever, do not guess-tune what you cannot measure.

## Merging ranges into one timing is only safe while coupled thresholds keep the merge remappable (feedback 0012)

Pause-based grouping merges several segments' recorded ranges into ONE paragraph timing (first start
through last end). That merge is only sound because of a load-bearing coupling to a SEPARATE constant:
the paragraph group threshold (`ParagraphGrouper.defaultGapThreshold`, 1.5s) must stay strictly BELOW
any dead-air / silence-trim minimum-pause threshold (the transcript-refinement work targets ~2.0s).
The reasoning: any silence long enough to be trimmed (>= the trim floor) is necessarily >= the group
threshold, so it is always a PARAGRAPH BOUNDARY, never an interior sub-threshold silence inside a
merged paragraph. Therefore trimming only ever removes time BETWEEN paragraphs, and a merged
paragraph's `[start, duration]` stays remappable by shifting paragraph starts. Lift the group threshold
to or above the trim floor and an interior silence could be trimmed out of a merged paragraph, and its
stored range would no longer map to the recording. The rule: when a merge (of ranges, offsets, spans)
is only correct because two constants sit on a particular side of each other, DOCUMENT that coupling
on the constant itself and record it as a learning, so a later change to either constant is forced to
reconsider the merge rather than silently break the mapping. Generalizes to any pair of thresholds
where one governs "what we combine" and the other "what we remove", and the combine is only reversible
while the remove never reaches inside a combined unit.

## Gate a cosmetic transform on the condition that justifies it, not on every pass (spec 0016)

`FillerRemovalProcessor` was to "re-capitalize a sentence whose leading filler was removed", but the
first implementation capitalized the leading letter of EVERY segment it processed - including ones with
no filler removed at all. On the happy path (a filler-only or filler-led segment) it looked correct;
the over-reach only showed when a clean segment with a deliberately lowercase lead ("second thought", a
grouped continuation) flowed through and got silently title-cased to "Second thought". The tell: a
cleanup step whose JUSTIFICATION is a specific event (a leading token was stripped) applied
UNCONDITIONALLY on every input, so it mutated inputs the event never happened to. The fix threads the
condition (`removedLeadingFiller`) into the tidy step and only capitalizes when it holds. Two supports
made the miss cheap to catch: the transform is a pure function with a boolean gate that is unit-tested
both ways, and a view-model test drove a REAL grouped continuation through it (not just isolated filler
strings), which is exactly the input that exposed the over-reach. Generalizes to any "clean up the mess
X left behind" step - re-capitalization, re-spacing, re-punctuation, trimming - which must fire only
when X actually happened on this input, or it becomes a silent content change on the inputs where it did
not; and test it against a realistic no-op input, not only the input that triggers it.

## Normalize before you match: order regex cleanup passes so no pattern sees an unbounded run (spec 0016)

`FillerRemovalProcessor.tidy` ran a `\s+([,.;:!?])` "drop the space before punctuation" pass BEFORE the
`[ \t]+` "collapse whitespace" pass. On a long whitespace run NOT followed by terminal punctuation, the
`\s+` alternation backtracks quadratically (O(n^2)) - 8k spaces took ~2.3s on the main thread. Not
attacker-reachable here (input is bounded on-device dictation, never network/paste), so it is a
main-thread-hang robustness concern rather than a ReDoS, but the shape is the lesson: a later pass that
would have COLLAPSED the run to a single space was sequenced after the pass that scanned it greedily. The
fix reorders so normalization (collapse whitespace to one space) runs FIRST, and the punctuation passes
then match a bounded single space (` ?`) instead of `\s+`. Two rules generalize. First: when a pipeline
of string passes includes a normalizer that shrinks a class of input (whitespace, separators, casing),
run it EARLY so every downstream pattern matches the normalized, bounded form - never let a
greedy-quantifier pass scan the un-normalized run. Second: any repetition quantifier (`\s+`, `.*`, `+`)
over user-controlled length that is not anchored on both sides by a required literal is a backtracking
risk; either bound it or eliminate the run before it is reached. Generalizes to any multi-pass regex
cleanup (sanitizers, formatters, tokenizers) where an early normalization would make later patterns both
cheaper and simpler.

## A default-on transform must set its threshold at "can never change meaning", not "usually fine" (spec 0016)

The filler-removal default set first included `mm`/`mmm`/`er`/`ah`. Each is a plausible hesitation, but
`mm` is the millimetre UNIT ("20 mm of rain" -> "20 of rain", a factual change) and `ah`/`er` are real
interjections/words ("Ah, finally!" -> "Finally!"). The trap: the feature ships ON BY DEFAULT, so every
user's thoughts pass through it silently - a token that is "usually a filler" is not good enough, because
the rare real-word case is a silent content edit the user never opted into and may not notice. The bar
for a default-on, content-mutating transform is therefore "can this token EVER be a real word, unit, or
name in normal use" - if yes, it is out of the default, no matter how often it is a filler. The same
review surfaced a second class of the same bug: stripping a filler INSIDE quoted speech (`he said
"um, no"`) edits a quotation the user is transcribing verbatim. Two rules generalize. First: split the
policy into a safe-by-default set (only tokens that can never be meaningful) and an explicit opt-in
"aggressive" set for the ambiguous ones - never let convenience push an ambiguous token into the default.
Second: a content transform must respect the user's framing markers (quotes, code spans, verbatim
blocks) and skip protected regions, because inside them the user's INTENT is "leave this exactly as I
said it". Generalizes to any auto-applied rewrite (autocorrect, filler/dead-air removal, summarization,
redaction): gate the default on "never wrong", offer the rest as opt-in, and never rewrite inside a
verbatim/quoted span. Ship the pure core with negative tests for the exact real-word collisions ("20 mm",
"Ah, finally!", quoted "um") so the boundary is pinned in CI, not just reasoned about.

## Factor a repeated action surface before it forks, and tie its transient confirmation to the view (spec 0017)

The Share + Copy menu, the copy-to-pasteboard-and-flash routine, and the "Copied to clipboard" chip
were written twice - once in the thought detail toolbar, once in the list-row context menu - because the
second site was easy to reach by pasting the first. Two identical action surfaces are a drift trap: a
later change (the queued Delete-in-this-menu work) has to be made in both, and one will be missed. The
fix factors ONE `ThoughtActionsMenu(thought:onCopied:)` that emits the shared items and accepts optional
trailing content, so a caller appends its own item (Move, later Delete) without re-forking, plus one
`ThoughtClipboard.copy` and one `CopiedConfirmation` chip. The rule: when the SAME interactive affordance
appears on two screens, extract it at the first duplication - and design the shared piece to be
EXTENDED (a trailing-content slot) rather than copied when a caller needs one extra item. The paired
lesson is the confirmation's timer: a detached `DispatchQueue.asyncAfter` to hide a transient chip has
no generation guard and no lifecycle tie, so a rapid second copy hides it early and a fired timer can
mutate state after the view is gone. Drive the auto-hide from a `.task(id:)` keyed on a per-event
counter instead - it re-arms on each event and cancels on teardown - the same lifecycle-tied shape the
sibling error banners already used. Generalizes to any transient, self-dismissing UI (toasts, chips,
"copied"/"saved" flashes): key the dismissal on the view's lifecycle and a monotonic trigger, never a
free-floating timer.

## Make a destructive action reversible by moving, not removing - and route every entry point through one seam (spec 0020)

"Delete" that unlinks files immediately has no undo to offer, so the iOS Shake to Undo gesture and an
in-app "Undo" both have nothing to restore. The fix models delete as a MOVE into a per-store trash
directory plus a `restore`/`purge` pair, returning a lightweight token (id + former location +
filenames) that is enough to put the files back OR commit their removal - the files are never gone
until the undo window closes. Three shape choices made it safe and non-duplicative. First: the trash
is a HIDDEN subdirectory inside the store root (`.trash/`), so the existing tree walks that already
`skipsHiddenFiles` never surface a trashed thought and nothing downstream changed; keeping it inside the
root means the reused path-safety guard still holds (a soft-delete only ever moves within the tree).
Second: restore needs its OWN destination guard, subtly different from the delete-time one - a
top-level thought legitimately restores to the ROOT, so the guard is "at or BELOW root" where the folder
delete/rename guard is "strictly below root"; copying the strict guard verbatim would reject every
top-level restore, and dropping the guard would let a crafted former-folder path escape the tree. When
you reuse a safety check for a new operation, re-derive its exact predicate for that operation rather
than pasting it. Third: a destructive action reachable from several places (a swipe, a list menu, a
detail menu) must route through ONE coordinator, or the "make it undoable" wiring (register with the
UndoManager, show the affordance, arm the purge timer) is duplicated and one site drifts - here a
single `@MainActor` controller owned by the composition root serves every entry point, and a delete
from a pushed detail screen pops back to the list FIRST so the shared affordance is visible where it
lives. And tie the undo window's timer to the view lifecycle (a `.task(id:)` on a monotonic trigger),
never a detached `asyncAfter`, so a rapid second delete re-arms it and teardown cancels it - the same
rule the transient-confirmation chips already follow. Generalizes to any destructive operation that
should be undoable: move to a quarantine inside the same trust boundary, hand back a restore token,
funnel all triggers through one seam, and re-derive the path/permission guard for the restore
direction rather than reusing the delete-direction one.

## A move-to-quarantine delete must be atomic, and its coordinator must clear pending before awaiting (spec 0020, PR review)

Two defects surfaced in review of the undoable delete, both about a multi-step operation observed mid-flight. First, DATA LOSS: `softDelete` moved the `.md` to trash, then the `.m4a`; if the second move threw, the thought was already in trash but the function threw WITHOUT returning a token, so the thought vanished from the list, had no undo, and the launch sweep destroyed it. A "move several files into quarantine" is only safe if it is all-or-nothing: on any failure, ROLL BACK the moves already done so the thought ends up fully in place (throw, no token, still listed) - never half-quarantined-with-no-recovery-handle. Second, a REENTRANCY leak in the coordinator: `delete` read `pending`, then `await feed.purge(previous)`, then cleared `pending` - so a second delete arriving while the first was suspended read the same stale token and both raced to purge it, stranding the loser's trash. The fix is the same shape the sibling `undo()`/`commitWindow()` already used: capture-and-CLEAR the shared in-flight state SYNCHRONOUSLY before the first `await`, so no reentrant call sees it. The general rule for an async coordinator over shared mutable state: never leave a field readable across an await that will act on it - snapshot and null it out first. And keep the two undo channels (the system `UndoManager` stack and the in-app affordance) on ONE stack: route the in-app Undo through `undoManager.undo()` and drop settled actions with `removeAllActions(withTarget:)` on commit, or a later shake re-runs a closure for an already-settled delete. Generalizes to any quarantine-style destructive op (atomic move + rollback) and any async single-flight coordinator (clear-before-await).

## Reuse a validation seam by widening it for the collection, not by pasting the scalar rule (spec 0018)

Aliases extended the single control-word setting to an ordered LIST, and it was tempting to reuse `ControlPhrase.validated` (the scalar rule) per item. But the scalar rule DEFAULTS a bad input to "Mira" - correct for the primary word, which must always resolve to something, and WRONG for a list item, which should be DROPPED so the list can legitimately be empty. And an alias carries two constraints the scalar rule never had: it must not COLLIDE with the primary word (else an alias silently shadows it), and duplicates must fold case-insensitively. So the list got its own seam (`validatedAlias` returns nil to drop, `validatedAliases` de-dups against the primary key) sitting BESIDE the scalar one, sharing the token/length core but not its fallback. Three supports kept it honest. First: a "single token required" alias REJECTS a multi-word entry (nil) rather than silently keeping its first word the way the primary collapses "Hey Nova" -> "Hey", so the user is told their two-word alias was not accepted. Second: the fresh-install DEFAULT set is presence-checked on the persistence key, exactly like `refineTranscript` - an ABSENT key means "use the defaults", an empty stored array means "the user cleared it"; conflating the two would either re-add deleted aliases on every launch or ship no defaults at all. Third: the UI's add-button gate calls the SAME `validatedAlias` + collision check the store validates on read, so the view never offers an add the store would silently drop. Generalizes: when a scalar setting grows into a collection, do not reuse the scalar's validator per element - its fallback semantics are usually wrong for a list (drop vs. default), and the collection brings cross-element rules (dedup, no-collision-with-a-sibling-field) the scalar never had; give the collection its own pure seam sharing the scalar's core, presence-check any fresh-install default so "never set" and "set to empty" stay distinct, and gate the UI on the same seam the store enforces.

## A non-reversible rewrite is verify-then-atomic-replace, and the numeric core must be pure and separately proven (spec 0019)

Dead-air removal REPLACES a recording with no kept original, so a botched trim is unrecoverable data loss. The safe shape is never "overwrite the file": write the trimmed audio to a TEMP file, VERIFY it is a real non-empty audio file (it opens via `AVAudioFile` and has frames), and only THEN swap it in atomically - and swallow EVERY failure (unreadable source, nothing to trim, a write/verify slip, an empty result) into a "not trimmed" fallback that leaves the original untouched and lets the thought save anyway. The recording is never sacrificed for the sake of the trim. Building it, and the four-persona PR review, added several rules. First: carve the risky logic into PURE cores tested without audio - `SilenceTrimmer` (windowed RMS -> keep-ranges, named `silenceFloor`/`minPauseSeconds`/`breathGapSeconds` constants, every edge: silence at start/middle/end, back-to-back, none, all-silent, sub-threshold, AND the strict-boundary case exactly at the floor) and `TimingRemapper` (shift paragraph starts by removed duration, durations unchanged) - so the AVFoundation glue stays thin and the parts that corrupt data are provable in CI. Second: `AVAssetExportSession` + `AVURLAsset.tracks(...)` is a trap on modern iOS - the synchronous track accessor is load-gated and the export returned a bare `nilError`, so the composition-and-export path silently failed to `notTrimmed`; concatenating the kept frame ranges by straight `AVAudioFile` read/write is deterministic, self-contained, and has no async load/export to lose. Third: the atomic replace of a user file that a backend COORDINATES (the iCloud `.m4a` goes through `NSFileCoordinator`) must ALSO be coordinated - a bare `FileManager.replaceItemAt` on a ubiquity-container file races the sync daemon on a non-reversible op. So the destructive swap is a STORE seam (`replaceAudio`, `replaceItemAt` inside the coordination block on iCloud), not something the pure-ish trimmer does itself; the trimmer only produces + verifies the temp and hands it back. Fourth: the temp copy of raw voice must be created PROTECTED (`completeUnlessOpen`) before any audio is written into it, exactly like `RecordingWriter` - a full copy of sensitive audio sitting unprotected in the shared temp dir for the write+verify window is a real posture gap. Fifth: a background task that re-saves a record it captured EARLIER must RE-READ the current version and apply only its delta, never persist the stale snapshot - during a slow off-main trim the user can rename/move/delete the thought on the detail screen, and re-saving the finish()-time snapshot would clobber the edit or resurrect a deleted thought (a last-writer-wins race two personas flagged independently); read fresh by id, apply only the timings remap (`Thought.withTimings`), skip if the thought is gone, and reload the feed after so the stale in-memory copy is dropped. Sixth: a merge/remap that is only correct because two thresholds sit on a particular side of each other (trim floor 2.0s > paragraph-gap 1.5s, so a trimmable silence is always a paragraph boundary and never inside a paragraph) needs a GUARD TEST asserting the inequality, so a later tweak to either constant is forced to reconsider the remap rather than silently break the paragraph<->time mapping. Seventh (independent round-2 review, the round-1 self-review missed it): a "REPLACE this artifact's file" primitive over a slot that a DELETE can VACATE must refuse to create the slot - a bare `saveAudio`-style fallback that materializes the file when the slot is absent RESURRECTS a just-deleted artifact as an orphan (here a soft-delete hides the thought's `.md` in trash, so the audio slot resolves to a non-existent root path, and the deferred trim's `replaceAudio` re-created the raw-voice `.m4a` there - invisible to `loadAll`, never purged, defeating the delete AND leaking sensitive audio). Fix at BOTH layers: the caller re-reads and confirms the record still EXISTS before invoking replace (and skips the follow-up save when replace reports nothing was replaced, so a delete racing the swap does not resurrect it), and the primitive returns "nothing to replace" (nil) + cleans up its input rather than creating a file. Generalizes to any destructive/lossy transform of a user artifact: keep the numeric decision pure and exhaustively tested; do the mutation as verify-then-atomic-replace with a total-failure fallback, routed through whatever seam already coordinates that file, and clean up the intermediate on EVERY exit path with a `defer`; write any sensitive intermediate protected from byte zero; prefer a direct read/write over a load-gated framework pipeline when the transform is simple; when a deferred task re-persists a record, re-read-and-delta rather than re-save-a-snapshot AND make its "replace" primitive refuse to re-create a slot the record's deletion vacated (gate both the caller and the primitive); and pin any cross-constant invariant the transform depends on with its own assertion.

## Do not stack multiple .alert modifiers on one node, and lock the working seam with a test when the store is correct but the feature does nothing (feedback 0018)

Folder rename looked broken while the STORE was correct (sanitize -> no-clobber guard -> `moveItem`, and create worked). The fault was in the VIEW: three `.alert(...)` modifiers stacked on ONE view node (New folder / Rename / Delete), with the rename alert presented straight from a `.contextMenu` action via a bool binding. Stacked alerts on one node and context-menu-triggered bool alerts are both classic SwiftUI flakiness sources - a sibling alert can swallow another's presentation, so the rename alert may not present (or its TextField may not commit), and the working store call is never reached. The fix drives all three dialogs from ONE `FolderDialog` enum and hosts each alert on its OWN hidden `Color.clear` background anchor via a per-case binding, so no two share a node and none can lose the race; the text field lives in a separate `@State` so editing it does not churn the enum identity. Two rules generalize. First: never stack multiple `.alert`/`.confirmationDialog` modifiers on one SwiftUI node, and be wary of presenting a bool-driven alert directly from a `.contextMenu` action - drive a screen's dialogs from one state and host each on its own anchor (or use item-driven presentation) so presentation is deterministic. Second: when a "store logic is correct but the feature does nothing" bug appears, suspect the presentation/interaction layer, and lock the working seam with a DRIVER-level test (`StreamFeed.renameFolder(at:to:)` renames on disk, moves the thoughts, returns the name, republishes) so a later view regression cannot silently disable it again. Generalizes to any feature whose backend is proven but whose UI trigger is flaky.

## @Environment(\.undoManager) is unreliable; vend a first-responder-backed UndoManager and inject it (feedback 0018)

Shake to Undo did nothing because `ThoughtDeletionController` took its `UndoManager` from `@Environment(\.undoManager)`, which in a plain SwiftUI tree is frequently NIL (no UIKit responder vends one) - so the delete registered with a nil manager, and the system shake gesture (which invokes the FIRST RESPONDER's `UndoManager`) found no action. The fix is a small, separable `UndoManagerHost` (`UIViewControllerRepresentable`) embedding a zero-size `UIViewController` that `canBecomeFirstResponder`, becomes first responder, and vends a STABLE `UndoManager` from its `undoManager` override; the composition root injects THAT manager into the controller, so registerUndo/undo/redo operate on the manager the shake resolves. TWO PR-review follow-ups (found independently by two reviewers) hardened it. First: becoming first responder ONCE in `viewDidAppear` is NOT enough - once a text field takes first responder (and the search field is now on every screen, so this happens constantly), it does not return to the host on resign, and the shake silently breaks again; the host must RE-CLAIM first responder whenever focus should return to it (keyboard-hide / text end-editing / app-did-become-active notifications), deferred a runloop tick and skipped while a field is actively edited so it never fights the keyboard. Second, on testing: driving `UndoManager.undo()` synchronously in a unit test corrupts the harness heap (the registered closure hops onto an async Task that re-registers the redo outside the manager's undoing state, with no run loop to close the group) - so make the controller's own undo/redo work seams (`undoDelete`/`redoDelete`) internal and drive THEM directly with the injected manager present; that proves the shake channel RESTORES, the redo RE-DELETES, and the stale-pending leak guard commits a prior pending, while the literal `UndoManager.undo()` call and the physical shake stay manual-verify. Generalizes: if a SwiftUI feature depends on the system Undo/Shake gesture, do not trust `@Environment(\.undoManager)` - vend a stable manager from a first-responder-backed controller AND re-claim first responder after any text field takes it (not just once on appear); and treat run-loop-coupled system objects (UndoManager grouping) as manual-verify at the top, seam-tested (drive the work functions directly) underneath.

## Thread the create-context's location into the create path so a new artifact lands where the user is (feedback 0018)

Recording a thought while browsing a folder created it at the ROOT, because the record action routed through the shared session seam with no folder context and the dictation view model defaulted `folderPath = []`; the dictation cover is presented at the root, decoupled from which folder requested it, so the browsing context was lost. The fix threads a `folderPath` through `DictationViewModel.init` (a resuming thought still overrides it with its own folder) and captures the current folder at the moment Record/mic is tapped (the folder screen and thought page both know it), handing it to the model so the thought lands where the user was; hands-free entry points (Siri/CarPlay) keep passing `[]`. A companion lesson: a title-placement choice made for ONE screen (feedback 0016's inline root title) should be checked against the OTHER screens sharing the chrome before it ships - it read as cramped on folder screens, so both root and folder now use one consistent large title below the toolbar. Generalizes: when a "create" action is reachable from a scoped context (a folder, project, board), thread that scope into the create path rather than defaulting to the root and forcing a move - and if the create is decoupled from its trigger (a root-presented sheet), capture the context at trigger time and carry it through; and prefer one consistent presentation across a navigation stack over a per-screen local optimization.

## A product-wide term rename is a symbol rename with a frozen persistence + behavior boundary (spec 0024)

Renaming the domain term "note" -> "thought" across the whole app (types, files, members, tests, UI copy, docs) was safe only because one boundary was drawn and held: the on-disk and settings SERIALIZATION, plus the live voice-recognition GRAMMAR, are contracts that a rename must not touch. The Swift TYPE `Note` becomes `Thought`, but the strings it persists stay byte-identical: the Markdown frontmatter KEYS (`id`, `title`, `titleCustom`, `created`, `audio`, `timings`), the `<id>.md`/`<id>.m4a` filename scheme, the `.trash/` and `ThoughtStream` directory names, the UserDefaults key VALUES (`settings.noteSortOrder` kept even though its Swift accessor became `thoughtSortOrder`), the `ThoughtSortOrder` rawValue tags (`newest`/`oldest`/`titleAZ`/`titleZA`), and the `LockScreenTitle.noteTitle` case (its rawValue is a stored `storageTag`). Renaming any of those would ORPHAN every saved thought or reset every setting - the type name is code, the string it writes is data. The mechanical rename ran as a case-preserving whole-word/camelCase substitution with those exact literals MASKED first and restored after, so a blind pass could never rewrite a persisted string; the one prose "Note:" (N.B.) comment and the "Note that" doc sentence were masked too, since only the DOMAIN noun is the target. Two decisions were judgment calls worth recording. First, the Mira voice-editing grammar ("Mira new note" spoken mid-dictation) and the Siri phrases ARE product vocabulary, not persisted data, so they moved to "thought" together with the cheat-sheet and the tests that lock them - a matched set that must change in lockstep or the on-screen hint stops matching what fires. Second, the ONLY hard verifications that matter for a pure rename are: the full suite stays green at the SAME test count (renamed, not removed), a test loads an EXISTING on-disk file with the frozen keys and round-trips it, and a grep of the built strings shows no "note" left in UI copy. Generalizes to any product-wide term or symbol rename: enumerate the persistence + external-contract literals FIRST and freeze them explicitly (mask-and-restore, not trust-the-boundary), separate "code identifier" from "the string that identifier serializes", decide up front which user-facing vocabulary is product copy (rename) versus a stored/parsed contract (freeze), and prove the frozen format with an existing-artifact load test rather than only a fresh round-trip.

## Per-screen state that a multi-column layout shows twice must be lifted above the container, and the layout choice made a pure seam (spec 0022)

Going adaptive (a `NavigationSplitView` on iPad, the `NavigationStack` on iPhone) turned a design that was CORRECT for one-screen-at-a-time into a bug for two-columns-at-once, exactly where the 0021 architect review predicted it. The persistent bottom bar, the search query, and the global results were owned PER folder-screen instance and vended from a first-responder host attached to the single root stack - fine while a stack shows one screen, but under the split view the sidebar and content columns are BOTH folder screens on-screen at once, so each rendered its own search field bound to the one shared query (two fields fighting one state) and the shake could resolve against a stale column. The fix is structural, not cosmetic: LIFT the shared surface (bottom bar + search query + the results projection) ABOVE the navigation container so there is ONE instance across the whole split view, and have each column render bottom-bar-free (`showsBottomBar: false`) and read from the ONE projection computed once at the container. Three supports made it clean and provable. First: the layout DECISION is a pure function - `StreamContainer.decide(horizontalSizeClass:)` (regular -> split, compact/nil -> stack) - so the size-class -> container choice is unit-tested exhaustively and the view just switches on it, and a nil (not-yet-resolved) size class defaults to the SAFE compact stack so the first frame is the unchanged iPhone layout rather than a split view that then collapses. Second: the search projection that was inline in the view's `resolveContent` (a `thoughts x paragraphs` scan) was extracted into a pure `StreamSearchProjection.resolve(didLoad:thoughts:searchQuery:)` returning the `(FolderScreenState, results)` pair, so the SAME single-scan seam feeds both the compact per-screen path and the split's one-shared-surface path, and a test pins that lifting it did not change the state for any input (parity with `FolderScreenState.select`). Third: a first-responder host that re-claims on text/keyboard notifications is NOT enough for multi-column - a plain column switch (pick a sidebar folder, pick a detail thought) fires none of those notifications, so the host needs an explicit re-home trigger the composition root bumps on the active-column change (guarded so an unrelated update does not yank focus from an actively-edited field). And the detail column, which has its OWN search field on the thought page (spec 0021), must DROP it under the split view (pass `onSearch: nil`) and defer to the always-visible lifted bar, or it reintroduces the very two-fields problem the lift removed. Generalizes to any move from a single-screen container to a multi-pane / split / master-detail one: any state a screen OWNS and a second simultaneously-visible screen would duplicate (a search field, a filter, a selection, a toolbar, a first-responder) must be hoisted to the shared parent and each pane made a thin renderer of it; make the container CHOICE a pure, tested decision with a safe default for the unresolved size class; extract any per-screen projection the panes now share into one pure function so both paths run identical logic; and re-home focus-dependent OS gestures on a pane switch, since a plain pane change fires no field/keyboard event.
