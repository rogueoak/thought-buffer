# 0005 - CarPlay and Siri hands-free session start

## Problem

Ideas arrive when your hands are busy - driving above all. Today the only way to start a
Thought Stream is to open the app and tap Record. In the car that is exactly the friction the
product exists to remove. The user needs to begin dictating without touching the phone.

Two hands-free entry points are in scope:

- **Siri (primary, shippable).** "Hey Siri, start a Thought Stream" begins a new dictation
  session. Siri works in the car through the phone and through CarPlay's Siri button, so this is
  the real, distributable hands-free-in-car capability.
- **CarPlay (scaffold, gated).** A CarPlay screen with a "Start a thought stream" action.

## The CarPlay entitlement constraint (read first)

Apple grants the CarPlay app entitlement only for specific app CATEGORIES: audio, communication,
navigation, EV charging, parking, quick food ordering, fueling, and a few others. A dictation /
notes app is NOT one of those categories, so the CarPlay entitlement
(`com.apple.developer.carplay-*`) is generally unavailable for App Store distribution to this app.

Therefore CarPlay here is built but gated:

- No CarPlay entitlement is added to the shipping target. `DEVELOPMENT_TEAM` stays empty and the
  unsigned Simulator build and the App Store build stay green WITHOUT CarPlay.
- The CarPlay scene delegate and template are implemented and wired through the scene manifest so
  the code is ready, but the scene never activates without Apple's entitlement and a CarPlay head
  unit / the CarPlay simulator. This is documented as experimental / pending Apple approval.
- Siri is the path that actually ships hands-free-in-car today.

## Outcome

- Say "Hey Siri, start a stream in Thought Stream" (or friendly variants) and the app launches
  straight into a new dictation session with capture starting - no tap.
- The App Shortcut is registered on install so the phrases appear in the Shortcuts app and Siri.
- A single headless "start a new dictation session" entry point is shared by the UI Record
  button, the Siri App Intent, and the CarPlay action, so all three start a session identically.
- The CarPlay scene and template exist and are wired, dormant until the entitlement is granted.
- The default unsigned Simulator build and the App Store build are unaffected: they build and run
  with no CarPlay entitlement and no development team.

## Scope

In:

- A shared session-start seam in the composition root: a `SessionStarter` protocol plus a
  pending-route mechanism the app consumes on launch/foreground to open `DictationView` and begin
  capture.
- `StartThoughtStreamIntent` (`AppIntent`, `openAppWhenRun = true`) that requests the pending
  route, and an `AppShortcutsProvider` with natural phrases that include the app name.
- A second cheap intent, `NewNoteIntent`, sharing the same starter (phrases "New note in
  ${applicationName}" etc.).
- A `CPTemplateApplicationSceneDelegate` presenting a minimal template (a `CPListTemplate` with a
  "Start a thought stream" row) that calls the shared starter, wired via the CarPlay scene role in
  `UIApplicationSceneManifest`.
- Unit tests for the App Intent (via a stubbed starter), the shared route/starter, and the
  shortcut phrases.
- Docs: this spec, README, and the `docs/overview/` living docs.

Out:

- Adding any CarPlay entitlement to the shipping target (blocked on Apple's category approval).
- Dictating hands-free entirely inside CarPlay's own UI (CarPlay templates cannot host a live
  microphone transcript view; the CarPlay action launches the phone session). Full in-CarPlay
  capture is a later, entitlement-gated milestone.
- Parameterized intents (e.g. "start a stream about X"), donations/prediction tuning, and
  Shortcuts actions beyond start / new note.

## Approach

**Shared session-start seam.** Introduce a `SessionStarter` protocol with one method,
`startNewSession()`, and a concrete `PendingSessionRoute` (an `@MainActor ObservableObject`) that
holds a "start requested" flag the root view observes. Requesting a start sets the flag; the root
consumes it by presenting `DictationView`, which already begins capture in its `.task` via
`DictationViewModel.begin()`. This reuses the existing UI path rather than adding a second capture
entry: "start a session" means "route to a fresh DictationView", exactly what the Record button
does. The Record button, the App Intent, and CarPlay all call `startNewSession()`.

The route lives on `AppDependencies` so the one composition root owns it, and it is exposed to the
App Intent through a small process-wide accessor (App Intents are instantiated by the system
outside the SwiftUI tree, so they cannot receive it by injection; they reach the live route through
the composition root). The intent depends on the `SessionStarter` protocol, so tests inject a stub
and assert a start was requested without any UI.

**App Intents (iOS 17+).** `StartThoughtStreamIntent` sets `openAppWhenRun = true` and, in
`perform()`, calls the shared starter to request the route, then returns. iOS foregrounds the app;
the root observes the pending route and opens dictation. `AppShortcutsProvider` lists phrases for
both intents, each including `\(.applicationName)` per Apple's requirement, with friendly variants
("Start a stream in ${app}", "New thought in ${app}", "Start dictating in ${app}", "New note in
${app}").

**CarPlay scene.** `ThoughtStreamCarPlaySceneDelegate: UIResponder, CPTemplateApplicationSceneDelegate`
sets a `CPListTemplate` with one row, "Start a thought stream", whose handler calls the shared
starter. It is registered as an additional scene configuration under `UIApplicationSceneManifest`
with the `CPTemplateApplicationSceneSessionRoleApplication` role. Without the CarPlay entitlement
the system never creates this scene, so it is inert in the shipping build; the phone `WindowGroup`
scene is unaffected. The manifest keeps `UIApplicationSupportsMultipleScenes` semantics intact for
the phone.

**Trade-offs.**

- Process-wide accessor for the route is a small, documented seam, not general service location -
  App Intents genuinely run outside the view tree and this is the standard way to bridge them. The
  intent still depends on a protocol so it stays unit-testable.
- CarPlay is shipped dormant rather than removed so the code is ready the day Apple grants the
  entitlement (or the app's category changes); it costs nothing at runtime while gated.
- Reusing `DictationView`'s existing `begin()` avoids a parallel capture path that could drift from
  the Record-button behavior.

## Acceptance

- [ ] `cd ios && xcodegen generate` succeeds; build for `platform=iOS Simulator,name=iPhone 17`
      prints `** BUILD SUCCEEDED **` unsigned, no team, no CarPlay entitlement.
- [ ] The app still launches to the Stream list and the Record button still opens dictation.
- [ ] `StartThoughtStreamIntent.perform()` requests a session start through the shared starter;
      proven with a stub starter in a unit test (no UI).
- [ ] The shared route, when consumed, drives the same fresh-session open as the Record button.
- [ ] `AppShortcutsProvider` exposes start + new-note phrases, each referencing the app name;
      asserted in a test.
- [ ] The CarPlay scene delegate and template compile and are wired in the scene manifest, gated so
      the default build is unaffected (no entitlement required).
- [ ] `xcodebuild test` passes: the 84 existing tests plus the new ones.
- [ ] README and `docs/overview/` document the Siri capability and the CarPlay gating + what needs
      Apple's entitlement and a device.
