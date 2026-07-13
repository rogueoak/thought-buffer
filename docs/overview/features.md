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
