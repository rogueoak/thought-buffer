# Features

What the product does, feature by feature.

## Themed shell (spec 0001)

The first buildable milestone: a SwiftUI app that runs in the simulator with the River Mist
palette, the app icon, and mock data. No speech, CarPlay, or persistence yet.

- **Stream list** - a scrollable feed of thought cards (title, two-line snippet, timestamp,
  word count, primary accent dot) on the themed background, with a mic + gear toolbar and
  a floating Record button that opens dictation.
- **Thought detail** - a read-only view of a thought's paragraphs and timestamp.
- **Dictation (mock)** - the live-capture screen with a streaming sample string, a blinking
  caret, an animated waveform, a "Mira - removed last sentence" command chip, and a
  Pause / Mira record / New dock. Purely visual.
- **Settings stub** - a themed placeholder list; nothing here acts yet.

All screens follow the system light/dark appearance automatically through the tokens.

## On-device dictation (spec 0002)

Real dictation replaces the mock. Tap Record, grant microphone and speech access, and your words
stream into a thought on device.

- **Live capture** - `SFSpeechRecognizer` with `requiresOnDeviceRecognition` turns speech into
  text with no network. Finalized phrases become paragraphs; the in-progress phrase shows live
  with a blinking caret. The waveform rides the real microphone level.
- **Continuous feed** - a recognition task ends on its own after a while; the service starts a
  fresh task on the same audio so dictation never stops, without losing committed text.
- **Pause / resume** - halts and continues capture without losing the thought.
- **Save** - stopping writes the thought as a Markdown file and returns to the Stream list with the
  new thought on top.
- **Stream list + detail** - now load real saved thoughts (newest first) instead of mock data; an
  empty state invites the first recording. Opening a thought shows its saved paragraphs.
- **Permission states** - denied or unavailable speech/mic shows a clear in-app message, not a
  crash or silence.

Voice editing (Mira), CarPlay, sync, Siri, and spelling overrides are still out; the `Thought`
model keeps room for them.

## Mira control words (spec 0003)

Hands-free voice editing. Mid-dictation, say the control word "Mira" and a command and the app
acts on it instead of writing it into the thought.

- **Remove the last sentence** - "Mira remove the last sentence" drops the last sentence of the
  thought; if a paragraph empties, it goes too, so the thought stays coherent.
- **Remove the last paragraph** - "Mira remove the last paragraph" drops the last paragraph.
- **New thought** - "Mira new thought" saves the current thought and starts a fresh one while the session
  keeps recording.
- **Read that back** - "Mira read that back" speaks the last paragraph aloud. Capture pauses
  while Mira speaks so the audio does not feed back into recognition, then resumes.

Recognition is case-insensitive and tolerant of phrasing ("delete" for "remove", filler like
"the"/"that"/"to me"). The control word is detected as a token ANYWHERE in a finalized segment, not
only at the start (feedback 0006): on a real device a whole passage accumulates into one segment, so
a spoken command lands mid/end of it. The segment is SPLIT at the first control word - the dictation
BEFORE it is committed as a paragraph (with spelling overrides applied), and the text FROM the control
word to the end is command mode, never transcribed. It either runs, or (keyword-led but unrecognized)
is dropped with a brief "didn't catch that" chip. The tradeoff: a mid-sentence mention of the
assistant's name is treated as a command from that point, so pick an uncommon name if that bites.
Each command flashes a brief control chip ("Mira - removed last sentence") in the dictation screen.
The control word is configurable (Settings, default "Mira"); CarPlay, Siri, and sync ship separately.

## iCloud Drive storage (spec 0004)

Thoughts can live in the user's iCloud Drive so they sync across devices and appear in the Files app,
delivering the "markdown files in an iCloud folder, automatically synced" promise - while still
working offline-first when iCloud is not available.

- **iCloud when available** - at launch the app resolves its iCloud Drive ubiquity container. When
  it resolves (signed in, provisioned), thoughts read and write as `<id>.md` files in the container's
  `Documents/ThoughtBuffer/` folder, which shows up in the Files app as "Thought Buffer" and syncs
  across the user's devices.
- **Coordinated IO** - every read, write, and delete goes through `NSFileCoordinator` so the app
  never races the iCloud sync daemon on the same file.
- **Live refresh** - an `NSMetadataQuery` watches the folder, triggers downloads for thoughts synced
  in from other devices, and refreshes the Stream list on external edits without a manual reload.
- **Graceful fallback** - when iCloud is unavailable (not signed in, no provisioning, or the
  Simulator with no account), the app falls back to local `Documents/ThoughtBuffer/` and behaves
  exactly as before. The choice is made once and is observable, so a later Settings status can show
  where thoughts live. Both backends share `Thought`'s Markdown format, so switching never loses thoughts.

Real cross-device sync needs a physical device with an Apple Developer team and an iCloud account
(the capability auto-provisions the container). A Settings toggle/status UI and automatic import
of pre-existing local thoughts into iCloud are still out.

## CarPlay and Siri hands-free start (spec 0005)

Start a dictation session without touching the phone - the reason the product exists for people
whose hands are busy driving.

- **Siri (shippable).** "Hey Siri, start a thought in Thought Buffer" (and friendly variants -
  "start dictating", "new thought", "add a thought in Thought Buffer") launches the app straight into a
  fresh dictation session with capture starting. Siri works through the phone and through CarPlay's
  Siri button, so this is the real hands-free-in-car path today. Backed by `StartThoughtBufferIntent`
  / `NewThoughtIntent` (`AppIntent`, `openAppWhenRun`) and an `AppShortcutsProvider` that registers the
  phrases on install.
- **One shared session start.** The Record button, the Siri intent, and CarPlay all request a start
  through one seam (`SessionStarter` / `PendingSessionRoute` on the composition root), so every entry
  point opens the same fresh `DictationView` and begins capture identically.
- **CarPlay (scaffolded, gated).** A `CPTemplateApplicationSceneDelegate` presents a list template
  with a "Start a thought" row that calls the same starter. It is wired via the CarPlay scene
  role in the scene manifest but is DORMANT: Apple grants the CarPlay entitlement only for specific
  app categories (audio, navigation, communication, EV, parking, ...), and a dictation / thoughts app is
  not one of them, so no CarPlay entitlement is declared. Without it the system never creates the
  scene, so the default unsigned build and the App Store build are unaffected. Activating CarPlay
  needs Apple's entitlement plus a CarPlay head unit or the CarPlay simulator - pending approval.

Parameterized intents ("start a thought about X"), a fully in-CarPlay live-capture UI, and Shortcuts
actions beyond start / new thought are still out.

## Settings (spec 0006)

The Settings stub becomes real: two things a user configures, plus a read-only storage status.
Reachable from the gear in the Stream toolbar. Changes apply to the next dictation session started
(the text processor is built per session from current settings), noted in the UI copy.

