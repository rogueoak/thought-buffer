# 0010 - Home and note UX polish

Three usability refinements from using the app, all UI-clarity (no capture/storage change).

## Symptom

- **Ambiguous top-left button.** The Thoughts toolbar's leading button is a lone `waveform.circle`
  icon. It actually toggles the recordings-only filter (feedback 0008), but with no label and a
  waveform glyph it reads as "record voice" - the very action it is not. A user assumed it started
  recording.
- **Word count is the wrong stat.** Note cards and the detail header show a word count ("12 words").
  For a dictation app the more meaningful at-a-glance stat is how long the thought is - its recording
  duration.
- **The Edit button is unnecessary.** The saved-note page carries an Edit/Done toolbar toggle
  (feedback 0008). Tapping the note's text is a more direct way to start editing; the separate Edit
  button is redundant chrome.

## Root cause

- A single unlabeled icon in a navigation-bar leading slot reads as a primary action, and a waveform
  glyph specifically collides with "record" on a dictation app. The state (`waveform.circle` vs
  `.fill`) disambiguates on/off but not *what* it does.
- Word count was chosen in feedback 0005 as a better stat than a paragraph count, but for a
  voice-first app duration is more informative. The data already exists: `Note.recordingDuration`
  (spec 0007), with a formatter already living in `RecordingsListModel.durationLabel`.
- Editing was added as an explicit toolbar toggle (feedback 0008) before tap-to-edit was considered.

## Fix

- **Label the filter.** Keep the waveform icon but pair it with a "Recordings" text label
  (`Label(..).labelStyle(.titleAndIcon)`) so the control names itself; keep the fill/tint state and
  the existing accessibility label. The record affordances remain the top-right mic and the bottom
  "Record" pill, now clearly distinct.
- **Duration instead of word count, with a fallback.** Recorded notes show their recording duration
  ("1:24"); notes with no recording (transcript-only retention, resumed/edited notes, older files)
  fall back to the existing word count so the stat is never blank. Promote the duration formatter to
  `Note` (`durationLabel(_:)` / `recordingDurationLabel` / `metaStatLabel`) as the single source of
  truth; `RecordingsListModel.durationLabel` delegates to it. Card and detail header both read
  `Note.metaStatLabel` (and branch the icon on `hasAudio`: `timer` for duration, `text.alignleft`
  for word count).
- **Tap to edit.** Remove the read-mode Edit button; tapping the note's text region begins editing
  (`beginEdit()`), and the toolbar shows only a "Done" button while editing to commit. The text
  region gets a button trait and an edit hint for VoiceOver. Scoped to the saved-note detail page;
  the record-screen paused-Edit affordance is unchanged.

## Learning

Nothing here generalizes into a new build-time rule - these are product/design calls specific to
this surface, so the lesson lives with the feature in `overview/features.md`, not in
`overview/learnings.md`. One durable point worth noting from the fix: a lone unlabeled icon in a
nav-bar leading slot reads as an action, not a filter - prefer a labeled control (or a
platform-standard filter affordance) when the glyph could be confused with a primary action. If this
recurs on another surface it is worth promoting to a learning; on its own it does not clear the
"outlives this change" bar.
