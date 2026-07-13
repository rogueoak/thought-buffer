# 0006 - Settings

## Problem

The app is fully wired for hands-free capture and editing, but two things a real user needs are
still hardcoded. The control word is fixed to "Mira" (spec 0003 left it an injected constant so
this milestone could make it configurable), and on-device recognition mangles the same proper
nouns every time - it hears "Shea" as "Shay" and there is no way to correct it short of editing
the note by hand, which defeats hands-free capture. Settings has been a themed stub since spec
0001 (a placeholder list that does nothing). This milestone makes the stub real: the user picks
their own assistant name and teaches the app a list of spelling fixes, both persisted.

Who it is for: on-device testers who now capture real notes and want the assistant to answer to
a name they chose and to stop misspelling the words they say most.

## Outcome

Observable behavior when done:

- Tapping the gear in the Stream toolbar opens a real Settings screen (not the stub), themed with
  Canopy tokens to match the app.
- **Control phrase.** The user types an assistant name (default "Mira"). It is trimmed and
  validated: an empty or whitespace-only value falls back to "Mira". Once saved, the next
  dictation session's command grammar uses it - "Nova remove the last sentence" fires the remove
  command when the name is "Nova", and "Mira ..." no longer does. The command chip reads with the
  chosen name ("Nova - removed last sentence").
- **Spelling overrides.** The user maintains an ordered list of from -> to replacement pairs
  (e.g. spoken "Shay" -> written "Shea"). In the next session, dictated text has these applied
  before it is committed: whole-word and case-insensitive match, so "shay" and "Shay" both become
  "Shea" but "Shayla" is untouched. Multiple overrides apply together; a control-phrase command is
  never spelling-mangled.
- **Storage status.** A read-only row shows whether notes are stored on iCloud or on this device,
  read from the storage backend the app resolved at launch.
- **Persistence.** Every edit persists across relaunch.
- Changes apply to the **next** dictation session started (the processor is built per session from
  current settings), not to a session already running. This is documented in the UI copy.

## Scope

In:
- A `SettingsStoring` protocol with a `UserDefaults`-backed production impl
  (`UserDefaultsSettingsStore`), injected from the composition root. Holds the control phrase
  (validated, trimmed, non-empty, sensible max length, falls back to "Mira") and an ordered list
  of spelling overrides (from/to pairs).
- A `SpellingOverride` value type (from, to) and a pure `SpellingOverrideProcessor` (text -> text)
  that applies the override map whole-word and case-insensitively without corrupting substrings.
- A `CompositeTextProcessor` that composes the Mira command processor with the spelling processor:
  detect a command on the RAW segment first; if it is a command, return `.command`; otherwise run
  the segment through the spelling processor and return `.text`. Order matters - a control phrase
  must never be spelling-mangled.
- Wiring `makeTextProcessor` in `AppDependencies` to build the composite from CURRENT settings
  each session, threading the configured control word and overrides in.
- A real `SettingsView` (Form/List with tokens): a control-phrase field with validation and a hint,
  a spelling-overrides section (list with add / edit / delete), and a read-only storage-status row.
  Reachable from the existing gear button.
- Threading the storage kind (`NoteStoreKind`) into Settings for the status row.
- Unit tests: store persistence + validation; the configured control word changes command
  matching; spelling overrides apply (whole-word, case, multiple, no substring corruption);
  composition order (a command is detected and not mangled; a normal segment gets overrides).

Out (later, seams left, nothing built):
- Cloud sync of settings (settings are local `UserDefaults` only).
- Per-note settings.
- Importing / exporting override lists.
- Live re-application to an in-progress session (changes take effect next session, by design).

## Approach

### SettingsStore

`SettingsStoring` is a small protocol read by the composition root:

- `var controlPhrase: String { get set }` - the validated assistant name. The setter trims
  whitespace and, if the result is empty or exceeds a sensible max length, the getter falls back
  to `MiraTextProcessor.defaultControlWord` ("Mira"). Persisting an empty string is allowed (it
  just reads back as "Mira"), so "clear the field" is a valid way to reset.
