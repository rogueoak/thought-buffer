# Features

What the product does, feature by feature.

## Themed shell (spec 0001)

The first buildable milestone: a SwiftUI app that runs in the simulator with the River Mist
palette, the app icon, and mock data. No speech, CarPlay, or persistence yet.

- **Stream list** - a scrollable feed of note cards (title, two-line snippet, timestamp,
  word count, primary accent dot) on the themed background, with a mic + gear toolbar and
  a floating Record button that opens dictation.
- **Note detail** - a read-only view of a note's paragraphs and timestamp.
- **Dictation (mock)** - the live-capture screen with a streaming sample string, a blinking
  caret, an animated waveform, a "Mira - removed last sentence" command chip, and a
  Pause / Mira record / New dock. Purely visual.
- **Settings stub** - a themed placeholder list; nothing here acts yet.

All screens follow the system light/dark appearance automatically through the tokens.

## On-device dictation (spec 0002)

Real dictation replaces the mock. Tap Record, grant microphone and speech access, and your words
stream into a note on device.

- **Live capture** - `SFSpeechRecognizer` with `requiresOnDeviceRecognition` turns speech into
  text with no network. Finalized phrases become paragraphs; the in-progress phrase shows live
  with a blinking caret. The waveform rides the real microphone level.
- **Continuous feed** - a recognition task ends on its own after a while; the service starts a
  fresh task on the same audio so dictation never stops, without losing committed text.
- **Pause / resume** - halts and continues capture without losing the note.
- **Save** - stopping writes the note as a Markdown file and returns to the Stream list with the
  new note on top.
- **Stream list + detail** - now load real saved notes (newest first) instead of mock data; an
  empty state invites the first recording. Opening a note shows its saved paragraphs.
- **Permission states** - denied or unavailable speech/mic shows a clear in-app message, not a
  crash or silence.

Voice editing (Mira), CarPlay, sync, Siri, and spelling overrides are still out; the `Note`
model keeps room for them.

## Mira control words (spec 0003)

Hands-free voice editing. Mid-dictation, say the control word "Mira" and a command and the app
acts on it instead of writing it into the note.

- **Remove the last sentence** - "Mira remove the last sentence" drops the last sentence of the
  note; if a paragraph empties, it goes too, so the note stays coherent.
- **Remove the last paragraph** - "Mira remove the last paragraph" drops the last paragraph.
- **New note** - "Mira new note" saves the current note and starts a fresh one while the session
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

Notes can live in the user's iCloud Drive so they sync across devices and appear in the Files app,
delivering the "markdown files in an iCloud folder, automatically synced" promise - while still
working offline-first when iCloud is not available.

- **iCloud when available** - at launch the app resolves its iCloud Drive ubiquity container. When
  it resolves (signed in, provisioned), notes read and write as `<id>.md` files in the container's
  `Documents/ThoughtStream/` folder, which shows up in the Files app as "Thought Stream" and syncs
  across the user's devices.
- **Coordinated IO** - every read, write, and delete goes through `NSFileCoordinator` so the app
  never races the iCloud sync daemon on the same file.
- **Live refresh** - an `NSMetadataQuery` watches the folder, triggers downloads for notes synced
  in from other devices, and refreshes the Stream list on external edits without a manual reload.
- **Graceful fallback** - when iCloud is unavailable (not signed in, no provisioning, or the
  Simulator with no account), the app falls back to local `Documents/ThoughtStream/` and behaves
  exactly as before. The choice is made once and is observable, so a later Settings status can show
  where notes live. Both backends share `Note`'s Markdown format, so switching never loses notes.

Real cross-device sync needs a physical device with an Apple Developer team and an iCloud account
(the capability auto-provisions the container). A Settings toggle/status UI and automatic import
of pre-existing local notes into iCloud are still out.

## CarPlay and Siri hands-free start (spec 0005)

Start a dictation session without touching the phone - the reason the product exists for people
whose hands are busy driving.

- **Siri (shippable).** "Hey Siri, start a stream in Thought Stream" (and friendly variants -
  "start dictating", "new thought", "new note in Thought Stream") launches the app straight into a
  fresh dictation session with capture starting. Siri works through the phone and through CarPlay's
  Siri button, so this is the real hands-free-in-car path today. Backed by `StartThoughtStreamIntent`
  / `NewNoteIntent` (`AppIntent`, `openAppWhenRun`) and an `AppShortcutsProvider` that registers the
  phrases on install.
- **One shared session start.** The Record button, the Siri intent, and CarPlay all request a start
  through one seam (`SessionStarter` / `PendingSessionRoute` on the composition root), so every entry
  point opens the same fresh `DictationView` and begins capture identically.
