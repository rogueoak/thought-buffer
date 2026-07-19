# 0021 - Build warnings cleanup + Siri phrase disambiguation

A warnings/cleanup pass: no behavior change. Each warning below is a real Xcode 26.6 build
warning (most flagged as "error in Swift 6 language mode") that is now resolved, verified by
grepping the test build log. Also disambiguates two App Shortcut phrase sets that collided after
the notes -> thoughts rename (task 11 / follow-up).

## Warnings fixed

1. **ThoughtStreamIntents.swift** - "Stored property 'starter' of Sendable-conforming struct
   'StartThoughtStreamIntent' has non-Sendable type 'any SessionStarter'" (same for
   `NewThoughtIntent`).
   Fix: made the `SessionStarter` protocol require `Sendable` (`SessionStarter.swift`). Every
   conformer is already a `@MainActor final class` (`PendingSessionRoute`,
   `ColdStartSessionStarter`, the test `StubStarter`), and a main-actor-isolated class is
   implicitly `Sendable`, so the existential the intents store is now `Sendable` with no code
   change at the conformers. Intent behavior and the DI/test seams are unchanged.

2. **ICloudThoughtStore.swift** - "Stored property 'fileManager' of Sendable-conforming struct
   has non-Sendable type 'FileManager'".
   Fix: changed the stored `private let fileManager = FileManager.default` to a computed
   `private var fileManager: FileManager { .default }`. It was always `FileManager.default`
   (process-wide, thread-safe for the path-based calls here), so resolving it per access is
   equivalent and the struct no longer stores a non-`Sendable` value. Every call site is
   unchanged.

3. **DictationViewModel.swift** - two warnings in `scheduleTrim`'s detached task:
   - "Reference to captured var 'self' in concurrently-executing code" on
     `await MainActor.run { self?.onTrimmed?() }`. Fix: capture `self` explicitly with a nested
     `[weak self]` on the `MainActor.run` closure so the concurrently-executing closure does not
     reference the outer captured `var self`.
   - "Result of 'try?' is unused" on `try? store.save(remappedThought)`. Fix: explicitly discard
     with `_ =` (the background re-save's URL is intentionally dropped; the triggered reload
     reflects it).

4. **ThoughtStoreDriver.swift** - "Expression of type 'URL?' is unused" on
   `try? store.save(thought.withFolderPath(folderPath))` (the last expression of a `Void`
   detached task). Fix: `_ =` discard with a comment (fire-and-forget re-file; the reload
   reflects the move).

5. **SpeechAnalyzerService.swift** - "No 'async' operations occur within 'await' expression" x2 on
   `await self?.handle(result:)` and `await self?.handleResultsFailure(error)`.
   Fix: removed the unnecessary `await`. The enclosing `Task {}` in `beginAnalysis` inherits that
   method's `@MainActor` isolation, so these calls to main-actor methods are same-actor and need
   no hop.

6. **DictationView.swift** - "'+' was deprecated in iOS 26.0: Use string interpolation on Text"
   on the last-paragraph caret. Fix: replaced the `Text(...) + Text("|")` concatenation with a
   single `Text` that interpolates the two styled `Text` values, so the caret keeps its own color
   while the whole line shares one font/layout. Only the deprecated line changed.

7. **Xcode project - "Update to recommended settings".** The recommended build settings (the
   modern `CLANG_WARN_*` set and `ENABLE_USER_SCRIPT_SANDBOXING = YES`) were already emitted by
   XcodeGen; only the `LastUpgradeCheck` marker was stale (1430). Fix: set
   `options.xcodeVersion: "2600"` in `ios/project.yml`, which stamps `LastUpgradeCheck = 2600`
   (Xcode 26) on regenerate. No signing or deployment-target setting changed.

## Out of scope (left as-is)

- `PhoneConnectivityCoordinator.swift` `lock`/`unlock` async-context warnings - not in this pass.
- Four `result of 'try?' is unused` warnings in `DeviceFeedbackFixesTests.swift` - pre-existing
  test-file warnings, not in the listed files; left to avoid touching unrelated tests.
- The SwiftUI "Modifying state during view update" warning - owned by feedback 0020.

## Siri phrase disambiguation (task 11 / follow-up)

After notes -> thoughts, the `NewThoughtIntent` phrase "New thought in <app>" was IDENTICAL to a
phrase on `StartThoughtStreamIntent`, so Siri disambiguated the two intents unpredictably. Fix:
dropped "New thought in" from the start intent's phrase set (and its `startPhraseLeads`), leaving
it to the new-thought intent alone. The start intent keeps "Start a thought stream in / Start a
stream in / Start dictating in"; the new-thought intent keeps "New thought in / Start a thought
in". No phrase is now shared across the two intents; each intent's behavior is unchanged. A test
assertion (`SessionStartTests`) now pins that the two phrase-lead sets are disjoint.

## Verification

- `xcodebuild ... test` on iPhone 17: **TEST SUCCEEDED**, 631 tests, 0 failures.
- Each warning string above greps to zero hits in the test build log for the listed files.
