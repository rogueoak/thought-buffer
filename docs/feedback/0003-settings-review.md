# 0003 - Settings review findings

Feedback from the persona review of PR #6 (spec 0006, Settings: configurable control phrase and
spelling overrides).

## Symptom

Two majors and four minors surfaced on the first cut:

- **Multi-word / punctuated control phrase silently disabled all commands (engineer major).** The
  control phrase was validated only for empty/length, but `MiraCommandParser` matches the control
  word as a SINGLE leading token. So "Hey Nova" or "Mira!" was stored verbatim, `first ==
  "hey nova"` could never be true, and every voice command silently stopped firing with no user
  feedback. The Settings field even used `.textInputAutocapitalization(.words)`, inviting exactly
  that input.
- **Blank correction silently deleted the spoken word (engineer major).** `SpellingOverrideProcessor`
  dropped blank `from` rows but accepted a blank `to`, mapping a real word to `""`. Since the "Add
  override" button appends `SpellingOverride(from: "", to: "")` and persists on each keystroke, a
  half-typed row deleted every occurrence of the heard word from the note - the opposite of a fix.
- **Validation rule leaked out of its boundary (architect minor).** `SettingsView` reached into the
  concrete `UserDefaultsSettingsStore.validatedControlPhrase(_:)` for its hint, coupling the view to
  a concrete store while it was otherwise injected the `SettingsStoring` protocol.
- **Unbounded override persistence (security minor).** No cap on row count or per-field length, and
  the setter rewrote the whole array on every keystroke - a local unbounded-growth path feeding a
  map the processor rescans per segment.
- **Boundary and tokenizer-domain coverage gaps (tester minors).** The length cap was only tested
  with clearly-over values (40, 100), never at the on/off boundary; and multi-word / non-word
  `from` values (the tokenizer's blind spot) had no test pinning behavior either way.

## Root cause

The two majors share one cause: a settings value was validated for *shape* (non-empty, within
length) but not for the *contract of the consumer that reads it*. The control phrase must be a
single token because the parser tokenizes; an override is only meaningful when both sides are
present because a blank replacement is a deletion. Validating "looks reasonable" is not the same as
validating "the downstream will do the right thing with this," and the gap is invisible in the UI:
the app keeps running and silently does the wrong thing. The minor findings are the usual first-cut
misses: a rule placed in the concrete type instead of a shared seam, no bounds on user-editable
persisted collections, and tests that skip the boundary and the tokenizer's domain edges.

## Fix

- Route control-phrase validation through a shared `ControlPhrase` seam that trims, keeps the first
  alphanumeric token, and falls back to "Mira" when empty or over-long. Both the store and the view
  use it, so no concrete-type leak and no multi-word phrase can reach the parser.
- Require a non-blank (trimmed) `to` as well as `from` before an override is active, so an empty row
  is inert and never deletes text.
- Cap override row count and per-field length in the store setter.
- Add tests: the length boundary (max accepted, max+1 rejected), multi-word/punctuated phrase
  collapse, blank-`to` no-delete, multi-word `from` inert, and the override bounds.

## Learning

Validate a settings value against the CONTRACT of whatever consumes it, not just its surface shape -
see `overview/learnings.md`.
