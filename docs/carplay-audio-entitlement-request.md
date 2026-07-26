# CarPlay Audio entitlement request

A concise, honest justification for requesting the CarPlay **Audio** category entitlement
(`com.apple.developer.carplay-audio`) for Thought Buffer, plus the exact steps to enable it once
Apple grants it.

## What Thought Buffer is

Thought Buffer is an on-device voice-notes app. You dictate a thought; it transcribes it on device
and, alongside the transcript, keeps the actual voice as a compressed `.m4a` recording per note
(spec 0007). A saved note can be played back in your own voice. Nothing is sent off the device -
recognition is on-device (`requiresOnDeviceRecognition`), notes are Markdown files stored locally or
in the user's own iCloud Drive, and playback is a local file. There is no network component and no
account.

## Why the Audio category fits

Apple grants the CarPlay entitlement only for specific app categories: audio, communication,
navigation, EV charging, parking, fueling, and a few more. Thought Buffer is genuinely an **audio**
app for the CarPlay surface:

- It has a real library of audio recordings (the user's voice notes) with durations and titles.
- The CarPlay surface is a standard audio experience: a `CPListTemplate` recordings browser (title,
  date, duration, newest first) and `CPNowPlayingTemplate` with play / pause / skip transport,
  driven by the same playback engine that feeds `MPNowPlayingInfoCenter` and `MPRemoteCommandCenter`
  on the phone lock screen and in Control Center.
- It is low-distraction and hands-free-appropriate: browse and tap to play, with the system Now
  Playing UI and steering-wheel / head-unit transport controls doing the driving-time interaction.
  There is no free-form text entry or reading required in the car.
- It is on-device and private: no streaming service, no ads, no data collection - just the user's
  own recordings played back locally.

The in-car use case is the reason the product exists: capture and revisit thoughts when your hands
are busy, driving above all. Playing your own voice notes back through CarPlay Now Playing is the
natural audio-app expression of that.

## What already ships without the entitlement (and stays green)

The Audio-app identity is substantiated in the shipping build WITHOUT any CarPlay entitlement:

- Playing a note on the phone populates `MPNowPlayingInfoCenter` (title, duration, elapsed) and
  wires `MPRemoteCommandCenter` (play / pause / stop / skip), so it appears on the lock screen and
  in Control Center like any audio app.
- `UIBackgroundModes: [audio]` lets playback continue in the background.
- The CarPlay scene delegate and templates are fully implemented and wired via the
  `CPTemplateApplicationSceneSessionRoleApplication` role in the scene manifest, but stay DORMANT:
  no CarPlay entitlement is declared, so the system never creates the scene. The unsigned Simulator
  build and the App Store build build and run with `DEVELOPMENT_TEAM` empty and code signing
  disabled for the Simulator.

None of the above needs Apple's approval; it improves the phone app and proves the audio identity.

## Steps to enable once Apple grants the entitlement

When the CarPlay Audio entitlement is granted for the app's App ID:

1. **Add the entitlement.** In `ios/project.yml`, under the `ThoughtBuffer` target's
   `entitlements.properties`, add `com.apple.developer.carplay-audio: true`. XcodeGen writes it into
   `ThoughtBuffer/ThoughtBuffer.entitlements`.
2. **Set a signing team.** The CarPlay entitlement is validated at sign time, so a real
   `DEVELOPMENT_TEAM` and code signing are required for device / App Store builds. Keep a Simulator
   config that leaves signing disabled so the unsigned Simulator build stays green (the CarPlay scene
   is inert there anyway).
3. **Background audio** is already declared (`UIBackgroundModes: [audio]`) - no change.
4. **Scene manifest** is already wired (the `CPTemplateApplicationSceneSessionRoleApplication` role
   naming `CarPlaySceneDelegate` and `UIApplicationSupportsMultipleScenes: true`) - no change.
5. **The scene code** (`CarPlaySceneDelegate`, `RecordingsListModel`, `NotePlaybackController`) is
   already implemented - no change.
6. **Verify** on a CarPlay head unit or the CarPlay Simulator (Xcode > Simulator > I/O > External
   Displays > CarPlay): the recordings browser lists notes with audio, tapping one plays it and
   shows Now Playing with working transport, and the "Start a thought" row still begins a
   hands-free dictation session on the phone.

Until then, Siri (spec 0005: `StartThoughtBufferIntent` / `NewNoteIntent`, which work through
CarPlay's Siri button without any CarPlay entitlement) is the shippable hands-free-in-car path.
