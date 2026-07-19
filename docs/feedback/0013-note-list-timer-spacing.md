# Feedback 0013 - Note list: tighten timer icon spacing

## Source

Device feedback from Matthew (2026-07-19):

> On the note list page, tighten the space between the timer icon and its time so
> it matches the spacing of the time since recording icon.

## Observation

Each note card shows two metadata pairs: the "time since created" clock icon with
its relative time (already tightened, feedback 0011), and the recording-duration
timer icon with its duration. The timer/duration pair has a looser icon-to-label
gap than the clock pair, so they look inconsistent.

## Fix

In `NoteCard.swift`, match the timer (duration) icon-to-label spacing to the clock
(time-since-created) pair. Use the same Canopy spacing token both pairs use so they
stay in sync if the token changes. Pure layout change; no behavior change.

## Acceptance

- The duration icon sits as close to its time as the clock icon does to its
  relative time.
- Both pairs use the same spacing token.
- No snapshot/logic regressions; suite stays green.