- `var spellingOverrides: [SpellingOverride] { get set }` - the ordered list, persisted as JSON.

`UserDefaultsSettingsStore` stores the phrase under one key and the overrides as JSON-encoded data
under another. `UserDefaults` is injected (`.standard` by default) so tests use an isolated suite.
The store is a reference type so the SwiftUI Settings screen edits it and the composition root
reads the same instance.

`SpellingOverride` is `Codable`/`Equatable`/`Identifiable` with `from` and `to` strings. Blank
`from` values are ignored when the override map is built (a half-typed row does nothing).

### SpellingOverrideProcessor

A pure `struct SpellingOverrideProcessor` built from `[SpellingOverride]`. `process(_:)` returns
`.text` always (it is text -> text, never a command). Replacement is whole-word and
case-insensitive:

- It walks word tokens (via a word-boundary regex / `NSRegularExpression` with `\\b`), and replaces
  a token whose lowercased form equals an override's lowercased `from` with that override's `to`.
- Whole-word so "Shea" does not turn "Shayla" or "hooray" into anything - only a standalone token
  matches. This is the substring-corruption guard.
- Case-insensitive match, and it preserves the override's `to` casing as written by the user
  (simplest correct behavior: the user typed the replacement they want). If two overrides share a
  `from`, the first in the ordered list wins.
- Punctuation and spacing around a token are preserved because only the word span is replaced.

### Composition (order matters)

`CompositeTextProcessor` holds a `MiraTextProcessor` (built with the configured control word) and a
`SpellingOverrideProcessor` (built from the overrides). `process(_:)`:

1. Run the RAW segment through the command processor first.
2. If it is `.command`, return it unchanged - a command phrase must never be spelling-mangled, and
   the phrase is suppressed from the note anyway.
3. Otherwise, run the segment through the spelling processor and return its `.text`.

This keeps each processor pure and independently testable, and makes the ordering explicit.
`AppDependencies.makeTextProcessor` becomes a closure that, each time it is called (once per
session), reads the current `controlPhrase` and `spellingOverrides` off the `SettingsStoring`
instance and builds a fresh `CompositeTextProcessor`. Because it reads at build time, edits made in
Settings apply to the next session, not one already in flight - documented in the spec and the UI.

### Settings UI

`SettingsView` takes the `SettingsStoring` instance and the `NoteStoreKind`. It renders a themed
`List`:

- **Assistant** section: a `TextField` bound to the control phrase with a hint ("Say this word
  before a command") and a note that changes apply to the next session. Empty input reads back as
  "Mira".
- **Spelling overrides** section: a row per override (from -> to) with swipe-to-delete and tap-to-
  edit, plus an add control. Editing writes straight back to the store.
- **Storage** section: a read-only row showing "iCloud" or "On this device" from the kind.

Styling uses `CanopyColor` / `CanopySpacing` / `CanopyRadius` / `CanopyFont` only, matching the
existing stub's look (themed background, muted foreground, primary tint).

## Acceptance

- [ ] `cd ios && xcodegen generate` and build for `platform=iOS Simulator,name=iPhone 17`
      succeeds -> `** BUILD SUCCEEDED **`.
- [ ] `UserDefaultsSettingsStore` round-trips the control phrase and overrides across instances
      (persistence); an empty / whitespace phrase reads back as "Mira"; a too-long phrase falls
      back (validation).
- [ ] The configured control word changes command matching: the parser fires for the new word,
      not for the old, and a plain word is not a command.
- [ ] `SpellingOverrideProcessor` applies overrides whole-word, case-insensitively, for multiple
      overrides, and never corrupts a substring (e.g. "Shayla" untouched by a "Shay" override).
- [ ] `CompositeTextProcessor` order: a command phrase is detected as `.command` and NOT spelling-
      mangled; a normal segment gets overrides applied and returns `.text`.
- [ ] Settings opens from the gear, renders themed, edits persist across relaunch. A screenshot of
      the Settings screen is committed at `design/screenshots/settings.png`.
- [ ] Full suite green: the 97 existing tests plus the new ones.
