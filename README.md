<p align="center">
  <img src="design/branding/wordmark.svg" alt="Thought Buffer" width="440" />
</p>

# Thought Buffer

**Hands-free, on-device dictation thoughts for iPhone and CarPlay.**

Thought Buffer is an iOS app for capturing your thinking out loud. Tap once (or ask Siri, or
press Start in CarPlay) and just talk. Unlike the built-in Notes app, Thought Buffer is a
continuous feed of your thoughts that lets you pause to think and, importantly, edit entirely by
voice using a control word, so you never have to touch the screen.

All speech-to-text runs on the device. The words you speak are never sent to any server, and
dictation needs no internet connection. Your thoughts are stored locally by default; you can
optionally sync them through your own iCloud account so they follow you across your devices.

## Why it exists

Ideas arrive when your hands are busy: driving, walking, cooking. The moment you reach for a
keyboard, the thought is gone. Thought Buffer keeps the capture friction near zero: start a
stream, speak, and fix mistakes by voice. Your thoughts land as plain Markdown files you own.

## How it works

### Dictating a thought

Start a session any of three ways:

- Tap the record button in the app to open a new thought and start talking.
- Say "Hey Siri, start a Thought Buffer".
- Press Start in CarPlay.

A new thought is created and your words stream into it. Pause whenever you need to think; the stream
waits for you.

### Control with words

Set a custom control phrase to enter command mode. The default assistant name is **Mira**.
Spoken commands include:

- "Mira remove the last sentence" - delete the last sentence.
- "Mira remove the last paragraph" - delete the last paragraph.
- "Mira new thought" - start a fresh thought.
- "Mira read that back" - read the last paragraph aloud.

### Auto-replace common mistakes

On-device recognition sometimes spells names its own way. In settings you can define spelling
overrides so a word you use often always comes out right. For example, map the sound "Shay" to
the spelling "Shea".

## Features

- **On-device speech-to-text.** Recognition runs entirely on your phone and works offline; the
  audio never leaves the device. No Thought Buffer account required.
- **Voice recordings, kept or not.** Each thought can keep the actual recording of your voice, so
  "read that back" plays how you said it and a thought plays back in full. Recordings stay on your
  device by default (or your iCloud, if enabled). Turn them off (transcript only) or have them
  auto-delete after a set number of days, all in Settings.
- **Continuous feed.** Thoughts are a continuous feed you can pause and resume, not a blank page each time.
- **Voice editing.** Fix and manage thoughts hands-free with the control word.
- **CarPlay Audio surface.** Browse your voice thoughts and play them back in CarPlay Now Playing,
  with play / pause / skip on the head unit, plus a Start row to begin a new thought hands-free.
- **Lock-screen playback.** Playing a thought shows Now Playing on the lock screen and in Control
  Center, and keeps playing in the background, like any audio app.
- **Markdown storage.** Every thought is a Markdown file. Point storage at an iCloud Drive folder
  and thoughts sync across your devices automatically.
- **Browse and review.** A simple UI to jump back into the thoughts you have created.
- **Light and dark themes.** Follows the system appearance by default.

## Privacy

- **Speech is 100% on-device, always.** Recognition runs on your phone (Apple's on-device
  `SpeechAnalyzer`) and the audio is never sent to any server. The language model downloads once,
  then works offline; that one-time model install is the only network touch, and it carries no
  audio or text. This never changes, whichever storage you pick.
- **No Thought Buffer account, ever.** There is no Thought Buffer sign-in and no Thought Buffer
  server. "No account" means no account with us - iCloud, if you enable it, uses your existing
  Apple account, not one we create.
- **Thoughts are local by default; iCloud sync is optional and yours.** Your thoughts are plain files
  you own. Left local, they stay on the device. If you turn on iCloud sync, thought files travel
  through your own iCloud account (Apple) so they appear in the Files app and follow you across
  your devices - the same way any iCloud Drive document does. That is the only thing that leaves
  the device, it is your choice, and it can be kept off.
- **Voice recordings are stored, and you control them.** When recording is on (the default), the
  raw audio of a thought is saved as an `.m4a` next to its Markdown file, encrypted at rest, and
  syncs only where your thoughts do (locally, or your own iCloud). It is never uploaded to us. Set
  recordings to transcript-only to never save audio, or auto-delete them after a number of days,
  in Settings.
