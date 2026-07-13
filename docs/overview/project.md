# Project

## Mission

Thought Stream is a hands-free, on-device dictation notes app for iPhone and CarPlay. You start
a stream, talk, pause to think, and edit by voice with a control word (default "Mira"), so you
never have to touch the screen. Speech-to-text runs entirely on device; notes are Markdown files
you own. See the README for the full product story.

## Status

The **themed shell** (spec 0001) shipped a buildable SwiftUI app with the River Mist design
system and mock data. The **on-device dictation MVP** (spec 0002) makes capture real: speech
streams into a note on device and saves as a Markdown file that shows up in the Stream list and
reopens. **Mira control words** (spec 0003) add hands-free voice editing: say "Mira" and a
command mid-dictation to remove the last sentence or paragraph, start a new note, or hear the
last paragraph read back. Next up: a Settings milestone (configurable name, spelling overrides),
CarPlay, and sync build on this.