- **Custom control phrase.** Name the assistant whatever you like (default "Mira"). Type "Nova" and
  "Nova remove the last sentence" fires the remove command while "Mira ..." no longer does; the
  command chip reads with the chosen name. Input is trimmed and validated: an empty, whitespace, or
  over-long value falls back to "Mira", so clearing the field is a valid reset.
- **Command aliases (spec 0018).** Register extra single-word spellings that ALSO fire command mode,
  so a recognizer mishearing of the control word ("mirror" for "Mira") still triggers a command
  instead of being written into the thought. An editable list under the control-word field adds (a field
  + a plus button) and deletes (swipe) aliases; each alias is fully equivalent to the control word.
  A fresh install ships a default set for "Mira" ("mirra", "meera", "mirror"). Validation keeps only
  single tokens, de-duplicates case-insensitively, and never lets an alias shadow the primary word;
  matching is token-based so "admiral" never matches "mira". Aliases apply to the next session, like
  the control word.
- **Spelling overrides.** Keep an ordered list of from -> to fixes for words the recognizer gets
  wrong (spoken "Shay" -> written "Shea"). Add, edit, and delete pairs. They apply to dictated text
  before commit: whole-word and case-insensitive, so "shay"/"Shay" both become "Shea" while "Shayla"
  is untouched; multiple overrides apply together and never corrupt a substring. A control phrase is
  never spelling-mangled - commands are detected first, on the raw segment.
- **Storage status.** A read-only row shows whether thoughts live on iCloud or on this device, read
  from the backend the app resolved at launch.

Settings persist in `UserDefaults` across relaunch. Cloud sync of settings, per-thought settings, and
importing / exporting override lists are out; changes take effect next session, not mid-session.

## Dual-capture recording and playback (spec 0007)

Dictation now keeps the real voice, not just the words. While a session runs, the same microphone
feed that drives recognition is teed to a compressed `.m4a` recording for that thought, on device.
Recognition is unchanged and nothing leaves the phone.

- **One continuous recording.** One tap, forked to two sinks: the recognizer and an audio-file
  writer. The recognizer restarts its task many times per session (duration limits, hiccups), but
  the writer lives for the whole session, so the recording is one continuous file across every
  restart and across pause/resume.
- **Paragraph timing.** Each finalized paragraph knows its time range in the recording, captured
  from the recognizer's segment timestamps and anchored to absolute recording time across restarts.
  The timings persist with the thought (frontmatter, tolerant and backward compatible - a thought with no
  audio loads exactly as before).
- **Playback in your own voice.** A saved thought plays back in full (simple play / stop) from its
  detail view, in the voice that recorded it. When a thought has no recording (transcript-only, older
  thoughts, or auto-deleted), the play affordance is simply not shown. In-session "Mira read that back"
  speaks the last paragraph aloud - the current session's recording is still being written, so it is
  not finalized to play yet - reusing the pause-capture handshake so it never feeds back into the
  mic. The recording + timings model is left ready for a future recordings browser to seek per
  paragraph.
- **Retention you control.** Settings offers keep recordings (default), transcript-only (never
  record), or auto-delete after N days. Transcript-only skips the file writer entirely; auto-delete
  sweeps expired recordings at launch, keeping the thought's text.
- **Lifecycle.** The recording is a sibling `<id>.m4a` next to the thought's `<id>.md`. It saves,
  syncs, and deletes through the same storage layer with the same coordination and file protection;
  deleting a thought deletes its recording.

Real mic capture and playback quality need a physical device (the Simulator mic produces no useful
audio); the pipeline is proven structurally and by tests. A recordings list, a waveform scrubber,
parameterized playback controls, and the CarPlay Audio surface / entitlement are out.

## CarPlay Audio surface, shared playback, and system Now Playing (spec 0008)

The recordings from spec 0007 become a real Audio-app experience: browse and play your voice thoughts
in CarPlay Now Playing and on the phone lock screen. This is the concrete basis for requesting
Apple's CarPlay **Audio** entitlement.

- **CarPlay recordings browser + Now Playing.** The CarPlay root is a `CPListTemplate` listing thoughts
  that HAVE a recording (title, relative date, duration), newest first, driven by the headless
  `ThoughtStoreDriver` through a `RecordingsListModel`. A top "Start a thought" row still begins
  a hands-free session through the shared `SessionStarter`. Tapping a recording plays its `.m4a` and
  pushes `CPNowPlayingTemplate` with working play / pause and skip (+/-15s over the thought). The list
  refreshes live when a session saves or a thought syncs in.
- **System Now Playing + remote commands (phone AND CarPlay).** Playing a thought populates
  `MPNowPlayingInfoCenter` (title, duration, elapsed) and wires `MPRemoteCommandCenter`
  (play / pause / stop / skip), and the app declares the `audio` background mode, so a thought played on
  the phone shows on the lock screen and in Control Center and keeps playing in the background - a
  real Audio-app trait that needs no entitlement.
