# 0001 - Themed shell

## Problem

Thought Buffer has no running app yet, only a README and design assets. Before wiring
on-device speech, CarPlay, or persistence, the team needs a buildable visual shell: a SwiftUI
app that runs in the simulator, wears the River Mist design tokens and the app icon, and shows
the notes-feed UI with mock data. This gives every later milestone a real surface to build on
and a way to review the look and feel.

## Outcome

- `ios/` holds an XcodeGen project (`project.yml` + Swift sources). The generated
  `.xcodeproj` is gitignored; only sources and config are committed.
- The app builds clean for an iPhone simulator and launches, showing:
  - a Stream list of mock note cards on the River Mist palette, in light and dark,
  - a note detail screen,
  - a mock dictation screen (no real speech).
- The app icon appears on the simulator home screen.
- Screenshots (light list, dark list, dictation) are committed under `design/screenshots/`.
- The README "Local development" section carries the real setup and token re-sync steps.

## Scope

In:
- XcodeGen project for a SwiftUI, iPhone-only app, min iOS 17.0, Swift 5 language mode.
- Vendored `Tokens.swift` from Canopy (River Mist), used for all color/spacing/radius.
- Single 1024 universal app icon wired into `Assets.xcassets`.
- `Note` model, `MockNotes` provider, and three presentational views: `StreamListView`,
  `NoteDetailView`, `DictationView`. An optional Settings stub.
- Screenshots and README update.

Out:
- Speech framework, CarPlay, persistence, Markdown storage, Siri, settings that do anything.
- iPad, unit tests beyond a smoke build (no behavior to test yet).
- Any real recording: the dictation screen is purely visual.

## Approach

- XcodeGen keeps the project file out of git so it never drifts or conflicts; contributors run
  `xcodegen generate`. `project.yml` pins bundle id `com.rogueoak.thoughtbuffer`, display name
  "Thought Buffer", `IPHONEOS_DEPLOYMENT_TARGET: 17.0`, `SWIFT_VERSION: 5.0`, iPhone-only.
- Tokens are vendored, not fetched at build time: copy Canopy's generated `Tokens.swift` under
  `DesignSystem/`, keep its generated header, note it is vendored and how to regenerate. All
  views read `CanopyColor` / `CanopySpacing` / `CanopyRadius` - no hardcoded hex.
- Views are split into small SwiftUI files. Mock data lives behind `MockNotes` so a real store
  can replace it later without touching the views.
- The dictation screen fakes "live" capture with a timer-driven streaming string, a blinking
  caret, and animated waveform bars built from shapes - no audio, no permissions.

## Acceptance

- [ ] `cd ios && xcodegen generate` produces `ThoughtBuffer.xcodeproj` (gitignored).
- [ ] `xcodebuild ... -scheme ThoughtBuffer -destination 'platform=iOS Simulator,name=iPhone 17' build` succeeds.
- [ ] App installs and launches in the iPhone 17 simulator; icon shows on the home screen.
- [ ] Stream list, note detail, and dictation screens render themed with River Mist tokens.
- [ ] `design/screenshots/stream-light.png`, `stream-dark.png`, `dictation.png` committed.
- [ ] README "Local development" documents generate/open/run and token re-sync.
