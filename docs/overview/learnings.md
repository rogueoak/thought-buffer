# Learnings

What we learned, change by change.

## Simulator speech is not a gate (spec 0002)

On-device `SFSpeechRecognizer` capture is unreliable in the iOS Simulator (it may fall back to
the Mac mic or refuse on-device recognition), and `simctl privacy grant` cannot set the
speech-recognition permission. Do not block a milestone on live simulator speech. Instead, make
the capture path injectable (feed finalized text without audio) so the full flow - permission
request, save, reload, render - is provable structurally in the sim and by tests, and leave real
speech for a physical device.

## Keep persisted files tolerant from day one (spec 0002)

Notes are Markdown files that outlive any single app version. The parser ignores unknown
frontmatter keys and still loads a body without frontmatter, so later fields (tags, source,
edits) can be added without a migration and an old or hand-edited file never fails to load.

## Drive audio-mode transitions off "finished", not a timer (spec 0003)

Playing audio (text to speech) while the mic is live feeds the output straight back into
recognition. Do not overlap the two: pause capture, switch the session to `.playback`, speak,
and only reactivate the record session when the synthesizer reports the utterance actually
finished (its delegate callback), not after a guessed duration. Model the player as a protocol
that exposes an `onFinish` callback so the resume is event-driven and the player stays stubbable
in tests. This record -> playback -> record handshake generalizes to any future feature that
plays audio during a live capture session.

## Widen a seam by returning a result, not by adding a branch (spec 0003)

When a transform seam needs to do more than transform (here, consume a segment as a command
instead of committing it), change its return type to a small result enum (`.text` / `.command` /
`.drop`) rather than bolting a side channel onto the caller. The caller routes on the case, the
default implementation keeps its old behavior in one case, and future processors compose without
touching the view model or capture service.