- **Now Playing shows the thought title.** When you play a thought, its title (the thought's first line)
  appears in the system Now Playing surface - the lock screen, Control Center, and CarPlay - like
  any audio app shows its track title. This is your own content on your own device, never sent
  anywhere, and iOS's own "Show on Lock Screen" controls let you hide media info on the lock screen
  if you prefer.

## Tech and design

- **Native SwiftUI** app, targeting iPhone and CarPlay, using Apple's on-device Speech
  framework for recognition.
- **Design system from Canopy.** Thought Buffer shares design tokens (color, spacing, radius,
  type) and iconography with rogueoak's [Canopy](https://github.com/rogueoak/canopy) design
  system. Tokens are authored once in Canopy's `roots` package and generated into Swift so the
  app stays visually consistent with the rest of the rogueoak family. The palette is a custom
  "water / stream" theme with light and dark variants.
- **Conventions.** This repo follows [Trellis](https://github.com/rogueoak/trellis) (shared
  agent conventions) and [Spectra](https://github.com/rogueoak/spectra) (spec-driven
  development). See `AGENTS.md` and `docs/`.

## Local development

Requirements: macOS with Xcode 26 or newer, and the "iPhone 17" simulator (any recent iPhone
simulator on iOS 26 or newer works; the app targets iOS 26 for the on-device SpeechAnalyzer API).

The Xcode project is generated by [XcodeGen](https://github.com/yonaskolb/XcodeGen) from
`ios/project.yml`, so `ios/ThoughtBuffer.xcodeproj` is not committed. Generate it first:

```
brew install xcodegen
cd ios
xcodegen generate
open ThoughtBuffer.xcodeproj
```

Then pick a simulator and press Run. From the command line:

```
xcodebuild -project ios/ThoughtBuffer.xcodeproj -scheme ThoughtBuffer \
  -destination 'platform=iOS Simulator,name=iPhone 17' build
```

After editing `ios/project.yml` or adding source files, run `xcodegen generate` again.

#### Keep the project in sync automatically (recommended)

Because the `.xcodeproj` is generated and not committed, pulling changes that add new
source files leaves your local project stale - you get "Cannot find type" errors until
you regenerate. Run the one-time bootstrap to point git at the versioned hooks in
`.githooks/` and generate the project:

```
./scripts/bootstrap.sh
```

After that, `git pull` and branch switches regenerate `ios/ThoughtBuffer.xcodeproj`
automatically (via `post-merge` / `post-checkout` hooks) whenever anything under `ios/`
changed. You can also regenerate manually anytime with `./scripts/generate-project.sh`.

### First run: permissions and storage

On the first Record, the app asks for microphone and speech recognition access. Grant both, or
the dictation screen shows a message explaining what it needs and how to turn it on. Speech runs
on device (Apple's `SpeechAnalyzer`); nothing is sent to a server. The language model installs once
on first use (a model download, not your audio), then works offline.

Thoughts are saved as Markdown files, one `<id>.md` file per thought (YAML frontmatter plus the body).
The Stream list reads them straight from disk, newest first.

Where those files live depends on iCloud. At launch the app resolves its iCloud Drive ubiquity
container off the main thread:

- **iCloud available** (signed in, container provisioned): thoughts read and write to the container's
  `Documents/ThoughtBuffer/` folder through `NSFileCoordinator` (coordinated IO, to avoid sync
  conflicts). The folder shows up in the Files app as "Thought Buffer" and syncs across your
  devices. An `NSMetadataQuery` watches the folder, downloads thoughts synced in from other devices,
  and refreshes the Stream list on external changes.
- **iCloud unavailable** (not signed in, no provisioning, or the Simulator with no account): the
  app falls back to the local `Documents/ThoughtBuffer/` directory and behaves exactly as before.
  Nothing is lost; the choice is made once in the composition root.

#### Enabling real iCloud sync on a device

The iCloud Documents capability is declared in `ios/project.yml` (entitlements plus the
`NSUbiquitousContainers` Info.plist), targeting container `iCloud.com.rogueoak.thoughtbuffer`.
The repo builds unsigned for the Simulator with no development team, so at runtime in the
Simulator the container is nil and storage falls back to local - that is expected.

To use real iCloud sync on a physical device:

1. Open `ios/ThoughtBuffer.xcodeproj` (after `xcodegen generate`).
2. In the ThoughtBuffer target's Signing & Capabilities, set your Apple Developer **Team**. With
   automatic signing, the iCloud container provisions itself the first time you build to a device.
3. Sign in to iCloud on the device. Run the app; thoughts now live in your iCloud Drive under
   "Thought Buffer" and sync across your devices.

Cross-device sync cannot be verified in the Simulator (it needs your Team and an iCloud account
on a device); the storage, coordination, selection, and fallback logic are covered by unit tests.

Live speech capture in the simulator is unreliable: it may use the Mac microphone or decline
on-device recognition. Verify real dictation on a physical device. To exercise the design in the
simulator without a mic, launch with `-uiScreen dictation`, which injects sample text; add
`mira-command` to also fire a Mira control chip. `-uiScreen settings` roots to a seeded Settings
screen for the same tooling.

Mira control words let you edit hands-free while dictating. Say "Mira" and a command: "Mira
remove the last sentence", "Mira remove the last paragraph", "Mira new thought" (saves and starts
fresh), or "Mira read that back" (speaks the last paragraph aloud). The command phrase is not
written into the thought.

Settings (the gear in the Stream toolbar) let you rename the assistant and teach it spelling
fixes. Change the control phrase from "Mira" to anything you like - "Nova remove the last
sentence" then works. Add spelling overrides (spoken "Shay" -> written "Shea") that auto-replace
words the recognizer gets wrong, whole-word and case-insensitive. A read-only row shows whether
thoughts live on iCloud or on this device. Settings persist across launches; changes apply to your
next dictation session.

### Siri and CarPlay

Starting a thought without touching the phone runs through one shared seam: the Record button, the
Siri App Intent, and the CarPlay action all request the same fresh dictation session.

**Siri (the shippable hands-free path).** `StartThoughtBufferIntent` and `NewThoughtIntent` are
`AppIntent`s that open the app and begin a new session. An `AppShortcutsProvider` registers the
phrases on install, so "Hey Siri, start a thought in Thought Buffer" (or "start dictating", "new
thought", "add a thought in Thought Buffer") works, including through CarPlay's Siri button. Real Siri
invocation needs a device; the intents and the shared starter are covered by unit tests in the
simulator.

**CarPlay Audio surface (built, gated, pending Apple's approval).** The CarPlay scene is now a full
Audio experience: a recordings browser (`CPListTemplate` listing thoughts that have a recording -
title, date, duration, newest first, live-refreshed as thoughts are added or synced in) plus a
"Start a thought" row, and `CPNowPlayingTemplate` with play / pause / skip when you tap a
recording. It is driven by the shared, headless `ThoughtPlaybackController` - the one audio path that
also feeds the phone's lock-screen Now Playing. Apple grants the CarPlay entitlement only for
specific app categories (audio, navigation, communication, EV charging, parking, and a few more);
because Thought Buffer records and plays back the user's voice thoughts, the **Audio** category
(`com.apple.developer.carplay-audio`) fits - but it is granted only on approval, so:

- The default unsigned Simulator build and the App Store build are unaffected - they build and run
  with no CarPlay entitlement and no development team.
- Without the entitlement the system never creates the CarPlay scene, so it stays dormant. It is
  ready the day Apple grants the entitlement.
- Activating CarPlay needs Apple's Audio entitlement plus a CarPlay head unit or the CarPlay
  simulator. Until then, Siri is the hands-free-in-car capability that actually ships. See
  [docs/carplay-audio-entitlement-request.md](docs/carplay-audio-entitlement-request.md) for the
  request justification and the exact enable steps.

**System Now Playing (ships now, no entitlement).** Playing a thought - on the phone or in CarPlay -
populates `MPNowPlayingInfoCenter` (title, duration, elapsed) and wires `MPRemoteCommandCenter`
(play / pause / stop / skip), and the app declares the `audio` background mode, so a thought shows on
the lock screen and in Control Center and keeps playing in the background like any audio app. This
needs a device to see on the lock screen; the wiring is covered by unit tests in the simulator.

### Design tokens

The River Mist tokens live in Canopy's `roots` package and are vendored into the app at
`ios/ThoughtBuffer/DesignSystem/Tokens.swift`. Do not edit that file by hand. To re-sync after
the tokens change upstream, from the Canopy `roots` package run:

```
npx roots-swift examples/thoughtbuffer/brand.config.json
```

then copy `dist/thoughtbuffer/Tokens.swift` over `ios/ThoughtBuffer/DesignSystem/Tokens.swift`,
keeping the generated header. All colors, spacing, and radii come from `CanopyColor`,
`CanopySpacing`, and `CanopyRadius`; do not hardcode hex.

## Roadmap

Thought Buffer starts as a prototype for on-device testing and feedback, then ships to the App
Store as a paid app (a flat one-time price, no subscription).

## Publishing

Published by **Rogue Oak**.

## License

See [LICENSE](LICENSE) once added.