- **CarPlay (scaffolded, gated).** A `CPTemplateApplicationSceneDelegate` presents a list template
  with a "Start a thought stream" row that calls the same starter. It is wired via the CarPlay scene
  role in the scene manifest but is DORMANT: Apple grants the CarPlay entitlement only for specific
  app categories (audio, navigation, communication, EV, parking, ...), and a dictation / notes app is
  not one of them, so no CarPlay entitlement is declared. Without it the system never creates the
  scene, so the default unsigned build and the App Store build are unaffected. Activating CarPlay
  needs Apple's entitlement plus a CarPlay head unit or the CarPlay simulator - pending approval.

Parameterized intents ("start a stream about X"), a fully in-CarPlay live-capture UI, and Shortcuts
actions beyond start / new note are still out.

## Settings (spec 0006)

The Settings stub becomes real: two things a user configures, plus a read-only storage status.
Reachable from the gear in the Stream toolbar. Changes apply to the next dictation session started
(the text processor is built per session from current settings), noted in the UI copy.

- **Custom control phrase.** Name the assistant whatever you like (default "Mira"). Type "Nova" and
  "Nova remove the last sentence" fires the remove command while "Mira ..." no longer does; the
  command chip reads with the chosen name. Input is trimmed and validated: an empty, whitespace, or
  over-long value falls back to "Mira", so clearing the field is a valid reset.
- **Spelling overrides.** Keep an ordered list of from -> to fixes for words the recognizer gets
  wrong (spoken "Shay" -> written "Shea"). Add, edit, and delete pairs. They apply to dictated text
  before commit: whole-word and case-insensitive, so "shay"/"Shay" both become "Shea" while "Shayla"
  is untouched; multiple overrides apply together and never corrupt a substring. A control phrase is
  never spelling-mangled - commands are detected first, on the raw segment.
- **Storage status.** A read-only row shows whether notes live on iCloud or on this device, read
  from the backend the app resolved at launch.

Settings persist in `UserDefaults` across relaunch. Cloud sync of settings, per-note settings, and
importing / exporting override lists are out; changes take effect next session, not mid-session.

## Dual-capture recording and playback (spec 0007)

Dictation now keeps the real voice, not just the words. While a session runs, the same microphone
feed that drives recognition is teed to a compressed `.m4a` recording for that note, on device.
Recognition is unchanged and nothing leaves the phone.

- **One continuous recording.** One tap, forked to two sinks: the recognizer and an audio-file
  writer. The recognizer restarts its task many times per session (duration limits, hiccups), but
  the writer lives for the whole session, so the recording is one continuous file across every
  restart and across pause/resume.
- **Paragraph timing.** Each finalized paragraph knows its time range in the recording, captured
  from the recognizer's segment timestamps and anchored to absolute recording time across restarts.
  The timings persist with the note (frontmatter, tolerant and backward compatible - a note with no
  audio loads exactly as before).
- **Playback in your own voice.** A saved note plays back in full (simple play / stop) from its
  detail view, in the voice that recorded it. When a note has no recording (transcript-only, older
  notes, or auto-deleted), the play affordance is simply not shown. In-session "Mira read that back"
  speaks the last paragraph aloud - the current session's recording is still being written, so it is
  not finalized to play yet - reusing the pause-capture handshake so it never feeds back into the
  mic. The recording + timings model is left ready for a future recordings browser to seek per
  paragraph.
- **Retention you control.** Settings offers keep recordings (default), transcript-only (never
  record), or auto-delete after N days. Transcript-only skips the file writer entirely; auto-delete
  sweeps expired recordings at launch, keeping the note's text.
- **Lifecycle.** The recording is a sibling `<id>.m4a` next to the note's `<id>.md`. It saves,
  syncs, and deletes through the same storage layer with the same coordination and file protection;
  deleting a note deletes its recording.

Real mic capture and playback quality need a physical device (the Simulator mic produces no useful
audio); the pipeline is proven structurally and by tests. A recordings list, a waveform scrubber,
parameterized playback controls, and the CarPlay Audio surface / entitlement are out.

## CarPlay Audio surface, shared playback, and system Now Playing (spec 0008)

The recordings from spec 0007 become a real Audio-app experience: browse and play your voice notes
in CarPlay Now Playing and on the phone lock screen. This is the concrete basis for requesting
Apple's CarPlay **Audio** entitlement.

