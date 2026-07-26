# Feedback 0028 - Launch tagline under the wordmark

A small user-feedback polish to the animated launch cover (spec 0012).

## Symptom

> On the loading screen, we need a tagline under the title. Maybe "capture your thoughts, hands
> free".

The launch cover showed the "Thought Buffer" wordmark, the fading icon, and the waveform, but
nothing told a first-time viewer what the app is for in that branded moment.

## Root cause

Not a bug - the cover was built title-only (spec 0012). It simply never carried a one-line
promise of what the app does.

## Fix

Add a tagline directly under the wordmark in `LaunchCoverView`: **Capture your thoughts, hands
free**. The title and tagline share a tight inner `VStack` (`CanopySpacing.x2`) so the tagline
reads as a subtitle right under the title, while the outer `CanopySpacing.x8` stack keeps the
pair clear of the icon and waveform below. The tagline is styled with Canopy tokens as a
subtitle: `CanopyFont.sizeBase` (below the `sizeX3xl` title) in `CanopyColor.textMuted`,
centered. The title text, wave direction, and logo fade are untouched.

Copy follows `docs/rules/language.md`: sentence case, addresses "you", terse, no marketing hype,
no trailing period (the cover carries no other sentence punctuation to match).

## Learning

No general rule beyond what spec 0012 already captures - this is a copy/layout tweak to one
feature, so the story lives in `features.md`, not `learnings.md`.
