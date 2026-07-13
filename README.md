# Thought Stream

**Hands-free, on-device dictation notes for iPhone and CarPlay.**

Thought Stream is an iOS app for capturing your thinking out loud. Tap once (or ask Siri, or
press Start in CarPlay) and just talk. Unlike the built-in Notes app, Thought Stream is a
continuous feed of your thoughts that lets you pause to think and, importantly, edit entirely by
voice using a control word, so you never have to touch the screen.

All speech-to-text runs on the device. The words you speak are never sent to any server, and
dictation needs no internet connection. Your notes are stored locally by default; you can
optionally sync them through your own iCloud account so they follow you across your devices.

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

- **On-device speech-to-text.** Recognition runs entirely on your phone and works offline; the
  audio never leaves the device. No Thought Stream account required.
- **Voice recordings, kept or not.** Each note can keep the actual recording of your voice, so
  "read that back" plays how you said it and a note plays back in full. Recordings stay on your
  device by default (or your iCloud, if enabled). Turn them off (transcript only) or have them
  auto-delete after a set number of days, all in Settings.
- **Continuous feed.** Notes are a stream you can pause and resume, not a blank page each time.
- **Voice editing.** Fix and manage notes hands-free with the control word.
- **CarPlay support.** Capture safely while driving.
- **Markdown storage.** Every note is a Markdown file. Point storage at an iCloud Drive folder
  and notes sync across your devices automatically.
- **Browse and review.** A simple UI to jump back into the notes you have created.
- **Light and dark themes.** Follows the system appearance by default.

## Privacy

- **Speech is 100% on-device, always.** Recognition runs on your phone and the audio is never
  sent to any server. This never changes, whichever storage you pick.
- **No Thought Stream account, ever.** There is no Thought Stream sign-in and no Thought Stream
  server. "No account" means no account with us - iCloud, if you enable it, uses your existing
  Apple account, not one we create.
- **Notes are local by default; iCloud sync is optional and yours.** Your notes are plain files
  you own. Left local, they stay on the device. If you turn on iCloud sync, note files travel
  through your own iCloud account (Apple) so they appear in the Files app and follow you across
  your devices - the same way any iCloud Drive document does. That is the only thing that leaves
  the device, it is your choice, and it can be kept off.
- **Voice recordings are stored, and you control them.** When recording is on (the default), the
  raw audio of a note is saved as an `.m4a` next to its Markdown file, encrypted at rest, and
  syncs only where your notes do (locally, or your own iCloud). It is never uploaded to us. Set
  recordings to transcript-only to never save audio, or auto-delete them after a number of days,
  in Settings.

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

Requirements: macOS with Xcode 26 or newer, and the "iPhone 17" simulator (any recent iPhone
simulator on iOS 17 or newer works).

The Xcode project is generated by [XcodeGen](https://github.com/yonaskolb/XcodeGen) from
`ios/project.yml`, so `ios/ThoughtStream.xcodeproj` is not committed. Generate it first:

```
brew install xcodegen
cd ios
xcodegen generate
open ThoughtStream.xcodeproj
```

Then pick a simulator and press Run. From the command line:

```
xcodebuild -project ios/ThoughtStream.xcodeproj -scheme ThoughtStream \
  -destination 'platform=iOS Simulator,name=iPhone 17' build
```

After editing `ios/project.yml` or adding source files, run `xcodegen generate` again.

### First run: permissions and storage

On the first Record, the app asks for microphone and speech recognition access. Grant both, or
the dictation screen shows a message explaining what it needs and how to turn it on. Speech runs
on device (`requiresOnDeviceRecognition`); nothing is sent to a server.

Notes are saved as Markdown files, one `<id>.md` file per note (YAML frontmatter plus the body).
The Stream list reads them straight from disk, newest first.

Where those files live depends on iCloud. At launch the app resolves its iCloud Drive ubiquity
container off the main thread:

- **iCloud available** (signed in, container provisioned): notes read and write to the container's
  `Documents/ThoughtStream/` folder through `NSFileCoordinator` (coordinated IO, to avoid sync
  conflicts). The folder shows up in the Files app as "Thought Stream" and syncs across your
  devices. An `NSMetadataQuery` watches the folder, downloads notes synced in from other devices,
  and refreshes the Stream list on external changes.
- **iCloud unavailable** (not signed in, no provisioning, or the Simulator with no account): the
  app falls back to the local `Documents/ThoughtStream/` directory and behaves exactly as before.
  Nothing is lost; the choice is made once in the composition root.

#### Enabling real iCloud sync on a device

The iCloud Documents capability is declared in `ios/project.yml` (entitlements plus the
`NSUbiquitousContainers` Info.plist), targeting container `iCloud.com.rogueoak.thoughtstream`.
The repo builds unsigned for the Simulator with no development team, so at runtime in the
Simulator the container is nil and storage falls back to local - that is expected.

To use real iCloud sync on a physical device:

1. Open `ios/ThoughtStream.xcodeproj` (after `xcodegen generate`).
2. In the ThoughtStream target's Signing & Capabilities, set your Apple Developer **Team**. With
   automatic signing, the iCloud container provisions itself the first time you build to a device.
3. Sign in to iCloud on the device. Run the app; notes now live in your iCloud Drive under
   "Thought Stream" and sync across your devices.

Cross-device sync cannot be verified in the Simulator (it needs your Team and an iCloud account
on a device); the storage, coordination, selection, and fallback logic are covered by unit tests.

Live speech capture in the simulator is unreliable: it may use the Mac microphone or decline
on-device recognition. Verify real dictation on a physical device. To exercise the design in the
simulator without a mic, launch with `-uiScreen dictation`, which injects sample text; add
`mira-command` to also fire a Mira control chip. `-uiScreen settings` roots to a seeded Settings
screen for the same tooling.

Mira control words let you edit hands-free while dictating. Say "Mira" and a command: "Mira
remove the last sentence", "Mira remove the last paragraph", "Mira new note" (saves and starts
fresh), or "Mira read that back" (speaks the last paragraph aloud). The command phrase is not
written into the note.

