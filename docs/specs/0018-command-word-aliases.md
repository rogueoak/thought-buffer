# Spec 0018 - Command-word aliases

## Motivation

Device feedback from Matthew (2026-07-19):

> I want to be able to add aliases for the command word. I was saying "Mira" but
> sometimes it would interpret it as "mirror" and just literally put the word. With
> aliases, I could have several misspellings of what I'm saying.

The recognizer sometimes transcribes the control word as a near-homophone
("mirror", "meera"), so command mode never fires and the misheard word is written
into the note. Letting the user register several alias spellings for the control
word makes command detection robust to these mishearings.

## Current state

`MiraCommandParser` takes a single `controlWord: String` and fires command mode
when a token equals it (case-insensitive, token-boundary match via `wordRegex`).
The word is owned by the Settings `ControlPhrase` seam
(`SettingsStoring` + `SettingsView`) and injected through
`AppDependencies.makeTextProcessor` -> `CompositeTextProcessor` ->
`MiraTextProcessor` -> `MiraCommandParser`.

## Scope

1. **Parser accepts a set of trigger words.** Change `MiraCommandParser` to match
   ANY token in an injected, case-insensitive set of aliases (the primary control
   word plus user aliases). `splitAtControlWord` splits at the first token that
   matches any alias. Everything downstream (preText / command remainder) is
   unchanged. Keep aliases single tokens (the match is token-based); reject
   multi-word aliases in validation with a clear message.

2. **Settings owns the alias list.** Extend the `ControlPhrase` seam /
   `SettingsStoring` to persist the primary word plus an ordered list of aliases.
   Validation per alias: non-empty, single token, trimmed, de-duplicated
   (case-insensitively), and not colliding with the primary word. Provide a
   sensible default alias set for the default word "Mira" (e.g. "mira", "mirra",
   "meera", "mira") so a fresh install already tolerates common mishearings; the
   user can add/remove.

3. **Settings UI.** In `SettingsView`, under the existing control-word field, add a
   simple editable list to add/remove aliases (add field + swipe/tap to delete).
   Explain briefly that aliases catch mishearings of the command word.

4. **Wiring.** `AppDependencies.makeTextProcessor` builds the parser from the full
   alias set. Takes effect on the next dictation session (same lifecycle as the
   control word today).

## Non-goals

- No fuzzy/phonetic auto-matching (no Soundex/Levenshtein). Aliases are exact
  tokens the user curates - deterministic and privacy-preserving, consistent with
  the app's local-only framing.
- No per-alias behavior; every alias is fully equivalent to the control word.

## Acceptance

- With aliases {"mira","mirror"}, saying "mirror new note" fires `newNote`; it is
  not written into the note.
- The primary word still fires. Removing an alias stops it from triggering on the
  next session.
- Alias validation rejects empty, multi-word, and duplicate entries with a message;
  the primary word cannot be shadowed/removed.
- Parser alias matching is pure and unit-tested (multiple aliases, case-insensitive,
  token-boundary so "admiral" does not match "mira").
- Settings persist and round-trip; suite stays green.
