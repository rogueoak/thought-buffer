import AppIntents

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

    /// The seam that requests a session start. Defaults to the live route from the composition root;
    /// tests inject a stub. Not an `@Parameter` - it is a dependency, never a user-supplied value.
    let starter: SessionStarter?

    init() {
        self.starter = nil
    }

    /// Test/DI initializer: inject a stub starter to prove `perform()` requests a start without any
    /// UI or a resolved app.
    init(starter: SessionStarter) {
        self.starter = starter
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        // The injected starter wins (tests); otherwise reach the live route from the composition
        // root, which App Intents cannot receive by injection since the system builds them outside
        // the SwiftUI tree.
        (starter ?? AppDependencies.sessionStarter)?.startNewSession()
        return .result()
    }
}

/// "New note in Thought Stream." A second, cheap entry that starts the same fresh session. In this
/// app a "new note" and a "new stream" both mean "open a fresh dictation session", so it shares the
/// one starter; the separate phrase just gives Siri and Shortcuts a second natural way in.
struct NewNoteIntent: AppIntent {
    static var title: LocalizedStringResource = "New Note"
    static var description = IntentDescription(
        "Open Thought Stream and start a fresh note by voice."
    )

    static var openAppWhenRun: Bool = true

    let starter: SessionStarter?

    init() {
        self.starter = nil
    }

    init(starter: SessionStarter) {
        self.starter = starter
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        (starter ?? AppDependencies.sessionStarter)?.startNewSession()
        return .result()
    }
}

/// Registers the App Shortcuts so the phrases appear in the Shortcuts app and Siri on install. Each
/// phrase includes the app name via `\(.applicationName)`, which Apple requires for every App
/// Shortcut phrase. Friendly variants give Siri several natural ways to trigger the same intent.
struct ThoughtStreamShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: StartThoughtStreamIntent(),
            phrases: [
                "Start a thought stream in \(.applicationName)",
                "Start a stream in \(.applicationName)",
                "Start dictating in \(.applicationName)",
                "New thought in \(.applicationName)"
            ],
            shortTitle: "Start a Stream",
            systemImageName: "waveform"
        )
        AppShortcut(
            intent: NewNoteIntent(),
            phrases: [
                "New note in \(.applicationName)",
                "Start a note in \(.applicationName)"
            ],
            shortTitle: "New Note",
            systemImageName: "mic.fill"
        )
    }
}