Settings (the gear in the Stream toolbar) let you rename the assistant and teach it spelling
fixes. Change the control phrase from "Mira" to anything you like - "Nova remove the last
sentence" then works. Add spelling overrides (spoken "Shay" -> written "Shea") that auto-replace
words the recognizer gets wrong, whole-word and case-insensitive. A read-only row shows whether
notes live on iCloud or on this device. Settings persist across launches; changes apply to your
next dictation session.

### Siri and CarPlay

Starting a stream without touching the phone runs through one shared seam: the Record button, the
Siri App Intent, and the CarPlay action all request the same fresh dictation session.

**Siri (the shippable hands-free path).** `StartThoughtStreamIntent` and `NewNoteIntent` are
`AppIntent`s that open the app and begin a new session. An `AppShortcutsProvider` registers the
phrases on install, so "Hey Siri, start a stream in Thought Stream" (or "start dictating", "new
thought", "new note in Thought Stream") works, including through CarPlay's Siri button. Real Siri
invocation needs a device; the intents and the shared starter are covered by unit tests in the
simulator.

**CarPlay is scaffolded but gated, pending Apple's approval.** Apple grants the CarPlay
entitlement only for specific app categories (audio, navigation, communication, EV charging,
parking, and a few more). A dictation / notes app is not one of them, so the CarPlay entitlement
is generally unavailable for distribution here. The CarPlay scene delegate and its "Start a
thought stream" template are implemented and wired via the scene manifest, but **no CarPlay
entitlement is declared**, so:

- The default unsigned Simulator build and the App Store build are unaffected - they build and run
  with no CarPlay entitlement and no development team.
- Without the entitlement the system never creates the CarPlay scene, so it stays dormant. It is
  ready the day Apple grants the entitlement (or the app's category changes).
- Activating CarPlay needs Apple's entitlement plus a CarPlay head unit or the CarPlay simulator.
  Until then, Siri is the hands-free-in-car capability that actually ships.

### Design tokens

The River Mist tokens live in Canopy's `roots` package and are vendored into the app at
`ios/ThoughtStream/DesignSystem/Tokens.swift`. Do not edit that file by hand. To re-sync after
the tokens change upstream, from the Canopy `roots` package run:

```
npx roots-swift examples/thoughtstream/brand.config.json
```

then copy `dist/thoughtstream/Tokens.swift` over `ios/ThoughtStream/DesignSystem/Tokens.swift`,
keeping the generated header. All colors, spacing, and radii come from `CanopyColor`,
`CanopySpacing`, and `CanopyRadius`; do not hardcode hex.

## Roadmap

Thought Stream starts as a prototype for on-device testing and feedback, then ships to the App
Store as a paid app (a flat one-time price, no subscription).

## Publishing

Published by **Rogue Oak**.

## License

See [LICENSE](LICENSE) once added.
