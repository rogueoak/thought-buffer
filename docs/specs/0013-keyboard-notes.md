# 0013 - Keyboard notes

## Problem

Every note starts by talking. Sometimes you can't (a meeting, a quiet room) or you just want to jot
a line. There is no way to create a note with the keyboard, and no obvious way to add voice to a note
that began as text. The app should let you make a plain text note and, if you want, narrate part of
it later.

## Outcome

- A **New note** button on the Thoughts toolbar creates a blank note and opens it straight into the
  keyboard editor - type a title and body, done. It is filed in the folder you are currently in.
- The note page keeps its **record affordance**: on a note that has **no recording yet**, tapping it
  starts a dictation session that **captures real audio** for the note (so a typed note you later
  narrate becomes a true voice note). On a note that **already has a recording**, it keeps today's
  behavior - appended dictation is text-only so the original recording is never corrupted.
- Backing out of a brand-new note without typing anything does not leave an empty note behind.

## Scope

**In:** a new-note toolbar entry point; opening a fresh note in body-edit mode; persisting it on
first commit (and discarding an untouched new note); making the note page's record/resume capture
audio when the note has none. Reuses the existing `NoteDetailView` editor (spec 0009 title + body
edit) and the existing dictation/resume path.

**Out:** rich text / markdown formatting UI, checklists, attachments, and a separate notes-vs-voice
distinction in storage (a keyboard note is just a `Note` with no recording, exactly as today's
text-only notes are).

## Approach

- **Entry point.** Add a compose button (`square.and.pencil`) to the Thoughts toolbar
  (`FolderContentsView`), threaded up to `StreamListView` (which owns the store + navigation) via an
  `onNewNote` callback carrying the current folder path. It creates a fresh `Note` (new id, `createdAt`
  now, empty paragraphs, `folderPath` = current) and navigates to it, opening the editor.
- **Fresh-note editing.** `NoteDetailView` gains a `startInEdit` flag: when set it opens with the body
  editor focused (and, for a brand-new note, an empty title placeholder). It persists through the
  existing `onCommitEdit` path. A new note is saved on first commit; if the user leaves it with no
  title and no body, the composition root discards it (never persists, or deletes if it was
  provisionally saved) so the list is not littered with blanks.
- **Record captures audio when the note has none.** The note page's record/resume action already
  reopens a dictation session seeded with the note. Change the seam so it records audio when the note
  has no recording: pass `recordsAudio: !note.hasAudio` (subject to the user's transcript-only
  retention setting) instead of always `false`. `DictationViewModel`'s resume path already preserves
  an existing recording and pads timings for text-only paragraphs; verify (and cover with a test) that
  the inverse - text-only original, newly recorded tail - saves with the new audio attached and the
  original text paragraphs playing back via text-to-speech.
- Keep the record affordance labeled sensibly (e.g. "Record" when the note has no audio, "Resume"
  when it does), a small copy tweak.

## Acceptance

- [ ] Tapping New note opens a blank note in the keyboard editor; typing and Done saves it in the
      current folder.
- [ ] A new note left empty (no title, no body) is not persisted.
- [ ] Recording into a text-only note attaches real audio (the note then shows a Play control);
      the originally-typed paragraphs remain and play back via TTS, the newly spoken tail plays its
      recording.
- [ ] Recording into a note that already has audio stays text-only append (original recording intact).
- [ ] A keyboard note is a normal `Note` on disk (no format change) and works with folders, sort,
      editing, and delete like any other note.
- [ ] Full suite green; the text-note-gains-audio path is unit-tested in `DictationViewModel`.
