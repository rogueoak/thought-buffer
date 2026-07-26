# Project

## Mission

Thought Buffer is a hands-free, on-device dictation thoughts app for iPhone, iPad, Apple Watch, and
CarPlay. You start a thought, talk, pause to think, and edit by voice with a control word (default
"Mira"), so you never have to touch the screen. Speech-to-text runs entirely on device; thoughts are
Markdown files you own. On the watch you capture a thought from the wrist and it syncs to the phone,
which transcribes and files it. See the README for the full product story.

## Status

The **themed shell** (spec 0001) shipped a buildable SwiftUI app with the River Mist design
system and mock data. The **on-device dictation MVP** (spec 0002) makes capture real: speech
streams into a thought on device and saves as a Markdown file that shows up in the Stream list and
reopens. **Mira control words** (spec 0003) add hands-free voice editing: say "Mira" and a
command mid-dictation to remove the last sentence or paragraph, start a new thought, or hear the
last paragraph read back. Settings, iCloud sync, CarPlay, dual-capture recording + playback, folders,
full-text search, and iPad adaptive layout all shipped on top. The **Apple Watch app** (spec 0023) is
the latest milestone: quick-capture a voice thought on the wrist that syncs to the phone (which
transcribes it via a file-based analogue of the live engine and files it as a normal thought), plus a
browse-and-play list of recent thoughts pushed from the phone. On-watch speech-to-text, editing, and
complications/Siri are out of scope for this milestone.
