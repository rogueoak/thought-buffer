import AppIntents

/// Resolves the live starter for an App Intent built by the system. The system constructs App
/// Intents outside the SwiftUI tree, so they cannot receive the route by injection; this reaches it
/// through the `AppDependencies` bridge (which hands back a cold-start latch before the app has
/// resolved, so a cold-launch request is never lost). The system builds and runs intents on the
/// main actor, so `assumeIsolated` is safe here and keeps the stored `starter` non-optional.
private func resolveDefaultStarter() -> SessionStarter {
    MainActor.assumeIsolated { AppDependencies.sessionStarter }
}

/// "Hey Siri, start a stream in Thought Stream." Launches the app and begins a fresh dictation
/// session hands-free - the shippable in-car capability, since Siri works through the phone and
/// through CarPlay's Siri button without needing the (unavailable) CarPlay entitlement.
///
/// `openAppWhenRun` foregrounds the app; `perform()` requests the shared session route, which the
/// root view consumes to open `DictationView` (and begin capture in its `.task`). The intent
/// depends on the `SessionStarter` protocol, resolved from the composition root, so it starts the
/// exact same session the Record button does and stays unit-testable with a stub.
struct StartThoughtStreamIntent: AppIntent {
    static var title: LocalizedStringResource = "Start a Thought Stream"
    static var description = IntentDescription(
        "Open Thought Stream and start a new dictation session, hands-free."
    )

    /// Bring the app to the foreground so the dictation session can open and the microphone can run.
    static var openAppWhenRun: Bool = true

    /// The seam that requests a session start. Non-optional and fully resolved at construction (no
    /// nil-coalescing seam in stored state): the default init resolves the live starter through
    /// `resolveDefaultStarter()`, and tests inject a stub. Not an `@Parameter` - it is a dependency,
    /// never a user-supplied value.
    let starter: SessionStarter

    init() {
        self.starter = resolveDefaultStarter()
    }

    /// Test/DI initializer: inject a stub starter to prove `perform()` requests a start without any
    /// UI or a resolved app.
    init(starter: SessionStarter) {
        self.starter = starter
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        starter.startNewSession()
        return .result()
    }
}

/// "New thought in Thought Stream." A second, cheap entry that starts the same fresh session. In this
/// app a "new thought" and a "new stream" both mean "open a fresh dictation session", so it shares the
/// one starter; the separate phrase just gives Siri and Shortcuts a second natural way in.
struct NewThoughtIntent: AppIntent {
    static var title: LocalizedStringResource = "New Thought"
    static var description = IntentDescription(
        "Open Thought Stream and start a fresh thought by voice."
    )

    static var openAppWhenRun: Bool = true

    /// The seam that requests a session start. Non-optional, resolved at construction via
    /// `resolveDefaultStarter()` (no nil-coalescing seam); tests inject a stub.
    let starter: SessionStarter

    init() {
        self.starter = resolveDefaultStarter()
    }

    init(starter: SessionStarter) {
        self.starter = starter
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        starter.startNewSession()
        return .result()
    }
}

/// Registers the App Shortcuts so the phrases appear in the Shortcuts app and Siri on install. Each
/// phrase includes the app name via `\(.applicationName)`, which Apple requires for every App
/// Shortcut phrase. Friendly variants give Siri several natural ways to trigger the same intent.
///
/// The spoken text is mirrored as testable `static let` arrays (the leading half of each phrase,
/// before the interpolated app name) so a unit test can assert the wording and the app-name
/// contract - `AppShortcut.phrases` itself is not public and the phrase literals below require the
/// `AppShortcutPhrase` builder context, so they cannot be built from these arrays. The literals and
/// the leads must stay in step; the test asserts the leads, and each literal is `"<lead>
/// \(.applicationName)"`.
struct ThoughtStreamShortcuts: AppShortcutsProvider {
    /// The leading text of each "start a stream" phrase; the app name follows in the literal below.
    /// Deliberately share NO exact phrase with `newThoughtPhraseLeads`: "New thought in" belongs to the
    /// new-thought intent alone, so Siri never has to disambiguate an identical phrase between the two.
    static let startPhraseLeads = [
        "Start a thought stream in",
        "Start a stream in",
        "Start dictating in"
    ]

    /// The leading text of each "new thought" phrase; the app name follows in the literal below. Kept
    /// distinct from `startPhraseLeads` so no phrase is shared across the two intents.
    static let newThoughtPhraseLeads = [
        "New thought in",
        "Start a thought in"
    ]

    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: StartThoughtStreamIntent(),
            phrases: [
                "Start a thought stream in \(.applicationName)",
                "Start a stream in \(.applicationName)",
                "Start dictating in \(.applicationName)"
            ],
            shortTitle: "Start a Stream",
            systemImageName: "waveform"
        )
        AppShortcut(
            intent: NewThoughtIntent(),
            phrases: [
                "New thought in \(.applicationName)",
                "Start a thought in \(.applicationName)"
            ],
            shortTitle: "New Thought",
            systemImageName: "mic.fill"
        )
    }
}
