# 0004 - iCloud Drive storage

## Problem

Notes today are Markdown files under the app's local `Documents/ThoughtBuffer/`. They live on
one device and are invisible outside the app. The product promise is that notes are "markdown
files stored in an iCloud folder, automatically synced" - visible in the Files app and mirrored
across a user's devices. This milestone moves storage into the user's iCloud Drive when iCloud
is available, and keeps working locally when it is not.

Who it is for: on-device testers with an iCloud account who want their captured notes to sync
across devices and show up in Files, without losing the app's offline-first behavior.

## Outcome

Observable behavior when done:

- When the app can resolve its iCloud ubiquity container (signed in, container provisioned),
  notes are read and written as `.md` files in the container's `Documents/ThoughtBuffer/`
  folder. That folder is user-visible in the Files app as "Thought Buffer".
- Notes written on one device sync to the user's other devices; the Stream list refreshes when
  an external edit or a synced-in file changes, without a manual reload.
- When iCloud is unavailable (not signed in, no provisioning, or the Simulator with no account),
  the app behaves exactly as today: notes read and write under local `Documents/ThoughtBuffer/`.
- Which backend is in use is observable by the composition root, so a later Settings status can
  surface "syncing via iCloud" vs "on this device".
- The simulator build stays green unsigned, with no development team set.

## Scope

In:
- A `UbiquityContainerProviding` boundary that resolves (or fails to resolve) the iCloud
  ubiquity container URL off the main actor. A real provider backed by `FileManager`, plus a
  test double.
- An `iCloudNoteStore` conforming to `NoteStoring`, doing all reads/writes through
  `NSFileCoordinator` (coordinated IO) against the container's `Documents/ThoughtBuffer/`.
- A live-update boundary (`UbiquitousNoteObserving`) backed by `NSMetadataQuery`
  (`NSMetadataQueryUbiquitousDocumentsScope`) that enumerates iCloud note files, triggers
  downloads for not-yet-local items, and notifies on change. A test stub for unit tests.
- A `NoteStoreFactory` in the composition root that picks `iCloudNoteStore` when the container
  resolves, else the existing local `NoteStore`, and exposes the chosen backend kind.
- Entitlements + Info.plist for iCloud Documents and a user-visible container, via
  `ios/project.yml`.
- Keeping the simulator build unsigned and green (no `DEVELOPMENT_TEAM`).

Out (later milestones):
- A Settings toggle/status UI (this milestone only makes the choice observable).
- Conflict-resolution UI beyond coordinated IO and last-writer-wins on the file.
- Migrating/copying existing local notes into iCloud on first sign-in (notes are not lost - the
  local store is untouched - but no automatic import is done here).
- CarPlay, Siri.

## Approach

Key decisions and trade-offs:

- **Same `Note` serialization.** Both stores share `Note`'s Markdown (de)serialization
  unchanged, so a file written by either store is readable by either. The seam stays `NoteStoring`.
- **Coordinated IO.** `iCloudNoteStore` wraps every read, write, and delete in
  `NSFileCoordinator` so it does not race the sync daemon. Directory creation is coordinated too.
  Files keep `FileProtectionType.completeUnlessOpen` like the local store.
- **Container resolution off the main actor.** `url(forUbiquityContainerIdentifier:)` can block,
  so the provider resolves it on a background context. The factory awaits it before the app wires
  the store; the app roots after the decision so the first list load hits the right backend.
- **Live updates via `NSMetadataQuery`.** The Simulator and other devices deliver synced files as
  metadata items; the query enumerates them, kicks `startDownloadingUbiquitousItemAtURL` for
  items not yet local, and posts a change notification the Stream list observes to reload. The
  query lives behind `UbiquitousNoteObserving` so tests exercise the mapping with a stub and no
  real iCloud.
- **Availability + fallback in one place.** `NoteStoreFactory.make()` returns the store plus a
  `NoteStoreKind` (`.iCloud` / `.local`). The app holds the kind so a later Settings screen can
  read it. Switching backends never deletes notes: the local store is left intact; iCloud is
  additive.
- **Unsigned simulator build.** iCloud entitlements are embedded but, for the Simulator, code
  signing is disabled (`CODE_SIGNING_ALLOWED=NO`) so they are not validated. `DEVELOPMENT_TEAM`
  stays empty. At runtime in the Simulator the container resolves to nil and the app falls back
  to local - the app always runs. On a device, the developer sets their Team and the capability
  auto-provisions `iCloud.com.rogueoak.thoughtbuffer`.

## Acceptance

- [ ] `iCloudNoteStore` conforms to `NoteStoring`; save/load/delete round-trip through
      `NSFileCoordinator` against a temp directory (test).
- [ ] `UbiquityContainerProviding` boundary: a stub that resolves a URL selects `iCloudNoteStore`;
      a stub that resolves nil selects the local `NoteStore` (test).
- [ ] `UbiquitousNoteObserving` mapping: a stub feeding file URLs produces the expected note list
      and change notifications (test).
- [ ] Fallback correctness: with no container, behavior matches the local store (test).
- [ ] `ios/project.yml` declares the iCloud entitlement (iCloud Documents, container
      `iCloud.com.rogueoak.thoughtbuffer`) and `NSUbiquitousContainers` Info.plist with display
      name "Thought Buffer", public document scope, Documents supported scope.
- [ ] `xcodegen generate` then build for `platform=iOS Simulator,name=iPhone 17` succeeds
      **unsigned, no team** -> `** BUILD SUCCEEDED **`.
- [ ] App launches in the Simulator, uses local storage (no iCloud), existing dictation/list
      flows still work.
- [ ] Full suite green: 58 existing tests plus the new ones.
- [ ] README documents enabling real iCloud on a device (set Team; capability auto-provisions).
</content>
</invoke>