- **One shared playback path.** A single headless `ThoughtPlaybackController` owns the player, the lazy
  off-main URL resolution, and the Now Playing / remote-command wiring; the phone surfaces (the bottom
  player and the thought detail's Play button, spec 0027) and the CarPlay scene all drive it, so there is
  one audio path and one writer of `MPNowPlayingInfoCenter`. `AVAudioSession` `.playback` coexists with the record session
  used during dictation (dictation deactivates playback before recording, as spec 0007 established).
- **Entitlement gating.** The CarPlay scene stays dormant without the CarPlay Audio entitlement,
  exactly like the 0005 scaffold: the unsigned Simulator build and the App Store build stay green
  with an empty `DEVELOPMENT_TEAM` and no CarPlay entitlement declared.
  `docs/carplay-audio-entitlement-request.md` records the honest justification (on-device, records
  and plays the user's voice thoughts, low-distraction browse + Now Playing) and the exact steps to
  enable it once Apple grants it.

CarPlay itself needs the Audio entitlement plus a CarPlay head unit / the CarPlay simulator, so it is
proven structurally and by tests. The lock-screen Now Playing render needs a device; the wiring is
covered by unit tests. A waveform scrubber, per-paragraph seek, in-CarPlay live capture, and a
"play my last thought" Siri intent are out.

## On-device feedback fixes (feedback 0005)

Fixes from real device testing:

- **Continuous feed survives a natural pause** - a recognition task that ends on a no-speech
  timeout now commits its in-progress words as a paragraph before restarting, so a pause mid-thought
  never loses text.
- **Keyword-led command mode** - anything that leads with the control word is treated as a command
  and never transcribed; an unrecognized keyword-led phrase is dropped with a chip (see Mira above).
- **Swipe to delete** - the Stream list is a `List` with iOS-standard swipe-to-delete. As of spec
  0020 the delete is UNDOABLE (see "Undoable delete" below): the thought and its recording are moved to
  the store's trash, an Undo affordance shows, and shaking the device offers "Undo Delete".
- **Word count** - thought cards and the detail header show a word count ("12 words" / "1 word")
  instead of a paragraph count.
- **Louder waveform** - the mic-level -> bar-height mapping is tuned (perceptual curve, higher gain)
  so normal speech visibly moves the bars.
- **Record button never overlaps content** - it lives in the bottom safe-area inset, clear of the
  empty state and the list.
- **Playback discovery** - thoughts with a recording show a small play affordance on the card; tapping
  the card opens the detail Play control.

## Device speech accumulation fixes (feedback 0006)

Two device-only bugs the 0005 fix missed because the simulator/tests did not model how a real device
feeds speech (one task accumulates the whole passage and finalizes only on end):

- **A long pause no longer resets the thought** - a task can end with an error and a NIL result, holding
  the words only as the in-progress partial. The service now tracks that partial and commits the best
  available text (result, else the partial) on ANY end, so the last-heard words survive the restart.
- **Mira commands fire mid-utterance** - the control word is detected ANYWHERE in a finalized
  segment, not only at the start. The segment splits at the first control word: the dictation before
  it is committed, and the rest is command mode (see Mira control words above).

## Post-device polish (feedback 0008)

Fixes and refinements from a round of on-device testing:

- **No duplicate paragraph after a command** - a task can commit an utterance as a paragraph via an
  utterance reset AND still lead with it in its final transcription, so a following command's split
  re-committed it. The service now strips the already-committed lead from the task-end transcription
  before committing the remainder.
- **Cheat sheet** - a Commands button by Stop opens a bottom drawer listing the control word, each
  voice command with what it does, and a pause-to-think tip.
- **Thoughts list** - the list is titled "Thoughts"; thought cards have no disclosure chevron and are
  tappable across their full width.
- **Keyboard editing** - the saved-thought page has an Edit/Done toggle to correct text with the
  keyboard; the record screen offers Edit while paused.
- **Resume a thought** - a saved thought's page offers Resume, reopening it into a dictation session that
  continues the same thought. Appended text is added. Resume now CONTINUES the AUDIO too (feedback 0022,
  superseding feedback 0008's text-only append): when audio retention is on, the new segment is recorded
  and concatenated onto the thought's existing recording as one file, with the new paragraphs' timings
  offset past the original so playback seeks correctly across the seam. On any concatenation failure the
  original recording is kept and the new paragraphs stay text-only (no data loss); a text-only thought
  resuming records a fresh recording (spec 0013), and retention OFF stays a text-only append.
- **Find recordings on the phone** - a waveform toggle in the Thoughts toolbar filters the list to
  thoughts that have a kept recording (previously browsable only on CarPlay).
- **Debug panel removed** - the on-record DEBUG diagnostic scaffolding is gone now that capture is
  verified on device.

## On-device round 2 (feedback 0009)

- **No duplicate from self-correction** - a recognizer revision that collapses spacing ("I'm saying
  the" -> "I'msayingthe.com") or drops a leading word ("What kind of games" -> "Kind of games") now
  updates in place instead of splitting into two paragraphs. Reset detection compares on normalized
  text (spacing/punctuation removed) and treats containment or start/end overlap as a revision.
- **Transcript auto-scrolls** while recording, keeping the newest words and the live caret in view.
- **Resume** on a saved thought is a centered pill pinned to the bottom of the screen, clear of the
  scrolling thought body.

## Home and thought UX polish (feedback 0010)

Three UI-clarity refinements from using the app (no capture or storage change):

- **Labeled recordings filter** - the Thoughts toolbar's leading control keeps its waveform icon but
  now reads "Recordings", so it no longer looks like a record button. Recording still starts from the
  top-right mic or the bottom Record pill.
- **Duration instead of word count** - a thought's at-a-glance stat is its recording duration ("1:24")
  when it has audio, falling back to the word count for a text-only thought (transcript-only retention,
  resumed/edited thoughts, older files). Shown on the thought card and the detail header. The duration
  formatter lives on `Thought` as the single source of truth; the CarPlay recordings browser reuses it.
- **Tap to edit** - the saved-thought page has no Edit button; tapping the thought's text starts editing and
  a Done button (shown only while editing) commits. The record-screen paused-Edit affordance is
  unchanged.

## Home and thought UX polish, round 2 (feedback 0011)

Three more refinements from using the app (no capture or storage change):

- **Recordings filter removed** - the Thoughts toolbar no longer carries the recordings-only toggle
  (added feedback 0008, labeled feedback 0010); it was a rarely-used mode switch on the home screen.
  Recorded thoughts are still obvious inline (each shows its play affordance and duration), and the
  CarPlay recordings browser is unchanged.
- **Mic + gear on the thought page** - a thought's detail page now has the same mic (start a new thought)
  and gear (Settings) as the Stream list, so a new thought is one tap from anywhere. The mic requests
  a session through the shared route the list uses; both are hidden while editing text.
- **Timestamp no longer goes stale** - the thought card's "x mins ago" used to freeze at render (it read
  roughly the thought's own recording length right after saving) because a SwiftUI label built from the
  current time has no wall-clock dependency to refresh on. It is now wrapped in a `TimelineView` that
  recomputes every minute against a live reference, and sits tighter to its clock glyph.

## Editable thought titles (spec 0009)

Thoughts get a real, editable title instead of an always-derived one.

- **First-sentence default.** A new thought's title is its first sentence - what you said before your
  first pause - not the whole first line. Derived through the existing `SentenceTokenizer`, capped and
  tidied; a single-sentence opening is unchanged.
- **Edit the title, separate from the body.** On a saved thought's page the title is a prominent header
  you tap to edit (matching the body's tap-to-edit). A custom title sticks: later body edits no longer
  overwrite it. Clearing the title to empty resets it to the derived first sentence.
- **Persistence.** A user title is marked with a `titleCustom: true` frontmatter key, written only for
  a custom title so a derived-title thought (and every existing file) serializes and loads exactly as
  before. Resuming a titled thought keeps its title rather than re-deriving it.

## Animated launch cover (spec 0012)

A branded launch moment: on a normal cold launch the app shows a full-screen cover on the River Mist
background before the Thoughts list.

- **Title over icon over a waveform.** A prominent "Thought Buffer" wordmark (Canopy `sizeX3xl`,
  bold) sits above the app icon, centered, with a tagline directly beneath it - "Capture your
  thoughts, hands free" (Canopy `sizeBase`, `textMuted`), in a tight inner stack so it reads as a
  subtitle under the title (feedback 0028). Below the pair is a row of eight thin equalizer bars in
  the primary token that rise and fall as if reacting to a voice. The bars are narrow (a named
  `barWidth`/`barSpacing`) so the row reads as a fine, logo-like waveform (feedback 0019). The
  icon is borderless and fades into the background: a soft radial mask (`logoFadeMask`) melts its
  edges into the River Mist backdrop rather than showing a crisp rounded tile with a shadow
  (feedback 0019). The title and tagline render in both the animated and Reduce Motion variants.
- **Speech-like animation.** The bars are driven by a `TimelineView(.animation)`; each bar's height
  is a phase-shifted sum of two sines of the timeline date, so the row ripples like speech rather than
  sweeping as one wave. The per-bar phase is indexed from the far end (`count - 1 - bar`) so the
  traveling wave sweeps in the intended direction (feedback 0018). The pure math lives in the testable
  `LaunchCoverView.barHeight(bar:of:at:)`.
- **Short hold, then cross-fade.** The cover holds for ~2.5s (a named constant) and cross-fades into
  the Thoughts list. It sits above the brief storage-resolution themed background, so the open is one
  smooth moment rather than background -> pop -> list. Tapping the cover skips it immediately.
- **Reduce Motion.** With Reduce Motion on, the bars hold static (varied, sampled once) instead of
  animating, and the cover still auto-dismisses.
- **Screenshot-safe.** `-uiScreen` tooling launches show no cover, so automated captures are
  unaffected.

The icon art is a `LaunchIcon` image set (a copy of the 1024 app-icon PNG), because SwiftUI's
`Image("AppIcon")` cannot load the app-icon asset directly. Nothing about storage, capture, or
navigation changes.

## Folders and sorting (spec 0010)

The flat, newest-first Thoughts stream becomes a browsable tree with a chosen sort order. Folders are
real directories on disk (visible in Files / iCloud Drive), not tags - a thought in a folder lives at
`Documents/ThoughtBuffer/<folder>/.../<id>.md` with its `<id>.m4a` beside it.

- **Nested folders.** Create a folder from the Thoughts toolbar (the folder-plus button); open it to
  see its thoughts and subfolders; create a folder inside a folder. The Thoughts screen is a navigation
  stack: tapping a folder pushes into it (the same folder-list screen at a deeper path), tapping a thought
  opens its detail page, and Back walks the tree.
- **Interleaved, sorted list.** At any folder path the screen shows that folder's child folders AND the
  thoughts that live directly there, INTERLEAVED into one list ordered by the chosen sort. A folder sorts
  among thoughts by the same key: its "date" is its newest thought anywhere underneath (recursively) and its
  "title" is its name, so an active folder rises to the top under newest-first and an empty folder sinks
  to the bottom.
- **Sort control.** A toolbar menu (the up/down arrows) offers newest-first (default), oldest-first,
  title A-Z, and title Z-A. The choice is global, persisted across launches, and the list re-sorts live
  when changed.
- **Move a thought.** A thought's leading swipe or context menu offers "Move to folder", opening a picker with
  "New folder...", "Top level", and every existing folder indented by depth. Picking one re-saves the
  thought there; a recorded thought keeps its recording (the store relocates the `.m4a` with the `.md`). Thoughts
  are always created at the top level and filed afterward.
- **Folder create / rename / delete.** A new folder is named in an alert (an unusable name - empty,
  `.`/`..`, hidden, or containing a separator - is rejected with a brief message). A folder row's
  context menu / swipe offers Rename (reports a name conflict) and Delete. Delete is a confirming,
  destructive cascade: it removes the folder, its thoughts, their recordings, and its subfolders.
- **Empty states.** The empty root reads "No thoughts yet - tap Record"; an empty folder reads "This folder
  is empty - move a thought here, or create a folder inside it".
- **CarPlay unaffected.** The CarPlay recordings browser still lists every recorded thought regardless of
  which folder it lives in.

## Keyboard thoughts (spec 0013)

Not every thought starts by talking. You can now make a thought with the keyboard, and add voice to a thought
that began as text.

- **New thought button.** A compose button (the pencil-in-square) on the Thoughts toolbar, next to the
  mic, creates a blank thought and opens it straight into the keyboard editor - type a title and body,
  tap Done. It is filed in the folder you are currently browsing.
- **Discard-if-empty.** A brand-new thought is not saved until the first non-empty commit. Backing out of
  a fresh thought without typing anything - no title, no body - leaves nothing behind; the blank thought is
  discarded rather than littering the list.
- **Record onto a text thought.** The thought page's record affordance is labeled **Record** when the thought
  has no recording yet and **Resume** when it does. Recording into a text-only thought captures real
  audio: the thought becomes a true voice thought (a Play control appears). The originally-typed paragraphs
  play back via text-to-speech; the newly spoken tail plays its recording. Recording into a thought that
  already has audio stays a text-only append, so the original recording is never corrupted. Real audio
  capture is subject to the transcript-only retention setting.
- **Just a normal thought.** A keyboard thought is an ordinary `Thought` on disk (no storage or format change),
  so it works with folders, sort, editing, and delete exactly like any other thought.

## Natural text-to-speech voice (spec 0014)

Spoken text - Mira "read that back", and playback of text-only or resumed passages that have no
recording - now uses the best voice the user has installed for their language (premium, else enhanced,
else the system default), instead of always the robotic default. On a device with a modern voice
installed it sounds close to Siri; on one with only the compact voice it behaves exactly as before.
It stays on-device (`AVSpeechSynthesizer`), and enhanced/premium voices are a one-time user download
(Settings > Accessibility > Spoken Content > Voices). The literal Siri voice is Apple-private and not
available. The selection order lives in the pure, unit-tested `VoiceSelector`.

## Swipe to play and folder queue (spec 0015)

Playing a recording no longer means opening the thought first. You can start a recording - or a whole
folder of them - with one gesture, and see what is playing without leaving the list.

- **Swipe a thought right to play it.** A full leading swipe on a thought that has a recording starts playing
  it immediately through the shared playback controller, so the lock screen, Control Center, and
  CarPlay light up as they already do. A text-only thought offers no Play swipe (only Move).
- **Swipe a folder right to play the folder.** A full leading swipe on a folder plays its recordings as
  a queue: every recorded thought anywhere in that folder's subtree, in the current sort order, one at a
  time, auto-advancing to the next when one finishes. Text-only thoughts are skipped, and an empty or
  all-text folder plays nothing.
- **A now-playing bar.** While something plays from the list, a compact bar sits above the Record
  button on every folder screen: the current title, a play/pause button, and a stop button; when a
  queue is running it also shows Next. Tapping the title opens that thought. The bar disappears when
  playback stops or the queue ends.
- **One audio path.** The swipe, the bar, the thought detail Play control, and CarPlay all drive the same
  shared controller and the same single system Now Playing item (spec 0008) - a queue only changes
  which thought is current, never opening a second player or a second Now Playing writer.

## Transcript refinement (spec 0016)

Spoken thoughts carry disfluencies and the recognizer splits sentences on short pauses. Refinement makes
the saved text read like written thoughts without changing what you said in substance, and adds a
hands-free way to drop the last thing said. It is on by default (a Settings toggle turns it off) and is
NON-DESTRUCTIVE to audio - only the transcript text is refined; playback still plays the original
recording.

- **Filler-word removal (live).** A conservative, whole-token, case-insensitive `FillerRemovalProcessor`
  strips standalone hesitations - `um, umm, uh, uhh, erm, hmm, uh-huh` - from committed dictation, tidies
  the spacing / dangling punctuation left behind, and re-capitalizes a sentence whose leading filler was
  removed ("um so, uh, the plan" -> "So, the plan"). Because it is on by default, the default set holds
  only unambiguous hesitations that can never be a real word or unit: it NEVER touches a filler inside a
  real word ("I am hungry", "a hummingbird"), a quoted span (`he said "um, no"` is kept verbatim), a
  unit ("20 mm of rain" - `mm`/`mmm` are excluded), or a real interjection ("Ah, finally!" - `er`/`ah`
  are excluded), and it excludes the often-meaningful connectives ("like", "so", "you know", "yeah",
  "right"). A false positive silently changes meaning, which is worse than leaving a filler in;
  `mm`/`mmm`/`er`/`ah` are candidates for a future opt-in "aggressive" list, not the default. A segment
  that was nothing but fillers is dropped (no empty paragraph, and the pause-based paragraph grouper's
  anchor is not advanced, so it cannot shift the next paragraph boundary). The stage runs AFTER the Mira
  command split and spelling overrides, so it only ever touches dictation text, never a command.
- **"Delete the last line" and "scratch that" commands.** After the control word, "delete/remove the
  last line" and "scratch that" both reuse the existing remove-last-sentence action (a spoken "line"
  maps to the last thing said); "delete the last paragraph" still drops a whole block. The cheat sheet
  lists the new phrasings.
- **Sentence-merge cleanup on edit.** A pure `TranscriptCleanup.reflow` merges obvious continuation
  lines in edited or imported text - a paragraph with no terminal punctuation followed by one that
  begins lowercase is joined with a space. It never merges across a deliberate break and never splits (a
  dictated list of adjacent lowercase items does merge by design - the escape hatch is a deliberate blank
  line between them). The pure `TranscriptCleanup.refinedForSave(thought, refine:)` is the single gate: it
  runs the merge only when refine is on AND on the edit-save path (never on load), so an untouched old
  thought is never silently rewritten.
- **Settings.** A "Refine transcript" toggle (default on) persists in `UserDefaults` and gates both the
  filler stage (built into the per-session text processor, so it takes effect next session) and the
  edit-save reflow. When off, text is committed verbatim (the pre-0016 behavior). The subtitle thoughts
  that audio is never changed. All refinement is local, deterministic, and rule-based - no cloud / LLM.

## Automatic dead-air removal (spec 0019) - REMOVED (feedback 0026)

This feature (trimming long silences from a finished recording and remapping paragraph timings) was
REMOVED in capture-pipeline feedback 0026. On device the trimmed playback was poor and it was not worth
the complexity, so it was cut at the user's request. There is no "Trim silences" setting and no code
path touches recording audio after capture. Recordings are the byte-for-byte capture. (The coordinated
`replaceAudio` store seam it once used remains, reused by the resume-continues-audio concatenation,
feedback 0022.)

## Capture pipeline: transcription quality (feedback 0026)

On-device dictation quality was tuned after a device report that it read poorly.

- **Dictation-tuned audio session.** The record session mode is `.spokenAudio` (Apple's dictation
  mode), not `.measurement`. `.measurement` disabled the input signal conditioning (gain / noise / echo
  processing) the recognizer relies on; `.spokenAudio` keeps it on, so the recognizer hears clean input.
- **Native formatting, verbatim words.** The iOS 26 `SpeechTranscriber` punctuates and formats natively
  from its language model - there is no punctuation "option" to set on it (verified against the SDK). Its
  one available transcription option, `etiquetteReplacements`, REDACTS words, so it is deliberately NOT
  set; the transcriber runs with empty `transcriptionOptions` for a faithful, unredacted transcript.
- **Conservative refinement, pinned.** The default-on filler removal and pause-based paragraph grouping
  are non-destructive: filler removal strikes only genuine whole-token hesitations (never a real word,
  unit, interjection, or quoted span), and grouping breaks paragraphs on a real silence gap (1.5s).
  Representative realistic transcripts (fillers, numbers, punctuation, a natural pause) are unit-tested
  so "good, faithful output" cannot silently regress.

Real on-device transcription quality is device-verifiable only (the Simulator does not run real
recognition); the refinement layer is proven by tests.

## Modern on-device speech engine (spec 0002)

Dictation moves to Apple's iOS 26 `SpeechAnalyzer` / `SpeechTranscriber`. The app now requires
iOS 26.

- **Explicit paragraph boundaries.** The transcriber reports in-progress (volatile) text for the live
  caret and finalized, immutable results for committed paragraphs - each with a precise audio time
  range. The app no longer guesses where an utterance ends, so the whole class of reset / duplicate /
  self-correction bugs (feedback 0005-0009) cannot occur.
- **Still fully on-device.** Transcription runs on the phone; audio never leaves it. The language
  model installs once (a one-time download), then works offline.
- **Same everywhere else.** Thoughts, storage, iCloud, Mira commands, CarPlay, recording + playback, and
  editing/resume are unchanged - the swap sits behind the existing capture protocol.

## Flowing, Notes-style paragraph breaks (feedback 0012)

Dictation now flows like the native Notes app instead of breaking a paragraph on every finalized
result. The iOS 26 transcriber finalizes on a short mid-thought breath, so the previous "one
finalized result = one paragraph" rule split a single spoken sentence into several paragraphs.

- **Pause-based grouping.** A pure `ParagraphGrouper` decides, per finalized segment, whether it
  FLOWS into the current paragraph or STARTS a new one, based on the silence gap between the previous
  segment's end and the new one's start (from the recognizer's time range, present even for a
  text-only session). Below the threshold (default 1.5s, a single device-tunable constant) the text
  joins the current paragraph with a space; at or above it, a new paragraph begins. A mid-thought
  breath stays in one paragraph; a real pause between distinct thoughts still breaks.
- **Resume-seam breaks.** A pause/resume restarts analysis (its time resets to ~0), so the first
  segment after a resume always starts a new paragraph rather than mis-merging across the seam.
- **Merged timings.** When segments merge into one paragraph, their recorded ranges merge into one
  contiguous range (first start through last end), so playback still seeks the paragraph correctly
  and the per-paragraph timing invariant holds.
- **Latency.** Lightweight `#if DEBUG` timestamp instrumentation at each partial/final emit gives a
  later device pass a way to measure real cadence; the mic tap buffer is a named constant so it can
  be tuned there. Final latency tuning is deferred to that device session (release builds carry no
  instrumentation overhead).

## Thought share and copy actions (spec 0017)

A thought's text can leave the app: send it to another app or copy it to the clipboard.

- **"..." actions menu on the thought page.** The thought detail toolbar carries an ellipsis menu (beside
  the mic and gear, shown in the normal non-editing state) with **Share** and **Copy text**. Share
  opens the system share sheet (`ShareLink`) so the thought can go to Messages, Mail, Thoughts, etc.; Copy
  text puts the same text on the pasteboard and flashes a brief "Copied to clipboard" confirmation.
- **Long-press a thought in the list.** A thought row's context menu also offers **Share** and **Copy
  text** (alongside "Move to folder"), so a thought can be shared without opening it. Folder rows get no
  share/copy - only thoughts have shareable text.
- **One plain-text form.** Both surfaces build the shared string from the pure, unit-tested
  `Thought.shareableText`: the title on its own line, a blank line, then the body paragraphs joined by
  blank lines. A thought with no custom title shares its derived title; a thought with no body shares just
  its title. Audio is never shared here - text only.

## Thought UX polish, round 3 (feedback 0013-0016)

Small consistency fixes to the thought card, detail page, and Thoughts header, from a round of device
use:

- **Tighter timer spacing (0013).** The thought card's timer/duration glyph sits as close to its label
  as the clock glyph does to its relative time, both using the same `CanopySpacing.x1` token.
- **Tap out to save a title (0014).** Editing a thought's title and tapping anywhere outside the field
  (the background, or into the body) now commits the title and resigns focus, just like the Done
  button - no Done tap required. The commit reads the live edited text, and title/body editing stay
  mutually exclusive (tapping into the body commits the title first).
- **Matching duration on the detail page (0015).** The thought detail header shows the recording
  duration with the same timer glyph and spacing as the list card, not a dash. Both the card and the
  detail header now render one shared `ThoughtMetaStats` component, so their metadata line cannot drift.
- **Inline Thoughts header (0016).** The top-level "Thoughts" title sits on the same navigation-bar
  row as the mic and gear buttons (inline title) instead of on its own large-title row below them.
  SUPERSEDED by spec 0021: the title moved back to a large title below the toolbar, consistent with the
  folder screens (the inline title read as cramped under the buttons).

## Undoable delete (spec 0020)

Deleting a thought is recoverable, matching the iOS "Shake to Undo" expectation and adding a Delete
action to the thought's actions menu:

- **Delete in the menus.** The shared `ThoughtActionsMenu` "..." menu (thought detail) and the list-row
  long-press context menu both carry a destructive **Delete**. The list-row swipe deletes through the
  same path. Deleting from the detail page pops back to the list, where the undo affordance shows.
- **Soft delete (trash + restore).** A delete does not destroy files: it MOVES the thought's `<id>.md`
  (and sibling `<id>.m4a`) into a hidden `.trash/<id>/` directory inside the store root, returning a
  lightweight `DeletedThought` token. Restore moves the files back to their original folder - or to the
  root if that folder was deleted meanwhile (never a failure). The trash never escapes the store root
  and is skipped by the thoughts list.
- **Undo affordance.** A brief, non-blocking "Thought deleted - Undo" chip (~5s, styled like the
  "Copied to clipboard" confirmation) appears after any delete; tapping Undo restores the thought.
- **Shake to Undo.** The delete is registered with the system `UndoManager`, so shaking the device
  offers "Undo Delete" (and redo re-deletes). Nothing else about shake-to-edit changes.
- **Purge.** When the undo window elapses the delete is committed (the trashed files are purged), and
  the trash is swept on launch so it never accumulates across app runs.

## Full-text search and bottom-bar redesign (spec 0021)

The bottom of every screen becomes a persistent bar with a wide search field, and search finds thoughts
by their whole text, not just the title.

- **Persistent bottom bar.** A shared bar across the list, folder, and thought-detail screens: a SEARCH
  FIELD filling most of the width on the left, ICON-ONLY action buttons on the right (text labels
  dropped to make room). List/folder screens show new-thought + record; the thought-detail screen shows
  resume (only when resuming applies per the audio-retention setting). The record/resume icon keeps its
  prominent affordance without a text label, and every now-unlabeled button keeps its accessibility
  label ("New thought", "Record", "Resume recording", "Search thoughts"). The bar is ONE component; each
  screen passes in its own right-side actions rather than forking it. The search field is its OWN bounded
  (rounded) pill and the action buttons sit BESIDE it, visually OUTSIDE the field's background rather than
  reading as inside it (feedback 0020). On the list/folder screens the new-thought + record pair sit behind
  ONE shared background (a `BottomBarButtonGroup` with the same surface + border + capsule treatment as the
  search pill) so they read as a single grouped unit beside the field, matching the top-left new-folder +
  sort toolbar group (feedback 0023); the thought-detail's lone resume button stays a single bare button.
- **Full-text search.** Typing filters to thoughts whose TITLE or ANY body paragraph contains the query -
  case-insensitive AND diacritic-insensitive, substring (not title-only). Search is GLOBAL across the
  whole folder tree, shown as a flat result list; tapping a result opens that thought, and clearing the
  field restores the normal folder view. It reuses the thoughts the store already loads (no separate
  index). The match logic is the pure, unit-tested `ThoughtSearch`. (Superseded by spec 0025: on the
  thought-detail screen the search field now performs IN-THOUGHT find, not global routing - see below. The
  list / folder screens stay GLOBAL.)
- **Empty state.** A list or folder with no thoughts shows a centered call to action instead of an empty
  list: the RECORD button in the middle WITH its text label and a NEW-THOUGHT button directly below it
  (the one place these keep labels). A non-empty store filtered to zero matches shows a "no matches"
  state with the search field still visible. The state selection (empty / results / no-matches /
  normal) is the pure, unit-tested `FolderScreenState`.
- **Three bottom affordances compose.** The now-playing bar (spec 0015) still sits above the bottom bar
  while playback is active, and the transient undo-delete chip (spec 0020) now stacks above BOTH in the
  SAME bottom safe-area inset (a shared VStack), so the three never overlap - the earlier hardcoded
  overlay clearance for the undo chip is gone (the chip previously overlapped the record control).
- **Consistent title below the toolbar (revises feedback 0016).** Both the root "Thoughts" screen and
  every folder screen show their title as a large title BELOW the toolbar buttons, reading identically,
  instead of the inline title (feedback 0016) that read as cramped under the buttons. The title is sized
  at the Canopy H3 step (`sizeX3xl`), one step below the system large title (feedback 0020), and renders
  immediately on navigation (feedback 0020 removed a state-during-view-update warning that lazy-rendered it).
- **Contextual record + new thought.** Recording or creating a thought while inside a folder files it in
  THAT folder, not at the root - the record/mic and new-thought actions carry the current folder path
  through to the dictation session (hands-free Siri/CarPlay starts stay at the root, having no folder
  context).
- **Reliable folder rename + Shake to Undo.** Folder rename now presents and applies reliably (the three
  folder dialogs were un-stacked into one dialog host), and Shake to Undo works (the delete registers on
  a stable, first-responder-backed `UndoManager` instead of the frequently-nil environment one).

## iPad support - adaptive split view (spec 0022)

Thought Buffer is a first-class iPad app, not a stretched iPhone app: on a wide canvas it presents a
multi-column layout, and on iPhone it is unchanged.

- **Adaptive navigation.** On REGULAR width (iPad, and iPhone landscape where it fits) the Thoughts root
  is a `NavigationSplitView`: the root folder tree in the SIDEBAR, the selected folder's thoughts in the
  CONTENT column (its own stack, so nested folders push there), and the selected thought in the DETAIL
  column. On COMPACT width (iPhone portrait) it stays today's single `NavigationStack`, one screen at a
  time. The size-class -> container choice is the pure, tested `StreamContainer.decide`; both containers
  share the SAME route model, dictation / resume covers, Settings sheet, and lifecycle.
- **One search surface across the split.** The persistent bottom bar, the search query, and the flat
  global results are LIFTED above the columns to the split container, so the sidebar and content columns
  drive ONE search field and one results list (not two fields fighting one shared query). The split
  detail column defers search to that always-visible lifted bar. The search projection is the pure,
  tested `StreamSearchProjection`, computed once and shared by both columns.
- **Shake to Undo across columns.** The first-responder `UndoManagerHost` re-homes itself when the split
  view's active column changes (a sidebar folder or a detail thought selection), so Shake to Undo keeps
  reaching the deletion controller's manager regardless of which column is focused.
- **Space that reads well.** The centered empty-state CTA and a detail-column placeholder ("Select a
  thought") size sensibly on a large canvas; the lifted search field spans without looking stretched;
  thought cards read well in a wider column. iPad supports all orientations (rotation and multitasking
  split adapt without a broken layout); iPhone stays portrait-only. The launch cover, share sheet, and
  dictation UI lay out correctly on iPad.

## Apple Watch quick-capture and browse (spec 0023)

Thought Buffer reaches the wrist: record a voice thought from the watch, and browse recent thoughts on
it. The watch does NOT transcribe - it captures audio and syncs it to the phone, which transcribes and
files it as a normal thought. This is a paired watchOS app, embedded in and a companion of the iPhone
app.

- **Quick capture on the watch.** A prominent Record button records the watch mic to a compressed `.m4a`;
  tap to start, tap to stop, with a haptic and a glanceable recording state. On stop the capture is queued
  for RELIABLE background transfer to the phone (`transferFile`), so a thought spoken while the phone is
  away or the watch app closes is not lost - it syncs once connectivity returns. A "Syncing N captures"
  line shows while a transfer is pending.
- **Phone transcribes and files it.** The phone receives the `.m4a` plus a small metadata payload (capture
  id, when it was spoken, an optional folder hint) and turns it into a normal thought: it runs the iOS 26
  file-based speech engine over the recording, groups the result into paragraphs with timings (the same
  pause-based grouping dictation uses), derives the title from the first sentence, attaches the audio, and
  saves it through the existing store - into the folder hint when it still exists, else the top level. The
  capture's timestamp becomes the thought's, so a thought that syncs minutes later still sorts by when it
  was spoken. If transcription fails or finds no words, the thought is filed AUDIO-ONLY (a "Voice thought -
  <time>" title, the recording attached and playable) rather than dropping the capture - the text can be
  regenerated later.
- **Browse and play on the watch.** The phone pushes a lightweight recent-thoughts list (title, one-line
  preview, duration) to the watch, which shows it newest-first. Tapping a thought shows its text and, for a
  recorded thought, a Play control that fetches the audio from the phone on demand and plays it on the
  watch. Read-only: no editing, folders, search, or settings on the wrist.
- **Shared, on-device, private.** The watch and phone share one definition of the wire format and the
  thought model (no drift). Audio and transcription stay on the user's devices; nothing leaves them. The
  watch link is inactive on an iPad (no paired watch) and unaffects the phone-only path.

Real on-watch mic capture, the live watch<->phone transfer, and real file transcription need a physical
device / a paired simulator (the watch simulator has no mic and WatchConnectivity needs a pairing); the
pure cores - the wire codecs, the file-transcription mapping, the recent-thoughts projection, and the
ingest/audio-only-fallback logic - are proven by unit tests. Complications and Siri on the watch are out
(a possible follow-up).

## In-thought find (spec 0025)

Searching WITHIN a thought finds the text, seeks to it, highlights it, and skips between matches -
contextual search that supersedes spec 0021's "the detail search field routes to the global results".

- **Contextual search field.** On a thought's detail screen the bottom-bar search field now finds within
  THAT thought, not the whole store. On the list / folder screens the field stays the GLOBAL finder from
  spec 0021, unchanged. (In the iPad split view the detail column has no field of its own - it defers to
  the always-visible lifted GLOBAL bar, so there are never two competing search surfaces.)
- **Seek + highlight.** Typing highlights every match in the thought's title and body (a Canopy highlight
  background), with the CURRENT match emphasized more strongly (a stronger background, bold), and scrolls
  the current match into view. Matching is case- and diacritic-insensitive substring, the same folding the
  global search uses.
- **Skip between matches.** Previous / next chevrons and an "N of M" count sit beside the field while a
  find is active. Next past the last match WRAPS to the first, previous before the first wraps to the last.
  Clearing the query removes all highlights and the prev/next/count affordance.
- **Find and edit are mutually exclusive.** Tapping the title or body to edit clears the find (no
  highlights or find bar under the editor); the bottom bar is hidden entirely while editing. Find state
  resets when the thought is left.
- **Pure, tested core.** The match locations (region = title or paragraph index, plus the character range),
  their ordering, next/previous navigation (wrapping), the "N of M" count, and the match -> scroll-anchor
  mapping are the pure, unit-tested `ThoughtFind` + `ThoughtFindNavigator` - the per-thought counterpart to
  `ThoughtSearch`. The AttributedString highlight rendering and the actual scroll-into-view are
  device-verifiable.

## Folder model redesign - top-level folders + All/Recents (spec 0026)

The Thoughts home is now FOLDERS ONLY, one level deep, with two pinned virtual folders at the top. This
supersedes spec 0010's nested folders + interleaved folders-and-thoughts and the feedback 0016/0020/0024
fixed below-the-toolbar title placement.

- **Top level = folders only.** The home screen lists two pinned ALIAS folders - **All Thoughts** and
  **Recents** - then the user's folders. No loose thoughts and no folders-and-thoughts interleaving at the
  top level. There is one level of nesting: a folder opens a flat list of its thoughts, and new sub-folders
  cannot be created (the new-folder button and move-to-folder target the top level).
- **Virtual alias folders.** All Thoughts and Recents are pure PROJECTIONS over the loaded thoughts, not
  real directories: **All Thoughts** opens every thought (any folder + uncategorized) flat, honoring the
  sort order; **Recents** opens the 10 most recent thoughts by created time, newest first (independent of
  the chosen sort). They cannot be renamed or deleted.
- **Uncategorized thoughts.** A thought not in any user folder (an `.md` at the store root) is
  uncategorized: it appears in All Thoughts and Recents, in no user folder.
- **New thought placement.** Creating a thought while INSIDE a user folder files it in that folder
  (contextual, as feedback 0021 established); creating one from the top level, All Thoughts, or Recents
  leaves it uncategorized - "it just goes under recents / all". The record and new-thought actions carry
  the placement; hands-free Siri/CarPlay starts stay uncategorized.
- **Legacy data still surfaces.** A thought that lived in an old nested folder is shown FLATTENED under its
  top-level folder (its folder name is the first path component), so no thought is hidden by the redesign.
  Storage is unchanged - thoughts stay `<id>.md`, folders stay directories, the root holds uncategorized
  thoughts - so existing thoughts and folders load exactly as before.
- **Title scrolls with the list; one unified grouped list.** Each screen's title ("Thoughts" at the top
  level; the folder name / "All Thoughts" / "Recents" inside) is now the FIRST row of the scrollable list
  and scrolls away, instead of a fixed title pinned below the toolbar. The rows themselves are a UNIFIED,
  Notes-app-style grouped list (feedback 0025): the surface + border + rounded corners wrap the WHOLE list
  as ONE inset card, with rows separated by hairline Canopy-border dividers, rather than each folder or
  thought floating as its own bordered card. The title sits above that card. The search-field
  focus-stability fix (feedback 0024) is preserved. This applies on both list screens (top-level folders
  and folder-thoughts) and to search results, and in both the iPad split content column and the compact
  stack.
- **Pure, tested core.** The alias projections (`allThoughts(sorted:)`, `recents(limit: 10)`), a user
  folder's flattened thoughts, the uncategorized filter, and the new-thought placement decision are the
  pure, unit-tested `TopLevelFolders` + `NewThoughtPlacement`. The list layout, the title-in-list, and the
  tighter rows are device-verifiable.

## Playback overhaul - bottom player, transport, Now Playing + Dynamic Island (spec 0027)

Recording playback becomes a real, persistent PLAYER at the bottom of the app, not a bare play button
inside the note. This supersedes spec 0015's simpler now-playing bar and extends spec 0008's Now Playing.

- **A bottom player, not inside the note.** Playing a recorded thought - from its row, its detail page,
  or a folder queue - surfaces a full player in the bottom stack, positioned above the search bar and
  below the transient undo chip. The thought screen no longer hosts its own transport: its "Play
  recording" button just starts the recording in the bottom player (and reads "Playing" while that
  thought is the loaded one). The player is one component, rendered in one place, so the compact iPhone
  layout and the iPad lifted stack both get it.
- **Full transport.** Play / pause, a draggable progress slider that seeks (elapsed vs remaining labels
  either side), and skip-back / skip-forward 15s buttons (clamped to the recording). The progress tracks
  playback live. A Next button still shows while a folder queue (spec 0015) has a next item, so the queue
  behavior is intact and additive.
- **Lock screen, Control Center, and Dynamic Island.** The Now Playing item carries the title, duration,
  live elapsed time, and playback rate, updated as playback advances and on every seek, so the system
  surfaces show the thought with a live progress bar. The remote commands are wired - play, pause, toggle,
  skip +/-15s, and change-position (scrub) - so the lock screen / Control Center / Dynamic Island expanded
  controls drive the same recording the in-app player does. The Dynamic Island appears automatically for
  the active audio session; no custom Live Activity is needed.
- **One audio path, pure core.** Everything drives the ONE shared `ThoughtPlaybackController`, which now
  publishes elapsed / duration / isPlaying and owns a live-progress ticker. The seek/skip clamp to
  [0, duration] and the elapsed / remaining time formatting are the pure, unit-tested `PlaybackProgress`.
  Real audio playback, the live Now Playing / Dynamic Island render, and the system remote commands are
  device-verifiable; the transport math and the Now Playing / remote-command wiring are proven by tests.

## List and folder UX fixes (feedback 0026)

Six polish fixes on the redesigned Thoughts screens (spec 0026):

- **Tighter list headers.** The scrolling section title sits close to its rows and to the toolbar
  (Notes-app rhythm), on both the top-level and folder screens, single-sourced in `StreamListTitleRow` +
  `unifiedList()`.
- **Aligned row icons.** The "All Thoughts" / "Recents" alias rows and the user-folder rows now share one
  icon frame width, so every row label lines up on a single left edge.
- **Stable search focus.** The bottom search field keeps focus from the first keystroke onward and stays
  focused/editable in the "No matches" state, so a query can be refined or cleared in place. A stable id on
  the bottom stack keeps the `TextField` the same instance across the content-state flip that a search
  triggers.
- **Working folder rename + delete.** Renaming or deleting a folder from the top-level screen now takes
  effect. The bug was the alert button reading the dialog's target path from state the dialog's own
  dismissal had already cleared; the payload is now captured synchronously at tap time.
- **In-folder folder menu.** Inside a user folder, a nav-bar "..." menu renames or deletes THAT folder,
  wired to the same store ops; delete pops back to the top level. Aliases (All Thoughts / Recents) have no
  such menu.
- **Three empty-state actions.** An empty user folder offers Move thoughts here, Record, and New thought.
  "Move thoughts here" opens a multi-select picker of every thought not already in the folder and files the
  chosen ones in. The Move action is omitted where it is meaningless (the root / All Thoughts / an alias, or
  a truly empty store).

## List and folder screen fixes (feedback 0029)

Five more fixes on the redesigned Thoughts screens (spec 0026):

- **No sort on the home page.** The folders-only top level dropped its sort control - folders show A-Z and
  the aliases (All Thoughts / Recents) define their own order, so there was nothing thought-ordered to sort.
  Sort stays INSIDE a folder (and still orders the top-level swipe-to-play queues), so the persisted choice
  is unchanged.
- **Search in the "Move thoughts here" drawer.** The multi-select move picker now has a search field that
  filters candidate thoughts live by title/text (the same `ThoughtSearch` matcher the global search uses).
  Selections persist across filtering.
- **Folder "Move into" everywhere.** "Move thoughts here" is now reachable on a non-empty folder too: from
  the folder screen's "..." menu and from a top-level folder row's swipe / context menu, beside Rename. All
  routes open the one multi-select picker and file the chosen thoughts in one batch.
- **Tighter title-to-list gap.** The first list row sits closer under the scrolling title (Notes-app tight),
  on both the top-level and folder screens; the title still scrolls with the list.
- **Search field keeps focus for good.** The list screens now host ONE persistent `List` whose rows change
  with the query (normal / results / no-matches), instead of swapping between two distinct `List` views. The
  search `TextField` lives in a safe-area inset on that single list, so it is never torn down mid-typing and
  keeps first responder across the first keystroke, every later keystroke, the no-matches state, and clearing
  the query. This is the third and final fix for the recurring dropped-focus bug (feedback 0024 / 0026).
