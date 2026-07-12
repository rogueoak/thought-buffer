# Thought Stream

**Hands-free, on-device dictation notes for iPhone and CarPlay.**

Thought Stream is an iOS app for capturing your thinking out loud. Tap once (or ask Siri, or
press Start in CarPlay) and just talk. Unlike the built-in Notes app, Thought Stream is a
continuous feed of your thoughts that lets you pause to think and, importantly, edit entirely by
voice using a control word, so you never have to touch the screen.

All speech-to-text runs on the device. Nothing you say leaves your phone, and no internet
connection is required.

## Why it exists

Ideas arrive when your hands are busy: driving, walking, cooking. The moment you reach for a
keyboard, the thought is gone. Thought Stream keeps the capture friction near zero: start a
stream, speak, and fix mistakes by voice. Your notes land as plain Markdown files you own.

## How it works

### Dictating a note

Start a session any of three ways:

- Tap the record button in the app to open a new note and start talking.
- Say "Hey Siri, start a Thought Stream".
- Press Start in CarPlay.

A new note is created and your words stream into it. Pause whenever you need to think; the stream
waits for you.

### Control with words

Set a custom control phrase to enter command mode. The default assistant name is **Mira**.
Spoken commands include:

- "Mira remove the last sentence" - delete the last sentence.
- "Mira remove the last paragraph" - delete the last paragraph.
- "Mira new note" - start a fresh note.
- "Mira read that back" - read the last paragraph aloud.

### Auto-replace common mistakes

On-device recognition sometimes spells names its own way. In settings you can define spelling
overrides so a word you use often always comes out right. For example, map the sound "Shay" to
the spelling "Shea".

## Features

- **On-device speech-to-text.** Private by default, works offline, no account required.
- **Continuous feed.** Notes are a stream you can pause and resume, not a blank page each time.
- **Voice editing.** Fix and manage notes hands-free with the control word.
- **CarPlay support.** Capture safely while driving.
- **Markdown storage.** Every note is a Markdown file. Point storage at an iCloud Drive folder
  and notes sync across your devices automatically.
- **Browse and review.** A simple UI to jump back into the notes you have created.
- **Light and dark themes.** Follows the system appearance by default.

## Privacy

- Speech recognition happens locally on the device.
- No account, no sign-in, no server. The app is fully local.
- Your notes are your files, stored where you choose (on device or your own iCloud Drive folder).

## Tech and design

- **Native SwiftUI** app, targeting iPhone and CarPlay, using Apple's on-device Speech
  framework for recognition.
- **Design system from Canopy.** Thought Stream shares design tokens (color, spacing, radius,
  type) and iconography with rogueoak's [Canopy](https://github.com/rogueoak/canopy) design
  system. Tokens are authored once in Canopy's `roots` package and generated into Swift so the
  app stays visually consistent with the rest of the rogueoak family. The palette is a custom
  "water / stream" theme with light and dark variants.
- **Conventions.** This repo follows [Trellis](https://github.com/rogueoak/trellis) (shared
  agent conventions) and [Spectra](https://github.com/rogueoak/spectra) (spec-driven
  development). See `AGENTS.md` and `docs/`.

## Local development

> Setup instructions are coming as the Xcode project lands. Planned outline:

1. Requirements: macOS with Xcode, an iPhone or simulator running a recent iOS.
2. Clone this repo and open the Xcode project.
3. Regenerate design tokens from Canopy when they change (token pipeline documented here later).
4. Build and run on device to grant microphone and speech permissions.

## Roadmap

Thought Stream starts as a prototype for on-device testing and feedback, then ships to the App
Store as a paid app (a flat one-time price, no subscription).

## Publishing

Published by **Rogue Oak**.

## License

See [LICENSE](LICENSE) once added.
