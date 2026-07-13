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
