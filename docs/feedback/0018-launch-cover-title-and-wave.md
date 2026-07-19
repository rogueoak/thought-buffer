# 0018 - Launch cover: title text and reversed wave

- **Source:** Device feedback from Matthew (2026-07-19).
- **Observation:** "The loading screen is super cool but the audio wave is backwards. Can you
  add title text of 'Thought Stream' above the logo and reverse the direction of the wave."

## Symptom

Two issues on the animated launch cover (spec 0012):

1. No title. The cover showed the icon over the equalizer with no wordmark, so the brand name
   was implicit only.
2. The traveling wave swept in the wrong direction.

## Root cause

1. The launch cover VStack held only the icon and the bar row; there was never a title element.
2. In the pure `LaunchCoverView.barHeight(bar:of:at:)`, the per-bar phase offset was indexed
   from bar 0 upward (`phase = Double(bar) * 0.9`), which sends the crest sweeping from the first
   bar toward the last. That is the reverse of what reads correctly on device.

## Fix

1. Added a prominent "Thought Stream" title (Canopy `sizeX3xl` / `.bold`, `CanopyColor.text`)
   above the icon in the shared `body` VStack, so it renders in both the animated and Reduce
   Motion variants. Moved the "Thought Stream" accessibility label off the icon (now
   `accessibilityHidden`) since the visible title now announces the brand to VoiceOver.
2. Reversed the traveling-wave direction in the pure height function by flipping the per-bar
   index used for the phase term: `let index = Double(count - 1 - bar)`. The function stays pure
   and deterministic (still takes `t`); no `Date.now`/random introduced. At any fixed instant the
   height sequence is now the mirror of the old formula, so the crest sweeps the opposite way.

## Acceptance

- The launch cover shows "Thought Stream" centered above the icon, in both the animated and
  Reduce Motion variants.
- The equalizer wave travels in the reversed direction (device-verifiable).
- `LaunchCoverViewTests.testWaveTravelsInReversedDirection` locks the reversed direction: it
  reproduces the old (non-reversed) formula as a reference and asserts the current output is its
  mirror, and differs from the old sequence. This test fails against the pre-0018 direction.
- Full test suite green.

## Learning

None that generalizes past this change - a launch-cover phase-direction tweak belongs in the
feature's own story (`overview/features.md`), not the shared learnings.
