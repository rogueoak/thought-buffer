# Spec 0024 - "Thoughts" terminology rename (product + code)

## Motivation

Device feedback from Matthew (2026-07-19):

> I want to be really consistent with terminology. I keep interchanging notes and
> thoughts. Let's stick to "thoughts" as the nomenclature. This is Thought Buffer
> after all.

Decision (confirmed): rename BOTH user-facing text AND code symbols from "note" to
"thought", so the product and the codebase speak one language.

## Sequencing (critical)

This touches nearly every file. It MUST run SOLO - no other feature worktree open -
or it will conflict catastrophically. Run it as a dedicated PR right AFTER spec 0021
merges and BEFORE iPad (0022) / Watch (0023), so those are built in the new
vocabulary and never need a second rename.

## Scope

### 1. Code symbols (types, files, members, tests)

Rename identifiers from Note* -> Thought* across the app and tests, e.g.:
`Note` -> `Thought`, `NoteStore`/`ICloudNoteStore` -> `ThoughtStore`/`ICloudThoughtStore`,
`NoteStoring` -> `ThoughtStoring`, `NoteStoreDriver` -> `ThoughtStoreDriver`,
`NoteCard` -> `ThoughtCard`, `NoteDetailView` -> `ThoughtDetailView`,
`NoteMetaStats` -> `ThoughtMetaStats`, `NoteActionsMenu` -> `ThoughtActionsMenu`,
`NoteClipboard` -> `ThoughtClipboard`, `NotePlaybackController` -> `ThoughtPlaybackController`,
`NoteSortOrder` -> `ThoughtSortOrder`, `NoteDeletionController` -> `ThoughtDeletionController`,
`DeletedNote`/`RestoredNote` -> `DeletedThought`/`RestoredThought`, and all their files,
properties, locals, and test names. Use symbol-aware renaming (Xcode rename or careful
WHOLE-IDENTIFIER matching), NOT a blind text substitution - "note" appears in ordinary
comments/prose ("Note:", "footnote") that must NOT be mangled.

### 2. User-facing strings

Every UI label, button, empty state, share/export text, accessibility label, banner,
and cheat-sheet string that says "note(s)" -> "thought(s)", matching what spec 0021
already introduced for new strings. Check share/copy text, settings copy, launch/
onboarding, and Siri/intents phrasing.

### 3. Docs

Update the living docs (docs/overview/*), README(s), and user-facing release/language
notes to say "thought". Historical spec/feedback files keep their numbers and
filenames (they are a dated record); update their prose only where it is low-cost and
reduces confusion, but do not churn the whole history.

## MUST NOT change (guardrails)

- **On-disk serialization stays.** The `<id>.md` filename scheme, the Markdown
  frontmatter KEYS (`title`, `titleCustom`, `timings`, ...), the body structure, the
  sibling `<id>.m4a`, the `.trash/` dir, and folder directories are the storage
  contract. Renaming any of these would ORPHAN or corrupt every existing saved
  thought. The rename is code-symbol + UI-text only; the persisted format is
  untouched. Add/keep a test asserting an existing on-disk file still loads.
- App name, bundle identifier, scheme (`ThoughtBuffer`) are already correct - leave
  them.
- No behavior change of any kind - this is a pure rename. The full suite must pass
  unchanged (aside from renamed test symbols).
- SpeechAnalyzer/OS API names, `NSUbiquitousContainers`, entitlement keys, etc. are
  Apple's - never rename those.

## Acceptance

- No user-facing string says "note"/"notes" (grep the built strings); everything
  reads "thought"/"thoughts".
- Code identifiers are consistently Thought* (no `Note`-named app types remain,
  except where a name refers to a non-thought concept, if any).
- An existing on-disk thought (old `<id>.md`) still loads and plays - a test proves
  the storage format is unchanged.
- Full suite green; build + lint clean; the diff is a pure rename (no logic changes).
