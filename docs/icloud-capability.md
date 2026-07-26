# Re-enabling iCloud Drive sync

iCloud Drive sync is implemented (`ICloudNoteStore`, coordinated IO, `NSMetadataQuery`
observation) but the iCloud **capability is disabled by default** so the app can be signed and run
on a free/personal Apple Developer team. Personal teams cannot provision the iCloud capability
(Xcode reports "Personal development teams ... do not support the iCloud capability").

While disabled, the storage layer falls back to **local** storage automatically
(`NoteStoreFactory` returns the local `NoteStore` when no iCloud container resolves), so the app is
fully functional - notes are Markdown files on the device. No code changes are needed to toggle
this; it is purely a signing/capability matter.

## To re-enable on a paid Apple Developer account

1. In `ios/project.yml`, under the `ThoughtBuffer` target, restore the entitlements block (it sits
   right after `sources:`):

   ```yaml
   entitlements:
     path: ThoughtBuffer/ThoughtBuffer.entitlements
     properties:
       com.apple.developer.icloud-container-identifiers:
         - iCloud.com.rogueoak.thoughtbuffer
       com.apple.developer.icloud-services:
         - CloudDocuments
       com.apple.developer.ubiquity-container-identifiers:
         - iCloud.com.rogueoak.thoughtbuffer
   ```

2. In the same target's `info.properties`, restore the Files-app visibility entry:

   ```yaml
   NSUbiquitousContainers:
     iCloud.com.rogueoak.thoughtbuffer:
       NSUbiquitousContainerIsDocumentScopePublic: true
       NSUbiquitousContainerName: Thought Buffer
       NSUbiquitousContainerSupportedFolderLevels: One
   ```

3. Set your paid team in `ios/Signing.local.xcconfig` (`DEVELOPMENT_TEAM = YOURTEAMID`), then run
   `cd ios && xcodegen generate`.

4. On the device, sign into iCloud. The app will resolve the ubiquity container and use
   `ICloudNoteStore`; notes appear in the Files app under "Thought Buffer" and sync across devices.

The Simulator build stays green either way (code signing is disabled for the simulator SDK, and the
runtime falls back to local when no container resolves).