- **CarPlay recordings browser + Now Playing.** The CarPlay root is a `CPListTemplate` listing notes
  that HAVE a recording (title, relative date, duration), newest first, driven by the headless
  `NoteStoreDriver` through a `RecordingsListModel`. A top "Start a thought stream" row still begins
  a hands-free session through the shared `SessionStarter`. Tapping a recording plays its `.m4a` and
  pushes `CPNowPlayingTemplate` with working play / pause and skip (+/-15s over the note). The list
  refreshes live when a session saves or a note syncs in.
- **System Now Playing + remote commands (phone AND CarPlay).** Playing a note populates
  `MPNowPlayingInfoCenter` (title, duration, elapsed) and wires `MPRemoteCommandCenter`
  (play / pause / stop / skip), and the app declares the `audio` background mode, so a note played on
  the phone shows on the lock screen and in Control Center and keeps playing in the background - a
  real Audio-app trait that needs no entitlement.
- **One shared playback path.** A single headless `NotePlaybackController` owns the player, the lazy
  off-main URL resolution, and the Now Playing / remote-command wiring; both the phone detail view
  (through `NotePlaybackModel`) and the CarPlay scene drive it, so there is one audio path and one
  writer of `MPNowPlayingInfoCenter`. `AVAudioSession` `.playback` coexists with the record session
  used during dictation (dictation deactivates playback before recording, as spec 0007 established).
