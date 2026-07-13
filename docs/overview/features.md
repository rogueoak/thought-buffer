# Features

What the product does, feature by feature.

## Themed shell (spec 0001)

The first buildable milestone: a SwiftUI app that runs in the simulator with the River Mist
palette, the app icon, and mock data. No speech, CarPlay, or persistence yet.

- **Stream list** - a scrollable feed of note cards (title, two-line snippet, timestamp,
  paragraph count, primary accent dot) on the themed background, with a mic + gear toolbar and
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

Recognition is case-insensitive and tolerant of phrasing ("delete" for "remove", optional filler
like "the"/"that"), and requires the control word to lead the phrase so a passing mention of
"Mira" never misfires. Each command flashes a brief control chip ("Mira - removed last sentence")
in the dictation screen. The control word is fixed to "Mira" for now; a configurable name and
spelling overrides are still out (Settings milestone), as are CarPlay, Siri, and sync.

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
