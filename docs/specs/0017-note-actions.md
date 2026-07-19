# Spec 0017 - Note actions menu (share + copy)

## Motivation

Device feedback from Matthew (2026-07-19):

> I also want notes to have a share menu so I can send them to other apps. Maybe
> that is under a triple dot menu on the note. I also want a copy button so you can
> easily copy the text of the whole note. This could go under the same menu.

## Scope

Add an ellipsis ("...", `Menu` with `Image(systemName: "ellipsis")` or the
`ellipsis.circle` SF Symbol) to the `NoteDetailView` toolbar, alongside the
existing gear/mic actions, containing:

1. **Share** - presents the system share sheet (`ShareLink` / activity view) with
   the note's shareable text so it can go to Messages, Mail, Notes, etc.
2. **Copy text** - copies the whole note's text to the pasteboard
   (`UIPasteboard.general`) and shows brief confirmation (reuse the existing chip /
   banner feedback pattern if one exists; otherwise a lightweight transient label).

### List-row long-press

The same two actions are also reachable from the notes list without opening a note:
long-pressing a NOTE row opens its context menu with **Share** and **Copy text**
(alongside the existing "Move to folder"), both reusing the same pure
`Note.shareableText`. FOLDER rows do not get share/copy - only notes have shareable
text.

### Shared text format

One pure helper (e.g. `Note.shareableText` or a small `NoteExport` type) builds the
string so share and copy are identical and it is unit-testable:

- Title line (the note title), then a blank line, then the body paragraphs joined
  with blank lines (mirror `bodyMarkdown` paragraph joining, but plain text).
- A note with no custom title still shares with its derived title.
- Text-only and recorded notes share identically (audio is not shared here).

## Design notes

- Use Canopy tokens; no hardcoded colors. Match the existing toolbar styling.
- The menu must not interfere with the edit / title-edit modes already in the
  toolbar; it is available in the normal (non-editing) state.
- Keep it accessible: the menu button has an accessibility label ("Note actions").

## Non-goals

- No export to files / PDF / audio sharing in this milestone (text only).
- No per-paragraph share.

## Acceptance

- The note detail screen shows a "..." menu with Share and Copy text.
- Long-pressing a note row in the list opens a context menu with Share and Copy text;
  folder rows do not.
- Share presents the system share sheet with the note's title + body as plain text.
- Copy places the same text on the pasteboard and confirms.
- `Note.shareableText` (or equivalent) is pure and unit-tested: custom title,
  derived title, single paragraph, multi-paragraph, empty body.
- Suite stays green.