- **Entitlement gating.** The CarPlay scene stays dormant without the CarPlay Audio entitlement,
  exactly like the 0005 scaffold: the unsigned Simulator build and the App Store build stay green
  with an empty `DEVELOPMENT_TEAM` and no CarPlay entitlement declared.
  `docs/carplay-audio-entitlement-request.md` records the honest justification (on-device, records
  and plays the user's voice notes, low-distraction browse + Now Playing) and the exact steps to
  enable it once Apple grants it.

CarPlay itself needs the Audio entitlement plus a CarPlay head unit / the CarPlay simulator, so it is
proven structurally and by tests. The lock-screen Now Playing render needs a device; the wiring is
covered by unit tests. A waveform scrubber, per-paragraph seek, in-CarPlay live capture, and a
"play my last note" Siri intent are out.

## On-device feedback fixes (feedback 0005)

Fixes from real device testing:

- **Continuous feed survives a natural pause** - a recognition task that ends on a no-speech
  timeout now commits its in-progress words as a paragraph before restarting, so a pause mid-note
  never loses text.
- **Keyword-led command mode** - anything that leads with the control word is treated as a command
  and never transcribed; an unrecognized keyword-led phrase is dropped with a chip (see Mira above).
- **Swipe to delete** - the Stream list is a `List` with iOS-standard swipe-to-delete that removes
  the note and its sibling recording through the store, then reloads.
- **Word count** - note cards and the detail header show a word count ("12 words" / "1 word")
  instead of a paragraph count.
- **Louder waveform** - the mic-level -> bar-height mapping is tuned (perceptual curve, higher gain)
  so normal speech visibly moves the bars.
- **Record button never overlaps content** - it lives in the bottom safe-area inset, clear of the
  empty state and the list.
- **Playback discovery** - notes with a recording show a small play affordance on the card; tapping
  the card opens the detail Play control.

## Device speech accumulation fixes (feedback 0006)

Two device-only bugs the 0005 fix missed because the simulator/tests did not model how a real device
feeds speech (one task accumulates the whole passage and finalizes only on end):

- **A long pause no longer resets the note** - a task can end with an error and a NIL result, holding
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
- **Thoughts list** - the list is titled "Thoughts"; note cards have no disclosure chevron and are
  tappable across their full width.
- **Keyboard editing** - the saved-note page has an Edit/Done toggle to correct text with the
  keyboard; the record screen offers Edit while paused.
- **Resume a note** - a saved note's page offers Resume, reopening it into a dictation session that
  continues the same note. Appended text is added; the original recording is preserved (the resumed
  portion is text-only on playback).
- **Find recordings on the phone** - a waveform toggle in the Thoughts toolbar filters the list to
  notes that have a kept recording (previously browsable only on CarPlay).
- **Debug panel removed** - the on-record DEBUG diagnostic scaffolding is gone now that capture is
  verified on device.

## On-device round 2 (feedback 0009)

- **No duplicate from self-correction** - a recognizer revision that collapses spacing ("I'm saying
  the" -> "I'msayingthe.com") or drops a leading word ("What kind of games" -> "Kind of games") now
  updates in place instead of splitting into two paragraphs. Reset detection compares on normalized
  text (spacing/punctuation removed) and treats containment or start/end overlap as a revision.
- **Transcript auto-scrolls** while recording, keeping the newest words and the live caret in view.
- **Resume** on a saved note is a centered pill pinned to the bottom of the screen, clear of the
  scrolling note body.

## Home and note UX polish (feedback 0010)

Three UI-clarity refinements from using the app (no capture or storage change):

- **Labeled recordings filter** - the Thoughts toolbar's leading control keeps its waveform icon but
  now reads "Recordings", so it no longer looks like a record button. Recording still starts from the
  top-right mic or the bottom Record pill.
- **Duration instead of word count** - a note's at-a-glance stat is its recording duration ("1:24")
  when it has audio, falling back to the word count for a text-only note (transcript-only retention,
  resumed/edited notes, older files). Shown on the note card and the detail header. The duration
  formatter lives on `Note` as the single source of truth; the CarPlay recordings browser reuses it.
- **Tap to edit** - the saved-note page has no Edit button; tapping the note's text starts editing and
  a Done button (shown only while editing) commits. The record-screen paused-Edit affordance is
  unchanged.

## Home and note UX polish, round 2 (feedback 0011)

Three more refinements from using the app (no capture or storage change):

- **Recordings filter removed** - the Thoughts toolbar no longer carries the recordings-only toggle
  (added feedback 0008, labeled feedback 0010); it was a rarely-used mode switch on the home screen.
  Recorded notes are still obvious inline (each shows its play affordance and duration), and the
  CarPlay recordings browser is unchanged.
- **Mic + gear on the note page** - a note's detail page now has the same mic (start a new thought)
  and gear (Settings) as the Stream list, so a new thought is one tap from anywhere. The mic requests
  a session through the shared route the list uses; both are hidden while editing text.
- **Timestamp no longer goes stale** - the note card's "x mins ago" used to freeze at render (it read
  roughly the note's own recording length right after saving) because a SwiftUI label built from the
  current time has no wall-clock dependency to refresh on. It is now wrapped in a `TimelineView` that
  recomputes every minute against a live reference, and sits tighter to its clock glyph.

## Editable note titles (spec 0009)

Notes get a real, editable title instead of an always-derived one.

- **First-sentence default.** A new note's title is its first sentence - what you said before your
  first pause - not the whole first line. Derived through the existing `SentenceTokenizer`, capped and
  tidied; a single-sentence opening is unchanged.
- **Edit the title, separate from the body.** On a saved note's page the title is a prominent header
  you tap to edit (matching the body's tap-to-edit). A custom title sticks: later body edits no longer
  overwrite it. Clearing the title to empty resets it to the derived first sentence.
- **Persistence.** A user title is marked with a `titleCustom: true` frontmatter key, written only for
  a custom title so a derived-title note (and every existing file) serializes and loads exactly as
  before. Resuming a titled note keeps its title rather than re-deriving it.

## Animated launch cover (spec 0012)

A branded launch moment: on a normal cold launch the app shows a full-screen cover on the River Mist
background before the Thoughts list.

- **Icon over a waveform.** The app icon (rounded, with a subtle shadow) is centered, with a row of
  eight equalizer bars in the primary token beneath it that rise and fall as if reacting to a voice.
- **Speech-like animation.** The bars are driven by a `TimelineView(.animation)`; each bar's height
  is a phase-shifted sum of two sines of the timeline date, so the row ripples like speech rather than
  sweeping as one wave. The pure math lives in the testable `LaunchCoverView.barHeight(bar:of:at:)`.
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
real directories on disk (visible in Files / iCloud Drive), not tags - a note in a folder lives at
`Documents/ThoughtStream/<folder>/.../<id>.md` with its `<id>.m4a` beside it.

- **Nested folders.** Create a folder from the Thoughts toolbar (the folder-plus button); open it to
  see its notes and subfolders; create a folder inside a folder. The Thoughts screen is a navigation
  stack: tapping a folder pushes into it (the same folder-list screen at a deeper path), tapping a note
  opens its detail page, and Back walks the tree.
- **Interleaved, sorted list.** At any folder path the screen shows that folder's child folders AND the
  notes that live directly there, INTERLEAVED into one list ordered by the chosen sort. A folder sorts
  among notes by the same key: its "date" is its newest note anywhere underneath (recursively) and its
  "title" is its name, so an active folder rises to the top under newest-first and an empty folder sinks
  to the bottom.
- **Sort control.** A toolbar menu (the up/down arrows) offers newest-first (default), oldest-first,
  title A-Z, and title Z-A. The choice is global, persisted across launches, and the list re-sorts live
  when changed.
- **Move a note.** A note's leading swipe or context menu offers "Move to folder", opening a picker with
  "New folder...", "Top level", and every existing folder indented by depth. Picking one re-saves the
  note there; a recorded note keeps its recording (the store relocates the `.m4a` with the `.md`). Notes
  are always created at the top level and filed afterward.
- **Folder create / rename / delete.** A new folder is named in an alert (an unusable name - empty,
  `.`/`..`, hidden, or containing a separator - is rejected with a brief message). A folder row's
  context menu / swipe offers Rename (reports a name conflict) and Delete. Delete is a confirming,
  destructive cascade: it removes the folder, its notes, their recordings, and its subfolders.
- **Empty states.** The empty root reads "No notes yet - tap Record"; an empty folder reads "This folder
  is empty - move a note here, or create a folder inside it".
- **CarPlay unaffected.** The CarPlay recordings browser still lists every recorded note regardless of
  which folder it lives in.

## Keyboard notes (spec 0013)

Not every note starts by talking. You can now make a note with the keyboard, and add voice to a note
that began as text.

- **New note button.** A compose button (the pencil-in-square) on the Thoughts toolbar, next to the
  mic, creates a blank note and opens it straight into the keyboard editor - type a title and body,
  tap Done. It is filed in the folder you are currently browsing.
- **Discard-if-empty.** A brand-new note is not saved until the first non-empty commit. Backing out of
  a fresh note without typing anything - no title, no body - leaves nothing behind; the blank note is
  discarded rather than littering the list.
- **Record onto a text note.** The note page's record affordance is labeled **Record** when the note
  has no recording yet and **Resume** when it does. Recording into a text-only note captures real
  audio: the note becomes a true voice note (a Play control appears). The originally-typed paragraphs
  play back via text-to-speech; the newly spoken tail plays its recording. Recording into a note that
  already has audio stays a text-only append, so the original recording is never corrupted. Real audio
  capture is subject to the transcript-only retention setting.
- **Just a normal note.** A keyboard note is an ordinary `Note` on disk (no storage or format change),
  so it works with folders, sort, editing, and delete exactly like any other note.

## Natural text-to-speech voice (spec 0014)

Spoken text - Mira "read that back", and playback of text-only or resumed passages that have no
recording - now uses the best voice the user has installed for their language (premium, else enhanced,
else the system default), instead of always the robotic default. On a device with a modern voice
installed it sounds close to Siri; on one with only the compact voice it behaves exactly as before.
It stays on-device (`AVSpeechSynthesizer`), and enhanced/premium voices are a one-time user download
(Settings > Accessibility > Spoken Content > Voices). The literal Siri voice is Apple-private and not
available. The selection order lives in the pure, unit-tested `VoiceSelector`.

## Swipe to play and folder queue (spec 0015)

Playing a recording no longer means opening the note first. You can start a recording - or a whole
folder of them - with one gesture, and see what is playing without leaving the list.

- **Swipe a note right to play it.** A full leading swipe on a note that has a recording starts playing
  it immediately through the shared playback controller, so the lock screen, Control Center, and
  CarPlay light up as they already do. A text-only note offers no Play swipe (only Move).
- **Swipe a folder right to play the folder.** A full leading swipe on a folder plays its recordings as
  a queue: every recorded note anywhere in that folder's subtree, in the current sort order, one at a
  time, auto-advancing to the next when one finishes. Text-only notes are skipped, and an empty or
  all-text folder plays nothing.
- **A now-playing bar.** While something plays from the list, a compact bar sits above the Record
  button on every folder screen: the current title, a play/pause button, and a stop button; when a
  queue is running it also shows Next. Tapping the title opens that note. The bar disappears when
  playback stops or the queue ends.
- **One audio path.** The swipe, the bar, the note detail Play control, and CarPlay all drive the same
  shared controller and the same single system Now Playing item (spec 0008) - a queue only changes
  which note is current, never opening a second player or a second Now Playing writer.

## Modern on-device speech engine (spec 0002)

Dictation moves to Apple's iOS 26 `SpeechAnalyzer` / `SpeechTranscriber`. The app now requires
iOS 26.

- **Explicit paragraph boundaries.** The transcriber reports in-progress (volatile) text for the live
  caret and finalized, immutable results for committed paragraphs - each with a precise audio time
  range. The app no longer guesses where an utterance ends, so the whole class of reset / duplicate /
  self-correction bugs (feedback 0005-0009) cannot occur.
- **Still fully on-device.** Transcription runs on the phone; audio never leaves it. The language
  model installs once (a one-time download), then works offline.
- **Same everywhere else.** Notes, storage, iCloud, Mira commands, CarPlay, recording + playback, and
  editing/resume are unchanged - the swap sits behind the existing capture protocol.
